extends Node

# Windows desktop presentation scheduler.
#
# A worker thread owns the presentation clock and posts frame tokens at the
# monitor refresh interval. The main Godot thread never waits for that clock:
# it polls tokens non-blockingly and manually draws only when a frame is due.
# Gameplay/physics stay on Godot's fixed physics tick.
#
# Physics interpolation stays enabled for ordinary scene nodes, but the mining
# laser MultiMeshes are handled separately. Their instance count is rebuilt by
# gameplay code as beam length changes, which invalidates Godot's automatic
# MultiMesh interpolation history. We therefore disable automatic interpolation
# on those MultiMeshes, snapshot their physics-tick buffers, and interpolate
# those buffers ourselves immediately before each manual draw.

const FALLBACK_TARGET_FPS := 60.0
const STATS_INTERVAL_USEC := 5_000_000
const LATE_RESET_FRAMES := 3
const WORKER_SPIN_TAIL_USEC := 350
const WORKER_SLEEP_SLICE_USEC := 1000
const LASER_DISCONTINUITY_DISTANCE := 2.0

var target_fps := FALLBACK_TARGET_FPS
var measured_fps := 0.0
var presentation_serial := 0
var last_present_interval_usec := 0
var last_force_draw_usec := 0

var _enabled := false
var _worker_started := false
var _interval_usec := 0
var _stats_start_usec := 0
var _stats_frame_count := 0
var _stats_dropped_tokens := 0
var _stats_force_draw_usec := 0
var _stats_laser_prepare_usec := 0
var _stats_laser_resets := 0
var _last_present_usec := 0

var _present_semaphore := Semaphore.new()
var _pacing_thread := Thread.new()
var _stop_mutex := Mutex.new()
var _stop_requested := false

# Keyed by MultiMeshInstance3D instance id. Each entry contains the previous and
# current raw physics buffers. The beam particles use identity bases, so linear
# interpolation of the 12-float Transform3D records is exact for their motion.
var _laser_states: Dictionary = {}


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    # Draw before normal idle callbacks. Physics snapshots are captured after
    # normal scene physics callbacks using the very high physics priority below.
    process_priority = -1_000_000
    process_physics_priority = 1_000_000

    if (
        OS.has_feature("android")
        or OS.has_feature("ios")
        or OS.has_feature("mobile")
    ):
        RenderingServer.set_render_loop_enabled(true)
        DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
        Engine.max_fps = 0
        set_process(false)
        set_physics_process(false)
        return

    _enabled = OS.has_feature("windows") and not OS.has_feature("headless")
    if not _enabled:
        set_process(false)
        set_physics_process(false)
        return

    Engine.max_fps = 0
    DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
    RenderingServer.set_render_loop_enabled(false)
    get_tree().physics_interpolation = true

    var refresh := DisplayServer.screen_get_refresh_rate()
    if refresh > 1.0:
        target_fps = refresh
    else:
        target_fps = FALLBACK_TARGET_FPS

    _interval_usec = max(1, int(round(1_000_000.0 / target_fps)))

    var now := Time.get_ticks_usec()
    _stats_start_usec = now
    _last_present_usec = now

    var start_result := _pacing_thread.start(
        _pacing_thread_main,
        Thread.PRIORITY_NORMAL
    )
    if start_result != OK:
        _enabled = false
        RenderingServer.set_render_loop_enabled(true)
        set_process(false)
        set_physics_process(false)
        AppLogger.event(
            "FRAME_PACER threaded_present thread_start_failed error=%d"
            % start_result
        )
        return

    _worker_started = true
    AppLogger.event(
        "FRAME_PACER threaded_present enabled target_fps=%.3f interval_usec=%d "
        % [target_fps, _interval_usec]
        + "physics_tps=%d interpolation=%s engine_max_fps=%d vsync=%s driver=%s"
        % [
            Engine.physics_ticks_per_second,
            str(get_tree().physics_interpolation),
            Engine.max_fps,
            _vsync_name(DisplayServer.window_get_vsync_mode()),
            RenderingServer.get_current_rendering_driver_name(),
        ]
    )


func _physics_process(_delta: float) -> void:
    if not is_manual_presentation_enabled():
        return
    _capture_laser_multimeshes()


func _process(_delta: float) -> void:
    if not is_manual_presentation_enabled():
        return

    # Deliberately non-blocking. If no presentation token is ready, this outer
    # engine-loop iteration returns immediately without drawing another frame.
    if not _present_semaphore.try_wait():
        return

    # If startup/loading made us miss multiple deadlines, discard stale tokens
    # rather than issuing a catch-up render burst.
    var dropped := 0
    while _present_semaphore.try_wait():
        dropped += 1
    _stats_dropped_tokens += dropped

    var now := Time.get_ticks_usec()
    last_present_interval_usec = now - _last_present_usec
    _last_present_usec = now
    presentation_serial += 1

    var laser_start := Time.get_ticks_usec()
    _prepare_lasers_for_present()
    _stats_laser_prepare_usec += Time.get_ticks_usec() - laser_start

    var draw_start := Time.get_ticks_usec()
    RenderingServer.force_draw(
        true,
        float(_interval_usec) / 1_000_000.0
    )
    last_force_draw_usec = Time.get_ticks_usec() - draw_start

    _stats_force_draw_usec += last_force_draw_usec
    _stats_frame_count += 1

    var stats_elapsed := Time.get_ticks_usec() - _stats_start_usec
    if stats_elapsed >= STATS_INTERVAL_USEC:
        measured_fps = (
            float(_stats_frame_count) * 1_000_000.0
            / float(stats_elapsed)
        )
        var avg_draw_ms := 0.0
        var avg_laser_ms := 0.0
        if _stats_frame_count > 0:
            avg_draw_ms = (
                float(_stats_force_draw_usec)
                / float(_stats_frame_count)
                / 1000.0
            )
            avg_laser_ms = (
                float(_stats_laser_prepare_usec)
                / float(_stats_frame_count)
                / 1000.0
            )

        AppLogger.event(
            "FRAME_PACER threaded_present actual_fps=%.2f target=%.2f "
            % [measured_fps, target_fps]
            + "physics_tps=%d engine_loop_fps=%.1f avg_force_draw_ms=%.3f "
            % [
                Engine.physics_ticks_per_second,
                Engine.get_frames_per_second(),
                avg_draw_ms,
            ]
            + "avg_laser_interp_ms=%.3f laser_resets=%d dropped_tokens=%d"
            % [avg_laser_ms, _stats_laser_resets, _stats_dropped_tokens]
        )

        _stats_start_usec = Time.get_ticks_usec()
        _stats_frame_count = 0
        _stats_dropped_tokens = 0
        _stats_force_draw_usec = 0
        _stats_laser_prepare_usec = 0
        _stats_laser_resets = 0


func _capture_laser_multimeshes() -> void:
    var scene := get_tree().current_scene
    if scene == null:
        _laser_states.clear()
        return

    var lasers_value = scene.get("mining_lasers")
    if not (lasers_value is Array):
        _laser_states.clear()
        return

    var seen: Dictionary = {}

    for laser_value in lasers_value:
        if not (laser_value is Dictionary):
            continue

        var laser := laser_value as Dictionary
        var beam_value = laser.get("beam", null)
        if not (beam_value is MultiMeshInstance3D):
            continue

        var beam := beam_value as MultiMeshInstance3D
        if not is_instance_valid(beam) or beam.multimesh == null:
            continue

        var multimesh := beam.multimesh
        var key := beam.get_instance_id()
        seen[key] = true

        # The beam is the one object we interpolate ourselves. This prevents
        # Godot from trying to interpolate a MultiMesh whose allocation size is
        # repeatedly changed by the existing beam-generation code.
        beam.set_physics_interpolation_mode(
            Node.PHYSICS_INTERPOLATION_MODE_OFF
        )
        RenderingServer.multimesh_set_physics_interpolated(
            multimesh.get_rid(),
            false
        )

        var curr := multimesh.buffer
        var count := multimesh.instance_count
        var visible := beam.visible
        var previous := curr
        var reset := true

        var old_value = _laser_states.get(key, null)
        if old_value is Dictionary:
            var old := old_value as Dictionary
            var old_buffer = old.get("curr", PackedFloat32Array())
            var old_count := int(old.get("count", -1))
            var old_visible := bool(old.get("visible", false))

            if (
                old_buffer is PackedFloat32Array
                and old_count == count
                and old_visible
                and visible
                and (old_buffer as PackedFloat32Array).size() == curr.size()
            ):
                previous = old_buffer as PackedFloat32Array
                reset = _laser_buffer_discontinuous(previous, curr, count)

        if reset:
            previous = curr
            _stats_laser_resets += 1

        _laser_states[key] = {
            "beam": beam,
            "multimesh": multimesh,
            "prev": previous,
            "curr": curr,
            "count": count,
            "visible": visible,
        }

    for key in _laser_states.keys():
        if not seen.has(key):
            _laser_states.erase(key)


func _prepare_lasers_for_present() -> void:
    if _laser_states.is_empty():
        return

    var fraction := clampf(
        float(Engine.get_physics_interpolation_fraction()),
        0.0,
        1.0
    )

    for state_value in _laser_states.values():
        if not (state_value is Dictionary):
            continue
        var state := state_value as Dictionary

        var beam_value = state.get("beam", null)
        var multimesh_value = state.get("multimesh", null)
        if (
            not (beam_value is MultiMeshInstance3D)
            or not is_instance_valid(beam_value)
            or not (multimesh_value is MultiMesh)
        ):
            continue

        var beam := beam_value as MultiMeshInstance3D
        if not beam.visible or not bool(state.get("visible", false)):
            continue

        var multimesh := multimesh_value as MultiMesh
        var previous = state.get("prev", PackedFloat32Array())
        var current = state.get("curr", PackedFloat32Array())
        if (
            not (previous is PackedFloat32Array)
            or not (current is PackedFloat32Array)
        ):
            continue

        var prev_buffer := previous as PackedFloat32Array
        var curr_buffer := current as PackedFloat32Array
        if prev_buffer.size() != curr_buffer.size() or curr_buffer.is_empty():
            continue

        var render_buffer := curr_buffer.duplicate()
        for index in range(render_buffer.size()):
            render_buffer[index] = lerpf(
                prev_buffer[index],
                curr_buffer[index],
                fraction
            )

        # One buffer upload per beam is substantially cheaper and safer than
        # rewriting every instance transform through scene transforms on every
        # presented frame.
        multimesh.buffer = render_buffer


func _laser_buffer_discontinuous(
    previous: PackedFloat32Array,
    current: PackedFloat32Array,
    count: int
) -> bool:
    if count <= 0:
        return false
    if previous.size() != current.size() or current.size() < 12:
        return true

    var stride := int(current.size() / count)
    if stride < 12:
        return true

    var first_prev := _buffer_origin(previous, 0, stride)
    var first_curr := _buffer_origin(current, 0, stride)
    if first_prev.distance_to(first_curr) > LASER_DISCONTINUITY_DISTANCE:
        return true

    var last := count - 1
    var last_prev := _buffer_origin(previous, last, stride)
    var last_curr := _buffer_origin(current, last, stride)
    return (
        last_prev.distance_to(last_curr)
        > LASER_DISCONTINUITY_DISTANCE
    )


func _buffer_origin(
    buffer: PackedFloat32Array,
    instance_index: int,
    stride: int
) -> Vector3:
    var base := instance_index * stride
    return Vector3(
        buffer[base + 3],
        buffer[base + 7],
        buffer[base + 11]
    )


func _pacing_thread_main() -> void:
    var next_deadline := Time.get_ticks_usec() + _interval_usec

    while not _thread_should_stop():
        var now := Time.get_ticks_usec()

        # Sleep only on the worker thread, in short slices. A late worker wakeup
        # can delay a presentation token, but cannot suspend game logic or the
        # Windows event loop because the main thread never waits for it.
        while (
            not _thread_should_stop()
            and next_deadline - now > WORKER_SPIN_TAIL_USEC
        ):
            var remaining_before_spin := (
                next_deadline - now - WORKER_SPIN_TAIL_USEC
            )
            var sleep_usec := mini(
                WORKER_SLEEP_SLICE_USEC,
                maxi(1, remaining_before_spin)
            )
            OS.delay_usec(sleep_usec)
            now = Time.get_ticks_usec()

        if _thread_should_stop():
            return

        while now < next_deadline:
            now = Time.get_ticks_usec()

        if _thread_should_stop():
            return

        _present_semaphore.post()

        var lateness := maxi(0, now - next_deadline)
        next_deadline += _interval_usec
        if lateness >= _interval_usec * LATE_RESET_FRAMES:
            next_deadline = now + _interval_usec


func is_manual_presentation_enabled() -> bool:
    return _enabled and _worker_started


func _thread_should_stop() -> bool:
    _stop_mutex.lock()
    var result := _stop_requested
    _stop_mutex.unlock()
    return result


func _request_thread_stop() -> void:
    _stop_mutex.lock()
    _stop_requested = true
    _stop_mutex.unlock()


func _exit_tree() -> void:
    if _worker_started:
        _request_thread_stop()
        _pacing_thread.wait_to_finish()
        _worker_started = false

    if _enabled:
        RenderingServer.set_render_loop_enabled(true)


func _vsync_name(mode: DisplayServer.VSyncMode) -> String:
    match mode:
        DisplayServer.VSYNC_DISABLED:
            return "disabled"
        DisplayServer.VSYNC_ENABLED:
            return "enabled"
        DisplayServer.VSYNC_ADAPTIVE:
            return "adaptive"
        DisplayServer.VSYNC_MAILBOX:
            return "mailbox"
        _:
            return "unknown(%d)" % int(mode)
