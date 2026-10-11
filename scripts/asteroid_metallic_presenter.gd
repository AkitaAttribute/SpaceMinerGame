extends Node

# Presentation-only treatment for metallic asteroid voxels.
#
# SpaceAsteroid owns which voxels are metallic. Its normal asteroid material is
# intentionally unshaded so the palette remains readable against the black
# space background. Metallic voxels keep that palette color, but receive two
# presentation passes:
# 1. a subtle, angle-independent gray tint so they are identifiable even when
#    the reflective highlight is not facing the camera;
# 2. the existing view-dependent sheen that moves as the asteroid/camera angle
#    changes.

var _scene_id := 0
var _patched_asteroids: Dictionary = {}
var _tint_material: ShaderMaterial
var _sheen_material: ShaderMaterial


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    process_priority = 700_000
    _sheen_material = _create_sheen_material()
    _tint_material = _create_tint_material()
    _tint_material.next_pass = _sheen_material


func _process(_delta: float) -> void:
    var scene := get_tree().current_scene
    if scene == null:
        _scene_id = 0
        _patched_asteroids.clear()
        return

    var current_scene_id := scene.get_instance_id()
    if current_scene_id != _scene_id:
        _scene_id = current_scene_id
        _patched_asteroids.clear()

    var asteroids_value = scene.get("asteroids")
    if not (asteroids_value is Dictionary):
        return

    var asteroids := asteroids_value as Dictionary
    for asteroid_value in asteroids.values():
        if not (asteroid_value is Object) or not is_instance_valid(asteroid_value):
            continue

        var asteroid := asteroid_value as Object
        var asteroid_id := asteroid.get_instance_id()
        if _patched_asteroids.has(asteroid_id):
            continue

        var material_value = asteroid.get("_metallic_material")
        if not (material_value is StandardMaterial3D):
            continue

        var material := material_value as StandardMaterial3D

        # Keep the voxel's normal dirt/ice color as the base. The chained
        # passes provide the persistent metal tint and moving reflective cue.
        material.vertex_color_use_as_albedo = true
        material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
        material.metallic = 0.0
        material.roughness = 1.0
        material.cull_mode = BaseMaterial3D.CULL_DISABLED
        material.next_pass = _tint_material

        _patched_asteroids[asteroid_id] = true


func _create_tint_material() -> ShaderMaterial:
    var shader := Shader.new()
    shader.code = """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;

varying vec3 voxel_color;

void vertex() {
    voxel_color = COLOR.rgb;
}

void fragment() {
    // Blend a same-luminance gray over the existing palette color. This lowers
    // saturation without making blue ice or orange/brown rock converge on one
    // fixed silver color. At 20% opacity the original hue remains dominant.
    float luminance = dot(voxel_color, vec3(0.2126, 0.7152, 0.0722));
    ALBEDO = vec3(luminance);
    ALPHA = 0.20;
}
"""

    var material := ShaderMaterial.new()
    material.shader = shader
    return material


func _create_sheen_material() -> ShaderMaterial:
    var shader := Shader.new()
    shader.code = """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never;

varying vec3 voxel_color;

void vertex() {
    voxel_color = COLOR.rgb;
}

void fragment() {
    vec3 n = normalize(NORMAL);
    vec3 v = normalize(VIEW);
    float facing = clamp(abs(dot(n, v)), 0.0, 1.0);

    // A narrow broad-face reflection band plus a weaker grazing-angle rim.
    // Both are camera-relative, so the highlight visibly travels across the
    // voxel faces as the asteroid spins without needing scene lighting.
    float band_shape = max(0.0, 1.0 - abs(facing - 0.58) / 0.24);
    float band = pow(band_shape, 5.0);
    float rim = pow(1.0 - facing, 4.0);
    float sheen = clamp(band * 0.52 + rim * 0.16, 0.0, 0.62);

    // Tint the reflection toward white, but keep most of the voxel's original
    // hue so blue ice remains blue and brown rock remains brown.
    vec3 highlight = mix(voxel_color, vec3(1.0), 0.32);
    ALBEDO = highlight * sheen;
}
"""

    var material := ShaderMaterial.new()
    material.shader = shader
    return material
