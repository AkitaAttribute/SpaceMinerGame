extends Node

# High-resolution main-thread instrumentation for the desktop simulation.
# Everything is buffered in memory and written only at normal shutdown.
# Two marker nodes bracket ordinary SceneTree process/physics callbacks so a
# long stall can be classified as happening before callbacks, inside callbacks,
# or around rendering/presentation.

const GAP_THRESHOLD_MS := 20.0
const SEVERE_GAP_THRESHOLD_MS := 50.0
const PERIODIC_SECONDS := 5.0
const UI_REFRESH_SECONDS := 0.50
const EARLY_PRIORITY := -900_000
const LATE_PRIORITY := 900_000
const UI_TAG := "Main thread:"

var _enabled := false
var _records: Array[String] = []
var _start_usec := 0
var _last_early_process_usec := 0
var _last_late_process_usec := 0
var _early_process_usec := 0
var _last_early_physics_usec := 0
var _last_late_physics_usec := 0
var _early_physics_usec := 0
var _last_pre_draw_usec := 0
var _last_post_draw_usec := 0
var _pre_draw_usec := 0
var _next_periodic_usec := 0
var _next_ui_usec := 0

var _before_process_gaps := 0
var _process_span_gaps := 0
var _before_physics_gaps := 0
var _physics_span_gaps := 0
var _draw_gaps := 0
var _severe_gaps := 0
var _max_gap_ms := 0.0
var _last_gap_kind := "none"
var _last_gap_ms := 0.0
var _last_gap_elapsed := 0.0

var _performance_panel: PanelContainer
var _performance_label: Label


class StageMarker extends Node:
    var probe
    var stage := ""

    func _process(_delta: float) -> void:
        if probe != null:
            probe._stage_process(stage)

    func _physics_process(_delta: float) -> void:
        if probe != null:
            probe._stage_physics(stage)


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    _enabled = not (
        OS.has_feature("android")
        or OS.has_feature("ios")
        or OS.has_feature("mobile")
        or OS.has_feature("headless")
    )

    if not _enabled:
        return

    _start_usec = Time.get_ticks_usec()
    _next_periodic_usec = _start_usec + int(PERIODIC_SECONDS * 1_000_000.0)
    _next_ui_usec = _start_usec

    var early := StageMarker.new()
    early.name = "EarlyMainThreadMarker"
    early.probe = self
    early.stage = "early"
    early.process_mode = Node.PROCESS_MODE_ALWAYS
    early.process_priority = EARLY_PRIORITY
    early.process_physics_priority = EARLY_PRIORITY
    add_child(early)

    var late := StageMarker.new()
    late.name = "LateMainThreadMarker"
    late.probe = self
    late.stage = "late"
    late.process_mode = Node.PROCESS_MODE_ALWAYS
    late.process_priority = LATE_PRIORITY
    late.process_physics_priority = LATE_PRIORITY
    add_child(late)

    RenderingServer.frame_pre_draw.connect(_on_frame_pre_draw)
    RenderingServer.frame_post_draw.connect(_on_frame_post_draw)

    _records.append(
        "SpaceMiner main-thread diagnostic probe\n"
        + "Started: %s\n" % Time.get_datetime_string_from_system()
        + "Engine: %s\n" % str(Engine.get_version_info().get("string", "unknown"))
        + "Process bracket priorities: %d .. %d\n" % [EARLY_PRIORITY, LATE_PRIORITY]
        + "Gap threshold: %.1f ms severe: %.1f ms\n" % [GAP_THRESHOLD_MS, SEVERE_GAP_THRESHOLD_MS]
        + "No disk writes occur until normal application shutdown."
    )
    AppLogger.event("MAIN_THREAD_PROBE enabled threshold=%.1fms" % GAP_THRESHOLD_MS)


func _stage_process(stage: String) -> void:
    if not _enabled:
        return

    var now := Time.get_ticks_usec()
    if stage == "early":
        if _last_late_process_usec > 0:
            var gap_ms := float(now - _last_late_process_usec) / 1000.0
            if gap_ms >= GAP_THRESHOLD_MS:
                _record_gap("before_process", gap_ms, now)
                _before_process_gaps += 1
        _early_process_usec = now
        _last_early_process_usec = now
        return

    if _early_process_usec > 0:
        var span_ms := float(now - _early_process_usec) / 1000.0
        if span_ms >= GAP_THRESHOLD_MS:
            _record_gap("process_callbacks", span_ms, now)
            _process_span_gaps += 1
    _last_late_process_usec = now
    _periodic_and_ui(now)


func _stage_physics(stage: String) -> void:
    if not _enabled:
        return

    var now := Time.get_ticks_usec()
    if stage == "early":
        if _last_late_physics_usec > 0:
            var interval_ms := float(now - _last_late_physics_usec) / 1000.0
            # Normal 60 Hz physics cadence is ~16.7 ms. Only log a missed tick.
            if interval_ms >= GAP_THRESHOLD_MS:
                _record_gap("before_physics", interval_ms, now)
                _before_physics_gaps += 1
        _early_physics_usec = now
        _last_early_physics_usec = now
        return

    if _early_physics_usec > 0:
        var span_ms := float(now - _early_physics_usec) / 1000.0
        if span_ms >= GAP_THRESHOLD_MS:
            _record_gap("physics_callbacks", span_ms, now)
            _physics_span_gaps += 1
    _last_late_physics_usec = now


func _on_frame_pre_draw() -> void:
    if not _enabled:
        return

    var now := Time.get_ticks_usec()
    if _last_post_draw_usec > 0:
        var interval_ms := float(now - _last_post_draw_usec) / 1000.0
        if interval_ms >= GAP_THRESHOLD_MS:
            _record_gap("between_draws", interval_ms, now)
            _draw_gaps += 1
    _pre_draw_usec = now
    _last_pre_draw_usec = now


func _on_frame_post_draw() -> void:
    if not _enabled:
        return

    var now := Time.get_ticks_usec()
    if _pre_draw_usec > 0:
        var draw_ms := float(now - _pre_draw_usec) / 1000.0
        if draw_ms >= GAP_THRESHOLD_MS:
            _record_gap("draw", draw_ms, now)
            _draw_gaps += 1
    _last_post_draw_usec = now


func _record_gap(kind: String, gap_ms: float, now_usec: int) -> void:
    _max_gap_ms = maxf(_max_gap_ms, gap_ms)
    _last_gap_kind = kind
    _last_gap_ms = gap_ms
    _last_gap_elapsed = float(now_usec - _start_usec) / 1_000_000.0
    if gap_ms >= SEVERE_GAP_THRESHOLD_MS:
        _severe_gaps += 1

    var serial := -1
    var presented_fps := 0.0
    var force_draw_ms := -1.0
    if FramePacer != null and FramePacer.is_manual_presentation_enabled():
        serial = FramePacer.presentation_serial
        presented_fps = FramePacer.measured_fps
        force_draw_ms = float(FramePacer.last_force_draw_usec) / 1000.0

    var record := (
        "[%s] MAIN_GAP t=%.3fs kind=%s gap=%.2fms serial=%d "
        + "presented_fps=%.2f force_draw=%.2fms focused=%s "
        + "engine_process=%.2fms engine_physics=%.2fms objects=%d draws=%d"
    ) % [
        Time.get_datetime_string_from_system(),
        _last_gap_elapsed,
        kind,
        gap_ms,
        serial,
        presented_fps,
        force_draw_ms,
        str(DisplayServer.window_is_focused()),
        Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
        Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
        int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
        int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
    ]
    _records.append(record)
    AppLogger.event(record.substr(record.find("MAIN_GAP")))


func _periodic_and_ui(now_usec: int) -> void:
    if now_usec >= _next_periodic_usec:
        _records.append(_periodic_record(now_usec))
        _next_periodic_usec = now_usec + int(PERIODIC_SECONDS * 1_000_000.0)

    if now_usec >= _next_ui_usec:
        _refresh_performance_panel()
        _next_ui_usec = now_usec + int(UI_REFRESH_SECONDS * 1_000_000.0)


func _periodic_record(now_usec: int) -> String:
    return (
        "[%s] MAIN_PERIODIC t=%.3fs before_process=%d process_callbacks=%d "
        + "before_physics=%d physics_callbacks=%d draw_related=%d severe=%d "
        + "max_gap=%.2fms last=%s:%.2fms nodes=%d objects=%d draws=%d"
    ) % [
        Time.get_datetime_string_from_system(),
        float(now_usec - _start_usec) / 1_000_000.0,
        _before_process_gaps,
        _process_span_gaps,
        _before_physics_gaps,
        _physics_span_gaps,
        _draw_gaps,
        _severe_gaps,
        _max_gap_ms,
        _last_gap_kind,
        _last_gap_ms,
        int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
        int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
        int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
    ]


func _refresh_performance_panel() -> void:
    if _performance_panel == null or not is_instance_valid(_performance_panel):
        _performance_panel = null
        _performance_label = null
        var scene := get_tree().current_scene
        if scene != null:
            _performance_panel = scene.find_child("PerformanceMetrics", true, false) as PanelContainer
            if _performance_panel != null:
                _performance_label = _find_first_label(_performance_panel)

    if _performance_panel == null or _performance_label == null:
        return
    if not _performance_panel.visible:
        return

    # The simulation rewrites this label every 0.5 s. Replace our own prior
    # line, then append one concise main-thread status line.
    var lines := _performance_label.text.split("\n")
    var clean_lines: PackedStringArray = []
    for line in lines:
        if not str(line).begins_with(UI_TAG):
            clean_lines.append(str(line))
    clean_lines.append(
        "%s gaps %d  severe %d  max %.1f ms  last %s %.1f ms"
        % [
            UI_TAG,
            _before_process_gaps + _process_span_gaps,
            _severe_gaps,
            _max_gap_ms,
            _last_gap_kind,
            _last_gap_ms,
        ]
    )
    _performance_label.text = "\n".join(clean_lines)

    # Size the panel to its actual text instead of reserving the old fixed
    # 520x374 rectangle. This removes the large unused right/bottom region.
    var text_size := _performance_label.get_minimum_size()
    var desired_width := clampf(text_size.x + 26.0, 360.0, 455.0)
    var desired_height := clampf(text_size.y + 24.0, 180.0, 390.0)
    _performance_panel.offset_right = _performance_panel.offset_left + desired_width
    _performance_panel.offset_bottom = _performance_panel.offset_top + desired_height


func _find_first_label(node: Node) -> Label:
    for child in node.get_children():
        if child is Label:
            return child as Label
        var nested := _find_first_label(child)
        if nested != null:
            return nested
    return null


func _notification(what: int) -> void:
    if not _enabled:
        return

    var name := ""
    match what:
        NOTIFICATION_APPLICATION_FOCUS_IN:
            name = "focus_in"
        NOTIFICATION_APPLICATION_FOCUS_OUT:
            name = "focus_out"
        NOTIFICATION_APPLICATION_PAUSED:
            name = "paused"
        NOTIFICATION_APPLICATION_RESUMED:
            name = "resumed"
        NOTIFICATION_WM_WINDOW_FOCUS_IN:
            name = "window_focus_in"
        NOTIFICATION_WM_WINDOW_FOCUS_OUT:
            name = "window_focus_out"

    if not name.is_empty():
        _records.append(
            "[%s] MAIN_NOTIFICATION t=%.3fs event=%s"
            % [
                Time.get_datetime_string_from_system(),
                float(Time.get_ticks_usec() - _start_usec) / 1_000_000.0,
                name,
            ]
        )


func _write_log() -> void:
    var directory := ""
    if OS.has_feature("editor"):
        directory = ProjectSettings.globalize_path("res://")
    else:
        directory = OS.get_executable_path().get_base_dir()

    var path := directory.path_join("SpaceMinerMainThread.log")
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        path = ProjectSettings.globalize_path("user://SpaceMinerMainThread.log")
        file = FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        return

    for record in _records:
        file.store_line(record)
    file.store_line(
        "Summary: before_process=%d process_callbacks=%d before_physics=%d physics_callbacks=%d draw_related=%d severe=%d max_gap=%.2fms last=%s:%.2fms"
        % [
            _before_process_gaps,
            _process_span_gaps,
            _before_physics_gaps,
            _physics_span_gaps,
            _draw_gaps,
            _severe_gaps,
            _max_gap_ms,
            _last_gap_kind,
            _last_gap_ms,
        ]
    )
    file.flush()
    file.close()


func _exit_tree() -> void:
    if not _enabled:
        return

    if RenderingServer.frame_pre_draw.is_connected(_on_frame_pre_draw):
        RenderingServer.frame_pre_draw.disconnect(_on_frame_pre_draw)
    if RenderingServer.frame_post_draw.is_connected(_on_frame_post_draw):
        RenderingServer.frame_post_draw.disconnect(_on_frame_post_draw)

    _records.append(_periodic_record(Time.get_ticks_usec()).replace("MAIN_PERIODIC", "MAIN_EXIT"))
    _write_log()
