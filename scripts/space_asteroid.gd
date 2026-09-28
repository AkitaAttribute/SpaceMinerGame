class_name SpaceAsteroid
extends AnimatableBody3D

const GRID_SIZE := 20
const GRID_HEIGHT := 2
const CELL_SIZE := 1.0

var asteroid_id := ""
var spin_axis := Vector3.UP
var spin_speed := 0.03
var base_color := Color("#6e7783")

var _cells: Array[Vector3i] = []
var _colors: Dictionary = {}
var _visual: MultiMeshInstance3D
var _collision_shape: CollisionShape3D


func configure(id_value: String, world_position: Vector3, seed_value: int) -> void:
    asteroid_id = id_value
    global_position = world_position

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

    _cells.clear()
    _colors.clear()

    var half := int(GRID_SIZE / 2)
    var half_height := int(GRID_HEIGHT / 2)
    for y in range(-half_height, half_height):
        for x in range(-half, half):
            for z in range(-half, half):
                var cell := Vector3i(x, y, z)
                _cells.append(cell)

                var variation := rng.randf_range(-0.075, 0.075)
                _colors[_cell_key(cell)] = Color(
                    clampf(base_color.r + variation, 0.0, 1.0),
                    clampf(base_color.g + variation, 0.0, 1.0),
                    clampf(base_color.b + variation, 0.0, 1.0)
                )

    _build_visual()
    _build_collision()


func update_spin(delta: float) -> void:
    rotate(spin_axis, spin_speed * delta)


func closest_cell_world(from_world: Vector3) -> Vector3:
    if _cells.is_empty():
        return global_position

    var best_position := global_position
    var best_distance := INF
    for cell in _cells:
        var world_position := to_global(_cell_center(cell))
        var distance := world_position.distance_squared_to(from_world)
        if distance < best_distance:
            best_distance = distance
            best_position = world_position
    return best_position


func distance_to_surface(from_world: Vector3) -> float:
    return from_world.distance_to(closest_cell_world(from_world))


func detach_closest_cell(from_world: Vector3) -> Dictionary:
    if _cells.is_empty():
        return {}

    var best_index := -1
    var best_distance := INF
    var best_world_position := global_position

    for index in range(_cells.size()):
        var cell := _cells[index]
        if not _is_outer_cell(cell):
            continue

        var world_position := to_global(_cell_center(cell))
        var distance := world_position.distance_squared_to(from_world)
        if distance < best_distance:
            best_distance = distance
            best_index = index
            best_world_position = world_position

    if best_index < 0:
        return {}

    var cell := _cells[best_index]
    var color: Color = _colors.get(_cell_key(cell), base_color)
    _cells.remove_at(best_index)
    _colors.erase(_cell_key(cell))
    _rebuild_multimesh()

    return {
        "position": best_world_position,
        "color": color,
        "cell": cell,
    }


func has_cells() -> bool:
    return not _cells.is_empty()


func _is_outer_cell(cell: Vector3i) -> bool:
    var half := int(GRID_SIZE / 2)
    var half_height := int(GRID_HEIGHT / 2)
    return (
        cell.x == -half
        or cell.x == half - 1
        or cell.z == -half
        or cell.z == half - 1
        or cell.y == -half_height
        or cell.y == half_height - 1
    )


func _cell_center(cell: Vector3i) -> Vector3:
    return Vector3(
        float(cell.x) + 0.5,
        float(cell.y) + 0.5,
        float(cell.z) + 0.5
    ) * CELL_SIZE


func _cell_key(cell: Vector3i) -> String:
    return "%d,%d,%d" % [cell.x, cell.y, cell.z]


func _build_visual() -> void:
    _visual = MultiMeshInstance3D.new()
    _visual.name = "AsteroidGrid"
    add_child(_visual)

    var cube := BoxMesh.new()
    cube.size = Vector3.ONE * 0.94

    var material := StandardMaterial3D.new()
    material.vertex_color_use_as_albedo = true
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.roughness = 1.0
    cube.material = material

    var multimesh := MultiMesh.new()
    multimesh.transform_format = MultiMesh.TRANSFORM_3D
    multimesh.use_colors = true
    multimesh.mesh = cube
    _visual.multimesh = multimesh

    _rebuild_multimesh()


func _rebuild_multimesh() -> void:
    if _visual == null or _visual.multimesh == null:
        return

    var multimesh := _visual.multimesh
    multimesh.instance_count = _cells.size()

    for index in range(_cells.size()):
        var cell := _cells[index]
        multimesh.set_instance_transform(
            index,
            Transform3D(Basis.IDENTITY, _cell_center(cell))
        )
        multimesh.set_instance_color(
            index,
            _colors.get(_cell_key(cell), base_color)
        )


func _build_collision() -> void:
    _collision_shape = CollisionShape3D.new()
    var shape := BoxShape3D.new()
    shape.size = Vector3(
        float(GRID_SIZE),
        float(GRID_HEIGHT),
        float(GRID_SIZE)
    )
    _collision_shape.shape = shape
    add_child(_collision_shape)
