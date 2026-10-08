extends Node

# Windows desktop presentation scheduler.
#
# The main Godot thread never waits for frame pacing. A worker thread owns the
# presentation clock and posts frame tokens at the monitor refresh interval.
# The main thread polls those tokens without blocking and draws at most one
# frame for the newest token. Gameplay/physics remain on Godot's fixed physics
# tick, with physics interpolation providing smooth presentation between ticks.
#
# This preserves the proven nonblocking architecture from 924df8b:
# - all waiting/sleeping occurs on the worker thread;
# - the main thread uses only Semaphore.try_wait();
# - stale frame tokens are discarded instead of rendered as a catch-up burst;
# - automatic rendering stays disabled and force_draw() happens only for a
#   real presentation token.
#
# LaserPresenter is prepared immediately before a real draw. Its presentation
# path uses CPU-side endpoint history and upload-only MultiMesh buffers, so it
# adds no waits and performs no RenderingServer readbacks.

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
var last_laser_prepare_usec := 0

var _enabled := false
var _worker_started := false
var _interval_usec := 0
var _stats_start_usec := 0
var _stats_frame_count := 0
var _stats_dropped_tokens := 0
var _stats_force_draw_usec := 0
var _stats_laser_prepare_usec := 0
var _last_present_usec := 0

var _present_semaphore := Semaphore.new()
var _pacing_thread := Thread.new()
var _stop_mutex := Mutex.new()
var _stop_requested := false


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    # Consume a presentation token before normal scene _process callbacks.
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

    # Completely nonblocking on the main thread.
    if not _present_semaphore.try_wait():
        return

    # Never catch up by rendering old deadlines. Keep only the newest frame.
    var dropped := 0
    while _present_semaphore.try_wait():
        dropped += 1
    _stats_dropped_tokens += dropped

    var now := Time.get_ticks_usec()
    last_present_interval_usec = now - _last_present_usec
    _last_present_usec = now
    presentation_serial += 1

    # Prepare laser geometry only for frames that will actually be presented.
    # This is CPU interpolation + one upload per active laser, with no waits or
    # RenderingServer reads.
    last_laser_prepare_usec = LaserPresenter.prepare_for_present(
        Engine.get_physics_interpolation_fraction()
    )
    _stats_laser_prepare_usec += last_laser_prepare_usec

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
            + "avg_laser_prepare_ms=%.3f dropped_tokens=%d"
            % [avg_laser_ms, _stats_dropped_tokens]
        )

        _stats_start_usec = Time.get_ticks_usec()
        _stats_frame_count = 0
        _stats_dropped_tokens = 0
        _stats_force_draw_usec = 0
        _stats_laser_prepare_usec = 0


func _pacing_thread_main() -> void:
    var next_deadline := Time.get_ticks_usec() + _interval_usec

    while not _thread_should_stop():
        var now := Time.get_ticks_usec()

        # Sleeping is allowed only on this worker thread.
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

        # Precision tail also stays off the main thread.
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
