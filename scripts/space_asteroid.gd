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
var _collision_shape: CollisionShape3D


func configure(id_value: String, world_position: Vector3, seed_value: int) -> void:
    asteroid_id = id_value
    global_position = world_position
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

    # Mining is the only time the asteroid mesh changes. Rebuild one combined
    # exterior mesh after removing the voxel; there are never 8,000 cube
    # MeshInstances/MultiMesh instances being rendered or rotated.
    _rebuild_surface()

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
    _collision_shape = CollisionShape3D.new()

    # Collision stays deliberately coarse: one body-sized box rather than
    # thousands of per-voxel collision shapes. Mining a one-cell notch does not
    # justify rebuilding physics geometry every five seconds.
    var shape := BoxShape3D.new()
    shape.size = Vector3(
        float(GRID_SIZE),
        float(GRID_HEIGHT),
        float(GRID_SIZE)
    )
    _collision_shape.shape = shape
    add_child(_collision_shape)
