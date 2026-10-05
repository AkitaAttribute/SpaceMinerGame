extends Node

# Diagnostic desktop frame cap that deliberately avoids Godot's built-in
# Engine.max_fps/VSync wait paths. Those paths produced recurring long stalls
# on this Windows test system. Godot's normal render loop remains enabled; this
# node simply holds the main thread until the next refresh-rate deadline using
# Time.get_ticks_usec() only.
#
# This is intentionally a diagnostic implementation. It should cap the entire
# SceneTree/render loop near the monitor refresh rate without calling
# OS.delay_usec()/Sleep(), but it will consume a substantial fraction of one
# CPU core while waiting. If this stays smooth, a native high-resolution wait
# can replace the busy spin for the production solution.

const FALLBACK_TARGET_FPS := 60.0
const STATS_INTERVAL_USEC := 5_000_000
const LATE_RESET_FRAMES := 3

var target_fps := FALLBACK_TARGET_FPS
var measured_fps := 0.0

var _enabled := false
var _interval_usec := 0
var _next_deadline_usec := 0
var _stats_start_usec := 0
var _stats_frame_count := 0
var _stats_spin_usec := 0


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    # Run after normal game _process callbacks so the wait occurs at the end of
    # the idle-processing portion of the frame, immediately before rendering.
    process_priority = 1_000_000

    _enabled = not (
        OS.has_feature("android")
        or OS.has_feature("ios")
        or OS.has_feature("mobile")
        or OS.has_feature("headless")
    )

    if not _enabled:
        set_process(false)
        return

    # Undo the previous manual-render experiment if this script is hot-reloaded
    # in the editor. Normal Godot rendering must be active for this test.
    RenderingServer.set_render_loop_enabled(true)

    var refresh := DisplayServer.screen_get_refresh_rate()
    if refresh > 1.0:
        target_fps = refresh
    else:
        target_fps = FALLBACK_TARGET_FPS

    _interval_usec = max(
        1,
        int(round(1_000_000.0 / target_fps))
    )

    var now := Time.get_ticks_usec()
    _next_deadline_usec = now + _interval_usec
    _stats_start_usec = now

    AppLogger.event(
        "FRAME_PACER busy_wait enabled target_fps=%.3f interval_usec=%d "
        % [target_fps, _interval_usec]
        + "engine_max_fps=%d vsync=%s driver=%s"
        % [
            Engine.max_fps,
            _vsync_name(DisplayServer.window_get_vsync_mode()),
            RenderingServer.get_current_rendering_driver_name(),
        ]
    )


func _process(_delta: float) -> void:
    if not _enabled:
        return

    var now := Time.get_ticks_usec()
    var spin_start := now

    # Do not call OS.delay_usec() here. On Windows that ultimately uses Sleep(),
    # which is the behavior this diagnostic is isolating.
    while now < _next_deadline_usec:
        now = Time.get_ticks_usec()

    _stats_spin_usec += now - spin_start
    _stats_frame_count += 1

    var lateness := now - _next_deadline_usec
    _next_deadline_usec += _interval_usec

    # If startup/loading or another legitimate long frame made us miss several
    # deadlines, resume from the current time instead of trying to catch up with
    # a burst of effectively uncapped frames.
    if lateness >= _interval_usec * LATE_RESET_FRAMES:
        _next_deadline_usec = now + _interval_usec

    var stats_elapsed := now - _stats_start_usec
    if stats_elapsed >= STATS_INTERVAL_USEC:
        measured_fps = (
            float(_stats_frame_count) * 1_000_000.0
            / float(stats_elapsed)
        )
        var spin_percent := (
            float(_stats_spin_usec) * 100.0
            / float(stats_elapsed)
        )
        AppLogger.event(
            "FRAME_PACER busy_wait actual_fps=%.2f target=%.2f "
            % [measured_fps, target_fps]
            + "engine_fps=%.1f spin_cpu_time=%.1f%%"
            % [Engine.get_frames_per_second(), spin_percent]
        )
        _stats_start_usec = now
        _stats_frame_count = 0
        _stats_spin_usec = 0


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
