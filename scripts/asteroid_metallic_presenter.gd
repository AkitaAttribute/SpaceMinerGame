extends Node

# Presentation-only treatment for metallic asteroid voxels.
#
# SpaceAsteroid owns which voxels are metallic. Its normal asteroid material is
# intentionally unshaded so the palette remains readable against the black
# space background. Metallic voxels keep that palette color, but receive two
# presentation passes:
# 1. a subtle, angle-independent gray tint so they are identifiable even when
#    the reflective highlight is not facing the camera;
# 2. a view-dependent sheen that moves as the asteroid/camera angle changes.
#
# This presenter also preserves those same cues on detached tractor chunks and
# restores cheap visual-only self-spin for distant asteroids. The simulation's
# far-body optimization intentionally stops rotating the AnimatableBody3D itself;
# rotating only its visual child avoids reintroducing 60 Hz physics-server work.

var _scene_id := 0
var _patched_asteroids: Dictionary = {}
var _patched_chunks: Dictionary = {}
var _laser_metallic_cache: Dictionary = {}
var _far_visual_spin: Dictionary = {}
var _tint_material: ShaderMaterial
var _sheen_material: ShaderMaterial
var _chunk_sheen_shader: Shader


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    process_priority = 700_000
    _sheen_material = _create_sheen_material()
    _tint_material = _create_tint_material()
    _tint_material.next_pass = _sheen_material
    _chunk_sheen_shader = _create_chunk_sheen_shader()


func _reset_scene_state() -> void:
    _patched_asteroids.clear()
    _patched_chunks.clear()
    _laser_metallic_cache.clear()
    _far_visual_spin.clear()


func _process(_delta: float) -> void:
    var scene := get_tree().current_scene
    if scene == null:
        _scene_id = 0
        _reset_scene_state()
        return

    var current_scene_id := scene.get_instance_id()
    if current_scene_id != _scene_id:
        _scene_id = current_scene_id
        _reset_scene_state()

    var asteroids_value = scene.get("asteroids")
    if asteroids_value is Dictionary:
        _patch_asteroid_materials(asteroids_value as Dictionary)

    _update_tractor_chunk_materials(scene)


func _physics_process(delta: float) -> void:
    var scene := get_tree().current_scene
    if scene == null:
        return

    var asteroids_value = scene.get("asteroids")
    if not (asteroids_value is Dictionary):
        return

    _restore_far_asteroid_spin(
        scene,
        asteroids_value as Dictionary,
        delta
    )


func _patch_asteroid_materials(asteroids: Dictionary) -> void:
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


func _update_tractor_chunk_materials(scene: Node) -> void:
    var lasers_value = scene.get("mining_lasers")
    if not (lasers_value is Array):
        return

    var lasers := lasers_value as Array
    for laser_index in range(lasers.size()):
        var laser_value = lasers[laser_index]
        if not (laser_value is Dictionary):
            continue

        var laser := laser_value as Dictionary
        var prepared_value = laser.get("prepared_detach", {})
        if prepared_value is Dictionary:
            var prepared := prepared_value as Dictionary
            if prepared.has("metallic"):
                # prepare_detach_cell() exists for most of the mining cycle, so
                # cache composition before Simulation clears prepared_detach on
                # the exact frame it creates the tractor chunk.
                _laser_metallic_cache[laser_index] = bool(
                    prepared.get("metallic", false)
                )

        var chunk_value = laser.get("chunk", null)
        if not (chunk_value is MeshInstance3D) or not is_instance_valid(chunk_value):
            continue

        var chunk := chunk_value as MeshInstance3D
        var chunk_id := chunk.get_instance_id()
        if _patched_chunks.has(chunk_id):
            continue

        if bool(_laser_metallic_cache.get(laser_index, false)):
            _patch_metallic_chunk(chunk)

        _patched_chunks[chunk_id] = true


func _patch_metallic_chunk(chunk: MeshInstance3D) -> void:
    var mesh_value = chunk.mesh
    if not (mesh_value is PrimitiveMesh):
        return

    var primitive := mesh_value as PrimitiveMesh
    var material_value = primitive.material
    if not (material_value is StandardMaterial3D):
        return

    var material := material_value as StandardMaterial3D
    var base_color := material.albedo_color

    # Match the asteroid's persistent 20% same-luminance gray tint without
    # replacing the original blue/orange/brown identity.
    var luminance := (
        base_color.r * 0.2126
        + base_color.g * 0.7152
        + base_color.b * 0.0722
    )
    var gray := Color(luminance, luminance, luminance, base_color.a)
    material.albedo_color = base_color.lerp(gray, 0.20)
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.metallic = 0.0
    material.roughness = 1.0

    var sheen := ShaderMaterial.new()
    sheen.shader = _chunk_sheen_shader
    sheen.set_shader_parameter("base_color", base_color)
    material.next_pass = sheen


func _restore_far_asteroid_spin(
    scene: Node,
    asteroids: Dictionary,
    delta: float
) -> void:
    if not scene.has_method("_asteroid_detail_distance"):
        return

    var ship_value = scene.get("ship_body")
    if not (ship_value is Node3D) or not is_instance_valid(ship_value):
        return

    var ship := ship_value as Node3D
    var detail_distance := float(scene.call("_asteroid_detail_distance"))

    for asteroid_value in asteroids.values():
        if not (asteroid_value is Node3D) or not is_instance_valid(asteroid_value):
            continue

        var asteroid := asteroid_value as Node3D
        var asteroid_id := asteroid.get_instance_id()
        var visual_value = asteroid.get("_visual")
        if not (visual_value is Node3D) or not is_instance_valid(visual_value):
            continue

        var visual := visual_value as Node3D
        var is_far := (
            ship.global_position.distance_to(asteroid.global_position)
            > detail_distance
        )

        if is_far:
            var axis_value = asteroid.get("spin_axis")
            if not (axis_value is Vector3):
                continue

            var spin_axis := axis_value as Vector3
            var spin_speed := float(asteroid.get("spin_speed"))
            if spin_axis.length_squared() <= 0.000001 or absf(spin_speed) <= 0.000001:
                continue

            # spin_axis is stored in the asteroid parent's coordinate system.
            # Convert it into the visual child's parent coordinates so this
            # reproduces the original self-spin without rotating the physics
            # body or waking its collision state.
            var local_axis := asteroid.basis.inverse() * spin_axis
            if local_axis.length_squared() <= 0.000001:
                continue

            visual.basis = visual.basis.rotated(
                local_axis.normalized(),
                spin_speed * delta
            ).orthonormalized()
            _far_visual_spin[asteroid_id] = true
            continue

        if not _far_visual_spin.has(asteroid_id):
            continue

        # The asteroid has returned to the normal detailed update path. Bake
        # the accumulated visual-only far rotation into the body once, then
        # reset the child so mesh/collision/mining coordinates remain aligned.
        var body_transform := asteroid.transform
        body_transform.basis = (
            body_transform.basis * visual.basis
        ).orthonormalized()
        asteroid.transform = body_transform
        visual.basis = Basis.IDENTITY
        _far_visual_spin.erase(asteroid_id)


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

    float band_shape = max(0.0, 1.0 - abs(facing - 0.58) / 0.24);
    float band = pow(band_shape, 5.0);
    float rim = pow(1.0 - facing, 4.0);
    float sheen = clamp(band * 0.52 + rim * 0.16, 0.0, 0.62);

    vec3 highlight = mix(voxel_color, vec3(1.0), 0.32);
    ALBEDO = highlight * sheen;
}
"""

    var material := ShaderMaterial.new()
    material.shader = shader
    return material


func _create_chunk_sheen_shader() -> Shader:
    var shader := Shader.new()
    shader.code = """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never;

uniform vec4 base_color : source_color = vec4(1.0);

void fragment() {
    vec3 n = normalize(NORMAL);
    vec3 v = normalize(VIEW);
    float facing = clamp(abs(dot(n, v)), 0.0, 1.0);

    float band_shape = max(0.0, 1.0 - abs(facing - 0.58) / 0.24);
    float band = pow(band_shape, 5.0);
    float rim = pow(1.0 - facing, 4.0);
    float sheen = clamp(band * 0.52 + rim * 0.16, 0.0, 0.62);

    vec3 highlight = mix(base_color.rgb, vec3(1.0), 0.32);
    ALBEDO = highlight * sheen;
}
"""
    return shader
