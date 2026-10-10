extends Node

# Desktop frame-rate policy.
#
# The earlier diagnostic workaround disabled Godot's normal render loop and left
# the outer engine loop uncapped while a worker thread posted presentation
# tokens. That proved useful while isolating the periodic HID stall, but it also
# caused every _process callback in the project to run thousands of times per
# second even though only ~165 frames per second were actually presented.
#
# Now that the HID/gamepad cause is fixed at native startup, use Godot's normal
# render loop again and cap the engine loop to the monitor refresh rate. Physics
# remains fixed at 60 Hz and physics interpolation remains enabled.

const FALLBACK_TARGET_FPS := 60.0
const STATS_INTERVAL_USEC := 5_000_000

var target_fps := FALLBACK_TARGET_FPS
var measured_fps := 0.0
var presentation_serial := 0
var last_present_interval_usec := 0
var last_force_draw_usec := 0

var _enabled := false
var _stats_start_usec := 0
var _stats_frame_count := 0
var _last_present_usec := 0


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
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

    var refresh := DisplayServer.screen_get_refresh_rate()
    if refresh > 1.0:
        target_fps = refresh
    else:
        target_fps = FALLBACK_TARGET_FPS

    # Use one native engine iteration per visible frame. This prevents the old
    # 8,000-10,000 Hz _process spin while preserving 60 Hz physics + interpolation.
    Engine.max_fps = maxi(1, int(round(target_fps)))
    DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
    RenderingServer.set_render_loop_enabled(true)
    get_tree().physics_interpolation = true

    var now := Time.get_ticks_usec()
    _stats_start_usec = now
    _last_present_usec = now

    AppLogger.event(
        "FRAME_PACER native_cap enabled target_fps=%.3f engine_max_fps=%d "
        % [target_fps, Engine.max_fps]
        + "physics_tps=%d interpolation=%s vsync=%s driver=%s"
        % [
            Engine.physics_ticks_per_second,
            str(get_tree().physics_interpolation),
            _vsync_name(DisplayServer.window_get_vsync_mode()),
            RenderingServer.get_current_rendering_driver_name(),
        ]
    )


func _process(_delta: float) -> void:
    if not _enabled:
        return

    var now := Time.get_ticks_usec()
    last_present_interval_usec = now - _last_present_usec
    _last_present_usec = now
    last_force_draw_usec = 0
    presentation_serial += 1
    _stats_frame_count += 1

    var stats_elapsed := now - _stats_start_usec
    if stats_elapsed < STATS_INTERVAL_USEC:
        return

    measured_fps = (
        float(_stats_frame_count) * 1_000_000.0
        / float(stats_elapsed)
    )

    AppLogger.event(
        "FRAME_PACER native_cap actual_fps=%.2f target=%.2f "
        % [measured_fps, target_fps]
        + "physics_tps=%d engine_loop_fps=%.1f engine_max_fps=%d"
        % [
            Engine.physics_ticks_per_second,
            Engine.get_frames_per_second(),
            Engine.max_fps,
        ]
    )

    _stats_start_usec = now
    _stats_frame_count = 0


# Kept for FrameStageProbe compatibility. Manual presentation is intentionally
# gone; normal Godot rendering and Engine.max_fps now own frame pacing.
func is_manual_presentation_enabled() -> bool:
    return false


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
