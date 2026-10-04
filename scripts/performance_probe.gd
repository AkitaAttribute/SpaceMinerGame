extends Node

const HITCH_THRESHOLD_MS := 25.0
const SEVERE_HITCH_THRESHOLD_MS := 50.0
const PERIODIC_SNAPSHOT_SECONDS := 10.0
const INPUT_RATE_WINDOW_SECONDS := 1.0

# Desktop-only controlled VSync A/B test. Give the game a short startup window,
# then alternate five three-minute blocks:
#   ON -> OFF -> ON -> OFF -> ON
# VSync-off blocks are capped at 60 FPS so the comparison does not turn into
# an uncapped-GPU-load test on fast desktop hardware.
const AB_START_DELAY_SECONDS := 30.0
const AB_PHASE_SECONDS := 180.0
const AB_PHASE_COUNT := 5
const AB_PHASE_WARMUP_SECONDS := 5.0
const AB_VSYNC_OFF_MAX_FPS := 60

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

var _ab_started := false
var _ab_complete := false
var _ab_delay_elapsed := 0.0
var _ab_phase_index := -1
var _ab_phase_elapsed := 0.0
var _ab_phase_hitches := 0
var _ab_phase_severe := 0
var _ab_results: Array[String] = []
var _initial_vsync_mode: DisplayServer.VSyncMode
var _initial_max_fps := 0


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
    _initial_vsync_mode = DisplayServer.window_get_vsync_mode()
    _initial_max_fps = Engine.max_fps

    call_deferred("_enable_render_measurement")
    _records.append(_header_text())
    _records.append(
        "Passive probe enabled. F9 or normal exit writes the current log."
    )
    _records.append(
        "VSYNC_AB scheduled: %.0fs startup delay, then %d x %.0fs phases "
        % [AB_START_DELAY_SECONDS, AB_PHASE_COUNT, AB_PHASE_SECONDS]
        + "(ON/OFF/ON/OFF/ON). OFF phases use Engine.max_fps=%d."
        % AB_VSYNC_OFF_MAX_FPS
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

    if not _ab_started and not _ab_complete:
        _ab_delay_elapsed += delta
        if _ab_delay_elapsed >= AB_START_DELAY_SECONDS:
            _start_ab_phase(0)

    if _ab_started and not _ab_complete:
        _ab_phase_elapsed += delta
        if _ab_phase_elapsed >= AB_PHASE_SECONDS:
            _finish_ab_phase()

    if _ab_complete:
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
        var severe := frame_ms >= SEVERE_HITCH_THRESHOLD_MS
        if severe:
            _severe_hitch_count += 1

        if (
            _ab_started
            and _ab_phase_elapsed >= AB_PHASE_WARMUP_SECONDS
        ):
            _ab_phase_hitches += 1
            if severe:
                _ab_phase_severe += 1

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


func _start_ab_phase(index: int) -> void:
    _ab_started = true
    _ab_phase_index = index
    _ab_phase_elapsed = 0.0
    _ab_phase_hitches = 0
    _ab_phase_severe = 0

    var enable_vsync := index % 2 == 0
    if enable_vsync:
        DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
        Engine.max_fps = _initial_max_fps
    else:
        DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
        Engine.max_fps = AB_VSYNC_OFF_MAX_FPS

    _records.append(
        "[%s] VSYNC_AB_PHASE_START phase=%d/%d mode=%s max_fps=%d "
        % [
            Time.get_datetime_string_from_system(),
            index + 1,
            AB_PHASE_COUNT,
            "ON" if enable_vsync else "OFF",
            Engine.max_fps,
        ]
        + "warmup_excluded=%.0fs"
        % AB_PHASE_WARMUP_SECONDS
    )


func _finish_ab_phase() -> void:
    var enable_vsync := _ab_phase_index % 2 == 0
    var result := (
        "VSYNC_AB_RESULT phase=%d/%d mode=%s duration=%.1fs "
        + "hitches_after_warmup=%d severe_after_warmup=%d"
    ) % [
        _ab_phase_index + 1,
        AB_PHASE_COUNT,
        "ON" if enable_vsync else "OFF",
        _ab_phase_elapsed,
        _ab_phase_hitches,
        _ab_phase_severe,
    ]
    _ab_results.append(result)
    _records.append("[%s] %s" % [
        Time.get_datetime_string_from_system(),
        result,
    ])

    var next_phase := _ab_phase_index + 1
    if next_phase < AB_PHASE_COUNT:
        _start_ab_phase(next_phase)
        return

    _complete_ab_test()


func _complete_ab_test() -> void:
    _ab_complete = true
    _ab_started = false

    DisplayServer.window_set_vsync_mode(_initial_vsync_mode)
    Engine.max_fps = _initial_max_fps

    _records.append(
        "[%s] VSYNC_AB_COMPLETE restored_vsync=%s restored_max_fps=%d"
        % [
            Time.get_datetime_string_from_system(),
            _vsync_name(_initial_vsync_mode),
            _initial_max_fps,
        ]
    )
    _records.append("VSYNC_AB_SUMMARY_BEGIN")
    for result in _ab_results:
        _records.append(result)
    _records.append("VSYNC_AB_SUMMARY_END")

    # The user can simply leave the build running. The completed 15-minute
    # result is written automatically without requiring F9 or an app exit.
    _write_log()


func _current_phase_name() -> String:
    if _ab_complete:
        return "complete"
    if not _ab_started:
        return "startup_delay"
    return "vsync_on" if _ab_phase_index % 2 == 0 else "vsync_off"


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
        "[%s] %s t=%.3fs phase=%s phase_t=%.2fs "
        + "frame=%.2fms fps=%.1f "
        + "render_cpu=%.2fms render_gpu=%.2fms setup_cpu=%.2fms "
        + "engine_process=%.2fms engine_physics=%.2fms "
        + "draws=%d primitives=%d objects=%d "
        + "textures=%.1fMB buffers=%.1fMB "
        + "input_rate=%d/s mouse_motion=%d/s "
        + "input_current=%d mouse_current=%d "
        + "vsync=%s max_fps=%d refresh=%.2fHz "
        + "window=%dx%d focused=%s hitches=%d severe=%d"
    ) % [
        Time.get_datetime_string_from_system(),
        kind,
        elapsed_seconds,
        _current_phase_name(),
        _ab_phase_elapsed,
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
        Engine.max_fps,
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
        + "Initial VSync: %s\n"
        % _vsync_name(DisplayServer.window_get_vsync_mode())
        + "Initial max FPS: %d\n" % Engine.max_fps
        + "Refresh: %.2f Hz\n"
        % DisplayServer.screen_get_refresh_rate()
        + "F9 writes the current in-memory probe log.\n"
        + "The VSync A/B test writes automatically when complete."
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

    if not _ab_complete:
        DisplayServer.window_set_vsync_mode(_initial_vsync_mode)
        Engine.max_fps = _initial_max_fps
        _records.append(
            "[%s] VSYNC_AB_ABORTED phase=%s restored_vsync=%s restored_max_fps=%d"
            % [
                Time.get_datetime_string_from_system(),
                _current_phase_name(),
                _vsync_name(_initial_vsync_mode),
                _initial_max_fps,
            ]
        )

    _records.append(_snapshot_text("EXIT", 0.0))
    _write_log()
