class_name DistantSpace
extends Node3D

const DEFAULT_CATALOG_PATH := "res://assets/space/distant_space_catalog.csv"
const EXPECTED_FORMAT := "SPACE_FIELD_V1"


func build_from_catalog(path: String = DEFAULT_CATALOG_PATH) -> bool:
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        push_error("Unable to open distant-space catalog: %s" % path)
        return false

    var header := file.get_csv_line()
    if header.size() < 5 or header[0] != EXPECTED_FORMAT:
        push_error("Invalid distant-space catalog header: %s" % path)
        return false

    var star_count := int(header[1])
    var nebula_count := int(header[2])
    var star_radius := float(header[3])
    var nebula_radius := float(header[4])

    var stars := _create_layer(
        "DistantStars",
        star_count,
        _create_star_material(),
        maxf(star_radius, nebula_radius)
    )
    var nebulae := _create_layer(
        "DistantNebulae",
        nebula_count,
        _create_nebula_material(),
        maxf(star_radius, nebula_radius)
    )

    add_child(nebulae)
    add_child(stars)

    var star_index := 0
    var nebula_index := 0

    while not file.eof_reached():
        var values := file.get_csv_line()
        if values.size() < 9:
            continue

        var kind := values[0]
        if kind != "S" and kind != "N":
            continue

        var direction := Vector3(
            float(values[1]),
            float(values[2]),
            float(values[3])
        )
        if direction.length_squared() < 0.5:
            continue
        direction = direction.normalized()

        var size := float(values[4])
        var tint := Color(
            float(values[5]),
            float(values[6]),
            float(values[7]),
            float(values[8])
        )

        if kind == "S":
            if star_index >= star_count:
                continue
            stars.multimesh.set_instance_transform(
                star_index,
                _tangent_transform(direction, star_radius, size)
            )
            stars.multimesh.set_instance_custom_data(star_index, tint)
            star_index += 1
        else:
            if nebula_index >= nebula_count:
                continue
            nebulae.multimesh.set_instance_transform(
                nebula_index,
                _tangent_transform(direction, nebula_radius, size)
            )
            nebulae.multimesh.set_instance_custom_data(nebula_index, tint)
            nebula_index += 1

    stars.multimesh.visible_instance_count = star_index
    nebulae.multimesh.visible_instance_count = nebula_index

    if star_index != star_count or nebula_index != nebula_count:
        push_warning(
            "Distant-space catalog count mismatch: stars %d/%d, nebulae %d/%d"
            % [star_index, star_count, nebula_index, nebula_count]
        )

    return star_index > 0


func _create_layer(
    layer_name: String,
    count: int,
    material: Material,
    radius: float
) -> MultiMeshInstance3D:
    var quad := QuadMesh.new()
    quad.size = Vector2.ONE
    quad.material = material

    var multimesh := MultiMesh.new()
    multimesh.transform_format = MultiMesh.TRANSFORM_3D
    multimesh.use_custom_data = true
    multimesh.instance_count = maxi(0, count)
    multimesh.visible_instance_count = 0
    multimesh.mesh = quad

    var bounds_radius := radius * 1.08
    multimesh.custom_aabb = AABB(
        Vector3.ONE * -bounds_radius,
        Vector3.ONE * bounds_radius * 2.0
    )

    var instance := MultiMeshInstance3D.new()
    instance.name = layer_name
    instance.multimesh = multimesh
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    return instance


func _tangent_transform(
    direction: Vector3,
    radius: float,
    size: float
) -> Transform3D:
    var inward := -direction
    var reference := Vector3.UP
    if absf(inward.dot(reference)) > 0.94:
        reference = Vector3.RIGHT

    var x_axis := reference.cross(inward).normalized()
    var y_axis := inward.cross(x_axis).normalized()
    var basis := Basis(
        x_axis * size,
        y_axis * size,
        inward
    )

    return Transform3D(basis, direction * radius)


func _create_star_material() -> ShaderMaterial:
    var shader := Shader.new()
    shader.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never;

varying vec4 instance_tint;

void vertex() {
    instance_tint = INSTANCE_CUSTOM;
}

void fragment() {
    vec2 p = UV * 2.0 - vec2(1.0);
    float radius = length(p);
    float halo = 1.0 - smoothstep(0.18, 1.0, radius);
    float core = 1.0 - smoothstep(0.0, 0.24, radius);
    float intensity = clamp(core + halo * 0.48, 0.0, 1.0) * instance_tint.a;

    ALBEDO = instance_tint.rgb * intensity;
    EMISSION = instance_tint.rgb * (1.45 * intensity + 0.75 * core * instance_tint.a);
    ALPHA = intensity;
}
"""

    var material := ShaderMaterial.new()
    material.shader = shader
    return material


func _create_nebula_material() -> ShaderMaterial:
    var shader := Shader.new()
    shader.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never;

varying vec4 instance_tint;

void vertex() {
    instance_tint = INSTANCE_CUSTOM;
}

void fragment() {
    vec2 p = UV * 2.0 - vec2(1.0);
    float radius = length(p);
    float cloud = pow(max(1.0 - radius, 0.0), 2.4) * instance_tint.a;

    ALBEDO = instance_tint.rgb * cloud;
    EMISSION = instance_tint.rgb * cloud * 0.72;
    ALPHA = cloud;
}
"""

    var material := ShaderMaterial.new()
    material.shader = shader
    return material
