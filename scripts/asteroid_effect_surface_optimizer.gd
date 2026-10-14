extends Node

# Collapses the experimental five-category asteroid renderer to one mesh surface
# and one shader pass per asteroid.
#
# AsteroidMetallicPresenter remains authoritative for deterministic per-voxel
# effect assignment and for rebuilding geometry after mining. This optimizer
# runs immediately after it, reads those generated surfaces, encodes the effect
# category into vertex-color alpha, and merges everything into one surface.
# The resulting shader reproduces the same five visual ideas in one opaque pass.
#
# This matters especially on mobile: the old layout could create five surfaces
# plus next_pass chains (roughly ten draws per fully represented asteroid).

const MAX_OPTIMIZATIONS_PER_FRAME := 24

const EFFECT_NORMAL := 0
const EFFECT_METALLIC := 1
const EFFECT_IRIDESCENT := 2
const EFFECT_HOLOGRAPHIC := 3
const EFFECT_INVERSE := 4
const EFFECT_COUNT := 5

var _scene_id := 0
var _optimized_versions: Dictionary = {}
var _single_pass_material: ShaderMaterial
var _logged_initial_summary := false
var _optimized_total := 0


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    # AsteroidMetallicPresenter is 700000. Run after it so a freshly rebuilt
    # five-surface mesh can be collapsed in the same rendered frame.
    process_priority = 750_000
    _single_pass_material = ShaderMaterial.new()
    _single_pass_material.shader = _create_single_pass_shader()


func _process(_delta: float) -> void:
    var scene := get_tree().current_scene
    if scene == null:
        _scene_id = 0
        _optimized_versions.clear()
        _logged_initial_summary = false
        _optimized_total = 0
        return

    var scene_id := scene.get_instance_id()
    if scene_id != _scene_id:
        _scene_id = scene_id
        _optimized_versions.clear()
        _logged_initial_summary = false
        _optimized_total = 0

    var asteroids_value = scene.get("asteroids")
    if not (asteroids_value is Dictionary):
        return

    var presenter := get_node_or_null("/root/AsteroidMetallicPresenter")
    if presenter == null:
        return

    var presenter_versions_value = presenter.get("_asteroid_geometry_versions")
    if not (presenter_versions_value is Dictionary):
        return
    var presenter_versions := presenter_versions_value as Dictionary

    var optimized_this_frame := 0
    var asteroids := asteroids_value as Dictionary
    for asteroid_value in asteroids.values():
        if optimized_this_frame >= MAX_OPTIMIZATIONS_PER_FRAME:
            break
        if not (asteroid_value is Object) or not is_instance_valid(asteroid_value):
            continue

        var asteroid := asteroid_value as Object
        var asteroid_id := asteroid.get_instance_id()
        var geometry_version := int(asteroid.get("_geometry_version"))

        # Wait until the experimental presenter has rebuilt this exact geometry
        # revision. Otherwise we could accidentally collapse the original plain
        # asteroid mesh before effect categories have been applied.
        if not presenter_versions.has(asteroid_id):
            continue
        if int(presenter_versions[asteroid_id]) != geometry_version:
            continue

        if (
            _optimized_versions.has(asteroid_id)
            and int(_optimized_versions[asteroid_id]) == geometry_version
        ):
            continue

        if _optimize_asteroid_mesh(asteroid, presenter):
            _optimized_versions[asteroid_id] = geometry_version
            optimized_this_frame += 1
            _optimized_total += 1

    if not _logged_initial_summary and _optimized_total >= asteroids.size():
        _logged_initial_summary = true
        AppLogger.event(
            "ASTEROID_EFFECT_OPTIMIZER single_surface=true optimized=%d"
            % _optimized_total
        )


func _optimize_asteroid_mesh(asteroid: Object, presenter: Node) -> bool:
    var visual_value = asteroid.get("_visual")
    if not (visual_value is MeshInstance3D) or not is_instance_valid(visual_value):
        return false

    var visual := visual_value as MeshInstance3D
    var mesh_value = visual.mesh
    if not (mesh_value is ArrayMesh):
        return false
    var source := mesh_value as ArrayMesh
    if source.get_surface_count() <= 0:
        return false

    var surface := SurfaceTool.new()
    surface.begin(Mesh.PRIMITIVE_TRIANGLES)
    surface.set_material(_single_pass_material)

    var copied_vertices := 0
    for surface_index in range(source.get_surface_count()):
        var effect := _effect_for_material(
            source.surface_get_material(surface_index),
            presenter
        )
        if effect < 0:
            # Unknown material means this is not one of the five generated
            # effect surfaces. Leave it alone rather than corrupting geometry.
            return false

        var arrays := source.surface_get_arrays(surface_index)
        if arrays.size() <= Mesh.ARRAY_VERTEX:
            continue

        var vertices_value = arrays[Mesh.ARRAY_VERTEX]
        if not (vertices_value is PackedVector3Array):
            continue
        var vertices := vertices_value as PackedVector3Array

        var normals := PackedVector3Array()
        var normals_value = arrays[Mesh.ARRAY_NORMAL]
        if normals_value is PackedVector3Array:
            normals = normals_value as PackedVector3Array

        var colors := PackedColorArray()
        var colors_value = arrays[Mesh.ARRAY_COLOR]
        if colors_value is PackedColorArray:
            colors = colors_value as PackedColorArray

        var indices := PackedInt32Array()
        var indices_value = arrays[Mesh.ARRAY_INDEX]
        if indices_value is PackedInt32Array:
            indices = indices_value as PackedInt32Array

        if indices.is_empty():
            for vertex_index in range(vertices.size()):
                _append_encoded_vertex(
                    surface,
                    vertices,
                    normals,
                    colors,
                    vertex_index,
                    effect
                )
                copied_vertices += 1
        else:
            for index_value in indices:
                var vertex_index := int(index_value)
                if vertex_index < 0 or vertex_index >= vertices.size():
                    continue
                _append_encoded_vertex(
                    surface,
                    vertices,
                    normals,
                    colors,
                    vertex_index,
                    effect
                )
                copied_vertices += 1

    if copied_vertices <= 0:
        return false

    var compact_mesh := surface.commit()
    if compact_mesh == null:
        return false

    visual.mesh = compact_mesh
    return true


func _append_encoded_vertex(
    surface: SurfaceTool,
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    vertex_index: int,
    effect: int
) -> void:
    var color := Color.WHITE
    if vertex_index < colors.size():
        color = colors[vertex_index]

    # The original asteroid colors are opaque, so alpha is free metadata here.
    # Encoding 0..4 over 0..1 is stable because every triangle belongs to one
    # voxel/effect and therefore has the same value on all three vertices.
    color.a = float(effect) / float(EFFECT_COUNT - 1)
    surface.set_color(color)

    if vertex_index < normals.size():
        surface.set_normal(normals[vertex_index])

    surface.add_vertex(vertices[vertex_index])


func _effect_for_material(material: Material, presenter: Node) -> int:
    if material == presenter.get("_normal_material"):
        return EFFECT_NORMAL
    if material == presenter.get("_metallic_material"):
        return EFFECT_METALLIC
    if material == presenter.get("_iridescent_material"):
        return EFFECT_IRIDESCENT
    if material == presenter.get("_holographic_material"):
        return EFFECT_HOLOGRAPHIC
    if material == presenter.get("_inverse_material"):
        return EFFECT_INVERSE
    return -1


func _create_single_pass_shader() -> Shader:
    var shader := Shader.new()
    shader.code = """
shader_type spatial;
render_mode unshaded, cull_disabled;

varying vec3 voxel_color;
varying float effect_code;
varying vec3 local_pos;

void vertex() {
    voxel_color = COLOR.rgb;
    effect_code = COLOR.a * 4.0;
    local_pos = VERTEX;
}

vec3 spectrum(float phase) {
    return 0.5 + 0.5 * cos(
        6.2831853 * (phase + vec3(0.00, 0.33, 0.67))
    );
}

void fragment() {
    vec3 base = voxel_color;
    vec3 result = base;
    float effect = floor(effect_code + 0.5);

    vec3 n = normalize(NORMAL);
    vec3 v = normalize(VIEW);
    float facing = clamp(abs(dot(n, v)), 0.0, 1.0);

    if (effect < 0.5) {
        // Normal: unchanged asteroid palette color.
        result = base;
    } else if (effect < 1.5) {
        // Metallic: preserve the palette, add the constant gray tinge, then
        // layer the same view-dependent bright sheen into the one opaque pass.
        float luminance = dot(base, vec3(0.2126, 0.7152, 0.0722));
        vec3 metal = mix(base, vec3(luminance), 0.20);
        float band_shape = max(0.0, 1.0 - abs(facing - 0.58) / 0.24);
        float band = pow(band_shape, 5.0);
        float rim = pow(1.0 - facing, 4.0);
        float sheen = clamp(band * 0.52 + rim * 0.16, 0.0, 0.62);
        vec3 highlight = mix(base, vec3(1.0), 0.32);
        result = metal + highlight * sheen;
    } else if (effect < 2.5) {
        // Iridescent/oil-film look. The old implementation drew this as a
        // translucent next-pass over the base. Mix it directly here instead.
        float swirl = sin(local_pos.x * 4.1 + local_pos.z * 5.3) * 0.075;
        swirl += sin(local_pos.y * 6.2 - local_pos.x * 3.7) * 0.055;
        float phase = fract(
            (1.0 - facing) * 1.65
            + swirl
            + length(local_pos) * 0.08
        );
        vec3 rainbow = spectrum(phase);
        vec3 oil = mix(base, rainbow, 0.78);
        float amount = 0.48 + (1.0 - facing) * 0.18;
        result = mix(base, oil, amount);
    } else if (effect < 3.5) {
        // Holographic trading-card foil: diagonal rainbow bands plus sparse
        // glints, composited directly into the base color.
        float angle_shift = (1.0 - facing) * 3.4;
        float phase = fract(
            local_pos.x * 0.82
            + local_pos.y * 1.17
            + local_pos.z * 0.53
            + angle_shift
        );
        vec3 rainbow = spectrum(phase);
        vec3 glitter_cell = floor(
            local_pos * 11.0 + vec3(angle_shift * 2.0)
        );
        float glitter_noise = fract(
            sin(dot(glitter_cell, vec3(12.9898, 78.233, 37.719)))
            * 43758.5453
        );
        float sparkle = smoothstep(0.965, 0.995, glitter_noise);
        sparkle *= 0.35 + 0.65 * pow(1.0 - facing, 2.0);
        vec3 foil = mix(base, rainbow, 0.68) + vec3(sparkle * 0.80);
        result = mix(base, foil, 0.52);
    } else {
        // Inverse color.
        result = vec3(1.0) - base;
    }

    ALBEDO = clamp(result, vec3(0.0), vec3(1.0));
    ALPHA = 1.0;
}
"""
    return shader
