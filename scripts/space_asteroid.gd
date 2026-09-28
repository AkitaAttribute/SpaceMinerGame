class_name SpaceAsteroid
extends AnimatableBody3D

const GRID_SIZE := 20
const GRID_HEIGHT := 20
const CELL_SIZE := 1.0
const TOTAL_CELLS := GRID_SIZE * GRID_HEIGHT * GRID_SIZE

const FACE_DIRECTIONS: Array[Vector3i] = [
    Vector3i(1, 0, 0),
    Vector3i(-1, 0, 0),
    Vector3i(0, 1, 0),
    Vector3i(0, -1, 0),
    Vector3i(0, 0, 1),
    Vector3i(0, 0, -1),
]

var asteroid_id := ""
var spin_axis := Vector3.UP
var spin_speed := 0.03
var base_color := Color("#6e7783")

var _seed := 0
var _removed_cells: Dictionary = {}
var _surface_cells: Array[Vector3i] = []
var _remaining_cells := TOTAL_CELLS
var _visual: MeshInstance3D
var _collision_shapes: Array[CollisionShape3D] = []
var _collision_boxes: Array[AABB] = []
var _debug_hitboxes_visible := false
var _debug_hitbox_root: Node3D


func configure(id_value: String, world_position: Vector3, seed_value: int) -> void:
    asteroid_id = id_value
    position = world_position
    _seed = seed_value
    _removed_cells.clear()
    _surface_cells.clear()
    _remaining_cells = TOTAL_CELLS

    var rng := RandomNumberGenerator.new()
    rng.seed = seed_value

    spin_axis = Vector3(
        rng.randf_range(-1.0, 1.0),
        rng.randf_range(-1.0, 1.0),
        rng.randf_range(-1.0, 1.0)
    )
    if spin_axis.length_squared() < 0.05:
        spin_axis = Vector3(0.25, 1.0, -0.15)
    spin_axis = spin_axis.normalized()
    spin_speed = rng.randf_range(0.012, 0.032)

    var palette := [
        Color("#6e7783"),
        Color("#756b63"),
        Color("#646f72"),
        Color("#7a7061"),
    ]
    base_color = palette[rng.randi_range(0, palette.size() - 1)]

    _build_visual()
    _build_collision()
    _rebuild_surface()


func update_spin(delta: float) -> void:
    # The asteroid is one MeshInstance3D under one rotating body. Individual
    # voxel cells are not rendered or rotated as separate objects/instances.
    rotate(spin_axis, spin_speed * delta)


func closest_cell_world(from_world: Vector3) -> Vector3:
    if _surface_cells.is_empty():
        return global_position

    var best_position := global_position
    var best_distance := INF
    for cell in _surface_cells:
        var world_position := to_global(_cell_center(cell))
        var distance := world_position.distance_squared_to(from_world)
        if distance < best_distance:
            best_distance = distance
            best_position = world_position
    return best_position


func distance_from_world_cell_to_hitbox(
    cell_center_world: Vector3,
    cell_basis_world: Basis,
    cell_half_extent := 0.5
) -> float:
    if _collision_boxes.is_empty():
        return INF

    # Collision is represented by merged boxes made only from occupied cells.
    # Measure against the nearest of those boxes, then subtract the support
    # radius of the laser's 1x1x1 builder cell in the separation direction.
    var center_local := to_local(cell_center_world)
    var cell_basis := cell_basis_world.orthonormalized()
    var best_distance := INF

    for box in _collision_boxes:
        var nearest_local := Vector3(
            clampf(center_local.x, box.position.x, box.end.x),
            clampf(center_local.y, box.position.y, box.end.y),
            clampf(center_local.z, box.position.z, box.end.z)
        )
        var separation_local := center_local - nearest_local
        var center_distance := separation_local.length()

        if center_distance <= 0.000001:
            return 0.0

        var separation_world := (
            global_basis * separation_local.normalized()
        ).normalized()
        var cell_support := cell_half_extent * (
            absf(separation_world.dot(cell_basis.x))
            + absf(separation_world.dot(cell_basis.y))
            + absf(separation_world.dot(cell_basis.z))
        )
        best_distance = minf(
            best_distance,
            maxf(0.0, center_distance - cell_support)
        )

    return best_distance


func distance_to_surface(from_world: Vector3) -> float:
    if _surface_cells.is_empty():
        return INF

    # Measure to the actual exterior of the asteroid's voxel surface, not to
    # the asteroid center and not to the center of the nearest surface cell.
    # Transform into asteroid-local space so the randomized body rotation does
    # not complicate the box-distance calculation.
    var local_from := to_local(from_world)
    var best_distance_squared := INF
    var half_cell := Vector3.ONE * (CELL_SIZE * 0.5)

    for cell in _surface_cells:
        var center := _cell_center(cell)
        var minimum := center - half_cell
        var maximum := center + half_cell
        var closest := Vector3(
            clampf(local_from.x, minimum.x, maximum.x),
            clampf(local_from.y, minimum.y, maximum.y),
            clampf(local_from.z, minimum.z, maximum.z)
        )
        best_distance_squared = minf(
            best_distance_squared,
            local_from.distance_squared_to(closest)
        )

    return sqrt(best_distance_squared)


func detach_closest_cell(from_world: Vector3) -> Dictionary:
    if _surface_cells.is_empty():
        return {}

    var best_cell := Vector3i.ZERO
    var found := false
    var best_distance := INF
    var best_world_position := global_position

    for cell in _surface_cells:
        var world_position := to_global(_cell_center(cell))
        var distance := world_position.distance_squared_to(from_world)
        if distance < best_distance:
            best_distance = distance
            best_cell = cell
            best_world_position = world_position
            found = true

    if not found:
        return {}

    var color := _cell_color(best_cell)
    _removed_cells[_cell_key(best_cell)] = true
    _remaining_cells = maxi(0, _remaining_cells - 1)

    # Mining is the only time the asteroid geometry changes. Rebuild both the
    # one combined exterior mesh and the merged collision cuboids so physics
    # matches the visible missing cell without creating thousands of shapes.
    _rebuild_surface()
    _rebuild_collision()

    return {
        "position": best_world_position,
        "color": color,
        "cell": best_cell,
    }


func has_cells() -> bool:
    return _remaining_cells > 0


func _cell_center(cell: Vector3i) -> Vector3:
    return Vector3(
        float(cell.x) + 0.5,
        float(cell.y) + 0.5,
        float(cell.z) + 0.5
    ) * CELL_SIZE


func _cell_key(cell: Vector3i) -> String:
    return "%d,%d,%d" % [cell.x, cell.y, cell.z]


func _is_in_bounds(cell: Vector3i) -> bool:
    var half := int(GRID_SIZE / 2)
    var half_height := int(GRID_HEIGHT / 2)
    return (
        cell.x >= -half
        and cell.x < half
        and cell.y >= -half_height
        and cell.y < half_height
        and cell.z >= -half
        and cell.z < half
    )


func _is_occupied(cell: Vector3i) -> bool:
    return _is_in_bounds(cell) and not _removed_cells.has(_cell_key(cell))


func _is_surface_cell(cell: Vector3i) -> bool:
    if not _is_occupied(cell):
        return false

    for direction in FACE_DIRECTIONS:
        if not _is_occupied(cell + direction):
            return true
    return false


func _cell_color(cell: Vector3i) -> Color:
    # Deterministic per-cell variation without storing 8,000 Color objects.
    var key := "%d:%d:%d:%d" % [_seed, cell.x, cell.y, cell.z]
    var hashed: int = int(abs(hash(key)))
    var normalized := float(hashed % 1000) / 999.0
    var variation := lerpf(-0.075, 0.075, normalized)
    return Color(
        clampf(base_color.r + variation, 0.0, 1.0),
        clampf(base_color.g + variation, 0.0, 1.0),
        clampf(base_color.b + variation, 0.0, 1.0),
        1.0
    )


func _build_visual() -> void:
    _visual = MeshInstance3D.new()
    _visual.name = "AsteroidSurface"
    _visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    add_child(_visual)


func _rebuild_surface() -> void:
    _surface_cells.clear()

    var half := int(GRID_SIZE / 2)
    var half_height := int(GRID_HEIGHT / 2)

    for y in range(-half_height, half_height):
        for x in range(-half, half):
            for z in range(-half, half):
                var cell := Vector3i(x, y, z)
                if _is_surface_cell(cell):
                    _surface_cells.append(cell)

    var surface := SurfaceTool.new()
    surface.begin(Mesh.PRIMITIVE_TRIANGLES)

    for cell in _surface_cells:
        var center := _cell_center(cell)
        var color := _cell_color(cell)

        for direction in FACE_DIRECTIONS:
            if not _is_occupied(cell + direction):
                _append_exposed_face(surface, center, direction, color)

    var mesh := surface.commit()

    var material := StandardMaterial3D.new()
    material.vertex_color_use_as_albedo = true
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.roughness = 1.0
    material.cull_mode = BaseMaterial3D.CULL_DISABLED
    mesh.surface_set_material(0, material)

    _visual.mesh = mesh


func _append_exposed_face(
    surface: SurfaceTool,
    center: Vector3,
    direction: Vector3i,
    color: Color
) -> void:
    var half_cell := CELL_SIZE * 0.5
    var a := Vector3.ZERO
    var b := Vector3.ZERO
    var c := Vector3.ZERO
    var d := Vector3.ZERO

    match direction:
        Vector3i(1, 0, 0):
            a = center + Vector3(half_cell, -half_cell, -half_cell)
            b = center + Vector3(half_cell, half_cell, -half_cell)
            c = center + Vector3(half_cell, half_cell, half_cell)
            d = center + Vector3(half_cell, -half_cell, half_cell)
        Vector3i(-1, 0, 0):
            a = center + Vector3(-half_cell, -half_cell, half_cell)
            b = center + Vector3(-half_cell, half_cell, half_cell)
            c = center + Vector3(-half_cell, half_cell, -half_cell)
            d = center + Vector3(-half_cell, -half_cell, -half_cell)
        Vector3i(0, 1, 0):
            a = center + Vector3(-half_cell, half_cell, -half_cell)
            b = center + Vector3(-half_cell, half_cell, half_cell)
            c = center + Vector3(half_cell, half_cell, half_cell)
            d = center + Vector3(half_cell, half_cell, -half_cell)
        Vector3i(0, -1, 0):
            a = center + Vector3(-half_cell, -half_cell, half_cell)
            b = center + Vector3(-half_cell, -half_cell, -half_cell)
            c = center + Vector3(half_cell, -half_cell, -half_cell)
            d = center + Vector3(half_cell, -half_cell, half_cell)
        Vector3i(0, 0, 1):
            a = center + Vector3(half_cell, -half_cell, half_cell)
            b = center + Vector3(half_cell, half_cell, half_cell)
            c = center + Vector3(-half_cell, half_cell, half_cell)
            d = center + Vector3(-half_cell, -half_cell, half_cell)
        Vector3i(0, 0, -1):
            a = center + Vector3(-half_cell, -half_cell, -half_cell)
            b = center + Vector3(-half_cell, half_cell, -half_cell)
            c = center + Vector3(half_cell, half_cell, -half_cell)
            d = center + Vector3(half_cell, -half_cell, -half_cell)
        _:
            return

    _append_triangle(surface, a, b, c, color)
    _append_triangle(surface, a, c, d, color)


func _append_triangle(
    surface: SurfaceTool,
    a: Vector3,
    b: Vector3,
    c: Vector3,
    color: Color
) -> void:
    surface.set_color(color)
    surface.add_vertex(a)
    surface.set_color(color)
    surface.add_vertex(b)
    surface.set_color(color)
    surface.add_vertex(c)


func _build_collision() -> void:
    _rebuild_collision()


func _rebuild_collision() -> void:
    # The visual is voxel-based, but using one CollisionShape3D per occupied
    # cell would mean as many as 8,000 physics shapes. Instead greedily merge
    # adjacent occupied cells into larger axis-aligned cuboids. A pristine
    # asteroid is exactly one box; mined notches add only the boxes needed to
    # describe the remaining solid volume.
    for collision_shape in _collision_shapes:
        if collision_shape != null and is_instance_valid(collision_shape):
            if collision_shape.get_parent() == self:
                remove_child(collision_shape)
            collision_shape.queue_free()

    _collision_shapes.clear()
    _collision_boxes.clear()

    var visited: Dictionary = {}
    var half := int(GRID_SIZE / 2)
    var half_height := int(GRID_HEIGHT / 2)

    for y in range(-half_height, half_height):
        for z in range(-half, half):
            for x in range(-half, half):
                var start := Vector3i(x, y, z)
                if not _collision_cell_available(start, visited):
                    continue

                var size_x := 1
                while (
                    x + size_x < half
                    and _collision_cell_available(
                        Vector3i(x + size_x, y, z),
                        visited
                    )
                ):
                    size_x += 1

                var size_z := 1
                while z + size_z < half:
                    var z_clear := true
                    for check_x in range(x, x + size_x):
                        if not _collision_cell_available(
                            Vector3i(check_x, y, z + size_z),
                            visited
                        ):
                            z_clear = false
                            break
                    if not z_clear:
                        break
                    size_z += 1

                var size_y := 1
                while y + size_y < half_height:
                    var y_clear := true
                    for check_z in range(z, z + size_z):
                        for check_x in range(x, x + size_x):
                            if not _collision_cell_available(
                                Vector3i(check_x, y + size_y, check_z),
                                visited
                            ):
                                y_clear = false
                                break
                        if not y_clear:
                            break
                    if not y_clear:
                        break
                    size_y += 1

                for mark_y in range(y, y + size_y):
                    for mark_z in range(z, z + size_z):
                        for mark_x in range(x, x + size_x):
                            visited[_cell_key(
                                Vector3i(mark_x, mark_y, mark_z)
                            )] = true

                var box := AABB(
                    Vector3(float(x), float(y), float(z)) * CELL_SIZE,
                    Vector3(
                        float(size_x),
                        float(size_y),
                        float(size_z)
                    ) * CELL_SIZE
                )
                _collision_boxes.append(box)

                var box_shape := BoxShape3D.new()
                box_shape.size = box.size

                var collision_shape := CollisionShape3D.new()
                collision_shape.shape = box_shape
                collision_shape.position = box.position + box.size * 0.5
                add_child(collision_shape)
                _collision_shapes.append(collision_shape)

    _rebuild_debug_hitboxes()


func set_debug_hitboxes_visible(value: bool) -> void:
    _debug_hitboxes_visible = value
    _rebuild_debug_hitboxes()


func _rebuild_debug_hitboxes() -> void:
    if _debug_hitbox_root != null and is_instance_valid(_debug_hitbox_root):
        _debug_hitbox_root.queue_free()
        _debug_hitbox_root = null

    if not _debug_hitboxes_visible:
        return

    _debug_hitbox_root = Node3D.new()
    _debug_hitbox_root.name = "DebugHitboxes"
    add_child(_debug_hitbox_root)

    for box in _collision_boxes:
        var mesh := BoxMesh.new()
        mesh.size = box.size

        var material := StandardMaterial3D.new()
        material.albedo_color = Color(1.0, 0.35, 0.08, 0.16)
        material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
        material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
        material.no_depth_test = true
        material.cull_mode = BaseMaterial3D.CULL_DISABLED
        mesh.material = material

        var instance := MeshInstance3D.new()
        instance.mesh = mesh
        instance.position = box.position + box.size * 0.5
        instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        _debug_hitbox_root.add_child(instance)


func _collision_cell_available(
    cell: Vector3i,
    visited: Dictionary
) -> bool:
    return (
        _is_occupied(cell)
        and not visited.has(_cell_key(cell))
    )
