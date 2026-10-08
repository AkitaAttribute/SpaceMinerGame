extends Node

# Windows desktop presentation scheduler.
#
# The main Godot thread never waits for frame pacing. A worker thread owns the
# presentation clock and posts frame tokens at the monitor refresh interval.
# The main thread polls those tokens without blocking and draws at most one
# frame for the newest token. Gameplay/physics remain on Godot's fixed physics
# tick, with physics interpolation providing smooth presentation between ticks.
#
# This avoids both failure modes already observed on this system:
# - blocking the main thread, which produced periodic 130-180 ms stalls;
# - allowing every uncapped engine-loop iteration to render, which produced
#   tens of thousands of rendered frames per second.

const FALLBACK_TARGET_FPS := 60.0
const STATS_INTERVAL_USEC := 5_000_000
const LATE_RESET_FRAMES := 3
const WORKER_SPIN_TAIL_USEC := 350
const WORKER_SLEEP_SLICE_USEC := 1000

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
var _last_present_usec := 0

var _present_semaphore := Semaphore.new()
var _pacing_thread := Thread.new()
var _stop_mutex := Mutex.new()
var _stop_requested := false


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    # Consume a presentation token before normal scene _process callbacks. This
    # also makes the frame-stage probe observe only completed manual draws.
    process_priority = -1_000_000

    if OS.has_feature("android") or OS.has_feature("ios") or OS.has_feature("mobile"):
        RenderingServer.set_render_loop_enabled(true)
        DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
        Engine.max_fps = 0
        set_process(false)
        return

    _enabled = OS.has_feature("windows") and not OS.has_feature("headless")
    if not _enabled:
        set_process(false)
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


func _process(_delta: float) -> void:
    if not is_manual_presentation_enabled():
        return

    # This is deliberately non-blocking. If no presentation token is ready,
    # this engine-loop iteration immediately returns without advancing game
    # state or rendering another frame.
    if not _present_semaphore.try_wait():
        return

    # If rendering or startup caused us to miss more than one presentation
    # deadline, discard stale tokens instead of issuing a catch-up render burst.
    var dropped := 0
    while _present_semaphore.try_wait():
        dropped += 1
    _stats_dropped_tokens += dropped

    var now := Time.get_ticks_usec()
    last_present_interval_usec = now - _last_present_usec
    _last_present_usec = now
    presentation_serial += 1

    var draw_start := now
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
        if _stats_frame_count > 0:
            avg_draw_ms = (
                float(_stats_force_draw_usec)
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
            + "dropped_tokens=%d"
            % _stats_dropped_tokens
        )

        _stats_start_usec = Time.get_ticks_usec()
        _stats_frame_count = 0
        _stats_dropped_tokens = 0
        _stats_force_draw_usec = 0


func _pacing_thread_main() -> void:
    var next_deadline := Time.get_ticks_usec() + _interval_usec

    while not _thread_should_stop():
        var now := Time.get_ticks_usec()

        # Sleep only on the worker thread, in short slices. The 2 ms diagnostic
        # heartbeat has already shown that a sleeping worker remains responsive
        # while the problematic stalls affect the main thread. The main thread
        # never waits for this worker.
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

        # Precision tail stays off the main thread. Even a late worker wakeup
        # cannot directly suspend game logic or Windows event processing.
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
