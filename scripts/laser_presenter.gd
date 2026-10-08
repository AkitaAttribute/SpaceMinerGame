extends Node

# Windows mining-laser diagnostics and renderer policy.
#
# Simulation remains the sole owner of:
# - target selection and obstruction/alignment decisions
# - turret rotation
# - authoritative muzzle/aim positions
# - original particle MultiMesh composition and transforms
# - beam visibility
#
# This node does NOT hide, clone, replace, reposition, or rebuild laser beams.
# It only:
# 1. disables physics interpolation on each original laser MultiMesh, because
#    Simulation already rewrites every particle transform at the fixed physics
#    rate and changes instance counts as beam length changes; interpolating stale
#    per-instance history can place particles between unrelated old/new slots;
# 2. logs authoritative endpoints alongside the actual first/last MultiMesh
#    particle transforms so beam placement problems are visible in the main log.
#
# FramePacer performs no laser work.

const LASER_BARREL_LENGTH := 0.42
const LASER_MINING_SECONDS := 5.0
const LASER_SURFACE_TRANSITION_SECONDS := 1.50
const LOG_INTERVAL_SECONDS := 1.0

var _enabled := false
var _scene_id := 0
var _configured_beams: Dictionary = {}
var _last_modes: Dictionary = {}
var _log_elapsed := 0.0


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    process_physics_priority = 1_000_000

    _enabled = OS.has_feature("windows") and not OS.has_feature("headless")
    if not _enabled:
        set_physics_process(false)
        return

    AppLogger.event(
        "LASER_DIAGNOSTICS original_multimesh enabled; "
        + "per-instance physics interpolation disabled; "
        + "Simulation owns beam geometry/visibility; "
        + "FramePacer performs no laser work"
    )


func _physics_process(delta: float) -> void:
    if not _enabled:
        return

    var scene := get_tree().current_scene
    if scene == null:
        return

    var current_scene_id := scene.get_instance_id()
    if current_scene_id != _scene_id:
        _scene_id = current_scene_id
        _configured_beams.clear()
        _last_modes.clear()
        _log_elapsed = LOG_INTERVAL_SECONDS
        AppLogger.event("LASER_SCENE_CHANGE scene=%d" % current_scene_id)

    var lasers_value = scene.get("mining_lasers")
    if not (lasers_value is Array):
        return

    var lasers := lasers_value as Array
    for laser_index in range(lasers.size()):
        var laser_value = lasers[laser_index]
        if not (laser_value is Dictionary):
            continue
        var laser := laser_value as Dictionary
        var beam_value = laser.get("beam", null)
        if not (beam_value is MultiMeshInstance3D):
            continue
        var beam := beam_value as MultiMeshInstance3D
        if not is_instance_valid(beam) or beam.multimesh == null:
            continue

        var key := beam.get_instance_id()
        if not _configured_beams.has(key):
            RenderingServer.multimesh_set_physics_interpolated(
                beam.multimesh.get_rid(),
                false
            )
            _configured_beams[key] = true
            AppLogger.event(
                "LASER_MM_CONFIG laser=%d beam_id=%d interpolation=false"
                % [laser_index, key]
            )

        var mode := _laser_mode(laser, beam)
        var old_mode := str(_last_modes.get(key, ""))
        if mode != old_mode:
            AppLogger.event(
                "LASER_STATE laser=%d mode=%s visible=%s target=%s chunk=%s reserved=%s fire=%.3f"
                % [
                    laser_index,
                    mode,
                    str(beam.visible),
                    _object_id_text(laser.get("target", null)),
                    _object_id_text(laser.get("chunk", null)),
                    str(laser.get("reserved_cell", null)),
                    float(laser.get("fire_time", 0.0)),
                ]
            )
            _last_modes[key] = mode

    _log_elapsed += delta
    if _log_elapsed < LOG_INTERVAL_SECONDS:
        return
    _log_elapsed = 0.0

    for laser_index in range(lasers.size()):
        var laser_value = lasers[laser_index]
        if not (laser_value is Dictionary):
            continue
        _log_laser_sample(laser_index, laser_value as Dictionary)


func _laser_mode(laser: Dictionary, beam: MultiMeshInstance3D) -> String:
    var chunk = laser.get("chunk", null)
    if chunk is Node3D and is_instance_valid(chunk):
        return "chunk_pull"

    var target = laser.get("target", null)
    if target is Node3D and is_instance_valid(target):
        return "target_fire" if beam.visible else "target_hidden"

    return "idle"


func _log_laser_sample(laser_index: int, laser: Dictionary) -> void:
    var beam_value = laser.get("beam", null)
    var pivot_value = laser.get("pivot", null)
    if not (beam_value is MultiMeshInstance3D) or not (pivot_value is Node3D):
        AppLogger.event(
            "LASER_SAMPLE laser=%d invalid_nodes beam=%s pivot=%s"
            % [laser_index, str(beam_value), str(pivot_value)]
        )
        return

    var beam := beam_value as MultiMeshInstance3D
    var pivot := pivot_value as Node3D
    if (
        not is_instance_valid(beam)
        or beam.multimesh == null
        or not is_instance_valid(pivot)
    ):
        AppLogger.event("LASER_SAMPLE laser=%d invalid_instances" % laser_index)
        return

    var expected := _expected_endpoints(laser, pivot)
    var expected_start := expected.get("start", Vector3.ZERO) as Vector3
    var expected_end := expected.get("finish", Vector3.ZERO) as Vector3
    var has_expected := bool(expected.get("valid", false))

    var count := beam.multimesh.instance_count
    var first_world := Vector3.ZERO
    var last_world := Vector3.ZERO
    var has_particles := count > 0
    if has_particles:
        var first_local := beam.multimesh.get_instance_transform(0).origin
        var last_local := beam.multimesh.get_instance_transform(count - 1).origin
        first_world = beam.to_global(first_local)
        last_world = beam.to_global(last_local)

    var start_error := -1.0
    var end_error := -1.0
    if has_expected and has_particles:
        start_error = first_world.distance_to(expected_start)
        end_error = last_world.distance_to(expected_end)

    AppLogger.event(
        (
            "LASER_SAMPLE laser=%d mode=%s visible=%s count=%d "
            + "muzzle=%s expected_end=%s first=%s last=%s "
            + "start_err=%.5f end_err=%.5f beam_global=%s "
            + "target=%s chunk=%s reserved=%s fire=%.3f"
        )
        % [
            laser_index,
            _laser_mode(laser, beam),
            str(beam.visible),
            count,
            _vec(expected_start) if has_expected else "n/a",
            _vec(expected_end) if has_expected else "n/a",
            _vec(first_world) if has_particles else "n/a",
            _vec(last_world) if has_particles else "n/a",
            start_error,
            end_error,
            _vec(beam.global_position),
            _object_id_text(laser.get("target", null)),
            _object_id_text(laser.get("chunk", null)),
            str(laser.get("reserved_cell", null)),
            float(laser.get("fire_time", 0.0)),
        ]
    )


func _expected_endpoints(laser: Dictionary, pivot: Node3D) -> Dictionary:
    var start := (
        pivot.global_position
        + pivot.global_basis.y.normalized() * LASER_BARREL_LENGTH
    )

    var chunk = laser.get("chunk", null)
    if chunk is Node3D and is_instance_valid(chunk):
        return {
            "valid": true,
            "start": start,
            "finish": (chunk as Node3D).global_position,
        }

    var target = laser.get("target", null)
    if not (target is Node3D) or not is_instance_valid(target):
        return {"valid": false}

    var target_node := target as Node3D
    var finish := target_node.global_position
    var reserved = laser.get("reserved_cell", null)
    if reserved is Vector3i and target_node.has_method("cell_world_position"):
        var cell_value = target_node.call("cell_world_position", reserved)
        if cell_value is Vector3:
            var transition_start := (
                LASER_MINING_SECONDS - LASER_SURFACE_TRANSITION_SECONDS
            )
            var transition := clampf(
                (float(laser.get("fire_time", 0.0)) - transition_start)
                / LASER_SURFACE_TRANSITION_SECONDS,
                0.0,
                1.0
            )
            var smooth_transition := transition * transition * (3.0 - 2.0 * transition)
            finish = target_node.global_position.lerp(
                cell_value as Vector3,
                smooth_transition
            )

    return {"valid": true, "start": start, "finish": finish}


func _object_id_text(value) -> String:
    if value is Object and is_instance_valid(value):
        return str((value as Object).get_instance_id())
    return "null"


func _vec(value: Vector3) -> String:
    return "(%.5f,%.5f,%.5f)" % [value.x, value.y, value.z]


# Compatibility shim for any stale caller. The known-good frame pacer no longer
# invokes this function, and it intentionally performs no presentation work.
func prepare_for_present(_interpolation_fraction: float) -> int:
    return 0
