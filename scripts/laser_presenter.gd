extends Node

# Lightweight presentation-only mining laser bridge for the Windows manual
# renderer. Simulation remains authoritative for targeting, obstruction,
# turret motion, mining state and beam visibility. We snapshot only the final
# 60 Hz endpoints and interpolate a single MeshInstance3D transform at monitor
# presentation rate. No MultiMesh buffer is rebuilt or uploaded per frame.
#
# The source MultiMesh is suppressed with its VisualInstance3D layer mask,
# never by changing `visible`. Simulation owns `visible`, so changing it here
# would feed the presenter's own hidden state back into the next physics tick.

const LASER_BARREL_LENGTH := 0.42
const LASER_MINING_SECONDS := 5.0
const LASER_SURFACE_TRANSITION_SECONDS := 1.50
const DISCONTINUITY_DISTANCE := 2.0
const SMOOTH_POSITION_WARN_DISTANCE := 0.75
const STATS_INTERVAL_USEC := 5_000_000
const BEAM_WIDTH := 0.065

var _enabled := false
var _scene_id := 0
var _states: Dictionary = {}

var _stats_start_usec := 0
var _stats_physics_usec := 0
var _stats_present_usec := 0
var _stats_ticks := 0
var _stats_presents := 0
var _stats_resets := 0
var _trace_errors := 0


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    process_physics_priority = 1_000_000

    _enabled = OS.has_feature("windows") and not OS.has_feature("headless")
    if not _enabled:
        set_physics_process(false)
        return

    _stats_start_usec = Time.get_ticks_usec()
    AppLogger.event(
        "LASER_PRESENTER transform_only enabled; "
        + "source MultiMesh suppressed by render layers; "
        + "no per-present MultiMesh buffer uploads"
    )


func _physics_process(_delta: float) -> void:
    if not _enabled or not FramePacer.is_manual_presentation_enabled():
        _restore_original_beams()
        return

    var started := Time.get_ticks_usec()
    var scene := get_tree().current_scene
    if scene == null:
        _clear_states()
        return

    var current_scene_id := scene.get_instance_id()
    if current_scene_id != _scene_id:
        _clear_states()
        _scene_id = current_scene_id
        AppLogger.event("LASER_SCENE_CHANGE scene=%d" % current_scene_id)

    var lasers_value = scene.get("mining_lasers")
    if not (lasers_value is Array):
        _clear_states()
        return

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
        if not is_instance_valid(source) or not is_instance_valid(pivot):
            continue

        var key := source.get_instance_id()
        seen[key] = true
        var state := _ensure_state(key, source)
        if state.is_empty():
            continue

        # Capture Simulation's final visibility decision. The source MultiMesh
        # is hidden from rendering through layers=0 in _ensure_state(), which
        # deliberately leaves source.visible untouched for Simulation to own.
        var source_visible := source.visible
        var endpoint_data := _laser_endpoints(laser, pivot)
        var signature := _laser_signature(laser)
        var pivot_position := pivot.global_position
        var turret_tip := _laser_tip_world(pivot)

        if not source_visible or endpoint_data.is_empty():
            var reason := _hidden_reason(laser, source_visible, endpoint_data)
            if bool(state.get("visible", false)) or str(state.get("last_hide_reason", "")) != reason:
                AppLogger.event(
                    "LASER_HIDDEN laser=%d reason=%s signature=%s pivot=%s tip=%s"
                    % [
                        laser_index,
                        reason,
                        signature,
                        _vec(pivot_position),
                        _vec(turret_tip),
                    ]
                )
            _set_hidden(state)
            state["last_hide_reason"] = reason
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
        else:
            # Reappearing/retargeted beams start exactly at the new geometry.
            # No position from before an obstruction/out-of-range transition is
            # retained or interpolated.
            state["prev_start"] = start
            state["prev_finish"] = finish
            state["prev_tip"] = turret_tip
            state["prev_pivot"] = pivot_position
            _stats_resets += 1
            AppLogger.event(
                "LASER_RESET laser=%d reason=%s signature=%s start=%s end=%s tip=%s"
                % [
                    laser_index,
                    _reset_reason(
                        was_visible,
                        old_signature,
                        signature,
                        old_start,
                        start,
                        old_finish,
                        finish
                    ),
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
        state["signature"] = signature
        state["visible"] = true
        state["laser_index"] = laser_index
        state["last_hide_reason"] = ""

        var present := state["present"] as MeshInstance3D
        present.visible = true
        _states[key] = state

    for key in _states.keys():
        if not seen.has(key):
            _free_state(key)

    _stats_physics_usec += Time.get_ticks_usec() - started
    _stats_ticks += 1
    _log_stats_if_due()


# Called only when FramePacer has a real presentation token. This path changes
# Node3D transforms only; it performs no RenderingServer resource-buffer writes.
func prepare_for_present(interpolation_fraction: float) -> int:
    if not _enabled or not FramePacer.is_manual_presentation_enabled():
        return 0

    var started := Time.get_ticks_usec()
    var fraction := clampf(interpolation_fraction, 0.0, 1.0)

    for key in _states.keys():
        var state_value = _states.get(key, null)
        if not (state_value is Dictionary):
            continue
        var state := state_value as Dictionary
        if not bool(state.get("visible", false)):
            continue

        var present_value = state.get("present", null)
        if not (present_value is MeshInstance3D) or not is_instance_valid(present_value):
            continue
        var present := present_value as MeshInstance3D

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

        _apply_beam_transform(present, draw_start, draw_finish)
        _check_present_jump(
            state,
            draw_pivot,
            draw_tip,
            draw_start,
            draw_finish
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
        if present_value is MeshInstance3D and is_instance_valid(present_value):
            # Keep the original beam out of render passes without changing the
            # Simulation-owned visible flag.
            source.layers = 0
            return existing_state

    var parent := source.get_parent()
    if parent == null:
        return {}

    var beam_mesh := BoxMesh.new()
    beam_mesh.size = Vector3.ONE

    var material: Material = null
    if source.multimesh != null and source.multimesh.mesh != null:
        var source_mesh := source.multimesh.mesh
        if source_mesh.get_surface_count() > 0:
            material = source_mesh.surface_get_material(0)

    if material == null:
        var fallback := StandardMaterial3D.new()
        fallback.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
        fallback.albedo_color = Color(0.20, 0.75, 1.0, 0.92)
        fallback.emission_enabled = true
        fallback.emission = Color(0.10, 0.55, 1.0)
        fallback.emission_energy_multiplier = 2.0
        material = fallback
    beam_mesh.material = material

    var present := MeshInstance3D.new()
    present.name = "PresentedMiningBeam_%d" % key
    present.mesh = beam_mesh
    present.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    present.visible = false
    present.top_level = true
    present.set_physics_interpolation_mode(Node.PHYSICS_INTERPOLATION_MODE_OFF)
    parent.add_child(present)

    var source_layers := source.layers
    source.layers = 0

    var state := {
        "source": source,
        "source_layers": source_layers,
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
        "last_present_start": Vector3.ZERO,
        "last_present_finish": Vector3.ZERO,
        "last_present_tip": Vector3.ZERO,
        "last_present_pivot": Vector3.ZERO,
        "had_present": false,
        "last_hide_reason": "",
    }
    _states[key] = state
    return state


func _apply_beam_transform(
    present: MeshInstance3D,
    start: Vector3,
    finish: Vector3
) -> void:
    var delta := finish - start
    var distance := delta.length()
    if distance <= 0.0001:
        present.visible = false
        return

    var direction := delta / distance
    var up := Vector3.UP
    if absf(direction.dot(up)) > 0.95:
        up = Vector3.RIGHT

    var basis := Basis.looking_at(direction, up)
    basis = basis.scaled(Vector3(BEAM_WIDTH, BEAM_WIDTH, distance))
    present.global_transform = Transform3D(basis, (start + finish) * 0.5)
    present.visible = true


func _check_present_jump(
    state: Dictionary,
    pivot: Vector3,
    tip: Vector3,
    start: Vector3,
    finish: Vector3
) -> void:
    if not bool(state.get("had_present", false)):
        return

    var old_start := state.get("last_present_start", start) as Vector3
    var old_finish := state.get("last_present_finish", finish) as Vector3
    var old_tip := state.get("last_present_tip", tip) as Vector3
    var old_pivot := state.get("last_present_pivot", pivot) as Vector3

    var pivot_step := old_pivot.distance_to(pivot)
    var tip_step := old_tip.distance_to(tip)
    var start_step := old_start.distance_to(start)
    var finish_step := old_finish.distance_to(finish)
    var largest := maxf(maxf(pivot_step, tip_step), maxf(start_step, finish_step))
    if largest <= SMOOTH_POSITION_WARN_DISTANCE:
        return

    _trace_errors += 1
    AppLogger.event(
        (
            "LASER_POSITION_ERROR laser=%d signature=%s "
            + "pivot_step=%.4f tip_step=%.4f start_step=%.4f end_step=%.4f "
            + "old_pivot=%s new_pivot=%s old_tip=%s new_tip=%s "
            + "old_start=%s new_start=%s old_end=%s new_end=%s"
        )
        % [
            int(state.get("laser_index", -1)),
            str(state.get("signature", "")),
            pivot_step,
            tip_step,
            start_step,
            finish_step,
            _vec(old_pivot),
            _vec(pivot),
            _vec(old_tip),
            _vec(tip),
            _vec(old_start),
            _vec(start),
            _vec(old_finish),
            _vec(finish),
        ]
    )


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
                (fire_time - transition_start)
                / LASER_SURFACE_TRANSITION_SECONDS,
                0.0,
                1.0
            )
            var smooth_transition := transition * transition * (3.0 - 2.0 * transition)
            finish = target_node.global_position.lerp(
                cell_value as Vector3,
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


func _set_hidden(state: Dictionary) -> void:
    var present_value = state.get("present", null)
    if present_value is MeshInstance3D and is_instance_valid(present_value):
        (present_value as MeshInstance3D).visible = false

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
    state["last_present_start"] = Vector3.ZERO
    state["last_present_finish"] = Vector3.ZERO
    state["last_present_tip"] = Vector3.ZERO
    state["last_present_pivot"] = Vector3.ZERO
    state["had_present"] = false


func _free_state(key) -> void:
    var state_value = _states.get(key, null)
    if state_value is Dictionary:
        var state := state_value as Dictionary
        var source_value = state.get("source", null)
        if source_value is MultiMeshInstance3D and is_instance_valid(source_value):
            var source := source_value as MultiMeshInstance3D
            source.layers = int(state.get("source_layers", source.layers))

        var present_value = state.get("present", null)
        if present_value is Node and is_instance_valid(present_value):
            (present_value as Node).queue_free()
    _states.erase(key)


func _clear_states() -> void:
    var keys := _states.keys()
    for key in keys:
        _free_state(key)


func _restore_original_beams() -> void:
    # _free_state restores each source's original render-layer mask. Do not
    # force source.visible here; that property belongs to Simulation.
    _clear_states()


func _visible_state_count() -> int:
    var active := 0
    for state_value in _states.values():
        if state_value is Dictionary:
            var state := state_value as Dictionary
            if bool(state.get("visible", false)):
                active += 1
    return active


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
        (
            "LASER_PRESENTER transform_only active=%d avg_physics_ms=%.3f "
            + "avg_present_ms=%.3f presents=%d resets=%d trace_errors=%d"
        )
        % [
            _visible_state_count(),
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


func _vec(value: Vector3) -> String:
    return "(%.5f,%.5f,%.5f)" % [value.x, value.y, value.z]


func _exit_tree() -> void:
    if not _enabled:
        return
    AppLogger.event(
        "LASER_PRESENTER exit transform_only trace_errors=%d" % _trace_errors
    )
    _restore_original_beams()
