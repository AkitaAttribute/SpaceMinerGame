class_name PartFactory
extends RefCounted

const DEFAULT_PART_COLOR := Color("#5f83c6")
const THRUSTER_CONE_COLOR := Color("#25282f")

const PARTS := [
    {
        "id": "cube",
        "name": "Cube",
        "slots": ["Hull"],
        "defaults": [DEFAULT_PART_COLOR],
        "rotation_reference": Vector3(0.0, -1.0, 0.0),
    },
    {
        "id": "half_sphere",
        "name": "Half Sphere",
        "slots": ["Hull"],
        "defaults": [DEFAULT_PART_COLOR],
        "rotation_reference": Vector3(0.0, -1.0, 0.0),
    },
    {
        "id": "pyramid",
        "name": "Pyramid",
        "slots": ["Hull"],
        "defaults": [DEFAULT_PART_COLOR],
        "rotation_reference": Vector3(0.0, -1.0, 0.0),
    },
    {
        "id": "small_slope",
        "name": "Small Slope",
        "slots": ["Hull"],
        "defaults": [DEFAULT_PART_COLOR],
        "rotation_reference": Vector3(0.0, -1.0, 0.0),
    },
    {
        "id": "roof",
        "name": "Even Roof",
        "slots": ["Left", "Right"],
        "defaults": [DEFAULT_PART_COLOR, DEFAULT_PART_COLOR],
        "rotation_reference": Vector3(0.0, -1.0, 0.0),
    },
    {
        "id": "large_slope",
        "name": "Large Slope",
        "slots": ["Hull"],
        "defaults": [DEFAULT_PART_COLOR],
        "rotation_reference": Vector3(0.0, -1.0, 0.0),
    },
    {
        "id": "color_tool",
        "name": "Color Tool",
        "slots": ["Paint"],
        "defaults": [DEFAULT_PART_COLOR],
        "tool": true,
    },
    {
        "id": "thruster_t1",
        "name": "Tier 1 Thruster",
        "slots": ["Thruster Cone"],
        "defaults": [THRUSTER_CONE_COLOR],
        "rotation_reference": Vector3(0.0, 0.0, -1.0),
        "functional": true,
    },
    {
        "id": "thruster_t2",
        "name": "Tier 2 Thruster",
        "slots": ["Thruster Cone", "Fuel Body"],
        "defaults": [THRUSTER_CONE_COLOR, DEFAULT_PART_COLOR],
        "rotation_reference": Vector3(0.0, 0.0, -1.0),
        "functional": true,
    },
]

static func part_count() -> int:
    return PARTS.size()

static func get_definition(index: int) -> Dictionary:
    return PARTS[clampi(index, 0, PARTS.size() - 1)]

static func get_part_index_by_id(part_id: String) -> int:
    for index in range(PARTS.size()):
        if str(PARTS[index]["id"]) == part_id:
            return index
    return -1

static func rotation_reference_normal(index: int) -> Vector3:
    var definition := get_definition(index)
    var value = definition.get("rotation_reference", Vector3(0.0, 0.0, -1.0))
    if value is Vector3:
        return (value as Vector3).normalized()
    return Vector3(0.0, 0.0, -1.0)

static func is_color_tool(index: int) -> bool:
    return str(get_definition(index)["id"]) == "color_tool"

static func is_placeable(index: int) -> bool:
    return not bool(get_definition(index).get("tool", false))

static func occupied_offsets(index: int) -> Array[Vector3i]:
    var result: Array[Vector3i] = [Vector3i.ZERO]
    if str(get_definition(index)["id"]) == "thruster_t2":
        result.append(Vector3i(0, 1, 0))
    return result

static func create_part(index: int, colors: Array[Color], ghost := false) -> Node3D:
    var definition := get_definition(index)
    var root := Node3D.new()
    root.name = str(definition["name"]).replace(" ", "")
    root.set_meta("part_index", index)

    match str(definition["id"]):
        "cube":
            _add_box(root, Vector3.ONE, colors[0], ghost, 0)
        "half_sphere":
            _add_mesh(root, _hemisphere_mesh(), colors[0], ghost, 0)
        "pyramid":
            _add_mesh(root, _pyramid_mesh(), colors[0], ghost, 0)
        "small_slope":
            _add_mesh(root, _wedge_mesh(1.0, 0.52), colors[0], ghost, 0)
        "roof":
            _add_roof(root, colors, ghost)
        "large_slope":
            _add_mesh(root, _wedge_mesh(1.0, 1.0), colors[0], ghost, 0)
        "thruster_t1":
            _add_thruster_tier_1(root, colors, ghost)
        "thruster_t2":
            _add_thruster_tier_2(root, colors, ghost)
        "color_tool":
            pass
        _:
            _add_box(root, Vector3.ONE, colors[0], ghost, 0)

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

static func apply_colors(root: Node, colors: Array[Color], ghost := false) -> void:
    if root is MeshInstance3D:
        var instance := root as MeshInstance3D
        if instance.has_meta("color_slot"):
            var slot := int(instance.get_meta("color_slot"))
            if slot >= 0 and slot < colors.size():
                var double_sided := bool(instance.get_meta("double_sided", false))
                instance.material_override = _material(colors[slot], ghost, double_sided)
    for child in root.get_children():
        apply_colors(child, colors, ghost)

static func _add_box(
    root: Node3D,
    size: Vector3,
    color: Color,
    ghost: bool,
    color_slot: int
) -> void:
    var mesh := BoxMesh.new()
    mesh.size = size
    _add_mesh(root, mesh, color, ghost, color_slot)

static func _add_mesh(
    root: Node3D,
    mesh: Mesh,
    color: Color,
    ghost: bool,
    color_slot: int,
    position_value := Vector3.ZERO,
    rotation_degrees_value := Vector3.ZERO,
    double_sided := false
) -> MeshInstance3D:
    var instance := MeshInstance3D.new()
    instance.mesh = mesh
    instance.position = position_value
    instance.rotation_degrees = rotation_degrees_value
    instance.material_override = _material(color, ghost, double_sided)
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    instance.set_meta("color_slot", color_slot)
    instance.set_meta("double_sided", double_sided)
    root.add_child(instance)
    return instance

static func _add_roof(root: Node3D, colors: Array[Color], ghost: bool) -> void:
    var left_mesh := BoxMesh.new()
    left_mesh.size = Vector3(0.68, 0.12, 0.96)
    _add_mesh(
        root,
        left_mesh,
        colors[0],
        ghost,
        0,
        Vector3(-0.24, 0.18, 0.0),
        Vector3(0.0, 0.0, -45.0)
    )

    var right_mesh := BoxMesh.new()
    right_mesh.size = Vector3(0.68, 0.12, 0.96)
    _add_mesh(
        root,
        right_mesh,
        colors[1] if colors.size() > 1 else colors[0],
        ghost,
        1,
        Vector3(0.24, 0.18, 0.0),
        Vector3(0.0, 0.0, 45.0)
    )

static func _add_thruster_tier_1(root: Node3D, colors: Array[Color], ghost: bool) -> void:
    # Tier 1 is only the nozzle. It occupies the rear half of one cell:
    # the narrow side sits flush on the -Z cell wall and the broad open side
    # ends at the cell center. There is no fuel body and no second color region.
    var shell := _hollow_frustum_mesh(
        -0.50,
        0.00,
        0.18,
        0.46,
        0.075,
        0.33
    )
    _add_mesh(root, shell, colors[0], ghost, 0, Vector3.ZERO, Vector3.ZERO, true)

static func _add_thruster_tier_2(root: Node3D, colors: Array[Color], ghost: bool) -> void:
    # Cell one is the dark fuel body: a cylinder with tapered ends, <=>.
    # It spans the entire anchor cell and joins the nozzle at the +Z wall.
    var fuel_profile := PackedVector2Array([
        Vector2(-0.50, 0.18),
        Vector2(-0.28, 0.40),
        Vector2(0.28, 0.40),
        Vector2(0.50, 0.18),
    ])
    _add_mesh(
        root,
        _profiled_solid_mesh(fuel_profile, 32),
        colors[1],
        ghost,
        1,
        Vector3.ZERO,
        Vector3.ZERO,
        true
    )

    # Cell two is the colored full-cell hollow nozzle. The narrow end is flush
    # against the fuel body at z=0.5 and the open mouth reaches z=1.5.
    var shell := _hollow_frustum_mesh(
        0.50,
        1.50,
        0.18,
        0.46,
        0.075,
        0.33
    )
    _add_mesh(root, shell, colors[0], ghost, 0, Vector3.ZERO, Vector3.ZERO, true)

static func _material(color: Color, ghost: bool, double_sided := false) -> StandardMaterial3D:
    var material := StandardMaterial3D.new()
    var final_color := color
    if ghost:
        final_color.a = 0.46
        material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    material.albedo_color = final_color

    # Ship-builder parts are editor geometry, not scene-lit objects. Keep every
    # color region completely flat/unshaded so adjacent pieces read as one model
    # instead of each procedural mesh picking up its own lighting gradient.
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.metallic = 0.0
    material.roughness = 1.0

    if double_sided:
        # Hollow thrusters have intentionally visible inner and outer walls.
        # Disabling culling prevents the shell from disappearing at grazing
        # angles while the explicit inner shell/rims still provide real thickness.
        material.cull_mode = BaseMaterial3D.CULL_DISABLED
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
            vertices.append_array(PackedVector3Array([p00, p11, p10, p00, p01, p11]))

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

static func _profiled_solid_mesh(profile: PackedVector2Array, segments := 24) -> ArrayMesh:
    var vertices := PackedVector3Array()
    if profile.size() < 2:
        return _mesh_from_triangles(vertices)

    for profile_index in range(profile.size() - 1):
        var z0 := profile[profile_index].x
        var r0 := profile[profile_index].y
        var z1 := profile[profile_index + 1].x
        var r1 := profile[profile_index + 1].y
        for segment in range(segments):
            var phi0 := TAU * float(segment) / float(segments)
            var phi1 := TAU * float(segment + 1) / float(segments)
            var a0 := Vector3(cos(phi0) * r0, sin(phi0) * r0, z0)
            var a1 := Vector3(cos(phi1) * r0, sin(phi1) * r0, z0)
            var b0 := Vector3(cos(phi0) * r1, sin(phi0) * r1, z1)
            var b1 := Vector3(cos(phi1) * r1, sin(phi1) * r1, z1)
            vertices.append_array(PackedVector3Array([a0, a1, b1, a0, b1, b0]))

    var first := profile[0]
    var last := profile[profile.size() - 1]
    var start_center := Vector3(0.0, 0.0, first.x)
    var end_center := Vector3(0.0, 0.0, last.x)
    for segment in range(segments):
        var phi0 := TAU * float(segment) / float(segments)
        var phi1 := TAU * float(segment + 1) / float(segments)
        var start0 := Vector3(cos(phi0) * first.y, sin(phi0) * first.y, first.x)
        var start1 := Vector3(cos(phi1) * first.y, sin(phi1) * first.y, first.x)
        vertices.append_array(PackedVector3Array([start_center, start1, start0]))

        var end0 := Vector3(cos(phi0) * last.y, sin(phi0) * last.y, last.x)
        var end1 := Vector3(cos(phi1) * last.y, sin(phi1) * last.y, last.x)
        vertices.append_array(PackedVector3Array([end_center, end0, end1]))

    return _mesh_from_triangles(vertices)

static func _hollow_frustum_mesh(
    z0: float,
    z1: float,
    outer0: float,
    outer1: float,
    inner0: float,
    inner1: float,
    segments := 24
) -> ArrayMesh:
    var vertices := PackedVector3Array()

    for segment in range(segments):
        var phi0 := TAU * float(segment) / float(segments)
        var phi1 := TAU * float(segment + 1) / float(segments)

        var o00 := Vector3(cos(phi0) * outer0, sin(phi0) * outer0, z0)
        var o01 := Vector3(cos(phi1) * outer0, sin(phi1) * outer0, z0)
        var o10 := Vector3(cos(phi0) * outer1, sin(phi0) * outer1, z1)
        var o11 := Vector3(cos(phi1) * outer1, sin(phi1) * outer1, z1)
        vertices.append_array(PackedVector3Array([o00, o01, o11, o00, o11, o10]))

        var i00 := Vector3(cos(phi0) * inner0, sin(phi0) * inner0, z0)
        var i01 := Vector3(cos(phi1) * inner0, sin(phi1) * inner0, z0)
        var i10 := Vector3(cos(phi0) * inner1, sin(phi0) * inner1, z1)
        var i11 := Vector3(cos(phi1) * inner1, sin(phi1) * inner1, z1)
        vertices.append_array(PackedVector3Array([i00, i11, i01, i00, i10, i11]))

        # Annular small and large faces keep the shell visibly thick rather than
        # reading as a zero-thickness cone.
        vertices.append_array(PackedVector3Array([o00, i01, o01, o00, i00, i01]))
        vertices.append_array(PackedVector3Array([o10, o11, i11, o10, i11, i10]))

    return _mesh_from_triangles(vertices)

static func _mesh_from_triangles(vertices: PackedVector3Array) -> ArrayMesh:
    var surface := SurfaceTool.new()
    surface.begin(Mesh.PRIMITIVE_TRIANGLES)
    for vertex in vertices:
        surface.add_vertex(vertex)
    surface.generate_normals()
    return surface.commit()
