extends Node

# Lightweight presented-frame probe. It keeps no dedicated log file; hitch
# records are appended to SpaceMinerGame.log through AppLogger.

const HITCH_THRESHOLD_MS := 20.0

var _enabled := false
var _start_usec := 0
var _last_process_usec := 0
var _last_pre_draw_usec := 0
var _last_post_draw_usec := 0
var _process_to_pre_ms := 0.0
var _pre_to_post_ms := 0.0
var _post_to_process_ms := 0.0
var _process_interval_ms := 0.0
var _hitch_count := 0
var _last_presentation_serial := -1


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

    _start_usec = Time.get_ticks_usec()
    RenderingServer.frame_pre_draw.connect(_on_frame_pre_draw)
    RenderingServer.frame_post_draw.connect(_on_frame_post_draw)
    AppLogger.event(
        "FRAME_STAGE_PROBE enabled threshold=%.1fms driver=%s vsync=%s max_fps=%d"
        % [
            HITCH_THRESHOLD_MS,
            RenderingServer.get_current_rendering_driver_name(),
            _vsync_name(DisplayServer.window_get_vsync_mode()),
            Engine.max_fps,
        ]
    )


func _process(delta: float) -> void:
    if not _enabled:
        return

    var frame_ms := delta * 1000.0

    # The Godot outer loop is intentionally uncapped. Sample only when a real
    # monitor frame was presented so polling iterations do not become logs.
    if FramePacer.is_manual_presentation_enabled():
        var serial := FramePacer.presentation_serial
        if serial == _last_presentation_serial:
            return
        _last_presentation_serial = serial
        if FramePacer.last_present_interval_usec > 0:
            frame_ms = float(FramePacer.last_present_interval_usec) / 1000.0

    var now_usec := Time.get_ticks_usec()
    if _last_process_usec > 0:
        _process_interval_ms = float(now_usec - _last_process_usec) / 1000.0
        if _last_post_draw_usec >= _last_process_usec:
            _post_to_process_ms = float(now_usec - _last_post_draw_usec) / 1000.0
        else:
            _post_to_process_ms = -1.0

    if frame_ms >= HITCH_THRESHOLD_MS:
        _hitch_count += 1
        AppLogger.event(_snapshot("FRAME_HITCH", frame_ms, now_usec))

    _last_process_usec = now_usec


func _on_frame_pre_draw() -> void:
    if not _enabled:
        return

    var now_usec := Time.get_ticks_usec()
    if _last_process_usec > 0:
        _process_to_pre_ms = float(now_usec - _last_process_usec) / 1000.0
    _last_pre_draw_usec = now_usec


func _on_frame_post_draw() -> void:
    if not _enabled:
        return

    var now_usec := Time.get_ticks_usec()
    if _last_pre_draw_usec > 0:
        _pre_to_post_ms = float(now_usec - _last_pre_draw_usec) / 1000.0
    _last_post_draw_usec = now_usec


func _snapshot(kind: String, frame_ms: float, now_usec: int) -> String:
    var elapsed := float(now_usec - _start_usec) / 1000000.0
    var displayed_fps := Engine.get_frames_per_second()
    var present_serial := -1
    var force_draw_ms := -1.0

    if FramePacer.is_manual_presentation_enabled():
        if FramePacer.measured_fps > 0.0:
            displayed_fps = FramePacer.measured_fps
        present_serial = FramePacer.presentation_serial
        force_draw_ms = float(FramePacer.last_force_draw_usec) / 1000.0

    return (
        "%s t=%.3fs frame=%.2fms process_interval=%.2fms "
        + "process_to_pre=%.2fms pre_to_post=%.2fms "
        + "post_to_process=%.2fms force_draw=%.2fms "
        + "presented_fps=%.1f serial=%d focused=%s hitches=%d"
    ) % [
        kind,
        elapsed,
        frame_ms,
        _process_interval_ms,
        _process_to_pre_ms,
        _pre_to_post_ms,
        _post_to_process_ms,
        force_draw_ms,
        displayed_fps,
        present_serial,
        str(DisplayServer.window_is_focused()),
        _hitch_count,
    ]


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

    if RenderingServer.frame_pre_draw.is_connected(_on_frame_pre_draw):
        RenderingServer.frame_pre_draw.disconnect(_on_frame_pre_draw)
    if RenderingServer.frame_post_draw.is_connected(_on_frame_post_draw):
        RenderingServer.frame_post_draw.disconnect(_on_frame_post_draw)

    AppLogger.event(
        "FRAME_STAGE_EXIT hitches_over_%.1fms=%d"
        % [HITCH_THRESHOLD_MS, _hitch_count]
    )
