extends Node

# Presentation-only mining laser bridge for the Windows manual renderer.
#
# The gameplay simulation continues to own targeting, mining progress, turret
# rotation, and the original beam nodes at the 60 Hz physics rate. This node
# never reads MultiMesh buffers back from RenderingServer. Instead, after each
# physics tick it derives the visible beam endpoints from gameplay state,
# builds current/previous transform buffers in CPU memory, and uploads both in
# one direction with multimesh_set_buffer_interpolated().
#
# The original simulation beam is hidden only after its visibility decision has
# been sampled. A separate fixed-size presentation MultiMesh is rendered. This
# avoids both per-tick instance-count reallocations in the visible beam and GPU
# readbacks that can synchronize/stall the main thread.

const MAX_BEAM_INSTANCES := 80
const PARTICLES_PER_UNIT := 6.5
const LASER_BARREL_LENGTH := 0.42
const LASER_MINING_SECONDS := 5.0
const LASER_SURFACE_TRANSITION_SECONDS := 1.50
const DISCONTINUITY_DISTANCE := 2.0
const STATS_INTERVAL_USEC := 5_000_000
const TRANSFORM_STRIDE := 12

var _enabled := false
var _scene_id := 0
var _states: Dictionary = {}
var _stats_start_usec := 0
var _stats_sync_usec := 0
var _stats_ticks := 0
var _stats_resets := 0


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

    var lasers_value = scene.get("mining_lasers")
    if not (lasers_value is Array):
        _clear_states()
        return

    var beam_phase := float(scene.get("beam_time"))
    var seen: Dictionary = {}
    var lasers := lasers_value as Array

    for laser_value in lasers:
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

        # Capture the simulation's decision before hiding its beam from the
        # manual renderer. The simulation writes this value every active tick.
        var source_visible := source.visible
        source.visible = false

        var endpoint_data := _laser_endpoints(laser, pivot)
        if not source_visible or endpoint_data.is_empty():
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
        var current := _build_beam_buffer(
            start,
            finish,
            count,
            beam_phase
        )

        var previous := current
        var reset := true
        if bool(state.get("visible", false)):
            var previous_buffer = state.get("current", PackedFloat32Array())
            if previous_buffer is PackedFloat32Array:
                var old_buffer := previous_buffer as PackedFloat32Array
                var old_count := int(state.get("count", -1))
                var old_start := state.get("start", start) as Vector3
                var old_finish := state.get("finish", finish) as Vector3
                var old_signature := str(state.get("signature", ""))
                var signature := _laser_signature(laser)
                reset = (
                    old_buffer.size() != current.size()
                    or old_count != count
                    or old_signature != signature
                    or old_start.distance_to(start) > DISCONTINUITY_DISTANCE
                    or old_finish.distance_to(finish) > DISCONTINUITY_DISTANCE
                )
                if not reset:
                    previous = old_buffer

        if reset:
            previous = current
            _stats_resets += 1

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
        state["signature"] = _laser_signature(laser)
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
    }
    _states[key] = state
    return state


func _laser_endpoints(laser: Dictionary, pivot: Node3D) -> Dictionary:
    var start := (
        pivot.global_position
        + pivot.global_basis.y.normalized() * LASER_BARREL_LENGTH
    )

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
    state["visible"] = false
    state["count"] = 0
    state["signature"] = ""


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
        "LASER_PRESENTER cpu_buffer active=%d avg_physics_sync_ms=%.3f resets=%d"
        % [_states.size(), avg_ms, _stats_resets]
    )
    _stats_start_usec = now
    _stats_sync_usec = 0
    _stats_ticks = 0
    _stats_resets = 0


func _exit_tree() -> void:
    _restore_original_beams()
    _clear_states()
