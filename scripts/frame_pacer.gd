extends Node

# Desktop workaround for Godot frame pacing stalls observed when using either
# VSync or Engine.max_fps. The engine/main loop remains uncapped so it never
# enters Godot's frame-wait path. Instead, automatic rendering is disabled and
# we explicitly draw at the active display refresh rate.
#
# This intentionally caps *rendered/presented* frames, not SceneTree process
# iterations. Engine.get_frames_per_second() can therefore still report a much
# higher number than the actual draw rate.

const FALLBACK_TARGET_FPS := 60.0
const STATS_INTERVAL_USEC := 5_000_000

var target_render_fps := FALLBACK_TARGET_FPS
var measured_render_fps := 0.0

var _enabled := false
var _interval_usec := 0
var _next_draw_usec := 0
var _stats_start_usec := 0
var _stats_draw_count := 0


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS

    _enabled = not (
        OS.has_feature("android")
        or OS.has_feature("ios")
        or OS.has_feature("mobile")
        or OS.has_feature("headless")
    )

    if not _enabled:
        set_process(false)
        return

    var refresh := DisplayServer.screen_get_refresh_rate()
    if refresh > 1.0:
        target_render_fps = refresh
    else:
        target_render_fps = FALLBACK_TARGET_FPS

    _interval_usec = max(
        1,
        int(round(1_000_000.0 / target_render_fps))
    )

    var now := Time.get_ticks_usec()
    _next_draw_usec = now
    _stats_start_usec = now

    # The normal render loop is what would otherwise render every uncapped
    # SceneTree iteration. force_draw() below becomes the only presentation
    # path, so GPU work is limited without sleeping the main thread.
    RenderingServer.set_render_loop_enabled(false)

    AppLogger.event(
        "FRAME_PACER enabled target_render_fps=%.3f interval_usec=%d "
        % [target_render_fps, _interval_usec]
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
    if now < _next_draw_usec:
        return

    # Draw and swap once. VSync remains disabled, so this call should not enter
    # the presentation wait path that produced the recurring long stalls.
    RenderingServer.force_draw(true, 0.0)
    _stats_draw_count += 1

    # Preserve phase when possible, but never try to "catch up" by drawing a
    # burst of missed frames after a delay.
    _next_draw_usec += _interval_usec
    if now - _next_draw_usec >= _interval_usec:
        _next_draw_usec = now + _interval_usec

    var stats_elapsed := now - _stats_start_usec
    if stats_elapsed >= STATS_INTERVAL_USEC:
        measured_render_fps = (
            float(_stats_draw_count) * 1_000_000.0 / float(stats_elapsed)
        )
        AppLogger.event(
            "FRAME_PACER presented_fps=%.2f target=%.2f engine_loop_fps=%.1f"
            % [
                measured_render_fps,
                target_render_fps,
                Engine.get_frames_per_second(),
            ]
        )
        _stats_start_usec = now
        _stats_draw_count = 0


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


func _exit_tree() -> void:
    if not _enabled:
        return

    # Restore normal engine behavior during teardown.
    RenderingServer.set_render_loop_enabled(true)
