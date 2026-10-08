extends Node

# Presentation-only mining laser bridge for the Windows manual renderer.
#
# The gameplay simulation continues to own targeting, mining progress, turret
# rotation, and the original beam nodes at the 60 Hz physics rate. This node
# snapshots that completed physics state and renders a presentation-only beam.
#
# IMPORTANT: when a beam becomes hidden/obstructed/out-of-range, all cached
# endpoint/interpolation state is discarded. A later visible beam always starts
# from its current muzzle/end position; no pre-obstruction beam position is
# allowed to participate in the next draw.

const MAX_BEAM_INSTANCES := 80
const PARTICLES_PER_UNIT := 6.5
const LASER_BARREL_LENGTH := 0.42
const LASER_MINING_SECONDS := 5.0
const LASER_SURFACE_TRANSITION_SECONDS := 1.50
const DISCONTINUITY_DISTANCE := 2.0
const SMOOTH_POSITION_WARN_DISTANCE := 0.75
const STATS_INTERVAL_USEC := 5_000_000
const TRANSFORM_STRIDE := 12
const TRACE_FILE_NAME := "SpaceMinerLaserTrace.log"

var _enabled := false
var _scene_id := 0
var _states: Dictionary = {}
var _stats_start_usec := 0
var _stats_sync_usec := 0
var _stats_ticks := 0
var _stats_resets := 0
var _trace_records: Array[String] = []
var _trace_start_usec := 0
var _trace_tick := 0
var _trace_errors := 0


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    # Run after the simulation's normal physics callback so its target/beam
    # state for this physics tick is complete before we snapshot it.
    process_physics_priority = 1_000_000

    _enabled = (
        OS.has_feature("windows")
        and not OS.has_feature("headless")
    )
    if not _enabled:
        set_physics_process(false)
        return

    _stats_start_usec = Time.get_ticks_usec()
    _trace_start_usec = _stats_start_usec
    _trace_records.append(
        "SpaceMiner mining-laser presentation trace\n"
        + "Started: %s\n" % Time.get_datetime_string_from_system()
        + "Engine: %s\n" % str(Engine.get_version_info().get("string", "unknown"))
        + "Smooth-position warning distance: %.3f units/tick\n" % SMOOTH_POSITION_WARN_DISTANCE
        + "All trace data is buffered in memory until normal shutdown."
    )


func _physics_process(_delta: float) -> void:
    if not _enabled or not FramePacer.is_manual_presentation_enabled():
        _restore_original_beams()
        return

    _trace_tick += 1
    var started := Time.get_ticks_usec()
    var scene := get_tree().current_scene
    if scene == null:
        _clear_states()
        return

    var current_scene_id := scene.get_instance_id()
    if current_scene_id != _scene_id:
        _trace_records.append(_trace_prefix() + " SCENE_CHANGE old=%d new=%d" % [_scene_id, current_scene_id])
        _clear_states()
        _scene_id = current_scene_id

    var lasers_value = scene.get("mining_lasers")
    if not (lasers_value is Array):
        _clear_states()
        return

    var beam_phase := float(scene.get("beam_time"))
    var seen: Dictionary = {}
    var lasers := lasers_value as Array

    for laser_index in range(lasers.size()):
        var laser_value = lasers[laser_index]
        if not (laser_value is Dictionary):
            continue
        var laser := laser_value as Dictionary
        var source_value = laser.get("beam", null)
        var pivot_value = laser.get("pivot", null)
        if (
            not (source_value is MultiMeshInstance3D)
            or not (pivot_value is Node3D)
        ):
            continue

        var source := source_value as MultiMeshInstance3D
        var pivot := pivot_value as Node3D
        if (
            not is_instance_valid(source)
            or source.multimesh == null
            or not is_instance_valid(pivot)
        ):
            continue

        var key := source.get_instance_id()
        seen[key] = true
        var state := _ensure_state(key, source)
        if state.is_empty():
            continue

        # Capture the simulation's final visibility decision for this physics
        # tick before hiding the original beam from the manual renderer.
        var source_visible := source.visible
        source.visible = false

        var endpoint_data := _laser_endpoints(laser, pivot)
        var signature := _laser_signature(laser)
        var pivot_position := pivot.global_position
        var turret_tip := _laser_tip_world(pivot)

        if not source_visible or endpoint_data.is_empty():
            var hide_reason := _hidden_reason(laser, source_visible, endpoint_data)
            _trace_hidden_transition(
                laser_index,
                state,
                signature,
                pivot_position,
                turret_tip,
                hide_reason
            )
            _set_hidden(state)
            _states[key] = state
            continue

        var start := endpoint_data["start"] as Vector3
        var finish := endpoint_data["finish"] as Vector3
        var distance := start.distance_to(finish)
        var count := clampi(
            int(ceil(distance * PARTICLES_PER_UNIT)),
            1,
            MAX_BEAM_INSTANCES
        )

        _trace_visible_sample(
            laser_index,
            state,
            signature,
            pivot_position,
            turret_tip,
            start,
            finish,
            count
        )

        var current := _build_beam_buffer(
            start,
            finish,
            count,
            beam_phase
        )

        var previous := current
        var reset := true
        var reset_reason := "new_or_reappeared"
        if bool(state.get("visible", false)):
            var previous_buffer = state.get("current", PackedFloat32Array())
            if previous_buffer is PackedFloat32Array:
                var old_buffer := previous_buffer as PackedFloat32Array
                var old_count := int(state.get("count", -1))
                var old_start := state.get("start", start) as Vector3
                var old_finish := state.get("finish", finish) as Vector3
                var old_signature := str(state.get("signature", ""))

                if old_buffer.size() != current.size():
                    reset_reason = "buffer_size"
                elif old_count != count:
                    reset_reason = "instance_count"
                elif old_signature != signature:
                    reset_reason = "signature_change"
                elif old_start.distance_to(start) > DISCONTINUITY_DISTANCE:
                    reset_reason = "start_discontinuity"
                elif old_finish.distance_to(finish) > DISCONTINUITY_DISTANCE:
                    reset_reason = "finish_discontinuity"
                else:
                    reset = false
                    reset_reason = "none"
                    previous = old_buffer

        if reset:
            # Never interpolate from an old/obstructed/out-of-range position.
            previous = current
            _stats_resets += 1
            _trace_records.append(
                _trace_prefix()
                + " LASER_RESET laser=%d reason=%s signature=%s start=%s end=%s tip=%s"
                % [
                    laser_index,
                    reset_reason,
                    signature,
                    _vec(start),
                    _vec(finish),
                    _vec(turret_tip),
                ]
            )

        var present := state["present"] as MultiMeshInstance3D
        var multimesh := present.multimesh
        var rid := multimesh.get_rid()
        RenderingServer.multimesh_set_buffer_interpolated(
            rid,
            current,
            previous
        )
        RenderingServer.multimesh_set_visible_instances(rid, count)
        present.visible = true

        state["current"] = current
        state["count"] = count
        state["visible"] = true
        state["start"] = start
        state["finish"] = finish
        state["signature"] = signature
        state["pivot_position"] = pivot_position
        state["turret_tip"] = turret_tip
        state["last_hide_reason"] = ""
        _states[key] = state

    for key in _states.keys():
        if not seen.has(key):
            _free_state(key)

    _stats_sync_usec += Time.get_ticks_usec() - started
    _stats_ticks += 1
    _log_stats_if_due()


func _ensure_state(key: int, source: MultiMeshInstance3D) -> Dictionary:
    var existing = _states.get(key, null)
    if existing is Dictionary:
        var existing_state := existing as Dictionary
        var present_value = existing_state.get("present", null)
        if present_value is MultiMeshInstance3D and is_instance_valid(present_value):
            return existing_state

    if source.multimesh == null or source.multimesh.mesh == null:
        return {}
    var parent := source.get_parent()
    if parent == null:
        return {}

    var multimesh := MultiMesh.new()
    multimesh.transform_format = MultiMesh.TRANSFORM_3D
    multimesh.mesh = source.multimesh.mesh
    multimesh.instance_count = MAX_BEAM_INSTANCES
    multimesh.visible_instance_count = 0

    var present := MultiMeshInstance3D.new()
    present.name = "PresentedMiningBeam_%d" % key
    present.multimesh = multimesh
    present.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    present.visible = false
    present.set_physics_interpolation_mode(
        Node.PHYSICS_INTERPOLATION_MODE_OFF
    )
    parent.add_child(present)

    var rid := multimesh.get_rid()
    RenderingServer.multimesh_set_physics_interpolated(rid, true)

    var state := {
        "source": source,
        "present": present,
        "current": PackedFloat32Array(),
        "count": 0,
        "visible": false,
        "start": Vector3.ZERO,
        "finish": Vector3.ZERO,
        "signature": "",
        "pivot_position": Vector3.ZERO,
        "turret_tip": Vector3.ZERO,
        "last_hide_reason": "",
    }
    _states[key] = state
    return state


func _laser_tip_world(pivot: Node3D) -> Vector3:
    return (
        pivot.global_position
        + pivot.global_basis.y.normalized() * LASER_BARREL_LENGTH
    )


func _laser_endpoints(laser: Dictionary, pivot: Node3D) -> Dictionary:
    var start := _laser_tip_world(pivot)

    var chunk = laser.get("chunk", null)
    if chunk is Node3D and is_instance_valid(chunk):
        return {
            "start": start,
            "finish": (chunk as Node3D).global_position,
        }

    var target = laser.get("target", null)
    if not (target is Node3D) or not is_instance_valid(target):
        return {}

    var target_node := target as Node3D
    var finish := target_node.global_position
    var reserved = laser.get("reserved_cell", null)
    if reserved is Vector3i and target_node.has_method("cell_world_position"):
        var cell_value = target_node.call("cell_world_position", reserved)
        if cell_value is Vector3:
            var cell_position := cell_value as Vector3
            var transition_start := (
                LASER_MINING_SECONDS
                - LASER_SURFACE_TRANSITION_SECONDS
            )
            var fire_time := float(laser.get("fire_time", 0.0))
            var transition := clampf(
                (fire_time - transition_start)
                / LASER_SURFACE_TRANSITION_SECONDS,
                0.0,
                1.0
            )
            var smooth_transition := (
                transition
                * transition
                * (3.0 - 2.0 * transition)
            )
            finish = target_node.global_position.lerp(
                cell_position,
                smooth_transition
            )

    return {"start": start, "finish": finish}


func _laser_signature(laser: Dictionary) -> String:
    var chunk = laser.get("chunk", null)
    if chunk is Object and is_instance_valid(chunk):
        return "chunk:%d" % (chunk as Object).get_instance_id()

    var target = laser.get("target", null)
    var target_id := 0
    if target is Object and is_instance_valid(target):
        target_id = (target as Object).get_instance_id()
    return "target:%d:cell:%s" % [
        target_id,
        str(laser.get("reserved_cell", null)),
    ]


func _hidden_reason(
    laser: Dictionary,
    source_visible: bool,
    endpoint_data: Dictionary
) -> String:
    if endpoint_data.is_empty():
        var target = laser.get("target", null)
        var chunk = laser.get("chunk", null)
        if chunk == null and (target == null or not is_instance_valid(target)):
            return "no_target_or_out_of_range"
        return "no_endpoints"
    if not source_visible:
        return "simulation_hidden_obstructed_or_unaligned"
    return "hidden"


func _trace_visible_sample(
    laser_index: int,
    state: Dictionary,
    signature: String,
    pivot_position: Vector3,
    turret_tip: Vector3,
    start: Vector3,
    finish: Vector3,
    count: int
) -> void:
    var was_visible := bool(state.get("visible", false))
    var old_signature := str(state.get("signature", ""))
    var old_start := state.get("start", start) as Vector3
    var old_finish := state.get("finish", finish) as Vector3
    var old_tip := state.get("turret_tip", turret_tip) as Vector3
    var old_pivot := state.get("pivot_position", pivot_position) as Vector3

    var start_step := old_start.distance_to(start) if was_visible else 0.0
    var end_step := old_finish.distance_to(finish) if was_visible else 0.0
    var tip_step := old_tip.distance_to(turret_tip) if was_visible else 0.0
    var pivot_step := old_pivot.distance_to(pivot_position) if was_visible else 0.0

    _trace_records.append(
        _trace_prefix()
        + " LASER_DRAW laser=%d visible=1 signature=%s pivot=%s tip=%s start=%s end=%s count=%d steps[pivot=%.4f tip=%.4f start=%.4f end=%.4f]"
        % [
            laser_index,
            signature,
            _vec(pivot_position),
            _vec(turret_tip),
            _vec(start),
            _vec(finish),
            count,
            pivot_step,
            tip_step,
            start_step,
            end_step,
        ]
    )

    # A target/cell/chunk change can legitimately move the endpoint. For a
    # continuous beam with the same signature, any large one-tick jump is an
    # error and is duplicated into the main diagnostic log for easy discovery.
    if was_visible and old_signature == signature:
        if (
            pivot_step > SMOOTH_POSITION_WARN_DISTANCE
            or tip_step > SMOOTH_POSITION_WARN_DISTANCE
            or start_step > SMOOTH_POSITION_WARN_DISTANCE
            or end_step > SMOOTH_POSITION_WARN_DISTANCE
        ):
            _trace_errors += 1
            var error_text := (
                "LASER_POSITION_ERROR laser=%d signature=%s "
                + "pivot_step=%.4f tip_step=%.4f start_step=%.4f end_step=%.4f "
                + "old_pivot=%s new_pivot=%s old_tip=%s new_tip=%s "
                + "old_start=%s new_start=%s old_end=%s new_end=%s"
            ) % [
                laser_index,
                signature,
                pivot_step,
                tip_step,
                start_step,
                end_step,
                _vec(old_pivot),
                _vec(pivot_position),
                _vec(old_tip),
                _vec(turret_tip),
                _vec(old_start),
                _vec(start),
                _vec(old_finish),
                _vec(finish),
            ]
            _trace_records.append(_trace_prefix() + " ERROR " + error_text)
            AppLogger.event(error_text)


func _trace_hidden_transition(
    laser_index: int,
    state: Dictionary,
    signature: String,
    pivot_position: Vector3,
    turret_tip: Vector3,
    reason: String
) -> void:
    var was_visible := bool(state.get("visible", false))
    var last_reason := str(state.get("last_hide_reason", ""))
    if was_visible or last_reason != reason:
        _trace_records.append(
            _trace_prefix()
            + " LASER_HIDDEN laser=%d reason=%s signature=%s pivot=%s tip=%s old_start=%s old_end=%s"
            % [
                laser_index,
                reason,
                signature,
                _vec(pivot_position),
                _vec(turret_tip),
                _vec(state.get("start", Vector3.ZERO) as Vector3),
                _vec(state.get("finish", Vector3.ZERO) as Vector3),
            ]
        )
    state["last_hide_reason"] = reason


func _trace_prefix() -> String:
    return "[%s] t=%.3fs tick=%d" % [
        Time.get_datetime_string_from_system(),
        float(Time.get_ticks_usec() - _trace_start_usec) / 1_000_000.0,
        _trace_tick,
    ]


func _vec(value: Vector3) -> String:
    return "(%.5f,%.5f,%.5f)" % [value.x, value.y, value.z]


func _build_beam_buffer(
    start: Vector3,
    finish: Vector3,
    count: int,
    phase_time: float
) -> PackedFloat32Array:
    var buffer := PackedFloat32Array()
    buffer.resize(MAX_BEAM_INSTANCES * TRANSFORM_STRIDE)

    var delta := finish - start
    var distance := delta.length()
    var direction := Vector3.FORWARD
    if distance > 0.000001:
        direction = delta / distance

    var helper := Vector3.UP
    if absf(direction.dot(helper)) > 0.92:
        helper = Vector3.RIGHT
    var side := direction.cross(helper).normalized()
    if side.length_squared() < 0.000001:
        side = Vector3.RIGHT
    var up := side.cross(direction).normalized()

    for index in range(MAX_BEAM_INSTANCES):
        var base := index * TRANSFORM_STRIDE
        buffer[base] = 1.0
        buffer[base + 5] = 1.0
        buffer[base + 10] = 1.0

        if index >= count:
            continue

        var t := (
            float(index) / float(maxi(1, count - 1))
            if count > 1
            else 0.0
        )
        var position := start.lerp(finish, t)
        if index != 0 and index != count - 1:
            var phase := phase_time * 8.0 + float(index) * 1.73
            position += side * sin(phase) * 0.035
            position += up * cos(phase * 1.27) * 0.035

        buffer[base + 3] = position.x
        buffer[base + 7] = position.y
        buffer[base + 11] = position.z

    return buffer


func _set_hidden(state: Dictionary) -> void:
    var present_value = state.get("present", null)
    if present_value is MultiMeshInstance3D and is_instance_valid(present_value):
        var present := present_value as MultiMeshInstance3D
        present.visible = false
        if present.multimesh != null:
            RenderingServer.multimesh_set_visible_instances(
                present.multimesh.get_rid(),
                0
            )

    # Deliberately erase all prior beam geometry. This is stronger than merely
    # setting visible=false: no subsequent reappearance can accidentally use a
    # position captured before an obstruction/out-of-range transition.
    state["visible"] = false
    state["count"] = 0
    state["signature"] = ""
    state["current"] = PackedFloat32Array()
    state["start"] = Vector3.ZERO
    state["finish"] = Vector3.ZERO
    state["pivot_position"] = Vector3.ZERO
    state["turret_tip"] = Vector3.ZERO


func _restore_original_beams() -> void:
    for state_value in _states.values():
        if not (state_value is Dictionary):
            continue
        var state := state_value as Dictionary
        var source_value = state.get("source", null)
        var present_value = state.get("present", null)
        if source_value is MultiMeshInstance3D and is_instance_valid(source_value):
            (source_value as MultiMeshInstance3D).visible = bool(
                state.get("visible", false)
            )
        if present_value is MultiMeshInstance3D and is_instance_valid(present_value):
            (present_value as MultiMeshInstance3D).visible = false


func _free_state(key) -> void:
    var state_value = _states.get(key, null)
    if state_value is Dictionary:
        var state := state_value as Dictionary
        var present_value = state.get("present", null)
        if present_value is MultiMeshInstance3D and is_instance_valid(present_value):
            (present_value as MultiMeshInstance3D).queue_free()
    _states.erase(key)


func _clear_states() -> void:
    for key in _states.keys():
        _free_state(key)
    _states.clear()


func _log_stats_if_due() -> void:
    var now := Time.get_ticks_usec()
    var elapsed := now - _stats_start_usec
    if elapsed < STATS_INTERVAL_USEC:
        return

    var avg_ms := 0.0
    if _stats_ticks > 0:
        avg_ms = (
            float(_stats_sync_usec)
            / float(_stats_ticks)
            / 1000.0
        )
    AppLogger.event(
        "LASER_PRESENTER cpu_buffer active=%d avg_physics_sync_ms=%.3f resets=%d trace_errors=%d"
        % [_states.size(), avg_ms, _stats_resets, _trace_errors]
    )
    _stats_start_usec = now
    _stats_sync_usec = 0
    _stats_ticks = 0
    _stats_resets = 0


func _write_trace_log() -> void:
    var directory := ""
    if OS.has_feature("editor"):
        directory = ProjectSettings.globalize_path("res://")
    else:
        directory = OS.get_executable_path().get_base_dir()

    var path := directory.path_join(TRACE_FILE_NAME)
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        path = ProjectSettings.globalize_path("user://" + TRACE_FILE_NAME)
        file = FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        return

    for record in _trace_records:
        file.store_line(record)
    file.store_line(
        "Summary: ticks=%d position_errors=%d states=%d"
        % [_trace_tick, _trace_errors, _states.size()]
    )
    file.flush()
    file.close()


func _exit_tree() -> void:
    _restore_original_beams()
    _write_trace_log()
    _clear_states()
