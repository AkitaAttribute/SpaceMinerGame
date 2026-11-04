class_name SkyGenerationDialog
extends CanvasLayer

class ProgressWheel:
    extends Control

    var progress := 0.0

    func set_progress(value: float) -> void:
        progress = clampf(value, 0.0, 1.0)
        queue_redraw()

    func _draw() -> void:
        var center := size * 0.5
        var radius := minf(size.x, size.y) * 0.36
        var palette := SpaceMinerTheme.palette(AppSettings.is_dark_theme())
        var track := palette["muted"] as Color
        track.a = 0.22
        var active := AppSettings.highlight_color

        draw_arc(center, radius, 0.0, TAU, 72, track, 8.0, true)
        if progress > 0.0:
            draw_arc(
                center,
                radius,
                -PI * 0.5,
                -PI * 0.5 + TAU * progress,
                72,
                active,
                8.0,
                true
            )


var _wheel: ProgressWheel
var _percent_label: Label
var _status_label: Label
var _action_button: Button
var _close_button: Button
var _mode := ""


func _ready() -> void:
    layer = 100
    process_mode = Node.PROCESS_MODE_ALWAYS
    _build_ui()

    SkyCatalog.generation_progress.connect(_on_generation_progress)
    SkyCatalog.generation_paused.connect(_on_generation_paused)
    SkyCatalog.generation_completed.connect(_on_generation_completed)
    SkyCatalog.generation_failed.connect(_on_generation_failed)


func start_new() -> void:
    _mode = "new"
    _action_button.text = "Pause and Save"
    _close_button.visible = false

    if not SkyCatalog.start_generation():
        _on_generation_failed("A sky generation job is already running.")


func start_resume() -> void:
    _mode = "resume"
    _action_button.text = "Pause and Save"
    _close_button.visible = false

    if not SkyCatalog.resume_generation():
        _on_generation_failed("No resumable sky generation checkpoint was found.")


func _build_ui() -> void:
    var palette := SpaceMinerTheme.palette(AppSettings.is_dark_theme())

    var dim := ColorRect.new()
    dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    dim.color = palette["overlay"]
    dim.mouse_filter = Control.MOUSE_FILTER_STOP
    add_child(dim)

    var center := CenterContainer.new()
    center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    center.mouse_filter = Control.MOUSE_FILTER_STOP
    add_child(center)

    var panel := PanelContainer.new()
    panel.custom_minimum_size = Vector2(470.0, 390.0)
    panel.theme = SpaceMinerTheme.build(AppSettings.is_dark_theme())
    center.add_child(panel)

    var margin := MarginContainer.new()
    margin.add_theme_constant_override("margin_left", 28)
    margin.add_theme_constant_override("margin_right", 28)
    margin.add_theme_constant_override("margin_top", 24)
    margin.add_theme_constant_override("margin_bottom", 24)
    panel.add_child(margin)

    var content := VBoxContainer.new()
    content.add_theme_constant_override("separation", 12)
    margin.add_child(content)

    var title := Label.new()
    title.text = "Generate Skybox"
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    title.add_theme_font_size_override("font_size", 26)
    content.add_child(title)

    var subtitle := Label.new()
    subtitle.text = "Generating source data, then baking an 8192 x 4096 static panorama"
    subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    subtitle.modulate.a = 0.76
    content.add_child(subtitle)

    var wheel_center := CenterContainer.new()
    wheel_center.custom_minimum_size = Vector2(0.0, 142.0)
    content.add_child(wheel_center)

    _wheel = ProgressWheel.new()
    _wheel.custom_minimum_size = Vector2(132.0, 132.0)
    _wheel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    wheel_center.add_child(_wheel)

    _percent_label = Label.new()
    _percent_label.text = "0%"
    _percent_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _percent_label.add_theme_font_size_override("font_size", 22)
    content.add_child(_percent_label)

    _status_label = Label.new()
    _status_label.text = "Preparing generation..."
    _status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _status_label.custom_minimum_size = Vector2(0.0, 48.0)
    content.add_child(_status_label)

    var checkpoint_note := Label.new()
    checkpoint_note.text = "Source generation and panorama baking are checkpointed. A crash or closure can resume from the latest saved JSON/partial PNG state."
    checkpoint_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    checkpoint_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    checkpoint_note.modulate.a = 0.70
    content.add_child(checkpoint_note)

    var actions := HBoxContainer.new()
    actions.add_theme_constant_override("separation", 10)
    content.add_child(actions)

    _action_button = Button.new()
    _action_button.text = "Pause and Save"
    _action_button.custom_minimum_size = Vector2(0.0, 54.0)
    _action_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _action_button.pressed.connect(_on_action_pressed)
    actions.add_child(_action_button)

    _close_button = Button.new()
    _close_button.text = "Close"
    _close_button.custom_minimum_size = Vector2(0.0, 54.0)
    _close_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _close_button.visible = false
    _close_button.pressed.connect(queue_free)
    actions.add_child(_close_button)


func _on_action_pressed() -> void:
    if SkyCatalog.is_generating():
        SkyCatalog.pause_generation()
        return

    if SkyCatalog.has_checkpoint():
        _action_button.text = "Pause and Save"
        _close_button.visible = false
        if not SkyCatalog.resume_generation():
            _on_generation_failed("Could not resume the saved generation checkpoint.")
        return

    queue_free()


func _on_generation_progress(progress: float, status: String) -> void:
    _wheel.set_progress(progress)
    _percent_label.text = "%d%%" % int(round(progress * 100.0))
    _status_label.text = status


func _on_generation_paused() -> void:
    var summary := SkyCatalog.get_checkpoint_summary()
    var progress := float(summary.get("progress", 0.0))
    _wheel.set_progress(progress)
    _percent_label.text = "%d%%" % int(round(progress * 100.0))
    _status_label.text = "Paused. The checkpoint is saved and can be resumed now or after restarting the game."
    _action_button.text = "Resume"
    _close_button.visible = true


func _on_generation_completed(path: String) -> void:
    _wheel.set_progress(1.0)
    _percent_label.text = "100%"
    _status_label.text = "Complete. The source JSON and static panorama PNG are saved, and the panorama is now active.\n%s" % path
    _action_button.text = "Close"
    _close_button.visible = false


func _on_generation_failed(message: String) -> void:
    _status_label.text = message

    if SkyCatalog.has_checkpoint():
        _action_button.text = "Resume"
        _close_button.visible = true
    else:
        _action_button.text = "Close"
        _close_button.visible = false
