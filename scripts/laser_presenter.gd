extends Node

# Presentation-only mining laser bridge for the Windows manual renderer.
#
# The 60 Hz simulation remains the sole owner of targeting, obstruction,
# turret rotation, mining progress, and beam visibility. This node snapshots
# that completed physics state into CPU-side previous/current endpoints.
#
# FramePacer calls prepare_for_present() only when an actual monitor frame is
# due. That function performs no waits and no RenderingServer readbacks: it
# interpolates the cached CPU endpoints, builds a small beam buffer, uploads it,
# and returns immediately before force_draw().
#
# Hidden/obstructed/out-of-range beams erase all interpolation history. A beam
# that reappears starts from its current muzzle/end positions and can never
# interpolate from geometry captured before it became hidden.

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
const PRESENT_TRACE_EVERY := 10

var _enabled := false
var _scene_id := 0
var _states: Dictionary = {}

var _stats_start_usec := 0
var _stats_physics_usec := 0
var _stats_present_usec := 0
var _stats_ticks := 0
var _stats_presents := 0
var _stats_resets := 0

var _trace_records: Array[String] = []
var _trace_start_usec := 0
var _trace_tick := 0
var _trace_present := 0
var _trace_errors := 0


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    # Snapshot only after Simulation has completed its physics update.
    process_physics_priority = 1_000_000

    _enabled = OS.has_feature("windows") and not OS.has_feature("headless")
    if not _enabled:
        set_physics_process(false)
        return

    _stats_start_usec = Time.get_ticks_usec()
    _trace_start_usec = _stats_start_usec
    _trace_records.append(
        "SpaceMiner mining-laser presentation trace\n"
        + "Started: %s\n" % Time.get_datetime_string_from_system()
        + "Engine: %s\n" % str(Engine.get_version_info().get("string", "unknown"))
        + "Mode: CPU endpoint snapshots + manual per-present buffer upload\n"
        + "No RenderingServer readbacks are used.\n"
        + "Smooth-position warning distance: %.3f units/present\n" % SMOOTH_POSITION_WARN_DISTANCE
        + "All trace data is buffered in memory until normal shutdown."
    )


func _physics_process(_delta: float) -> void:
    if not _enabled or not FramePacer.is_manual_presentation_enabled():
        _restore_original_beams()
        return

    var started := Time.get_ticks_usec()
    _trace_tick += 1

    var scene := get_tree().current_scene
    if scene == null:
        _clear_states()
        return

    var current_scene_id := scene.get_instance_id()
    if current_scene_id != _scene_id:
        _trace_records.append(
            _trace_prefix() + " SCENE_CHANGE old=%d new=%d"
            % [_scene_id, current_scene_id]
        )
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
        if not (source_value is MultiMeshInstance3D) or not (pivot_value is Node3D):
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

        # Simulation writes beam.visible every physics tick. Capture that final
        # decision, then hide only the simulation beam so the presenter is the
        # sole rendered copy under manual presentation.
        var source_visible := source.visible
        var endpoint_data := _laser_endpoints(laser, pivot)
        var signature := _laser_signature(laser)
        var pivot_position := pivot.global_position
        var turret_tip := _laser_tip_world(pivot)
        source.visible = false

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
        var was_visible := bool(state.get("visible", false))
        var old_signature := str(state.get("signature", ""))
        var old_start := state.get("curr_start", start) as Vector3
        var old_finish := state.get("curr_finish", finish) as Vector3

        var continuous := (
            was_visible
            and old_signature == signature
            and old_start.distance_to(start) <= DISCONTINUITY_DISTANCE
            and old_finish.distance_to(finish) <= DISCONTINUITY_DISTANCE
        )

        if continuous:
            state["prev_start"] = old_start
            state["prev_finish"] = old_finish
            state["prev_tip"] = state.get("curr_tip", turret_tip)
            state["prev_pivot"] = state.get("curr_pivot", pivot_position)
            state["prev_phase"] = float(state.get("curr_phase", beam_phase))
        else:
            # First visible tick after hidden/target change/discontinuity starts
            # from the NEW state. No stale geometry can participate.
            state["prev_start"] = start
            state["prev_finish"] = finish
            state["prev_tip"] = turret_tip
            state["prev_pivot"] = pivot_position
            state["prev_phase"] = beam_phase
            _stats_resets += 1
            _trace_records.append(
                _trace_prefix()
                + " LASER_RESET laser=%d reason=%s signature=%s start=%s end=%s tip=%s"
                % [
                    laser_index,
                    _reset_reason(was_visible, old_signature, signature, old_start, start, old_finish, finish),
                    signature,
                    _vec(start),
                    _vec(finish),
                    _vec(turret_tip),
                ]
            )

        state["curr_start"] = start
        state["curr_finish"] = finish
        state["curr_tip"] = turret_tip
        state["curr_pivot"] = pivot_position
        state["curr_phase"] = beam_phase
        state["signature"] = signature
        state["visible"] = true
        state["laser_index"] = laser_index
        state["last_hide_reason"] = ""

        var present := state["present"] as MultiMeshInstance3D
        present.visible = true
        _states[key] = state

        _trace_physics_sample(
            laser_index,
            signature,
            pivot_position,
            turret_tip,
            start,
            finish
        )

    for key in _states.keys():
        if not seen.has(key):
            _free_state(key)

    _stats_physics_usec += Time.get_ticks_usec() - started
    _stats_ticks += 1
    _log_stats_if_due()


# Called by FramePacer exactly once for an actual presented frame.
# Returns elapsed microseconds so FramePacer can include this work in its stats.
func prepare_for_present(interpolation_fraction: float) -> int:
    if not _enabled or not FramePacer.is_manual_presentation_enabled():
        return 0

    var started := Time.get_ticks_usec()
    var fraction := clampf(interpolation_fraction, 0.0, 1.0)
    _trace_present += 1

    for key in _states.keys():
        var state_value = _states.get(key, null)
        if not (state_value is Dictionary):
            continue
        var state := state_value as Dictionary
        if not bool(state.get("visible", false)):
            continue

        var present_value = state.get("present", null)
        if not (present_value is MultiMeshInstance3D) or not is_instance_valid(present_value):
            continue
        var present := present_value as MultiMeshInstance3D
        if present.multimesh == null:
            continue

        var prev_start := state.get("prev_start", Vector3.ZERO) as Vector3
        var curr_start := state.get("curr_start", prev_start) as Vector3
        var prev_finish := state.get("prev_finish", Vector3.ZERO) as Vector3
        var curr_finish := state.get("curr_finish", prev_finish) as Vector3
        var prev_tip := state.get("prev_tip", Vector3.ZERO) as Vector3
        var curr_tip := state.get("curr_tip", prev_tip) as Vector3
        var prev_pivot := state.get("prev_pivot", Vector3.ZERO) as Vector3
        var curr_pivot := state.get("curr_pivot", prev_pivot) as Vector3

        var draw_start := prev_start.lerp(curr_start, fraction)
        var draw_finish := prev_finish.lerp(curr_finish, fraction)
        var draw_tip := prev_tip.lerp(curr_tip, fraction)
        var draw_pivot := prev_pivot.lerp(curr_pivot, fraction)
        var draw_phase := lerpf(
            float(state.get("prev_phase", 0.0)),
            float(state.get("curr_phase", 0.0)),
            fraction
        )

        var distance := draw_start.distance_to(draw_finish)
        var count := clampi(
            int(ceil(distance * PARTICLES_PER_UNIT)),
            1,
            MAX_BEAM_INSTANCES
        )
        var buffer := _build_beam_buffer(
            draw_start,
            draw_finish,
            count,
            draw_phase
        )

        # Upload-only path. We never read the RenderingServer/MultiMesh state.
        var rid := present.multimesh.get_rid()
        RenderingServer.multimesh_set_buffer(rid, buffer)
        RenderingServer.multimesh_set_visible_instances(rid, count)
        present.visible = true

        _trace_present_sample(
            state,
            draw_pivot,
            draw_tip,
            draw_start,
            draw_finish,
            count,
            fraction
        )

        state["last_present_start"] = draw_start
        state["last_present_finish"] = draw_finish
        state["last_present_tip"] = draw_tip
        state["last_present_pivot"] = draw_pivot
        state["had_present"] = true
        _states[key] = state

    var elapsed := Time.get_ticks_usec() - started
    _stats_present_usec += elapsed
    _stats_presents += 1
    return elapsed


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
    present.set_physics_interpolation_mode(Node.PHYSICS_INTERPOLATION_MODE_OFF)
    parent.add_child(present)

    # The presenter performs interpolation itself. Godot must not retain a
    # second, independent history for this MultiMesh.
    RenderingServer.multimesh_set_physics_interpolated(multimesh.get_rid(), false)

    var state := {
        "source": source,
        "present": present,
        "visible": false,
        "signature": "",
        "laser_index": -1,
        "prev_start": Vector3.ZERO,
        "curr_start": Vector3.ZERO,
        "prev_finish": Vector3.ZERO,
        "curr_finish": Vector3.ZERO,
        "prev_tip": Vector3.ZERO,
        "curr_tip": Vector3.ZERO,
        "prev_pivot": Vector3.ZERO,
        "curr_pivot": Vector3.ZERO,
        "prev_phase": 0.0,
        "curr_phase": 0.0,
        "last_present_start": Vector3.ZERO,
        "last_present_finish": Vector3.ZERO,
        "last_present_tip": Vector3.ZERO,
        "last_present_pivot": Vector3.ZERO,
        "had_present": false,
        "last_hide_reason": "",
    }
    _states[key] = state
    return state


func _laser_tip_world(pivot: Node3D) -> Vector3:
    return pivot.global_position + pivot.global_basis.y.normalized() * LASER_BARREL_LENGTH


func _laser_endpoints(laser: Dictionary, pivot: Node3D) -> Dictionary:
    var start := _laser_tip_world(pivot)

    var chunk = laser.get("chunk", null)
    if chunk is Node3D and is_instance_valid(chunk):
        return {"start": start, "finish": (chunk as Node3D).global_position}

    var target = laser.get("target", null)
    if not (target is Node3D) or not is_instance_valid(target):
        return {}

    var target_node := target as Node3D
    var finish := target_node.global_position
    var reserved = laser.get("reserved_cell", null)
    if reserved is Vector3i and target_node.has_method("cell_world_position"):
        var cell_value = target_node.call("cell_world_position", reserved)
        if cell_value is Vector3:
            var transition_start := LASER_MINING_SECONDS - LASER_SURFACE_TRANSITION_SECONDS
            var fire_time := float(laser.get("fire_time", 0.0))
            var transition := clampf(
                (fire_time - transition_start) / LASER_SURFACE_TRANSITION_SECONDS,
                0.0,
                1.0
            )
            var smooth_transition := transition * transition * (3.0 - 2.0 * transition)
            finish = target_node.global_position.lerp(cell_value as Vector3, smooth_transition)

    return {"start": start, "finish": finish}


func _laser_signature(laser: Dictionary) -> String:
    var chunk = laser.get("chunk", null)
    if chunk is Object and is_instance_valid(chunk):
        return "chunk:%d" % (chunk as Object).get_instance_id()

    var target = laser.get("target", null)
    var target_id := 0
    if target is Object and is_instance_valid(target):
        target_id = (target as Object).get_instance_id()
    return "target:%d:cell:%s" % [target_id, str(laser.get("reserved_cell", null))]


func _hidden_reason(laser: Dictionary, source_visible: bool, endpoint_data: Dictionary) -> String:
    if endpoint_data.is_empty():
        var target = laser.get("target", null)
        var chunk = laser.get("chunk", null)
        if chunk == null and (target == null or not is_instance_valid(target)):
            return "no_target_or_out_of_range"
        return "no_endpoints"
    if not source_visible:
        return "simulation_hidden_obstructed_or_unaligned"
    return "hidden"


func _reset_reason(
    was_visible: bool,
    old_signature: String,
    signature: String,
    old_start: Vector3,
    start: Vector3,
    old_finish: Vector3,
    finish: Vector3
) -> String:
    if not was_visible:
        return "new_or_reappeared"
    if old_signature != signature:
        return "signature_change"
    if old_start.distance_to(start) > DISCONTINUITY_DISTANCE:
        return "start_discontinuity"
    if old_finish.distance_to(finish) > DISCONTINUITY_DISTANCE:
        return "finish_discontinuity"
    return "reset"


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

        var t := float(index) / float(maxi(1, count - 1)) if count > 1 else 0.0
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
            RenderingServer.multimesh_set_visible_instances(present.multimesh.get_rid(), 0)

    # Hard reset of ALL geometry and presentation history.
    state["visible"] = false
    state["signature"] = ""
    state["prev_start"] = Vector3.ZERO
    state["curr_start"] = Vector3.ZERO
    state["prev_finish"] = Vector3.ZERO
    state["curr_finish"] = Vector3.ZERO
    state["prev_tip"] = Vector3.ZERO
    state["curr_tip"] = Vector3.ZERO
    state["prev_pivot"] = Vector3.ZERO
    state["curr_pivot"] = Vector3.ZERO
    state["prev_phase"] = 0.0
    state["curr_phase"] = 0.0
    state["last_present_start"] = Vector3.ZERO
    state["last_present_finish"] = Vector3.ZERO
    state["last_present_tip"] = Vector3.ZERO
    state["last_present_pivot"] = Vector3.ZERO
    state["had_present"] = false


func _trace_physics_sample(
    laser_index: int,
    signature: String,
    pivot_position: Vector3,
    turret_tip: Vector3,
    start: Vector3,
    finish: Vector3
) -> void:
    _trace_records.append(
        _trace_prefix()
        + " LASER_PHYSICS laser=%d signature=%s pivot=%s tip=%s start=%s end=%s"
        % [
            laser_index,
            signature,
            _vec(pivot_position),
            _vec(turret_tip),
            _vec(start),
            _vec(finish),
        ]
    )


func _trace_present_sample(
    state: Dictionary,
    pivot_position: Vector3,
    turret_tip: Vector3,
    start: Vector3,
    finish: Vector3,
    count: int,
    fraction: float
) -> void:
    var laser_index := int(state.get("laser_index", -1))
    var signature := str(state.get("signature", ""))
    var had_present := bool(state.get("had_present", false))

    var old_start := state.get("last_present_start", start) as Vector3
    var old_finish := state.get("last_present_finish", finish) as Vector3
    var old_tip := state.get("last_present_tip", turret_tip) as Vector3
    var old_pivot := state.get("last_present_pivot", pivot_position) as Vector3

    var start_step := old_start.distance_to(start) if had_present else 0.0
    var end_step := old_finish.distance_to(finish) if had_present else 0.0
    var tip_step := old_tip.distance_to(turret_tip) if had_present else 0.0
    var pivot_step := old_pivot.distance_to(pivot_position) if had_present else 0.0

    if _trace_present % PRESENT_TRACE_EVERY == 0:
        _trace_records.append(
            _trace_present_prefix()
            + " LASER_PRESENT laser=%d signature=%s fraction=%.4f pivot=%s tip=%s start=%s end=%s count=%d steps[pivot=%.4f tip=%.4f start=%.4f end=%.4f]"
            % [
                laser_index,
                signature,
                fraction,
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

    if had_present and (
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
        _trace_records.append(_trace_present_prefix() + " ERROR " + error_text)
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
                _vec(state.get("curr_start", Vector3.ZERO) as Vector3),
                _vec(state.get("curr_finish", Vector3.ZERO) as Vector3),
            ]
        )
    state["last_hide_reason"] = reason


func _trace_prefix() -> String:
    return "[%s] t=%.3fs tick=%d" % [
        Time.get_datetime_string_from_system(),
        float(Time.get_ticks_usec() - _trace_start_usec) / 1_000_000.0,
        _trace_tick,
    ]


func _trace_present_prefix() -> String:
    return "[%s] t=%.3fs present=%d" % [
        Time.get_datetime_string_from_system(),
        float(Time.get_ticks_usec() - _trace_start_usec) / 1_000_000.0,
        _trace_present,
    ]


func _vec(value: Vector3) -> String:
    return "(%.5f,%.5f,%.5f)" % [value.x, value.y, value.z]


func _restore_original_beams() -> void:
    for state_value in _states.values():
        if not (state_value is Dictionary):
            continue
        var state := state_value as Dictionary
        var source_value = state.get("source", null)
        var present_value = state.get("present", null)
        if source_value is MultiMeshInstance3D and is_instance_valid(source_value):
            (source_value as MultiMeshInstance3D).visible = bool(state.get("visible", false))
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

    var avg_physics_ms := 0.0
    if _stats_ticks > 0:
        avg_physics_ms = float(_stats_physics_usec) / float(_stats_ticks) / 1000.0

    var avg_present_ms := 0.0
    if _stats_presents > 0:
        avg_present_ms = float(_stats_present_usec) / float(_stats_presents) / 1000.0

    AppLogger.event(
        "LASER_PRESENTER cpu_endpoint active=%d avg_physics_ms=%.3f avg_present_ms=%.3f presents=%d resets=%d trace_errors=%d"
        % [
            _states.size(),
            avg_physics_ms,
            avg_present_ms,
            _stats_presents,
            _stats_resets,
            _trace_errors,
        ]
    )

    _stats_start_usec = now
    _stats_physics_usec = 0
    _stats_present_usec = 0
    _stats_ticks = 0
    _stats_presents = 0
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
        "Summary: physics_ticks=%d presents=%d position_errors=%d states=%d"
        % [_trace_tick, _trace_present, _trace_errors, _states.size()]
    )
    file.flush()
    file.close()


func _exit_tree() -> void:
    _restore_original_beams()
    _write_trace_log()
    _clear_states()
