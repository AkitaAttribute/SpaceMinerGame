extends Node

const PERIOD_SECONDS := 29.95
const PRE_GREEN_SECONDS := 5.0
const POST_GREEN_SECONDS := 5.0
const POST_RED_SECONDS := 5.0
const HITCH_MIN_MS := 100.0
const HITCH_MAX_MS := 300.0
const RESYNC_COOLDOWN_SECONDS := 5.0
const PULSE_HZ := 1.0

const WHITE := Color(1.0, 1.0, 1.0, 1.0)
const GREEN := Color(0.30, 1.0, 0.42, 1.0)
const RED := Color(1.0, 0.28, 0.28, 1.0)

var _panel: PanelContainer
var _timer_label: Label
var _next_expected_usec := 0
var _last_sync_usec := 0
var _synced := false


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS


func _process(delta: float) -> void:
    _ensure_attached()

    if _panel == null or not is_instance_valid(_panel):
        return
    if not _panel.visible:
        return

    var now_usec := Time.get_ticks_usec()
    var frame_ms := delta * 1000.0

    if (
        frame_ms >= HITCH_MIN_MS
        and frame_ms <= HITCH_MAX_MS
        and (
            _last_sync_usec == 0
            or float(now_usec - _last_sync_usec) / 1000000.0
                >= RESYNC_COOLDOWN_SECONDS
        )
    ):
        _sync_from_hitch(now_usec, frame_ms)

    _update_timer(now_usec)


func _ensure_attached() -> void:
    if (
        _panel != null
        and is_instance_valid(_panel)
        and _timer_label != null
        and is_instance_valid(_timer_label)
    ):
        return

    _panel = null
    _timer_label = null
    _next_expected_usec = 0
    _last_sync_usec = 0
    _synced = false

    var scene := get_tree().current_scene
    if scene == null:
        return

    var candidate := scene.find_child("PerformanceMetrics", true, false)
    if not (candidate is PanelContainer):
        return

    var panel := candidate as PanelContainer
    if panel.has_meta("spike_predictor_attached"):
        return

    var margin: MarginContainer = null
    for child in panel.get_children():
        if child is MarginContainer:
            margin = child as MarginContainer
            break
    if margin == null:
        return

    var metrics_label: Label = null
    for child in margin.get_children():
        if child is Label:
            metrics_label = child as Label
            break
    if metrics_label == null:
        return

    margin.remove_child(metrics_label)

    var stack := VBoxContainer.new()
    stack.name = "PerformanceMetricsStack"
    stack.add_theme_constant_override("separation", 6)
    margin.add_child(stack)

    _timer_label = Label.new()
    _timer_label.name = "SpikePredictionTimer"
    _timer_label.text = "30 s spike predictor: waiting for a 100–300 ms hitch to sync"
    _timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _timer_label.add_theme_font_size_override("font_size", 16)
    _timer_label.add_theme_constant_override("outline_size", 3)
    _timer_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
    _timer_label.modulate = WHITE
    _timer_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    stack.add_child(_timer_label)

    var separator := HSeparator.new()
    separator.mouse_filter = Control.MOUSE_FILTER_IGNORE
    stack.add_child(separator)

    stack.add_child(metrics_label)

    panel.offset_bottom += 34.0
    panel.set_meta("spike_predictor_attached", true)
    _panel = panel


func _sync_from_hitch(now_usec: int, frame_ms: float) -> void:
    _synced = true
    _last_sync_usec = now_usec
    _next_expected_usec = now_usec + int(PERIOD_SECONDS * 1000000.0)

    AppLogger.event(
        "SPIKE_PREDICTOR sync hitch=%.2fms next=%.2fs"
        % [frame_ms, PERIOD_SECONDS]
    )


func _update_timer(now_usec: int) -> void:
    if _timer_label == null or not is_instance_valid(_timer_label):
        return

    if not _synced or _next_expected_usec <= 0:
        _timer_label.text = (
            "30 s spike predictor: waiting for a 100–300 ms hitch to sync"
        )
        _timer_label.modulate = WHITE
        return

    var post_window_seconds := POST_GREEN_SECONDS + POST_RED_SECONDS

    while (
        float(now_usec - _next_expected_usec) / 1000000.0
        > post_window_seconds
    ):
        _next_expected_usec += int(PERIOD_SECONDS * 1000000.0)

    var seconds_until := float(_next_expected_usec - now_usec) / 1000000.0

    if seconds_until > 0.0:
        _timer_label.text = "Expected spike in %05.1f s" % seconds_until
        _timer_label.modulate = (
            GREEN
            if seconds_until <= PRE_GREEN_SECONDS
            else WHITE
        )
        return

    var seconds_after := -seconds_until
    _timer_label.text = "Expected spike +%04.1f s" % seconds_after

    if seconds_after <= POST_GREEN_SECONDS:
        _timer_label.modulate = WHITE.lerp(
            GREEN,
            _pulse_mix(seconds_after)
        )
        return

    if seconds_after <= post_window_seconds:
        _timer_label.modulate = WHITE.lerp(
            RED,
            _pulse_mix(seconds_after - POST_GREEN_SECONDS)
        )
        return

    _timer_label.modulate = WHITE


func _pulse_mix(elapsed_seconds: float) -> float:
    return 0.5 - 0.5 * cos(TAU * PULSE_HZ * elapsed_seconds)
