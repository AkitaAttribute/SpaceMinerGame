class_name DistantSpace
extends Node3D

const DEFAULT_CATALOG_PATH := "res://assets/space/distant_space_catalog.csv"
const EXPECTED_FORMAT := "SPACE_FIELD_V1"

# At 6200 units, a 3.4-unit star is only ~0.34 pixels across in the
# project's 720p render viewport at 60 degrees vertical FOV. Sub-pixel
# geometry aliases badly during camera motion and looks like fake twinkling.
# Keep stars a little over one pixel wide, then reduce their intensity to
# preserve the intended point-source brightness.
const MIN_STAR_RENDER_SIZE := 11.0
const STAR_STABILITY_ALPHA_EXPONENT := 1.5


func build_active_or_default() -> bool:
    var active_path := SkyCatalog.get_active_sky_path()
    if not active_path.is_empty() and build_from_json(active_path):
        return true
    return build_from_catalog()


func build_from_json(path: String) -> bool:
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        push_error("Unable to open distant-space JSON: %s" % path)
        return false

    var parsed = JSON.parse_string(file.get_as_text())
    file.close()

    if not (parsed is Dictionary):
        push_error("Invalid distant-space JSON: %s" % path)
        return false

    var data := parsed as Dictionary
    if str(data.get("format", "")) != EXPECTED_FORMAT:
        push_error("Unsupported distant-space JSON format: %s" % path)
        return false

    var star_records = data.get("stars", [])
    var nebula_records = data.get("nebulae", [])
    if not (star_records is Array) or not (nebula_records is Array):
        push_error("Distant-space JSON is missing record arrays: %s" % path)
        return false

    var stars_data := star_records as Array
    var nebula_data := nebula_records as Array
    var star_radius := float(data.get("star_radius", 6200.0))
    var nebula_radius := float(data.get("nebula_radius", 5900.0))

    var stars := _create_layer(
        "DistantStars",
        stars_data.size(),
        _create_star_material(),
        maxf(star_radius, nebula_radius)
    )
    var nebulae := _create_layer(
        "DistantNebulae",
        nebula_data.size(),
        _create_nebula_material(),
        maxf(star_radius, nebula_radius)
    )

    add_child(nebulae)
    add_child(stars)

    var star_index := 0
    for value in stars_data:
        if _apply_json_record(
            stars,
            star_index,
            value,
            star_radius,
            true
        ):
            star_index += 1

    var nebula_index := 0
    for value in nebula_data:
        if _apply_json_record(
            nebulae,
            nebula_index,
            value,
            nebula_radius,
            false
        ):
            nebula_index += 1

    stars.multimesh.visible_instance_count = star_index
    nebulae.multimesh.visible_instance_count = nebula_index
    return star_index > 0


func _apply_json_record(
    layer: MultiMeshInstance3D,
    index: int,
    value,
    radius: float,
    stabilize_star: bool
) -> bool:
    if not (value is Array):
        return false

    var record := value as Array
    if record.size() < 8:
        return false

    var direction := Vector3(
        float(record[0]),
        float(record[1]),
        float(record[2])
    )
    if direction.length_squared() < 0.5:
        return false
    direction = direction.normalized()

    var original_size := float(record[3])
    var render_size := original_size
    var tint := Color(
        float(record[4]),
        float(record[5]),
        float(record[6]),
        float(record[7])
    )

    if stabilize_star:
        render_size = maxf(original_size, MIN_STAR_RENDER_SIZE)
        tint = _stabilize_star_tint(
            tint,
            original_size,
            render_size
        )

    layer.multimesh.set_instance_transform(
        index,
        _tangent_transform(direction, radius, render_size)
    )
    layer.multimesh.set_instance_custom_data(index, tint)
    return true


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

        var original_size := float(values[4])
        var tint := Color(
            float(values[5]),
            float(values[6]),
            float(values[7]),
            float(values[8])
        )

        if kind == "S":
            if star_index >= star_count:
                continue

            var render_size := maxf(
                original_size,
                MIN_STAR_RENDER_SIZE
            )
            var stable_tint := _stabilize_star_tint(
                tint,
                original_size,
                render_size
            )
            stars.multimesh.set_instance_transform(
                star_index,
                _tangent_transform(
                    direction,
                    star_radius,
                    render_size
                )
            )
            stars.multimesh.set_instance_custom_data(
                star_index,
                stable_tint
            )
            star_index += 1
        else:
            if nebula_index >= nebula_count:
                continue
            nebulae.multimesh.set_instance_transform(
                nebula_index,
                _tangent_transform(
                    direction,
                    nebula_radius,
                    original_size
                )
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


func _stabilize_star_tint(
    tint: Color,
    original_size: float,
    render_size: float
) -> Color:
    if render_size <= original_size + 0.0001:
        return tint

    # Enlarging the quad prevents sub-pixel on/off aliasing. Reduce brightness
    # as the footprint grows so a stabilized tiny star still reads as a distant
    # point rather than a larger luminous object.
    var size_ratio := clampf(
        original_size / render_size,
        0.0,
        1.0
    )
    var brightness_scale := pow(
        size_ratio,
        STAR_STABILITY_ALPHA_EXPONENT
    )

    return Color(
        tint.r,
        tint.g,
        tint.b,
        tint.a * brightness_scale
    )


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
    float radius_sq = dot(p, p);

    // Smooth Gaussian-like profiles avoid a hard sub-pixel edge changing
    // coverage abruptly as the camera rotates.
    float halo = exp(-radius_sq * 4.5);
    float core = exp(-radius_sq * 30.0);
    float intensity = (
        halo * 0.58
        + core * 0.62
    ) * instance_tint.a;

    ALBEDO = instance_tint.rgb * intensity;
    EMISSION = instance_tint.rgb * (
        intensity * 1.55
        + core * instance_tint.a * 0.45
    );
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
