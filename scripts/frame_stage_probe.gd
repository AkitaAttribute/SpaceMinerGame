extends Node

const HITCH_THRESHOLD_MS := 10.0

var _enabled := false
var _records: Array[String] = []
var _start_usec := 0
var _last_process_usec := 0
var _last_pre_draw_usec := 0
var _last_post_draw_usec := 0
var _process_to_pre_ms := 0.0
var _pre_to_post_ms := 0.0
var _post_to_process_ms := 0.0
var _process_interval_ms := 0.0
var _hitch_count := 0


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
    _records.append(
        "SpaceMiner main-thread frame-stage probe\n"
        + "Started: %s\n" % Time.get_datetime_string_from_system()
        + "Engine: %s\n" % str(
            Engine.get_version_info().get("string", "unknown")
        )
        + "Rendering driver: %s\n"
        % RenderingServer.get_current_rendering_driver_name()
        + "Process ID: %d\n" % OS.get_process_id()
        + "VSync: %s\n" % _vsync_name(DisplayServer.window_get_vsync_mode())
        + "Max FPS: %d\n" % Engine.max_fps
        + "Hitch threshold: %.1f ms\n" % HITCH_THRESHOLD_MS
        + "No disk writes occur until normal application shutdown."
    )


func _process(delta: float) -> void:
    if not _enabled:
        return

    var now_usec := Time.get_ticks_usec()

    if _last_process_usec > 0:
        _process_interval_ms = float(
            now_usec - _last_process_usec
        ) / 1000.0

        if _last_post_draw_usec >= _last_process_usec:
            _post_to_process_ms = float(
                now_usec - _last_post_draw_usec
            ) / 1000.0
        else:
            _post_to_process_ms = -1.0

    var frame_ms := delta * 1000.0
    if frame_ms >= HITCH_THRESHOLD_MS:
        _hitch_count += 1
        _records.append(_snapshot("HITCH", frame_ms, now_usec))

    _last_process_usec = now_usec


func _on_frame_pre_draw() -> void:
    if not _enabled:
        return

    var now_usec := Time.get_ticks_usec()
    if _last_process_usec > 0:
        _process_to_pre_ms = float(
            now_usec - _last_process_usec
        ) / 1000.0
    _last_pre_draw_usec = now_usec


func _on_frame_post_draw() -> void:
    if not _enabled:
        return

    var now_usec := Time.get_ticks_usec()
    if _last_pre_draw_usec > 0:
        _pre_to_post_ms = float(
            now_usec - _last_pre_draw_usec
        ) / 1000.0
    _last_post_draw_usec = now_usec


func _snapshot(kind: String, frame_ms: float, now_usec: int) -> String:
    var elapsed := float(now_usec - _start_usec) / 1000000.0
    return (
        "[%s] %s t=%.3fs frame=%.2fms process_interval=%.2fms "
        + "process_to_pre=%.2fms pre_to_post=%.2fms "
        + "post_to_process=%.2fms driver=%s vsync=%s max_fps=%d fps=%.1f "
        + "focused=%s hitches=%d"
    ) % [
        Time.get_datetime_string_from_system(),
        kind,
        elapsed,
        frame_ms,
        _process_interval_ms,
        _process_to_pre_ms,
        _pre_to_post_ms,
        _post_to_process_ms,
        RenderingServer.get_current_rendering_driver_name(),
        _vsync_name(DisplayServer.window_get_vsync_mode()),
        Engine.max_fps,
        Engine.get_frames_per_second(),
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


func _write_log() -> void:
    if not _enabled:
        return

    var directory := ""
    if OS.has_feature("editor"):
        directory = ProjectSettings.globalize_path("res://")
    else:
        directory = OS.get_executable_path().get_base_dir()

    var path := directory.path_join("SpaceMinerFrameStages.log")
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        path = ProjectSettings.globalize_path(
            "user://SpaceMinerFrameStages.log"
        )
        file = FileAccess.open(path, FileAccess.WRITE)

    if file == null:
        return

    for record in _records:
        file.store_line(record)
    file.store_line(
        "Summary: hitches >=%.1fms=%d" % [HITCH_THRESHOLD_MS, _hitch_count]
    )
    file.close()


func _exit_tree() -> void:
    if not _enabled:
        return

    if RenderingServer.frame_pre_draw.is_connected(_on_frame_pre_draw):
        RenderingServer.frame_pre_draw.disconnect(_on_frame_pre_draw)
    if RenderingServer.frame_post_draw.is_connected(_on_frame_post_draw):
        RenderingServer.frame_post_draw.disconnect(_on_frame_post_draw)

    _write_log()
