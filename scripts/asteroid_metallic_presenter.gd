extends Node

# Experimental asteroid voxel presentation.
#
# Every asteroid voxel is assigned one of five persistent visual categories as
# evenly as integer voxel counts permit:
#   20% normal
#   20% metallic
#   20% iridescent / oil-slick
#   20% holographic foil
#   20% inverse color
#
# Assignment covers the full voxel volume, not merely currently exposed cells,
# so mining can reveal an effect that was already assigned while buried. This
# presenter rebuilds only the visible faces into five render surfaces; asteroid
# physics, targeting, collision, mining timing, and orbital behavior stay in the
# simulation/core asteroid code.
#
# Detached tractor chunks inherit the same effect as their source voxel.
# This node also retains the existing visual-only self-spin restoration for far
# asteroids so the ring can tumble without waking distant physics bodies.

const EFFECT_NORMAL := 0
const EFFECT_METALLIC := 1
const EFFECT_IRIDESCENT := 2
const EFFECT_HOLOGRAPHIC := 3
const EFFECT_INVERSE := 4
const EFFECT_COUNT := 5
const CELL_SIZE := 1.0
const INITIAL_ASTEROIDS_PER_FRAME := 12

const FACE_DIRECTIONS: Array[Vector3i] = [
    Vector3i(1, 0, 0),
    Vector3i(-1, 0, 0),
    Vector3i(0, 1, 0),
    Vector3i(0, -1, 0),
    Vector3i(0, 0, 1),
    Vector3i(0, 0, -1),
]

var _scene_id := 0
var _initial_patch_complete := false
var _initial_patch_index := 0
var _asteroid_effect_maps: Dictionary = {}
var _asteroid_geometry_versions: Dictionary = {}
var _patched_chunks: Dictionary = {}
var _laser_effect_cache: Dictionary = {}
var _far_visual_spin: Dictionary = {}

# Passive mobile profiling; these counters never change presentation behavior.
var _mobile_process_count := 0
var _mobile_process_total_us := 0
var _mobile_spin_count := 0
var _mobile_spin_total_us := 0
var _mobile_spin_max_us := 0
var _mobile_profile_elapsed := 0.0

var _normal_material: StandardMaterial3D
var _metallic_material: StandardMaterial3D
var _iridescent_material: StandardMaterial3D
var _holographic_material: StandardMaterial3D
var _inverse_material: StandardMaterial3D

var _chunk_metal_sheen_shader: Shader
var _chunk_iridescent_shader: Shader
var _chunk_holographic_shader: Shader


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    process_priority = 700_000
    _build_effect_materials()
    _chunk_metal_sheen_shader = _create_chunk_metal_sheen_shader()
    _chunk_iridescent_shader = _create_chunk_iridescent_shader()
    _chunk_holographic_shader = _create_chunk_holographic_shader()


func _reset_scene_state() -> void:
    _initial_patch_complete = false
    _initial_patch_index = 0
    _asteroid_effect_maps.clear()
    _asteroid_geometry_versions.clear()
    _patched_chunks.clear()
    _laser_effect_cache.clear()
    _far_visual_spin.clear()


func _process(_delta: float) -> void:
    var mobile := OS.has_feature("android") or OS.has_feature("ios") or OS.has_feature("mobile")
    var profile_start := Time.get_ticks_usec() if mobile else 0
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
    if asteroids_value is Dictionary and not _initial_patch_complete:
        # Wait until all ring asteroids have been created. Otherwise the first
        # partial frame permanently marks the initial patch as complete.
        if scene.get("asteroid_ring_ready") == false:
            return

        var values := (asteroids_value as Dictionary).values()
        var processed := 0
        while (
            _initial_patch_index < values.size()
            and processed < INITIAL_ASTEROIDS_PER_FRAME
        ):
            var asteroid_value = values[_initial_patch_index]
            _initial_patch_index += 1
            processed += 1
            if asteroid_value is Object and is_instance_valid(asteroid_value):
                _ensure_asteroid_mesh_current(asteroid_value as Object)
        _initial_patch_complete = _initial_patch_index >= values.size()

    _update_laser_targets_and_chunks(scene)
    if mobile:
        _mobile_process_count += 1
        _mobile_process_total_us += Time.get_ticks_usec() - profile_start


func _physics_process(delta: float) -> void:
    var scene := get_tree().current_scene
    if scene == null or scene.get("asteroid_loading_in_progress") == true:
        return

    var asteroids_value = scene.get("asteroids")
    if not (asteroids_value is Dictionary):
        return

    var mobile := OS.has_feature("android") or OS.has_feature("ios") or OS.has_feature("mobile")
    var profile_start := Time.get_ticks_usec() if mobile else 0
    _restore_far_asteroid_spin(
        scene,
        asteroids_value as Dictionary,
        delta
    )
    if mobile:
        var elapsed_us := Time.get_ticks_usec() - profile_start
        _mobile_spin_count += 1
        _mobile_spin_total_us += elapsed_us
        _mobile_spin_max_us = maxi(_mobile_spin_max_us, elapsed_us)
        _mobile_profile_elapsed += delta
        if _mobile_profile_elapsed >= 5.0:
            AppLogger.event(
                "MOBILE_ASTEROID_PRESENTER process_avg_ms=%.3f "
                % [
                    float(_mobile_process_total_us)
                    / maxi(1, _mobile_process_count) / 1000.0
                ]
                + "far_spin_avg_ms=%.3f far_spin_max_ms=%.3f "
                % [
                    float(_mobile_spin_total_us)
                    / maxi(1, _mobile_spin_count) / 1000.0,
                    float(_mobile_spin_max_us) / 1000.0,
                ]
                + "asteroid_count=%d" % (asteroids_value as Dictionary).size()
            )
            _mobile_profile_elapsed = 0.0
            _mobile_process_count = 0
            _mobile_process_total_us = 0
            _mobile_spin_count = 0
            _mobile_spin_total_us = 0
            _mobile_spin_max_us = 0


func _build_effect_materials() -> void:
    _normal_material = _create_base_vertex_material()

    _metallic_material = _create_base_vertex_material()
    var metal_tint := _create_metal_tint_material()
    var metal_sheen := _create_metal_sheen_material()
    metal_tint.next_pass = metal_sheen
    _metallic_material.next_pass = metal_tint

    _iridescent_material = _create_base_vertex_material()
    _iridescent_material.next_pass = _create_iridescent_material()

    _holographic_material = _create_base_vertex_material()
    _holographic_material.next_pass = _create_holographic_material()

    _inverse_material = _create_base_vertex_material()
    _inverse_material.next_pass = _create_inverse_material()


func _create_base_vertex_material() -> StandardMaterial3D:
    var material := StandardMaterial3D.new()
    material.vertex_color_use_as_albedo = true
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.roughness = 1.0
    material.cull_mode = BaseMaterial3D.CULL_DISABLED
    return material


func _material_for_effect(effect: int) -> Material:
    match effect:
        EFFECT_METALLIC:
            return _metallic_material
        EFFECT_IRIDESCENT:
            return _iridescent_material
        EFFECT_HOLOGRAPHIC:
            return _holographic_material
        EFFECT_INVERSE:
            return _inverse_material
        _:
            return _normal_material


func _ensure_asteroid_mesh_current(asteroid: Object) -> void:
    var asteroid_id := asteroid.get_instance_id()
    if not _asteroid_effect_maps.has(asteroid_id):
        _asteroid_effect_maps[asteroid_id] = _build_effect_map(asteroid)

    var geometry_version := int(asteroid.get("_geometry_version"))
    if (
        _asteroid_geometry_versions.has(asteroid_id)
        and int(_asteroid_geometry_versions[asteroid_id]) == geometry_version
    ):
        return

    var visual_value = asteroid.get("_visual")
    var surface_cells_value = asteroid.get("_surface_cells")
    var removed_value = asteroid.get("_removed_cells")
    if not (visual_value is MeshInstance3D):
        return
    if not (surface_cells_value is Array):
        return
    if not (removed_value is Dictionary):
        return

    var visual := visual_value as MeshInstance3D
    var surface_cells := surface_cells_value as Array
    var removed := removed_value as Dictionary
    var grid_size := int(asteroid.get("grid_size"))
    var seed := int(asteroid.get("_seed"))
    var primary_value = asteroid.get("palette_primary")
    var secondary_value = asteroid.get("palette_secondary")
    if not (primary_value is Color) or not (secondary_value is Color):
        return

    visual.mesh = _build_effect_mesh(
        surface_cells,
        removed,
        grid_size,
        seed,
        primary_value as Color,
        secondary_value as Color,
        _asteroid_effect_maps[asteroid_id] as Dictionary
    )
    _asteroid_geometry_versions[asteroid_id] = geometry_version


func _build_effect_map(asteroid: Object) -> Dictionary:
    var result: Dictionary = {}
    var grid_size := int(asteroid.get("grid_size"))
    var seed := int(asteroid.get("_seed"))
    var minimum := -int(floor(float(grid_size) * 0.5))
    var maximum := minimum + grid_size
    var candidates: Array[Vector3i] = []

    for y in range(minimum, maximum):
        for x in range(minimum, maximum):
            for z in range(minimum, maximum):
                candidates.append(Vector3i(x, y, z))

    # Deterministic Fisher-Yates shuffle. Cycling through the five effects after
    # shuffling makes the population exactly even whenever voxel_count % 5 == 0
    # and otherwise keeps every category within one block of every other one.
    var rng := RandomNumberGenerator.new()
    rng.seed = seed ^ 0x45F3A91D
    for index in range(candidates.size() - 1, 0, -1):
        var selected := rng.randi_range(0, index)
        var swap := candidates[index]
        candidates[index] = candidates[selected]
        candidates[selected] = swap

    var category_offset := posmod(seed, EFFECT_COUNT)
    for index in range(candidates.size()):
        result[_cell_key(candidates[index])] = (
            (index + category_offset) % EFFECT_COUNT
        )

    return result


func _effect_for_cell(asteroid: Object, cell: Vector3i) -> int:
    var asteroid_id := asteroid.get_instance_id()
    if not _asteroid_effect_maps.has(asteroid_id):
        _asteroid_effect_maps[asteroid_id] = _build_effect_map(asteroid)
    var effect_map := _asteroid_effect_maps[asteroid_id] as Dictionary
    return int(effect_map.get(_cell_key(cell), EFFECT_NORMAL))


func _build_effect_mesh(
    surface_cells: Array,
    removed: Dictionary,
    grid_size: int,
    seed: int,
    palette_primary: Color,
    palette_secondary: Color,
    effect_map: Dictionary
) -> ArrayMesh:
    var surfaces: Array = []
    var face_counts: Array[int] = []

    for effect in range(EFFECT_COUNT):
        var tool := SurfaceTool.new()
        tool.begin(Mesh.PRIMITIVE_TRIANGLES)
        tool.set_material(_material_for_effect(effect))
        surfaces.append(tool)
        face_counts.append(0)

    var minimum := -int(floor(float(grid_size) * 0.5))
    var maximum := minimum + grid_size

    for cell_value in surface_cells:
        if not (cell_value is Vector3i):
            continue
        var cell := cell_value as Vector3i
        var effect := int(effect_map.get(_cell_key(cell), EFFECT_NORMAL))
        var destination := surfaces[effect] as SurfaceTool
        var center := _cell_center(cell, grid_size)
        var color := _cell_color(
            cell,
            seed,
            palette_primary,
            palette_secondary
        )

        for direction in FACE_DIRECTIONS:
            if not _is_occupied(
                cell + direction,
                minimum,
                maximum,
                removed
            ):
                _append_exposed_face(destination, center, direction, color)
                face_counts[effect] = int(face_counts[effect]) + 1

    var mesh := ArrayMesh.new()
    for effect in range(EFFECT_COUNT):
        if int(face_counts[effect]) <= 0:
            continue
        var tool := surfaces[effect] as SurfaceTool
        tool.generate_normals()
        tool.commit(mesh)
    return mesh


func _update_laser_targets_and_chunks(scene: Node) -> void:
    var lasers_value = scene.get("mining_lasers")
    if not (lasers_value is Array):
        return

    var lasers := lasers_value as Array
    for laser_index in range(lasers.size()):
        var laser_value = lasers[laser_index]
        if not (laser_value is Dictionary):
            continue

        var laser := laser_value as Dictionary
        var target_value = laser.get("target", null)
        if target_value is Object and is_instance_valid(target_value):
            var target := target_value as Object
            _ensure_asteroid_mesh_current(target)

            var prepared_value = laser.get("prepared_detach", {})
            if prepared_value is Dictionary:
                var prepared := prepared_value as Dictionary
                if prepared.has("cell"):
                    var cell_value = prepared.get("cell", Vector3i.ZERO)
                    if cell_value is Vector3i:
                        _laser_effect_cache[laser_index] = _effect_for_cell(
                            target,
                            cell_value as Vector3i
                        )

        var chunk_value = laser.get("chunk", null)
        if not (chunk_value is MeshInstance3D) or not is_instance_valid(chunk_value):
            continue

        var chunk := chunk_value as MeshInstance3D
        var chunk_id := chunk.get_instance_id()
        if _patched_chunks.has(chunk_id):
            continue

        var effect := int(
            _laser_effect_cache.get(laser_index, EFFECT_NORMAL)
        )
        _patch_chunk_effect(chunk, effect)
        _patched_chunks[chunk_id] = true


func _patch_chunk_effect(chunk: MeshInstance3D, effect: int) -> void:
    if effect == EFFECT_NORMAL:
        return

    var mesh_value = chunk.mesh
    if not (mesh_value is PrimitiveMesh):
        return

    var primitive := mesh_value as PrimitiveMesh
    var material_value = primitive.material
    if not (material_value is StandardMaterial3D):
        return

    var material := material_value as StandardMaterial3D
    var base_color := material.albedo_color
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.metallic = 0.0
    material.roughness = 1.0
    material.next_pass = null

    match effect:
        EFFECT_METALLIC:
            var luminance := (
                base_color.r * 0.2126
                + base_color.g * 0.7152
                + base_color.b * 0.0722
            )
            var gray := Color(
                luminance,
                luminance,
                luminance,
                base_color.a
            )
            material.albedo_color = base_color.lerp(gray, 0.20)
            var sheen := ShaderMaterial.new()
            sheen.shader = _chunk_metal_sheen_shader
            sheen.set_shader_parameter("base_color", base_color)
            material.next_pass = sheen
        EFFECT_IRIDESCENT:
            var oil := ShaderMaterial.new()
            oil.shader = _chunk_iridescent_shader
            oil.set_shader_parameter("base_color", base_color)
            material.next_pass = oil
        EFFECT_HOLOGRAPHIC:
            var holo := ShaderMaterial.new()
            holo.shader = _chunk_holographic_shader
            holo.set_shader_parameter("base_color", base_color)
            material.next_pass = holo
        EFFECT_INVERSE:
            material.albedo_color = Color(
                1.0 - base_color.r,
                1.0 - base_color.g,
                1.0 - base_color.b,
                base_color.a
            )


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

        var body_transform := asteroid.transform
        body_transform.basis = (
            body_transform.basis * visual.basis
        ).orthonormalized()
        asteroid.transform = body_transform
        visual.basis = Basis.IDENTITY
        _far_visual_spin.erase(asteroid_id)


func _cell_key(cell: Vector3i) -> String:
    return "%d,%d,%d" % [cell.x, cell.y, cell.z]


func _is_occupied(
    cell: Vector3i,
    minimum: int,
    maximum: int,
    removed: Dictionary
) -> bool:
    if (
        cell.x < minimum or cell.x >= maximum
        or cell.y < minimum or cell.y >= maximum
        or cell.z < minimum or cell.z >= maximum
    ):
        return false
    return not removed.has(_cell_key(cell))


func _cell_center(cell: Vector3i, grid_size: int) -> Vector3:
    var offset := 0.5 if grid_size % 2 == 1 else 0.0
    return Vector3(
        float(cell.x) + 0.5 - offset,
        float(cell.y) + 0.5 - offset,
        float(cell.z) + 0.5 - offset
    ) * CELL_SIZE


func _cell_color(
    cell: Vector3i,
    seed: int,
    palette_primary: Color,
    palette_secondary: Color
) -> Color:
    var key := "%d:%d:%d:%d" % [seed, cell.x, cell.y, cell.z]
    var hashed: int = int(abs(hash(key)))
    var normalized := float(hashed % 1000) / 999.0
    var mixed := palette_primary.lerp(
        palette_secondary,
        lerpf(0.18, 0.82, normalized)
    )
    var detail := lerpf(
        -0.035,
        0.035,
        float((hashed / 1000) % 1000) / 999.0
    )
    return Color(
        clampf(mixed.r + detail, 0.0, 1.0),
        clampf(mixed.g + detail, 0.0, 1.0),
        clampf(mixed.b + detail, 0.0, 1.0),
        1.0
    )


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


func _create_metal_tint_material() -> ShaderMaterial:
    var shader := Shader.new()
    shader.code = """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;

varying vec3 voxel_color;

void vertex() {
    voxel_color = COLOR.rgb;
}

void fragment() {
    float luminance = dot(voxel_color, vec3(0.2126, 0.7152, 0.0722));
    ALBEDO = vec3(luminance);
    ALPHA = 0.20;
}
"""
    var material := ShaderMaterial.new()
    material.shader = shader
    return material


func _create_metal_sheen_material() -> ShaderMaterial:
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


func _create_iridescent_material() -> ShaderMaterial:
    var shader := Shader.new()
    shader.code = """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;

varying vec3 voxel_color;
varying vec3 local_pos;

void vertex() {
    voxel_color = COLOR.rgb;
    local_pos = VERTEX;
}

void fragment() {
    vec3 n = normalize(NORMAL);
    vec3 v = normalize(VIEW);
    float facing = clamp(abs(dot(n, v)), 0.0, 1.0);

    // Wavy thin-film phase changes mimic the irregular rainbow bands visible
    // in gasoline/oil films rather than a clean uniform rainbow gradient.
    float swirl = sin(local_pos.x * 4.1 + local_pos.z * 5.3) * 0.075;
    swirl += sin(local_pos.y * 6.2 - local_pos.x * 3.7) * 0.055;
    swirl += sin((local_pos.x + local_pos.y + local_pos.z) * 2.6) * 0.035;
    float phase = fract((1.0 - facing) * 1.65 + swirl + length(local_pos) * 0.08);
    vec3 rainbow = 0.5 + 0.5 * cos(
        6.2831853 * (phase + vec3(0.00, 0.33, 0.67))
    );
    ALBEDO = mix(voxel_color, rainbow, 0.78);
    ALPHA = 0.48 + (1.0 - facing) * 0.18;
}
"""
    var material := ShaderMaterial.new()
    material.shader = shader
    return material


func _create_holographic_material() -> ShaderMaterial:
    var shader := Shader.new()
    shader.code = """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;

varying vec3 voxel_color;
varying vec3 local_pos;

void vertex() {
    voxel_color = COLOR.rgb;
    local_pos = VERTEX;
}

void fragment() {
    vec3 n = normalize(NORMAL);
    vec3 v = normalize(VIEW);
    float facing = clamp(abs(dot(n, v)), 0.0, 1.0);
    float angle_shift = (1.0 - facing) * 3.4;

    // Broad diagonal prism bands imitate foil trading-card laminates.
    float phase = fract(
        local_pos.x * 0.82
        + local_pos.y * 1.17
        + local_pos.z * 0.53
        + angle_shift
    );
    vec3 rainbow = 0.5 + 0.5 * cos(
        6.2831853 * (phase + vec3(0.00, 0.33, 0.67))
    );

    // Sparse white glints add the characteristic holographic-card sparkle.
    vec3 glitter_cell = floor(local_pos * 11.0 + vec3(angle_shift * 2.0));
    float glitter_noise = fract(
        sin(dot(glitter_cell, vec3(12.9898, 78.233, 37.719))) * 43758.5453
    );
    float sparkle = smoothstep(0.965, 0.995, glitter_noise);
    sparkle *= 0.35 + 0.65 * pow(1.0 - facing, 2.0);

    ALBEDO = mix(voxel_color, rainbow, 0.68) + vec3(sparkle * 0.80);
    ALPHA = 0.52;
}
"""
    var material := ShaderMaterial.new()
    material.shader = shader
    return material


func _create_inverse_material() -> ShaderMaterial:
    var shader := Shader.new()
    shader.code = """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;

varying vec3 voxel_color;

void vertex() {
    voxel_color = COLOR.rgb;
}

void fragment() {
    ALBEDO = vec3(1.0) - voxel_color;
    ALPHA = 1.0;
}
"""
    var material := ShaderMaterial.new()
    material.shader = shader
    return material


func _create_chunk_metal_sheen_shader() -> Shader:
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


func _create_chunk_iridescent_shader() -> Shader:
    var shader := Shader.new()
    shader.code = """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;
uniform vec4 base_color : source_color = vec4(1.0);
varying vec3 local_pos;

void vertex() {
    local_pos = VERTEX;
}

void fragment() {
    vec3 n = normalize(NORMAL);
    vec3 v = normalize(VIEW);
    float facing = clamp(abs(dot(n, v)), 0.0, 1.0);
    float swirl = sin(local_pos.x * 4.1 + local_pos.z * 5.3) * 0.075;
    swirl += sin(local_pos.y * 6.2 - local_pos.x * 3.7) * 0.055;
    float phase = fract((1.0 - facing) * 1.65 + swirl + length(local_pos) * 0.08);
    vec3 rainbow = 0.5 + 0.5 * cos(
        6.2831853 * (phase + vec3(0.00, 0.33, 0.67))
    );
    ALBEDO = mix(base_color.rgb, rainbow, 0.78);
    ALPHA = 0.48 + (1.0 - facing) * 0.18;
}
"""
    return shader


func _create_chunk_holographic_shader() -> Shader:
    var shader := Shader.new()
    shader.code = """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;
uniform vec4 base_color : source_color = vec4(1.0);
varying vec3 local_pos;

void vertex() {
    local_pos = VERTEX;
}

void fragment() {
    vec3 n = normalize(NORMAL);
    vec3 v = normalize(VIEW);
    float facing = clamp(abs(dot(n, v)), 0.0, 1.0);
    float angle_shift = (1.0 - facing) * 3.4;
    float phase = fract(
        local_pos.x * 0.82
        + local_pos.y * 1.17
        + local_pos.z * 0.53
        + angle_shift
    );
    vec3 rainbow = 0.5 + 0.5 * cos(
        6.2831853 * (phase + vec3(0.00, 0.33, 0.67))
    );
    vec3 glitter_cell = floor(local_pos * 11.0 + vec3(angle_shift * 2.0));
    float glitter_noise = fract(
        sin(dot(glitter_cell, vec3(12.9898, 78.233, 37.719))) * 43758.5453
    );
    float sparkle = smoothstep(0.965, 0.995, glitter_noise);
    sparkle *= 0.35 + 0.65 * pow(1.0 - facing, 2.0);
    ALBEDO = mix(base_color.rgb, rainbow, 0.68) + vec3(sparkle * 0.80);
    ALPHA = 0.52;
}
"""
    return shader
