class_name PartFactory
extends RefCounted

const DEFAULT_PART_COLOR := DEFAULT_PART_COLOR

const PARTS := [
    {
        "id": "cube",
        "name": "Cube",
        "slots": ["Hull"],
        "defaults": [DEFAULT_PART_COLOR],
    },
    {
        "id": "half_sphere",
        "name": "Half Sphere",
        "slots": ["Hull"],
        "defaults": [DEFAULT_PART_COLOR],
    },
    {
        "id": "pyramid",
        "name": "Pyramid",
        "slots": ["Hull"],
        "defaults": [DEFAULT_PART_COLOR],
    },
    {
        "id": "small_slope",
        "name": "Small Slope",
        "slots": ["Hull"],
        "defaults": [DEFAULT_PART_COLOR],
    },
    {
        "id": "roof",
        "name": "Even Roof",
        "slots": ["Left", "Right"],
        "defaults": [DEFAULT_PART_COLOR, DEFAULT_PART_COLOR],
    },
    {
        "id": "large_slope",
        "name": "Large Slope",
        "slots": ["Hull"],
        "defaults": [DEFAULT_PART_COLOR],
    },
]

static func part_count() -> int:
    return PARTS.size()

static func get_definition(index: int) -> Dictionary:
    return PARTS[clampi(index, 0, PARTS.size() - 1)]

static func create_part(index: int, colors: Array[Color], ghost := false) -> Node3D:
    var definition := get_definition(index)
    var root := Node3D.new()
    root.name = str(definition["name"]).replace(" ", "")
    root.set_meta("part_index", index)

    match str(definition["id"]):
        "cube":
            _add_box(root, Vector3.ONE, colors[0], ghost)
        "half_sphere":
            _add_mesh(root, _hemisphere_mesh(), colors[0], ghost)
        "pyramid":
            _add_mesh(root, _pyramid_mesh(), colors[0], ghost)
        "small_slope":
            _add_mesh(root, _wedge_mesh(1.0, 0.52), colors[0], ghost)
        "roof":
            _add_roof(root, colors, ghost)
        "large_slope":
            _add_mesh(root, _wedge_mesh(1.0, 1.0), colors[0], ghost)
        _:
            _add_box(root, Vector3.ONE, colors[0], ghost)

    return root

static func default_colors(index: int) -> Array[Color]:
    var definition := get_definition(index)
    var result: Array[Color] = []
    for value in definition["defaults"]:
        result.append(value as Color)
    return result

static func color_slot_names(index: int) -> Array[String]:
    var definition := get_definition(index)
    var result: Array[String] = []
    for value in definition["slots"]:
        result.append(str(value))
    return result

static func _add_box(root: Node3D, size: Vector3, color: Color, ghost: bool) -> void:
    var mesh := BoxMesh.new()
    mesh.size = size
    var instance := MeshInstance3D.new()
    instance.mesh = mesh
    instance.material_override = _material(color, ghost)
    root.add_child(instance)

static func _add_mesh(root: Node3D, mesh: Mesh, color: Color, ghost: bool) -> void:
    var instance := MeshInstance3D.new()
    instance.mesh = mesh
    instance.material_override = _material(color, ghost)
    root.add_child(instance)

static func _add_roof(root: Node3D, colors: Array[Color], ghost: bool) -> void:
    var left_mesh := BoxMesh.new()
    left_mesh.size = Vector3(0.68, 0.12, 0.96)
    var left := MeshInstance3D.new()
    left.mesh = left_mesh
    left.position = Vector3(-0.24, 0.18, 0.0)
    left.rotation_degrees.z = -45.0
    left.material_override = _material(colors[0], ghost)
    root.add_child(left)

    var right_mesh := BoxMesh.new()
    right_mesh.size = Vector3(0.68, 0.12, 0.96)
    var right := MeshInstance3D.new()
    right.mesh = right_mesh
    right.position = Vector3(0.24, 0.18, 0.0)
    right.rotation_degrees.z = 45.0
    right.material_override = _material(colors[1] if colors.size() > 1 else colors[0], ghost)
    root.add_child(right)

static func _material(color: Color, ghost: bool) -> StandardMaterial3D:
    var material := StandardMaterial3D.new()
    var final_color := color
    if ghost:
        final_color.a = 0.48
        material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
        material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.albedo_color = final_color
    material.metallic = 0.12
    material.roughness = 0.48
    return material

static func _pyramid_mesh() -> ArrayMesh:
    var a := Vector3(-0.5, -0.5, -0.5)
    var b := Vector3(0.5, -0.5, -0.5)
    var c := Vector3(0.5, -0.5, 0.5)
    var d := Vector3(-0.5, -0.5, 0.5)
    var top := Vector3(0.0, 0.5, 0.0)
    var vertices := PackedVector3Array([
        a, b, top,
        b, c, top,
        c, d, top,
        d, a, top,
        a, d, c,
        a, c, b,
    ])
    return _mesh_from_triangles(vertices)

static func _wedge_mesh(length: float, height: float) -> ArrayMesh:
    var z0 := -length * 0.5
    var z1 := length * 0.5
    var y0 := -0.5
    var y1 := y0 + height
    var a := Vector3(-0.5, y0, z0)
    var b := Vector3(0.5, y0, z0)
    var c := Vector3(0.5, y0, z1)
    var d := Vector3(-0.5, y0, z1)
    var e := Vector3(-0.5, y1, z1)
    var f := Vector3(0.5, y1, z1)
    var vertices := PackedVector3Array([
        a, d, c, a, c, b,
        a, b, f, a, f, e,
        d, e, f, d, f, c,
        a, e, d,
        a, f, e, a, b, f,
        b, c, f,
    ])
    return _mesh_from_triangles(vertices)

static func _hemisphere_mesh() -> ArrayMesh:
    var vertices := PackedVector3Array()
    var segments := 20
    var rings := 8
    var radius := 0.5
    var plane_y := -0.5

    for ring in range(rings):
        var theta0 := (PI * 0.5) * float(ring) / float(rings)
        var theta1 := (PI * 0.5) * float(ring + 1) / float(rings)
        for segment in range(segments):
            var phi0 := TAU * float(segment) / float(segments)
            var phi1 := TAU * float(segment + 1) / float(segments)
            var p00 := _hemisphere_point(theta0, phi0, radius, plane_y)
            var p01 := _hemisphere_point(theta0, phi1, radius, plane_y)
            var p10 := _hemisphere_point(theta1, phi0, radius, plane_y)
            var p11 := _hemisphere_point(theta1, phi1, radius, plane_y)
            vertices.append_array(PackedVector3Array([p00, p10, p11, p00, p11, p01]))

    var center := Vector3(0.0, plane_y, 0.0)
    for segment in range(segments):
        var phi0 := TAU * float(segment) / float(segments)
        var phi1 := TAU * float(segment + 1) / float(segments)
        var p0 := Vector3(cos(phi0) * radius, plane_y, sin(phi0) * radius)
        var p1 := Vector3(cos(phi1) * radius, plane_y, sin(phi1) * radius)
        vertices.append_array(PackedVector3Array([center, p1, p0]))

    return _mesh_from_triangles(vertices)

static func _hemisphere_point(theta: float, phi: float, radius: float, plane_y: float) -> Vector3:
    var ring_radius := cos(theta) * radius
    return Vector3(
        cos(phi) * ring_radius,
        plane_y + sin(theta) * radius,
        sin(phi) * ring_radius
    )

static func _mesh_from_triangles(vertices: PackedVector3Array) -> ArrayMesh:
    var surface := SurfaceTool.new()
    surface.begin(Mesh.PRIMITIVE_TRIANGLES)
    for vertex in vertices:
        surface.add_vertex(vertex)
    surface.generate_normals()
    return surface.commit()
