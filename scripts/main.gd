extends Node3D

const GRID_MIN_X := -5
const GRID_MAX_X := 5
const GRID_MIN_DEPTH := -5
const GRID_MAX_DEPTH := 5
const GRID_MIN_LEVEL := -3
const GRID_MAX_LEVEL := 5
const CAMERA_MIN_DISTANCE := 5.0
const CAMERA_MAX_DISTANCE := 28.0

var world_environment: WorldEnvironment
var camera: Camera3D
var camera_yaw := deg_to_rad(42.0)
var camera_pitch := deg_to_rad(-26.0)
var camera_distance := 14.0
var camera_target := Vector3(0.0, 0.6, 0.0)
var camera_dragging := false
var touch_points: Dictionary = {}
var pinch_previous_distance := 0.0

var grid_root: Node3D
var placed_root: Node3D
var ghost_root: Node3D
var cursor := Vector3i(0, 0, 0)
var selected_part := 0
var part_rotation := Vector3i.ZERO
var part_colors: Dictionary = {}
var placed_parts: Dictionary = {}

var ui_layer: CanvasLayer
var ui_root: Control
var parts_dim: ColorRect
var parts_panel: PanelContainer
var parts_tab: Button
var parts_scroll: ScrollContainer
var part_cards: HBoxContainer
var color_slot_select: OptionButton
var color_picker: ColorPickerButton
var level_label: Label
var controls_root: Control
var dpad_root: Control
var previous_bumper: Button
var next_bumper: Button
var gear_button: Button

var parts_open := false
var parts_scroll_dragging := false
var parts_scroll_last_x := 0.0

var menu_dim: ColorRect
var menu_panel: PanelContainer
var menu_content: VBoxContainer
var menu_open := false
var menu_state := "root"
var waiting_for_binding := false
var binding_action: StringName = &""
var binding_slot := 0

var palette: Dictionary

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    for index in range(PartFactory.part_count()):
        part_colors[index] = PartFactory.default_colors(index)
    _build_world()
    _build_scene_nodes()
    _build_ui()
    AppSettings.theme_changed.connect(_apply_theme)
    AppSettings.controls_visibility_changed.connect(_refresh_controls_visibility)
    AppSettings.bindings_changed.connect(_on_bindings_changed)
    _apply_theme()
    _refresh_controls_visibility()
    _refresh_ghost()
    _rebuild_grid()
    _update_camera()

func _notification(what: int) -> void:
    if what == NOTIFICATION_APPLICATION_FOCUS_IN and AppSettings.theme_mode == "system" and ui_root != null:
        _apply_theme()

func _build_world() -> void:
    world_environment = WorldEnvironment.new()
    var environment := Environment.new()
    environment.background_mode = Environment.BG_COLOR
    environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    environment.ambient_light_color = Color(0.72, 0.79, 0.92)
    environment.ambient_light_energy = 0.72
    environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
    world_environment.environment = environment
    add_child(world_environment)

    var key_light := DirectionalLight3D.new()
    key_light.rotation_degrees = Vector3(-48.0, -32.0, 0.0)
    key_light.light_energy = 1.15
    key_light.shadow_enabled = true
    add_child(key_light)

    var fill_light := OmniLight3D.new()
    fill_light.position = Vector3(-5.0, 5.0, 5.0)
    fill_light.omni_range = 20.0
    fill_light.light_energy = 1.4
    add_child(fill_light)

func _build_scene_nodes() -> void:
    grid_root = Node3D.new()
    grid_root.name = "ConstructionGrid"
    add_child(grid_root)

    placed_root = Node3D.new()
    placed_root.name = "PlacedParts"
    add_child(placed_root)

    ghost_root = Node3D.new()
    ghost_root.name = "PlacementGhost"
    add_child(ghost_root)

    camera = Camera3D.new()
    camera.name = "OrbitCamera"
    camera.current = true
    camera.fov = 55.0
    add_child(camera)

func _build_ui() -> void:
    ui_layer = CanvasLayer.new()
    ui_layer.layer = 20
    add_child(ui_layer)

    ui_root = Control.new()
    ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    ui_layer.add_child(ui_root)

    parts_dim = ColorRect.new()
    parts_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    parts_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
    parts_dim.visible = false
    ui_root.add_child(parts_dim)

    _build_parts_panel()
    _build_touch_controls()
    _build_gear()
    _build_menu_overlay()

    level_label = Label.new()
    level_label.position = Vector2(16.0, 14.0)
    level_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    level_label.add_theme_font_size_override("font_size", 18)
    ui_root.add_child(level_label)
    _update_level_label()

func _build_parts_panel() -> void:
    parts_panel = PanelContainer.new()
    parts_panel.set_anchors_preset(Control.PRESET_LEFT_WIDE)
    parts_panel.offset_left = 12.0
    parts_panel.offset_top = 16.0
    parts_panel.offset_right = 348.0
    parts_panel.offset_bottom = -16.0
    parts_panel.visible = false
    ui_root.add_child(parts_panel)

    var margin := MarginContainer.new()
    for side in ["left", "right", "top", "bottom"]:
        margin.add_theme_constant_override("margin_" + side, 16)
    parts_panel.add_child(margin)

    var content := VBoxContainer.new()
    content.add_theme_constant_override("separation", 12)
    margin.add_child(content)

    var header := HBoxContainer.new()
    content.add_child(header)
    var title := Label.new()
    title.text = "SHIP PARTS"
    title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    title.add_theme_font_size_override("font_size", 22)
    header.add_child(title)
    var close_button := Button.new()
    close_button.text = "Close"
    close_button.pressed.connect(func(): _set_parts_open(false))
    header.add_child(close_button)

    var selector_title := Label.new()
    selector_title.text = "Part"
    content.add_child(selector_title)

    parts_scroll = ScrollContainer.new()
    parts_scroll.custom_minimum_size = Vector2(0.0, 118.0)
    parts_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
    parts_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    parts_scroll.gui_input.connect(_on_parts_scroll_gui_input)
    content.add_child(parts_scroll)

    part_cards = HBoxContainer.new()
    part_cards.add_theme_constant_override("separation", 8)
    parts_scroll.add_child(part_cards)
    _rebuild_part_cards()

    var color_title := Label.new()
    color_title.text = "Color"
    content.add_child(color_title)

    var color_row := HBoxContainer.new()
    color_row.add_theme_constant_override("separation", 8)
    content.add_child(color_row)

    color_slot_select = OptionButton.new()
    color_slot_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    color_slot_select.item_selected.connect(_on_color_slot_selected)
    color_row.add_child(color_slot_select)

    color_picker = ColorPickerButton.new()
    color_picker.custom_minimum_size = Vector2(58.0, 44.0)
    color_picker.color_changed.connect(_on_color_changed)
    color_row.add_child(color_picker)

    var hint := Label.new()
    hint.text = "D-pad rotates the selected piece while this drawer is open. Side bumpers step through parts."
    hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    hint.modulate.a = 0.8
    content.add_child(hint)

    var actions := HBoxContainer.new()
    actions.add_theme_constant_override("separation", 8)
    content.add_child(actions)

    var place_button := Button.new()
    place_button.text = "Place"
    place_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    place_button.pressed.connect(_place_current_part)
    actions.add_child(place_button)

    var remove_button := Button.new()
    remove_button.text = "Remove"
    remove_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    remove_button.pressed.connect(_remove_current_part)
    actions.add_child(remove_button)

    parts_tab = Button.new()
    parts_tab.text = "PARTS"
    parts_tab.rotation = -PI * 0.5
    parts_tab.custom_minimum_size = Vector2(108.0, 42.0)
    parts_tab.position = Vector2(-30.0, 330.0)
    parts_tab.pressed.connect(func(): _set_parts_open(true))
    ui_root.add_child(parts_tab)

    _refresh_color_controls()

func _rebuild_part_cards() -> void:
    if part_cards == null:
        return
    for child in part_cards.get_children():
        child.queue_free()
    for index in range(PartFactory.part_count()):
        var definition := PartFactory.get_definition(index)
        var button := Button.new()
        button.custom_minimum_size = Vector2(118.0, 92.0)
        button.text = ("Selected\n" if index == selected_part else "") + str(definition["name"])
        button.pressed.connect(_select_part.bind(index))
        part_cards.add_child(button)

func _build_touch_controls() -> void:
    controls_root = Control.new()
    controls_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    controls_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    ui_root.add_child(controls_root)

    dpad_root = Control.new()
    dpad_root.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
    dpad_root.position = Vector2(-390.0, -230.0)
    dpad_root.size = Vector2(190.0, 190.0)
    dpad_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    controls_root.add_child(dpad_root)

    var up := _control_button("▲", Vector2(66, 0), Vector2(58, 58))
    var down := _control_button("▼", Vector2(66, 132), Vector2(58, 58))
    var left := _control_button("◀", Vector2(0, 66), Vector2(58, 58))
    var right := _control_button("▶", Vector2(132, 66), Vector2(58, 58))
    var center := _control_button("＋", Vector2(66, 66), Vector2(58, 58))
    for button in [up, down, left, right, center]:
        dpad_root.add_child(button)
    up.pressed.connect(func(): _perform_dpad(&"builder_up"))
    down.pressed.connect(func(): _perform_dpad(&"builder_down"))
    left.pressed.connect(func(): _perform_dpad(&"builder_left"))
    right.pressed.connect(func(): _perform_dpad(&"builder_right"))
    center.pressed.connect(_place_current_part)

    previous_bumper = _control_button("‹", Vector2(-62, 76), Vector2(50, 40))
    next_bumper = _control_button("›", Vector2(202, 76), Vector2(50, 40))
    previous_bumper.pressed.connect(func(): _cycle_part(-1))
    next_bumper.pressed.connect(func(): _cycle_part(1))
    dpad_root.add_child(previous_bumper)
    dpad_root.add_child(next_bumper)

    var vertical_root := Control.new()
    vertical_root.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
    vertical_root.position = Vector2(-116.0, -198.0)
    vertical_root.size = Vector2(84.0, 160.0)
    vertical_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    controls_root.add_child(vertical_root)

    var vertical_up := _control_button("UP", Vector2(0, 0), Vector2(78, 64))
    var vertical_down := _control_button("DOWN", Vector2(0, 88), Vector2(78, 64))
    vertical_up.pressed.connect(func(): _change_level(1))
    vertical_down.pressed.connect(func(): _change_level(-1))
    vertical_root.add_child(vertical_up)
    vertical_root.add_child(vertical_down)

func _control_button(text_value: String, position_value: Vector2, size_value: Vector2) -> Button:
    var button := Button.new()
    button.text = text_value
    button.position = position_value
    button.size = size_value
    button.custom_minimum_size = size_value
    button.modulate.a = 0.82
    return button

func _build_gear() -> void:
    gear_button = Button.new()
    gear_button.text = "⚙"
    gear_button.set_anchors_preset(Control.PRESET_TOP_RIGHT)
    gear_button.position = Vector2(-82.0, 18.0)
    gear_button.size = Vector2(58.0, 52.0)
    gear_button.add_theme_font_size_override("font_size", 28)
    gear_button.modulate.a = 0.76
    gear_button.pressed.connect(_open_menu)
    ui_root.add_child(gear_button)

func _build_menu_overlay() -> void:
    menu_dim = ColorRect.new()
    menu_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    menu_dim.mouse_filter = Control.MOUSE_FILTER_STOP
    menu_dim.visible = false
    ui_root.add_child(menu_dim)

    menu_panel = PanelContainer.new()
    menu_panel.set_anchors_preset(Control.PRESET_CENTER)
    menu_panel.position = Vector2(-240.0, -250.0)
    menu_panel.size = Vector2(480.0, 500.0)
    menu_panel.visible = false
    ui_root.add_child(menu_panel)

    var margin := MarginContainer.new()
    margin.add_theme_constant_override("margin_left", 22)
    margin.add_theme_constant_override("margin_right", 22)
    margin.add_theme_constant_override("margin_top", 18)
    margin.add_theme_constant_override("margin_bottom", 22)
    menu_panel.add_child(margin)

    menu_content = VBoxContainer.new()
    menu_content.add_theme_constant_override("separation", 12)
    margin.add_child(menu_content)

func _apply_theme() -> void:
    var dark := AppSettings.is_dark_theme()
    palette = SpaceMinerTheme.palette(dark)
    ui_root.theme = SpaceMinerTheme.build(dark)
    parts_dim.color = palette["parts_overlay"]
    menu_dim.color = palette["overlay"]
    if world_environment != null:
        world_environment.environment.background_color = palette["background"].darkened(0.18 if dark else 0.02)
        world_environment.environment.ambient_light_color = Color(0.70, 0.78, 0.94) if dark else Color(0.82, 0.86, 0.94)
    _rebuild_grid()

func _refresh_controls_visibility() -> void:
    if controls_root == null:
        return
    controls_root.visible = AppSettings.should_show_touch_controls() and not menu_open
    _refresh_bumper_visibility()

func _refresh_bumper_visibility() -> void:
    if previous_bumper == null:
        return
    previous_bumper.visible = parts_open
    next_bumper.visible = parts_open

func _input(event: InputEvent) -> void:
    if waiting_for_binding and event is InputEventKey:
        var key_event := event as InputEventKey
        if key_event.pressed and not key_event.echo:
            AppSettings.set_binding(binding_action, binding_slot, key_event)
            waiting_for_binding = false
            binding_action = &""
            _show_controls_menu()
            get_viewport().set_input_as_handled()

func _unhandled_input(event: InputEvent) -> void:
    if event.is_action_pressed(&"menu_back"):
        _handle_menu_back()
        get_viewport().set_input_as_handled()
        return

    if menu_open:
        return

    if event.is_action_pressed(&"parts_toggle"):
        _set_parts_open(not parts_open)
        get_viewport().set_input_as_handled()
        return

    if event is InputEventKey and event.pressed and not event.echo:
        if event.is_action_pressed(&"builder_up"):
            _perform_dpad(&"builder_up")
        elif event.is_action_pressed(&"builder_down"):
            _perform_dpad(&"builder_down")
        elif event.is_action_pressed(&"builder_left"):
            _perform_dpad(&"builder_left")
        elif event.is_action_pressed(&"builder_right"):
            _perform_dpad(&"builder_right")
        elif event.is_action_pressed(&"level_up"):
            _change_level(1)
        elif event.is_action_pressed(&"level_down"):
            _change_level(-1)
        elif event.is_action_pressed(&"part_previous"):
            _cycle_part(-1)
        elif event.is_action_pressed(&"part_next"):
            _cycle_part(1)
        elif event.is_action_pressed(&"place_part"):
            _place_current_part()
        elif event.is_action_pressed(&"remove_part"):
            _remove_current_part()
        else:
            return
        get_viewport().set_input_as_handled()
        return

    if event is InputEventMouseButton:
        var mouse_button := event as InputEventMouseButton
        if mouse_button.button_index == MOUSE_BUTTON_WHEEL_UP and mouse_button.pressed:
            _zoom_camera(-1.0)
            return
        if mouse_button.button_index == MOUSE_BUTTON_WHEEL_DOWN and mouse_button.pressed:
            _zoom_camera(1.0)
            return
        if mouse_button.button_index == MOUSE_BUTTON_LEFT:
            camera_dragging = mouse_button.pressed
            return

    if event is InputEventMouseMotion and camera_dragging:
        _orbit_camera((event as InputEventMouseMotion).relative)
        return

    if event is InputEventScreenTouch:
        var touch := event as InputEventScreenTouch
        if touch.pressed:
            touch_points[touch.index] = touch.position
        else:
            touch_points.erase(touch.index)
        if touch_points.size() == 2:
            var values := touch_points.values()
            pinch_previous_distance = (values[0] as Vector2).distance_to(values[1] as Vector2)
        else:
            pinch_previous_distance = 0.0
        return

    if event is InputEventScreenDrag:
        var drag := event as InputEventScreenDrag
        touch_points[drag.index] = drag.position
        if touch_points.size() >= 2:
            var values := touch_points.values()
            var distance := (values[0] as Vector2).distance_to(values[1] as Vector2)
            if pinch_previous_distance > 0.0:
                camera_distance = clampf(camera_distance - (distance - pinch_previous_distance) * 0.018, CAMERA_MIN_DISTANCE, CAMERA_MAX_DISTANCE)
                _update_camera()
            pinch_previous_distance = distance
        else:
            _orbit_camera(drag.relative)

func _handle_menu_back() -> void:
    if not menu_open:
        _open_menu()
    elif menu_state == "root":
        _close_menu()
    else:
        _show_root_menu()

func _open_menu() -> void:
    menu_open = true
    menu_dim.visible = true
    menu_panel.visible = true
    gear_button.visible = false
    controls_root.visible = false
    _show_root_menu()

func _close_menu() -> void:
    waiting_for_binding = false
    menu_open = false
    menu_dim.visible = false
    menu_panel.visible = false
    gear_button.visible = true
    _refresh_controls_visibility()

func _clear_menu_content() -> void:
    for child in menu_content.get_children():
        child.queue_free()

func _show_root_menu() -> void:
    waiting_for_binding = false
    menu_state = "root"
    _clear_menu_content()

    var title := _menu_title("SPACE MINER")
    menu_content.add_child(title)
    menu_content.add_spacer(false)

    for spec in [
        ["Resume", "resume"],
        ["Display", "display"],
        ["Controls", "controls"],
        ["Exit", "exit"],
    ]:
        var button := Button.new()
        button.text = spec[0]
        button.custom_minimum_size = Vector2(0.0, 56.0)
        button.pressed.connect(_root_menu_action.bind(spec[1]))
        menu_content.add_child(button)

func _root_menu_action(action: String) -> void:
    match action:
        "resume":
            _close_menu()
        "display":
            _show_display_menu()
        "controls":
            _show_controls_menu()
        "exit":
            get_tree().quit()

func _show_display_menu() -> void:
    menu_state = "display"
    _clear_menu_content()
    _add_submenu_header("Display")

    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", 12)
    menu_content.add_child(row)

    var label := Label.new()
    label.text = "Dark mode"
    label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    row.add_child(label)

    var selector := OptionButton.new()
    selector.add_item("System")
    selector.add_item("Light")
    selector.add_item("Dark")
    var selection := 0
    if AppSettings.theme_mode == "light":
        selection = 1
    elif AppSettings.theme_mode == "dark":
        selection = 2
    selector.select(selection)
    selector.item_selected.connect(func(index: int):
        var modes := ["system", "light", "dark"]
        AppSettings.set_theme_mode(modes[index])
    )
    row.add_child(selector)

func _show_controls_menu() -> void:
    menu_state = "controls"
    _clear_menu_content()
    _add_submenu_header("Controls")

    var show_controls := CheckButton.new()
    show_controls.text = "Show on-screen controls on PC"
    show_controls.button_pressed = AppSettings.show_controls_on_desktop
    show_controls.toggled.connect(func(value: bool): AppSettings.set_show_controls_on_desktop(value))
    menu_content.add_child(show_controls)

    var scroll := ScrollContainer.new()
    scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
    scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    menu_content.add_child(scroll)

    var bindings := VBoxContainer.new()
    bindings.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    bindings.add_theme_constant_override("separation", 8)
    scroll.add_child(bindings)

    for action in AppSettings.ACTION_ORDER:
        var row := VBoxContainer.new()
        row.add_theme_constant_override("separation", 4)
        bindings.add_child(row)

        var label := Label.new()
        label.text = AppSettings.get_action_label(action)
        label.modulate.a = 0.86
        row.add_child(label)

        var slots := HBoxContainer.new()
        slots.add_theme_constant_override("separation", 8)
        row.add_child(slots)

        var slot_count := 2 if action in [&"builder_up", &"builder_down", &"builder_left", &"builder_right"] else 1
        for slot in range(slot_count):
            var bind_button := Button.new()
            bind_button.text = AppSettings.get_binding_text(action, slot)
            bind_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
            bind_button.pressed.connect(_begin_binding_capture.bind(action, slot))
            slots.add_child(bind_button)

    if waiting_for_binding:
        var waiting := Label.new()
        waiting.text = "Press a key…"
        waiting.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
        waiting.add_theme_font_size_override("font_size", 20)
        menu_content.add_child(waiting)

func _add_submenu_header(title_text: String) -> void:
    var header := HBoxContainer.new()
    header.add_theme_constant_override("separation", 10)
    menu_content.add_child(header)

    var back := Button.new()
    back.text = "← Back"
    back.pressed.connect(_show_root_menu)
    header.add_child(back)

    var title := _menu_title(title_text)
    title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    header.add_child(title)

func _menu_title(value: String) -> Label:
    var label := Label.new()
    label.text = value
    label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    label.add_theme_font_size_override("font_size", 26)
    return label

func _begin_binding_capture(action: StringName, slot: int) -> void:
    waiting_for_binding = true
    binding_action = action
    binding_slot = slot
    _show_controls_menu()

func _on_bindings_changed() -> void:
    if menu_open and menu_state == "controls" and not waiting_for_binding:
        _show_controls_menu()

func _set_parts_open(value: bool) -> void:
    parts_open = value
    parts_panel.visible = value
    parts_dim.visible = value
    parts_tab.visible = not value
    _refresh_bumper_visibility()
    if value:
        _refresh_color_controls()
    _refresh_ghost()

func _perform_dpad(action: StringName) -> void:
    if parts_open:
        match action:
            &"builder_up":
                part_rotation.x = posmod(part_rotation.x - 90, 360)
            &"builder_down":
                part_rotation.x = posmod(part_rotation.x + 90, 360)
            &"builder_left":
                part_rotation.y = posmod(part_rotation.y - 90, 360)
            &"builder_right":
                part_rotation.y = posmod(part_rotation.y + 90, 360)
        _refresh_ghost()
        return

    match action:
        &"builder_up":
            cursor.y = clampi(cursor.y - 1, GRID_MIN_DEPTH, GRID_MAX_DEPTH)
        &"builder_down":
            cursor.y = clampi(cursor.y + 1, GRID_MIN_DEPTH, GRID_MAX_DEPTH)
        &"builder_left":
            cursor.x = clampi(cursor.x - 1, GRID_MIN_X, GRID_MAX_X)
        &"builder_right":
            cursor.x = clampi(cursor.x + 1, GRID_MIN_X, GRID_MAX_X)
    _refresh_ghost()
    _update_level_label()

func _change_level(delta: int) -> void:
    cursor.z = clampi(cursor.z + delta, GRID_MIN_LEVEL, GRID_MAX_LEVEL)
    _refresh_ghost()
    _update_level_label()
    _rebuild_grid()

func _cycle_part(delta: int) -> void:
    if not parts_open:
        return
    selected_part = posmod(selected_part + delta, PartFactory.part_count())
    part_rotation = Vector3i.ZERO
    _refresh_ghost()
    _rebuild_part_cards()
    _refresh_color_controls()

func _select_part(index: int) -> void:
    selected_part = clampi(index, 0, PartFactory.part_count() - 1)
    part_rotation = Vector3i.ZERO
    _refresh_ghost()
    _rebuild_part_cards()
    _refresh_color_controls()

func _refresh_color_controls() -> void:
    if color_slot_select == null or color_picker == null:
        return
    color_slot_select.clear()
    for slot_name in PartFactory.color_slot_names(selected_part):
        color_slot_select.add_item(slot_name)
    if color_slot_select.item_count > 0:
        color_slot_select.select(0)
        var colors: Array = part_colors[selected_part]
        color_picker.color = colors[0]

func _on_color_slot_selected(index: int) -> void:
    var colors: Array = part_colors[selected_part]
    if index >= 0 and index < colors.size():
        color_picker.color = colors[index]

func _on_color_changed(color: Color) -> void:
    var slot := color_slot_select.selected
    var colors: Array = part_colors[selected_part]
    if slot < 0 or slot >= colors.size():
        return
    colors[slot] = color
    part_colors[selected_part] = colors
    _refresh_ghost()

func _refresh_ghost() -> void:
    if ghost_root == null:
        return
    for child in ghost_root.get_children():
        child.queue_free()

    var colors: Array[Color] = []
    for value in part_colors[selected_part]:
        colors.append(value as Color)

    var ghost := PartFactory.create_part(selected_part, colors, true)
    ghost.position = _cursor_world_position()
    ghost.rotation_degrees = Vector3(part_rotation.x, part_rotation.y, part_rotation.z)
    ghost_root.add_child(ghost)

func _place_current_part() -> void:
    if menu_open:
        return

    var key := cursor
    if placed_parts.has(key):
        var old_node: Node = placed_parts[key]
        if is_instance_valid(old_node):
            old_node.queue_free()

    var colors: Array[Color] = []
    for value in part_colors[selected_part]:
        colors.append(value as Color)

    var part := PartFactory.create_part(selected_part, colors, false)
    part.position = _cursor_world_position()
    part.rotation_degrees = Vector3(part_rotation.x, part_rotation.y, part_rotation.z)
    part.set_meta("grid_position", key)
    part.set_meta("rotation_steps", part_rotation)
    placed_root.add_child(part)
    placed_parts[key] = part

func _remove_current_part() -> void:
    var key := cursor
    if not placed_parts.has(key):
        return
    var node: Node = placed_parts[key]
    if is_instance_valid(node):
        node.queue_free()
    placed_parts.erase(key)

func _cursor_world_position() -> Vector3:
    # Logical coordinates identify cells. World-space grid lines are the cell
    # boundaries, so the visual/part origin belongs half a cell inward on all axes.
    return Vector3(
        float(cursor.x) + 0.5,
        float(cursor.z) + 0.5,
        float(cursor.y) + 0.5
    )

func _update_level_label() -> void:
    if level_label != null:
        level_label.text = "GRID  X %d   Y %d   Z %d" % [cursor.x, cursor.y, cursor.z]

func _rebuild_grid() -> void:
    if grid_root == null:
        return

    for child in grid_root.get_children():
        child.queue_free()

    var below: Array[Transform3D] = []
    var current: Array[Transform3D] = []
    var above: Array[Transform3D] = []
    var thickness := 0.026

    # GRID_MIN/MAX values describe usable 1x1x1 cells. The visible line cage
    # therefore needs one additional boundary on each positive edge.
    var x_line_min := GRID_MIN_X
    var x_line_max := GRID_MAX_X + 1
    var depth_line_min := GRID_MIN_DEPTH
    var depth_line_max := GRID_MAX_DEPTH + 1
    var level_line_min := GRID_MIN_LEVEL
    var level_line_max := GRID_MAX_LEVEL + 1

    var span_x := float(x_line_max - x_line_min)
    var span_depth := float(depth_line_max - depth_line_min)
    var center_x := float(x_line_min + x_line_max) * 0.5
    var center_depth := float(depth_line_min + depth_line_max) * 0.5

    # Horizontal boundary planes.
    for level in range(level_line_min, level_line_max + 1):
        var target: Array[Transform3D]
        if level == cursor.z:
            target = current
        elif level < cursor.z:
            target = below
        else:
            target = above

        for depth in range(depth_line_min, depth_line_max + 1):
            target.append(_beam_transform(
                Vector3(center_x, float(level), float(depth)),
                Vector3(span_x, thickness, thickness)
            ))
        for x in range(x_line_min, x_line_max + 1):
            target.append(_beam_transform(
                Vector3(float(x), float(level), center_depth),
                Vector3(thickness, thickness, span_depth)
            ))

    # Vertical boundary segments are split by logical cell level so the focus
    # treatment can make the selected level and everything beneath it clearer.
    for x in range(x_line_min, x_line_max + 1):
        for depth in range(depth_line_min, depth_line_max + 1):
            for level in range(GRID_MIN_LEVEL, GRID_MAX_LEVEL + 1):
                var target: Array[Transform3D]
                if level == cursor.z:
                    target = current
                elif level < cursor.z:
                    target = below
                else:
                    target = above
                target.append(_beam_transform(
                    Vector3(float(x), float(level) + 0.5, float(depth)),
                    Vector3(thickness, 1.0, thickness)
                ))

    var accent: Color = palette.get("accent", Color("#4fb7d8"))
    _add_grid_multimesh(above, Color(accent.r, accent.g, accent.b, 0.045))
    _add_grid_multimesh(below, Color(accent.r, accent.g, accent.b, 0.20))
    _add_grid_multimesh(current, Color(accent.r, accent.g, accent.b, 0.42))

func _beam_transform(position_value: Vector3, scale_value: Vector3) -> Transform3D:
    return Transform3D(Basis.IDENTITY.scaled(scale_value), position_value)

func _add_grid_multimesh(transforms: Array[Transform3D], color: Color) -> void:
    if transforms.is_empty():
        return

    var box := BoxMesh.new()
    box.size = Vector3.ONE
    var material := StandardMaterial3D.new()
    material.albedo_color = color
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    box.material = material

    var multimesh := MultiMesh.new()
    multimesh.transform_format = MultiMesh.TRANSFORM_3D
    multimesh.mesh = box
    multimesh.instance_count = transforms.size()
    for index in range(transforms.size()):
        multimesh.set_instance_transform(index, transforms[index])

    var instance := MultiMeshInstance3D.new()
    instance.multimesh = multimesh
    grid_root.add_child(instance)

func _orbit_camera(relative: Vector2) -> void:
    camera_yaw -= relative.x * 0.006
    camera_pitch = clampf(camera_pitch - relative.y * 0.006, deg_to_rad(-78.0), deg_to_rad(22.0))
    _update_camera()

func _zoom_camera(direction: float) -> void:
    camera_distance = clampf(camera_distance + direction * 0.9, CAMERA_MIN_DISTANCE, CAMERA_MAX_DISTANCE)
    _update_camera()

func _update_camera() -> void:
    if camera == null:
        return
    var offset := Vector3(0.0, 0.0, camera_distance)
    offset = Basis(Vector3.RIGHT, camera_pitch) * offset
    offset = Basis(Vector3.UP, camera_yaw) * offset
    camera.global_position = camera_target + offset
    camera.look_at(camera_target, Vector3.UP)

func _on_parts_scroll_gui_input(event: InputEvent) -> void:
    if event is InputEventMouseButton:
        var button := event as InputEventMouseButton
        if button.button_index == MOUSE_BUTTON_LEFT:
            parts_scroll_dragging = button.pressed
            parts_scroll_last_x = button.position.x
            parts_scroll.accept_event()
    elif event is InputEventMouseMotion and parts_scroll_dragging:
        var motion := event as InputEventMouseMotion
        var delta := motion.position.x - parts_scroll_last_x
        parts_scroll.scroll_horizontal -= int(delta)
        parts_scroll_last_x = motion.position.x
        parts_scroll.accept_event()
