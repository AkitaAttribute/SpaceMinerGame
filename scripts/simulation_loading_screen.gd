extends CanvasLayer

# Remains above the builder and simulator during their scene replacement.
# The scene never becomes visible until all asteroid effect meshes are ready.
var _cover: ColorRect
var _message: Label
var _progress: ProgressBar
var _percentage: Label


func _ready() -> void:
    layer = 120
    process_mode = Node.PROCESS_MODE_ALWAYS

    _cover = ColorRect.new()
    _cover.color = Color(0.018, 0.024, 0.042, 1.0)
    _cover.mouse_filter = Control.MOUSE_FILTER_STOP
    add_child(_cover)
    _cover.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    _cover.visible = false

    var center := CenterContainer.new()
    _cover.add_child(center)
    center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

    var column := VBoxContainer.new()
    column.add_theme_constant_override("separation", 18)
    center.add_child(column)

    var heading := Label.new()
    heading.text = "PREPARING FLIGHT"
    heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    heading.add_theme_font_size_override("font_size", 30)
    column.add_child(heading)

    _message = Label.new()
    _message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _message.add_theme_font_size_override("font_size", 18)
    column.add_child(_message)

    _progress = ProgressBar.new()
    _progress.custom_minimum_size = Vector2(520.0, 28.0)
    _progress.min_value = 0.0
    _progress.max_value = 100.0
    _progress.show_percentage = false
    column.add_child(_progress)

    _percentage = Label.new()
    _percentage.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    column.add_child(_percentage)


func begin() -> void:
    _cover.visible = true
    set_progress(0.02, "Loading simulator...")


func set_progress(fraction: float, stage: String) -> void:
    _message.text = stage
    _progress.value = clampf(fraction, 0.0, 1.0) * 100.0
    _percentage.text = "%d%%" % int(roundf(_progress.value))


func finish() -> void:
    _cover.visible = false
