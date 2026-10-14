extends Node

# Replaces the builder's old horizontal part-card strip with one compact button
# and a centered, drag-safe vertical picker. The builder remains authoritative
# for selected_part, per-part colors, ghost refresh, placement, and side-bumper
# cycling; this node only owns the presentation/selection workflow.

const BUILDER_SCRIPT_PATH := "res://scripts/main.gd"
const DOUBLE_ACTIVATE_MS := 420
const MIN_ENTRY_HEIGHT := 112.0
const ENTRY_SCREEN_FRACTION := 0.20

var _scene: Node
var _scene_id := 0
var _old_parts_scroll: ScrollContainer
var _selected_part_button: Button

var _picker_open := false
var _picker_dim: ColorRect
var _picker_panel: PanelContainer
var _picker_scroll: ScrollContainer
var _picker_list: VBoxContainer
var _pending_part := 0
var _entry_height := MIN_ENTRY_HEIGHT
var _entry_records: Dictionary = {}

var _saved_scroll_y := 0
var _scroll_memory_valid := false
var _scroll_memory_selected := -1

var _last_activation_index := -1
var _last_activation_ms := -10000
var _last_screen_size := Vector2.ZERO


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    set_process_input(true)
    AppSettings.theme_changed.connect(_on_theme_changed)


func _process(_delta: float) -> void:
    var current := get_tree().current_scene
    if not _is_builder_scene(current):
        if _scene_id != 0:
            _release_scene()
        return

    if _scene_id != current.get_instance_id():
        _bind_scene(current)

    if _scene == null or not is_instance_valid(_scene):
        return

    _sync_selected_part_button()

    if _picker_open:
        if not bool(_scene.get("parts_open")):
            _close_picker(false)
            return
        _sync_thumbnail_colors()
        var screen_size := get_viewport().get_visible_rect().size
        if screen_size != _last_screen_size:
            _layout_picker()


func _input(event: InputEvent) -> void:
    if not _picker_open:
        return
    if event.is_action_pressed(&"menu_back"):
        _close_picker(false)
        get_viewport().set_input_as_handled()


func _is_builder_scene(node: Node) -> bool:
    if node == null:
        return false
    var script = node.get_script()
    return (
        script != null
        and str(script.resource_path) == BUILDER_SCRIPT_PATH
    )


func _bind_scene(scene: Node) -> void:
    _release_scene()

    var old_scroll_value = scene.get("parts_scroll")
    var ui_root_value = scene.get("ui_root")
    if not (old_scroll_value is ScrollContainer):
        return
    if not (ui_root_value is Control):
        return

    var old_scroll := old_scroll_value as ScrollContainer
    if not is_instance_valid(old_scroll) or old_scroll.get_parent() == null:
        return

    _scene = scene
    _scene_id = scene.get_instance_id()
    _old_parts_scroll = old_scroll

    # Keep the old card strip alive because main.gd still refreshes it when
    # selection/colors change, but remove it from layout and input entirely.
    _old_parts_scroll.visible = false

    var parent := _old_parts_scroll.get_parent()
    var existing := parent.get_node_or_null("PartPickerButton")
    if existing is Button:
        _selected_part_button = existing as Button
    else:
        _selected_part_button = Button.new()
        _selected_part_button.name = "PartPickerButton"
        _selected_part_button.custom_minimum_size = Vector2(0.0, 56.0)
        _selected_part_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        _selected_part_button.pressed.connect(_open_picker)
        parent.add_child(_selected_part_button)
        parent.move_child(
            _selected_part_button,
            mini(_old_parts_scroll.get_index() + 1, parent.get_child_count() - 1)
        )

    _sync_selected_part_button(true)


func _release_scene() -> void:
    if _picker_open:
        _close_picker(false)

    _scene = null
    _scene_id = 0
    _old_parts_scroll = null
    _selected_part_button = null


func _sync_selected_part_button(force := false) -> void:
    if (
        _scene == null
        or _selected_part_button == null
        or not is_instance_valid(_selected_part_button)
    ):
        return

    var index := _current_selected_part()
    var name := _part_name(index)
    var desired_text := "%s  ▾" % name
    var desired_tooltip := "Selected part: %s\nOpen part list" % name

    if force or _selected_part_button.text != desired_text:
        _selected_part_button.text = desired_text
    if force or _selected_part_button.tooltip_text != desired_tooltip:
        _selected_part_button.tooltip_text = desired_tooltip


func _open_picker() -> void:
    if _picker_open or _scene == null or not is_instance_valid(_scene):
        return

    var ui_root_value = _scene.get("ui_root")
    if not (ui_root_value is Control):
        return

    if bool(_scene.get("color_picker_open")):
        _scene.call("_close_color_picker")

    _picker_open = true
    _pending_part = _current_selected_part()
    _last_activation_index = -1
    _last_activation_ms = -10000
    _entry_records.clear()

    var ui_root := ui_root_value as Control
    var colors := SpaceMinerTheme.palette(AppSettings.is_dark_theme())

    _picker_dim = ColorRect.new()
    _picker_dim.name = "PartPickerDim"
    _picker_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    _picker_dim.color = colors["overlay"] as Color
    _picker_dim.mouse_filter = Control.MOUSE_FILTER_STOP
    _picker_dim.z_index = 80
    ui_root.add_child(_picker_dim)

    _picker_panel = PanelContainer.new()
    _picker_panel.name = "PartPickerPanel"
    _picker_panel.set_anchors_preset(Control.PRESET_CENTER)
    _picker_panel.z_index = 81
    ui_root.add_child(_picker_panel)

    var margin := MarginContainer.new()
    margin.add_theme_constant_override("margin_left", 18)
    margin.add_theme_constant_override("margin_right", 18)
    margin.add_theme_constant_override("margin_top", 16)
    margin.add_theme_constant_override("margin_bottom", 16)
    _picker_panel.add_child(margin)

    var content := VBoxContainer.new()
    content.add_theme_constant_override("separation", 10)
    margin.add_child(content)

    var title := Label.new()
    title.text = "SELECT PART"
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    title.add_theme_font_size_override("font_size", 24)
    content.add_child(title)

    var instruction := Label.new()
    instruction.text = "Tap once to highlight. Double-tap or Select to choose."
    instruction.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    instruction.add_theme_color_override("font_color", colors["muted"] as Color)
    content.add_child(instruction)

    _picker_scroll = ScrollContainer.new()
    _picker_scroll.name = "PartPickerScroll"
    _picker_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _picker_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _picker_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    _picker_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
    _picker_scroll.follow_focus = false
    content.add_child(_picker_scroll)

    _picker_list = VBoxContainer.new()
    _picker_list.name = "PartPickerList"
    _picker_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _picker_list.add_theme_constant_override("separation", 8)
    _picker_scroll.add_child(_picker_list)

    var actions := HBoxContainer.new()
    actions.add_theme_constant_override("separation", 10)
    content.add_child(actions)

    var back := Button.new()
    back.text = "Back"
    back.custom_minimum_size = Vector2(0.0, 54.0)
    back.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    back.pressed.connect(_close_picker.bind(false))
    actions.add_child(back)

    var select := Button.new()
    select.text = "Select"
    select.custom_minimum_size = Vector2(0.0, 54.0)
    select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    select.pressed.connect(_confirm_picker)
    actions.add_child(select)

    _layout_picker()
    _build_picker_entries()
    _refresh_entry_highlights()
    _restore_scroll_after_layout(_pending_part)


func _layout_picker() -> void:
    if _picker_panel == null or not is_instance_valid(_picker_panel):
        return

    var screen := get_viewport().get_visible_rect().size
    _last_screen_size = screen
    _entry_height = maxf(MIN_ENTRY_HEIGHT, screen.y * ENTRY_SCREEN_FRACTION)

    var width := minf(680.0, maxf(390.0, screen.x * 0.52))
    width = minf(width, maxf(280.0, screen.x - 28.0))

    var height := minf(screen.y * 0.88, screen.y - 24.0)
    height = maxf(300.0, height)
    height = minf(height, screen.y - 12.0)

    _picker_panel.position = Vector2(-width * 0.5, -height * 0.5)
    _picker_panel.size = Vector2(width, height)


func _build_picker_entries() -> void:
    if _picker_list == null:
        return

    for child in _picker_list.get_children():
        child.queue_free()
    _entry_records.clear()

    for index in range(PartFactory.part_count()):
        _add_picker_entry(index)


func _add_picker_entry(index: int) -> void:
    var button := Button.new()
    button.name = "PartEntry%d" % index
    button.custom_minimum_size = Vector2(0.0, _entry_height)
    button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    button.toggle_mode = true
    button.tooltip_text = _part_name(index)
    button.pressed.connect(_on_entry_pressed.bind(index))
    _picker_list.add_child(button)

    var overlay := MarginContainer.new()
    overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
    overlay.add_theme_constant_override("margin_left", 10)
    overlay.add_theme_constant_override("margin_right", 12)
    overlay.add_theme_constant_override("margin_top", 8)
    overlay.add_theme_constant_override("margin_bottom", 8)
    button.add_child(overlay)

    var row := HBoxContainer.new()
    row.mouse_filter = Control.MOUSE_FILTER_IGNORE
    row.add_theme_constant_override("separation", 14)
    overlay.add_child(row)

    var preview := TextureRect.new()
    preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
    preview.custom_minimum_size = Vector2(
        maxf(148.0, _entry_height * 1.20),
        maxf(88.0, _entry_height - 16.0)
    )
    preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
    preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    row.add_child(preview)

    var text_column := VBoxContainer.new()
    text_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
    text_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    text_column.alignment = BoxContainer.ALIGNMENT_CENTER
    row.add_child(text_column)

    var name_label := Label.new()
    name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    name_label.text = _part_name(index)
    name_label.add_theme_font_size_override("font_size", 21)
    name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    text_column.add_child(name_label)

    var selected_label := Label.new()
    selected_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    selected_label.text = "SELECTED"
    selected_label.add_theme_font_size_override("font_size", 13)
    selected_label.add_theme_color_override(
        "font_color",
        (SpaceMinerTheme.palette(AppSettings.is_dark_theme())["accent"] as Color)
    )
    text_column.add_child(selected_label)

    var thumbnail := _build_part_thumbnail(index, button)
    preview.texture = thumbnail["viewport"].get_texture()

    _entry_records[index] = {
        "button": button,
        "selected_label": selected_label,
        "root": thumbnail["root"],
        "environment": thumbnail["environment"],
        "signature": _color_signature(_colors_for(index)),
    }


func _build_part_thumbnail(index: int, owner: Node) -> Dictionary:
    var viewport := SubViewport.new()
    viewport.name = "PartPreview%d" % index
    viewport.size = Vector2i(320, 160)
    viewport.transparent_bg = false
    viewport.own_world_3d = true
    viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
    owner.add_child(viewport)

    var environment_node := WorldEnvironment.new()
    var environment := Environment.new()
    environment.background_mode = Environment.BG_COLOR
    environment.background_color = _thumbnail_background_color()
    environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    environment.ambient_light_color = Color.WHITE
    environment.ambient_light_energy = 0.35
    environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
    environment_node.environment = environment
    viewport.add_child(environment_node)

    var colors := _colors_for(index)
    var root: Node3D
    if PartFactory.is_color_tool(index):
        # The paint tool has no physical mesh. Show the same colored cube it
        # would paint so the entry still has a meaningful 3D preview.
        root = PartFactory.create_part(0, colors, false)
    else:
        root = PartFactory.create_part(index, colors, false)
    root.name = "PreviewGeometry"
    viewport.add_child(root)

    var camera := Camera3D.new()
    camera.fov = 38.0
    camera.position = Vector3(2.7, 2.0, 3.5)
    viewport.add_child(camera)
    camera.look_at(Vector3(0.0, 0.0, 0.25), Vector3.UP)
    camera.current = true

    return {
        "viewport": viewport,
        "root": root,
        "environment": environment,
    }


func _on_entry_pressed(index: int) -> void:
    var now := Time.get_ticks_msec()
    var double_activate := (
        index == _last_activation_index
        and now - _last_activation_ms <= DOUBLE_ACTIVATE_MS
    )

    _last_activation_index = index
    _last_activation_ms = now
    _pending_part = clampi(index, 0, PartFactory.part_count() - 1)
    _refresh_entry_highlights()

    if double_activate:
        _confirm_picker()


func _refresh_entry_highlights() -> void:
    for key in _entry_records.keys():
        var index := int(key)
        var record = _entry_records[key]
        if not (record is Dictionary):
            continue
        var data := record as Dictionary
        var button_value = data.get("button", null)
        var label_value = data.get("selected_label", null)
        var active := index == _pending_part

        if button_value is Button and is_instance_valid(button_value):
            (button_value as Button).button_pressed = active
        if label_value is Label and is_instance_valid(label_value):
            (label_value as Label).visible = active


func _confirm_picker() -> void:
    if _scene != null and is_instance_valid(_scene):
        _scene.call("_select_part", _pending_part)
    _close_picker(true)


func _close_picker(_selection_applied: bool) -> void:
    if not _picker_open:
        return

    if _picker_scroll != null and is_instance_valid(_picker_scroll):
        _saved_scroll_y = _picker_scroll.scroll_vertical
        _scroll_memory_valid = true
        _scroll_memory_selected = _current_selected_part()

    _picker_open = false
    _entry_records.clear()
    _last_activation_index = -1
    _last_activation_ms = -10000

    if _picker_dim != null and is_instance_valid(_picker_dim):
        _picker_dim.queue_free()
    if _picker_panel != null and is_instance_valid(_picker_panel):
        _picker_panel.queue_free()

    _picker_dim = null
    _picker_panel = null
    _picker_scroll = null
    _picker_list = null
    _sync_selected_part_button(true)


func _restore_scroll_after_layout(open_selected: int) -> void:
    await get_tree().process_frame
    await get_tree().process_frame

    if (
        not _picker_open
        or _picker_scroll == null
        or not is_instance_valid(_picker_scroll)
    ):
        return

    if _scroll_memory_valid and _scroll_memory_selected == open_selected:
        _picker_scroll.scroll_vertical = _saved_scroll_y
        return

    var record = _entry_records.get(open_selected, {})
    if not (record is Dictionary):
        return
    var button_value = (record as Dictionary).get("button", null)
    if not (button_value is Button) or not is_instance_valid(button_value):
        return

    var button := button_value as Button
    var target := (
        button.position.y
        + button.size.y * 0.5
        - _picker_scroll.size.y * 0.5
    )
    _picker_scroll.scroll_vertical = maxi(0, int(round(target)))


func _sync_thumbnail_colors() -> void:
    for key in _entry_records.keys():
        var index := int(key)
        var record = _entry_records[key]
        if not (record is Dictionary):
            continue
        var data := record as Dictionary
        var root_value = data.get("root", null)
        if not (root_value is Node3D) or not is_instance_valid(root_value):
            continue

        var colors := _colors_for(index)
        var signature := _color_signature(colors)
        if signature == str(data.get("signature", "")):
            continue

        if PartFactory.is_color_tool(index):
            PartFactory.apply_colors(root_value as Node, colors, false)
        else:
            PartFactory.apply_colors(root_value as Node, colors, false)
        data["signature"] = signature
        _entry_records[index] = data


func _colors_for(index: int) -> Array[Color]:
    var result: Array[Color] = []
    if _scene != null and is_instance_valid(_scene):
        var all_colors = _scene.get("part_colors")
        if all_colors is Dictionary:
            var raw = (all_colors as Dictionary).get(
                index,
                PartFactory.default_colors(index)
            )
            if raw is Array:
                for value in raw:
                    if value is Color:
                        result.append(value as Color)

    return PartFactory.normalize_colors(index, result)


func _color_signature(colors: Array[Color]) -> String:
    var signature := ""
    for color in colors:
        if not signature.is_empty():
            signature += ","
        signature += color.to_html(true)
    return signature


func _part_name(index: int) -> String:
    return str(PartFactory.get_definition(index).get("name", "Part"))


func _current_selected_part() -> int:
    if _scene == null or not is_instance_valid(_scene):
        return 0
    return clampi(
        int(_scene.get("selected_part")),
        0,
        PartFactory.part_count() - 1
    )


func _thumbnail_background_color() -> Color:
    var colors := SpaceMinerTheme.palette(AppSettings.is_dark_theme())
    var base := colors["panel_alt"] as Color
    var backdrop := colors["background"] as Color
    return base.lerp(backdrop, 0.34)


func _on_theme_changed() -> void:
    if not _picker_open:
        return

    var colors := SpaceMinerTheme.palette(AppSettings.is_dark_theme())
    if _picker_dim != null and is_instance_valid(_picker_dim):
        _picker_dim.color = colors["overlay"] as Color

    for record in _entry_records.values():
        if not (record is Dictionary):
            continue
        var environment_value = (record as Dictionary).get("environment", null)
        if environment_value is Environment:
            (environment_value as Environment).background_color = (
                _thumbnail_background_color()
            )
