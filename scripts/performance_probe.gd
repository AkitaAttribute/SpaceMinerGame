extends Node

const HITCH_THRESHOLD_MS := 25.0
const SEVERE_HITCH_THRESHOLD_MS := 50.0
const PERIODIC_SNAPSHOT_SECONDS := 10.0
const INPUT_RATE_WINDOW_SECONDS := 1.0

var _enabled := false
var _viewport_rid := RID()
var _records: Array[String] = []
var _periodic_elapsed := 0.0
var _input_elapsed := 0.0
var _input_events_current := 0
var _mouse_motion_current := 0
var _input_events_per_second := 0
var _mouse_motion_per_second := 0
var _hitch_count := 0
var _severe_hitch_count := 0
var _start_ticks_usec := 0


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
        set_process_input(false)
        return

    _start_ticks_usec = Time.get_ticks_usec()
    call_deferred("_enable_render_measurement")
    _records.append(_header_text())
    _records.append(
        "Passive probe enabled. No file I/O occurs until F9 or normal exit."
    )


func _enable_render_measurement() -> void:
    if not _enabled:
        return

    _viewport_rid = get_viewport().get_viewport_rid()
    if _viewport_rid.is_valid():
        RenderingServer.viewport_set_measure_render_time(
            _viewport_rid,
            true
        )


func _process(delta: float) -> void:
    if not _enabled:
        return

    _input_elapsed += delta
    _periodic_elapsed += delta

    if _input_elapsed >= INPUT_RATE_WINDOW_SECONDS:
        _input_events_per_second = int(
            round(float(_input_events_current) / _input_elapsed)
        )
        _mouse_motion_per_second = int(
            round(float(_mouse_motion_current) / _input_elapsed)
        )
        _input_events_current = 0
        _mouse_motion_current = 0
        _input_elapsed = 0.0

    var frame_ms := delta * 1000.0
    if frame_ms >= HITCH_THRESHOLD_MS:
        _hitch_count += 1
        if frame_ms >= SEVERE_HITCH_THRESHOLD_MS:
            _severe_hitch_count += 1
        _records.append(_snapshot_text("HITCH", frame_ms))

    if _periodic_elapsed >= PERIODIC_SNAPSHOT_SECONDS:
        _periodic_elapsed = 0.0
        _records.append(_snapshot_text("PERIODIC", frame_ms))


func _input(event: InputEvent) -> void:
    if not _enabled:
        return

    _input_events_current += 1
    if event is InputEventMouseMotion:
        _mouse_motion_current += 1

    if event is InputEventKey:
        var key_event := event as InputEventKey
        if (
            key_event.pressed
            and not key_event.echo
            and key_event.keycode == KEY_F9
        ):
            _records.append(
                _snapshot_text("MANUAL_DUMP", 0.0)
            )
            _write_log()


func _snapshot_text(kind: String, frame_ms: float) -> String:
    var render_setup_ms := RenderingServer.get_frame_setup_time_cpu()
    var render_cpu_ms := 0.0
    var render_gpu_ms := 0.0

    if _viewport_rid.is_valid():
        render_cpu_ms = RenderingServer.viewport_get_measured_render_time_cpu(
            _viewport_rid
        )
        render_gpu_ms = RenderingServer.viewport_get_measured_render_time_gpu(
            _viewport_rid
        )

    var engine_process_ms := (
        Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
    )
    var engine_physics_ms := (
        Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
    )

    var draws := int(Performance.get_monitor(
        Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME
    ))
    var primitives := int(Performance.get_monitor(
        Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME
    ))
    var objects := int(Performance.get_monitor(
        Performance.RENDER_TOTAL_OBJECTS_IN_FRAME
    ))

    var texture_mb := (
        Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)
        / (1024.0 * 1024.0)
    )
    var buffer_mb := (
        Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED)
        / (1024.0 * 1024.0)
    )

    var vsync := _vsync_name(DisplayServer.window_get_vsync_mode())
    var refresh := DisplayServer.screen_get_refresh_rate()
    var window_size := DisplayServer.window_get_size()
    var focused := DisplayServer.window_is_focused()

    var elapsed_seconds := float(
        Time.get_ticks_usec() - _start_ticks_usec
    ) / 1000000.0

    return (
        "[%s] %s t=%.3fs frame=%.2fms fps=%.1f "
        + "render_cpu=%.2fms render_gpu=%.2fms setup_cpu=%.2fms "
        + "engine_process=%.2fms engine_physics=%.2fms "
        + "draws=%d primitives=%d objects=%d "
        + "textures=%.1fMB buffers=%.1fMB "
        + "input_rate=%d/s mouse_motion=%d/s "
        + "input_current=%d mouse_current=%d "
        + "vsync=%s refresh=%.2fHz window=%dx%d focused=%s "
        + "hitches=%d severe=%d"
    ) % [
        Time.get_datetime_string_from_system(),
        kind,
        elapsed_seconds,
        frame_ms,
        Engine.get_frames_per_second(),
        render_cpu_ms,
        render_gpu_ms,
        render_setup_ms,
        engine_process_ms,
        engine_physics_ms,
        draws,
        primitives,
        objects,
        texture_mb,
        buffer_mb,
        _input_events_per_second,
        _mouse_motion_per_second,
        _input_events_current,
        _mouse_motion_current,
        vsync,
        refresh,
        window_size.x,
        window_size.y,
        str(focused),
        _hitch_count,
        _severe_hitch_count,
    ]


func _header_text() -> String:
    return (
        "SpaceMiner passive performance probe\n"
        + "Started: %s\n" % Time.get_datetime_string_from_system()
        + "Engine: %s\n" % str(
            Engine.get_version_info().get("string", "unknown")
        )
        + "Rendering method: %s\n"
        % RenderingServer.get_current_rendering_method()
        + "Rendering driver: %s\n"
        % RenderingServer.get_current_rendering_driver_name()
        + "Video adapter: %s\n"
        % RenderingServer.get_video_adapter_name()
        + "Video API: %s\n"
        % RenderingServer.get_video_adapter_api_version()
        + "VSync: %s\n"
        % _vsync_name(DisplayServer.window_get_vsync_mode())
        + "Refresh: %.2f Hz\n"
        % DisplayServer.screen_get_refresh_rate()
        + "F9 writes the current in-memory probe log."
    )


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

    var path := directory.path_join("SpaceMinerPerformance.log")
    var file := FileAccess.open(path, FileAccess.WRITE)

    if file == null:
        path = ProjectSettings.globalize_path(
            "user://SpaceMinerPerformance.log"
        )
        file = FileAccess.open(path, FileAccess.WRITE)

    if file == null:
        return

    for record in _records:
        file.store_line(record)

    file.store_line(
        "Summary: hitches >=25ms=%d, >=50ms=%d"
        % [_hitch_count, _severe_hitch_count]
    )
    file.flush()
    file.close()


func _exit_tree() -> void:
    if not _enabled:
        return

    if _viewport_rid.is_valid():
        RenderingServer.viewport_set_measure_render_time(
            _viewport_rid,
            false
        )

    _records.append(_snapshot_text("EXIT", 0.0))
    _write_log()
