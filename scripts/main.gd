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
var selection_highlight_root: Node3D
var rotation_guide_root: Node3D
var cursor := Vector3i(0, 0, 0)
var selected_part := 0
var part_basis := Basis.IDENTITY
var part_colors: Dictionary = {}
var placed_parts: Dictionary = {}
var paint_color := Color("#5f83c6")
var paint_slot := 0

var ui_layer: CanvasLayer
var ui_root: Control
var parts_dim: ColorRect
var parts_panel: PanelContainer
var parts_tab: Button
var parts_scroll: ScrollContainer
var part_cards: HBoxContainer
var color_slot_select: OptionButton
var color_picker: ColorPickerButton
var place_button: Button
var level_label: Label
var controls_root: Control
var dpad_root: Control
var vertical_controls_root: Control
var dpad_direction_buttons: Dictionary = {}
var previous_bumper: Button
var next_bumper: Button
var gear_button: Button

var selector_root: Control
var selector_background: ColorRect
var selector_list: VBoxContainer
var selector_gear_button: Button
var view_mode := "selector"
var current_ship_id := ""
var menu_ship_id := ""
var thumbnail_capture_pending := false
var thumbnail_capture_ship_id := ""
var thumbnail_after_capture: Callable

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
    AppSettings.highlight_color_changed.connect(_refresh_selection_highlight)
    AppSettings.controls_visibility_changed.connect(_refresh_controls_visibility)
    AppSettings.bindings_changed.connect(_on_bindings_changed)
    _apply_theme()
    _refresh_controls_visibility()
    _refresh_ghost()
    _rebuild_grid()
    _refresh_selection_highlight()
    _update_camera()

    if _launch_simulation_smoke_if_requested():
        return

    var launch := ShipStore.take_view_request()
    var launch_view := str(launch.get("view", "selector"))
    var launch_ship_id := str(launch.get("ship_id", ""))
    if launch_view == "builder" and not launch_ship_id.is_empty():
        current_ship_id = launch_ship_id
        _load_ship_model(launch_ship_id)
        _show_builder()
    else:
        _show_ship_selector()

func _launch_simulation_smoke_if_requested() -> bool:
    if "--simulation-smoke" not in OS.get_cmdline_user_args():
        return false

    var metadata := ShipStore.create_model()
    var smoke_ship_id := str(metadata.get("id", ""))
    var identity_basis := [
        1.0, 0.0, 0.0,
        0.0, 1.0, 0.0,
        0.0, 0.0, 1.0,
    ]
    ShipStore.save_model(smoke_ship_id, {
        "version": 1,
        "camera": {},
        "parts": [
            {
                "part_id": "cube",
                "anchor": [0, 0, 0],
                "basis": identity_basis,
                "colors": ["5f83c6ff"],
            },
            {
                "part_id": "mining_laser",
                "anchor": [1, 0, 0],
                "basis": identity_basis,
                "colors": ["5f83c6ff"],
            },
            {
                "part_id": "thruster_t1",
                "anchor": [0, 1, 0],
                "basis": identity_basis,
                "colors": ["25282fff"],
            },
        ],
    })
    ShipStore.request_view("simulation", smoke_ship_id)
    call_deferred("_change_scene_deferred", "res://simulation.tscn")
    return true


func _change_scene_deferred(path: String) -> void:
    get_tree().change_scene_to_file(path)


func _notification(what: int) -> void:
    if what == NOTIFICATION_APPLICATION_FOCUS_IN and AppSettings.theme_mode == "system" and ui_root != null:
        _apply_theme()
    elif what == NOTIFICATION_WM_CLOSE_REQUEST:
        if view_mode == "builder":
            _save_current_ship_model()
        get_tree().quit()

func _build_world() -> void:
    world_environment = WorldEnvironment.new()
    var environment := Environment.new()
    environment.background_mode = Environment.BG_COLOR
    environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    environment.ambient_light_color = Color(0.72, 0.79, 0.92)
    environment.ambient_light_energy = 0.24
    environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
    world_environment.environment = environment
    add_child(world_environment)

    var key_light := DirectionalLight3D.new()
    key_light.rotation_degrees = Vector3(-48.0, -32.0, 0.0)
    key_light.light_energy = 0.95
    # Construction mode deliberately uses shadow-free lighting. Geometry should
    # remain readable while orbiting without dark cast shadows obscuring cells.
    key_light.shadow_enabled = false
    add_child(key_light)

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

    selection_highlight_root = Node3D.new()
    selection_highlight_root.name = "SelectionHighlight"
    add_child(selection_highlight_root)

    rotation_guide_root = Node3D.new()
    rotation_guide_root.name = "RotationGuide"
    add_child(rotation_guide_root)

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
    _build_ship_selector()
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

    place_button = Button.new()
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

    var up := _control_button("▲ U", Vector2(66, 0), Vector2(58, 58))
    var down := _control_button("▼ D", Vector2(66, 132), Vector2(58, 58))
    var left := _control_button("◀ L", Vector2(0, 66), Vector2(58, 58))
    var right := _control_button("▶ R", Vector2(132, 66), Vector2(58, 58))
    var center := _control_button("＋", Vector2(66, 66), Vector2(58, 58))
    for button in [up, down, left, right, center]:
        dpad_root.add_child(button)
    up.pressed.connect(func(): _perform_dpad(&"builder_up"))
    down.pressed.connect(func(): _perform_dpad(&"builder_down"))
    left.pressed.connect(func(): _perform_dpad(&"builder_left"))
    right.pressed.connect(func(): _perform_dpad(&"builder_right"))
    center.pressed.connect(_place_current_part)

    dpad_direction_buttons = {
        &"builder_up": up,
        &"builder_down": down,
        &"builder_left": left,
        &"builder_right": right,
    }
    _refresh_rotation_direction_button_colors()

    previous_bumper = _control_button("‹", Vector2(-62, 76), Vector2(50, 40))
    next_bumper = _control_button("›", Vector2(202, 76), Vector2(50, 40))
    previous_bumper.pressed.connect(func(): _cycle_part(-1))
    next_bumper.pressed.connect(func(): _cycle_part(1))
    dpad_root.add_child(previous_bumper)
    dpad_root.add_child(next_bumper)

    vertical_controls_root = Control.new()
    vertical_controls_root.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
    vertical_controls_root.position = Vector2(-116.0, -198.0)
    vertical_controls_root.size = Vector2(84.0, 160.0)
    vertical_controls_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    controls_root.add_child(vertical_controls_root)

    var vertical_up := _control_button("UP", Vector2(0, 0), Vector2(78, 64))
    var vertical_down := _control_button("DOWN", Vector2(0, 88), Vector2(78, 64))
    vertical_up.pressed.connect(func(): _change_level(1))
    vertical_down.pressed.connect(func(): _change_level(-1))
    vertical_controls_root.add_child(vertical_up)
    vertical_controls_root.add_child(vertical_down)

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

func _build_ship_selector() -> void:
    selector_root = Control.new()
    selector_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    selector_root.mouse_filter = Control.MOUSE_FILTER_STOP
    selector_root.visible = false
    ui_root.add_child(selector_root)

    selector_background = ColorRect.new()
    selector_background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    selector_background.mouse_filter = Control.MOUSE_FILTER_IGNORE
    selector_root.add_child(selector_background)

    var top_actions := HBoxContainer.new()
    top_actions.set_anchors_preset(Control.PRESET_CENTER_TOP)
    top_actions.position = Vector2(-174.0, 28.0)
    top_actions.size = Vector2(348.0, 52.0)
    top_actions.add_theme_constant_override("separation", 12)
    selector_root.add_child(top_actions)

    var add_button := Button.new()
    add_button.text = "+ Add"
    add_button.custom_minimum_size = Vector2(168.0, 52.0)
    add_button.pressed.connect(_create_ship_model)
    top_actions.add_child(add_button)

    var import_button := Button.new()
    import_button.text = "Import"
    import_button.custom_minimum_size = Vector2(168.0, 52.0)
    import_button.pressed.connect(_open_import_menu)
    top_actions.add_child(import_button)

    selector_gear_button = Button.new()
    selector_gear_button.text = "⚙"
    selector_gear_button.set_anchors_preset(Control.PRESET_TOP_RIGHT)
    selector_gear_button.position = Vector2(-82.0, 18.0)
    selector_gear_button.size = Vector2(58.0, 52.0)
    selector_gear_button.add_theme_font_size_override("font_size", 28)
    selector_gear_button.modulate.a = 0.76
    selector_gear_button.pressed.connect(_open_menu)
    selector_root.add_child(selector_gear_button)

    var scroll := ScrollContainer.new()
    scroll.anchor_left = 0.5
    scroll.anchor_right = 0.5
    scroll.anchor_top = 0.0
    scroll.anchor_bottom = 1.0
    scroll.offset_left = -420.0
    scroll.offset_right = 420.0
    scroll.offset_top = 108.0
    scroll.offset_bottom = -36.0
    scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
    selector_root.add_child(scroll)

    var center := CenterContainer.new()
    center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    center.size_flags_vertical = Control.SIZE_EXPAND_FILL
    scroll.add_child(center)

    selector_list = VBoxContainer.new()
    selector_list.custom_minimum_size = Vector2(800.0, 0.0)
    selector_list.add_theme_constant_override("separation", 12)
    center.add_child(selector_list)

func _rebuild_ship_selector() -> void:
    if selector_list == null:
        return

    for child in selector_list.get_children():
        child.queue_free()

    var models := ShipStore.list_models()
    if models.is_empty():
        var empty := Label.new()
        empty.text = "No ship models yet."
        empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
        empty.custom_minimum_size = Vector2(800.0, 80.0)
        empty.modulate.a = 0.72
        selector_list.add_child(empty)
        return

    for metadata in models:
        _add_ship_selector_row(metadata)

func _add_ship_selector_row(metadata: Dictionary) -> void:
    var model_id := str(metadata.get("id", ""))
    var model_name := str(metadata.get("name", "Ship"))

    var row := PanelContainer.new()
    row.custom_minimum_size = Vector2(800.0, 112.0)
    selector_list.add_child(row)

    var margin := MarginContainer.new()
    margin.add_theme_constant_override("margin_left", 10)
    margin.add_theme_constant_override("margin_right", 10)
    margin.add_theme_constant_override("margin_top", 10)
    margin.add_theme_constant_override("margin_bottom", 10)
    row.add_child(margin)

    var content := HBoxContainer.new()
    content.add_theme_constant_override("separation", 14)
    margin.add_child(content)

    var preview := Button.new()
    preview.custom_minimum_size = Vector2(160.0, 90.0)
    preview.flat = true
    preview.expand_icon = true
    var thumbnail := ShipStore.load_thumbnail(model_id)
    if thumbnail != null:
        preview.icon = thumbnail
    else:
        preview.text = "No preview"
    preview.pressed.connect(_open_ship_model.bind(model_id))
    content.add_child(preview)

    var name_button := Button.new()
    name_button.text = model_name
    name_button.flat = true
    name_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
    name_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    name_button.add_theme_font_size_override("font_size", 23)
    name_button.pressed.connect(_open_ship_model.bind(model_id))
    content.add_child(name_button)

    var model_gear := Button.new()
    model_gear.text = "⚙"
    model_gear.custom_minimum_size = Vector2(58.0, 58.0)
    model_gear.add_theme_font_size_override("font_size", 25)
    model_gear.pressed.connect(_open_ship_model_menu.bind(model_id))
    content.add_child(model_gear)

func _open_import_menu() -> void:
    menu_open = true
    menu_dim.visible = true
    menu_panel.visible = true
    gear_button.visible = false
    selector_gear_button.visible = false
    controls_root.visible = false
    _show_import_menu()

func _show_import_menu() -> void:
    menu_state = "import"
    menu_ship_id = ""
    _clear_menu_content()
    _add_submenu_header("Import Ship")

    var file_button := Button.new()
    file_button.text = "Import From File"
    file_button.custom_minimum_size = Vector2(0.0, 56.0)
    file_button.pressed.connect(_import_ship_from_file)
    menu_content.add_child(file_button)

    var paste_button := Button.new()
    paste_button.text = "Paste JSON"
    paste_button.custom_minimum_size = Vector2(0.0, 56.0)
    paste_button.pressed.connect(func(): _show_import_paste_menu())
    menu_content.add_child(paste_button)

func _show_import_paste_menu(raw_text := "", error_text := "") -> void:
    menu_state = "import_paste"
    _clear_menu_content()

    var header := HBoxContainer.new()
    header.add_theme_constant_override("separation", 10)
    menu_content.add_child(header)

    var back := Button.new()
    back.text = "← Back"
    back.pressed.connect(_show_import_menu)
    header.add_child(back)

    var title := _menu_title("Paste JSON")
    title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    header.add_child(title)

    if not error_text.is_empty():
        var error_label := Label.new()
        error_label.text = error_text
        error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        error_label.modulate = palette.get("danger", Color("#d96f78"))
        menu_content.add_child(error_label)

    var text_edit := TextEdit.new()
    text_edit.custom_minimum_size = Vector2(0.0, 245.0)
    text_edit.placeholder_text = "Paste a Space Miner ship JSON object here."
    text_edit.text = raw_text
    menu_content.add_child(text_edit)

    var paste_clipboard := Button.new()
    paste_clipboard.text = "Paste From Clipboard"
    paste_clipboard.custom_minimum_size = Vector2(0.0, 48.0)
    paste_clipboard.pressed.connect(func():
        if DisplayServer.clipboard_has():
            text_edit.text = DisplayServer.clipboard_get()
    )
    menu_content.add_child(paste_clipboard)

    var import_button := Button.new()
    import_button.text = "Import JSON"
    import_button.custom_minimum_size = Vector2(0.0, 56.0)
    import_button.pressed.connect(_import_ship_from_text_field.bind(text_edit))
    menu_content.add_child(import_button)

func _import_ship_from_text_field(text_edit: TextEdit) -> void:
    var raw_json := text_edit.text
    var result := ShipStore.import_json(raw_json)
    if not bool(result.get("ok", false)):
        _show_import_paste_menu(raw_json, str(result.get("error", "Import failed.")))
        return

    _close_menu()
    _rebuild_ship_selector()

func _import_ship_from_file() -> void:
    var filters := PackedStringArray([
        "*.json;Space Miner Ship Model;application/json",
    ])

    if DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE):
        DisplayServer.file_dialog_show(
            "Import Ship Model",
            "",
            "",
            false,
            DisplayServer.FILE_DIALOG_MODE_OPEN_FILE,
            filters,
            _on_native_ship_import_selected
        )
        return

    var dialog := FileDialog.new()
    dialog.title = "Import Ship Model"
    dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
    dialog.access = FileDialog.ACCESS_FILESYSTEM
    dialog.filters = filters
    dialog.file_selected.connect(func(path: String):
        _import_ship_path(path)
        dialog.queue_free()
    )
    dialog.canceled.connect(dialog.queue_free)
    ui_root.add_child(dialog)
    dialog.popup_centered_ratio(0.62)

func _on_native_ship_import_selected(
    status: bool,
    selected_paths: PackedStringArray,
    _selected_filter_index: int
) -> void:
    if not status or selected_paths.is_empty():
        return
    _import_ship_path(selected_paths[0])

func _import_ship_path(path: String) -> void:
    var result := ShipStore.import_file(path)
    if not bool(result.get("ok", false)):
        _show_import_paste_menu("", str(result.get("error", "Import failed.")))
        return

    _close_menu()
    _rebuild_ship_selector()

func _show_ship_selector() -> void:
    view_mode = "selector"
    current_ship_id = ""
    _set_parts_open(false)

    selector_root.visible = true
    selector_gear_button.visible = not menu_open
    gear_button.visible = false
    level_label.visible = false
    controls_root.visible = false
    parts_tab.visible = false

    _set_builder_world_visible(false)
    _rebuild_ship_selector()

func _show_builder() -> void:
    view_mode = "builder"
    selector_root.visible = false
    selector_gear_button.visible = false
    gear_button.visible = not menu_open
    level_label.visible = true
    parts_tab.visible = not parts_open

    _set_builder_world_visible(true)
    _refresh_controls_visibility()
    _refresh_ghost()
    _refresh_selection_highlight()
    _refresh_rotation_guide()
    _rebuild_grid()

func _set_builder_world_visible(value: bool) -> void:
    for node in [
        grid_root,
        placed_root,
        ghost_root,
        selection_highlight_root,
        rotation_guide_root,
    ]:
        if node != null:
            node.visible = value

func _create_ship_model() -> void:
    var metadata := ShipStore.create_model()
    _open_ship_model(str(metadata.get("id", "")))

func _open_ship_model(model_id: String) -> void:
    if model_id.is_empty():
        return

    current_ship_id = model_id
    _load_ship_model(model_id)
    _show_builder()

func _return_to_ship_selector() -> void:
    if view_mode != "builder":
        _close_menu()
        _show_ship_selector()
        return

    _save_current_ship_model()
    _close_menu()

    # Give the viewport one clean frame after the settings overlay disappears,
    # then capture the exact camera angle being left before showing the selector.
    var timer := get_tree().create_timer(0.05)
    timer.timeout.connect(_finish_return_to_ship_selector, CONNECT_ONE_SHOT)

func _finish_return_to_ship_selector() -> void:
    if view_mode != "builder":
        return
    _capture_current_ship_thumbnail(_show_ship_selector)

func _clear_ship_builder() -> void:
    placed_parts.clear()
    for child in placed_root.get_children():
        child.free()

    cursor = Vector3i.ZERO
    part_basis = Basis.IDENTITY
    camera_yaw = deg_to_rad(42.0)
    camera_pitch = deg_to_rad(-26.0)
    camera_distance = 14.0
    camera_target = Vector3(0.0, 0.6, 0.0)
    _update_camera()

func _load_ship_model(model_id: String) -> void:
    _clear_ship_builder()
    var data := ShipStore.load_model(model_id)

    var camera_data = data.get("camera", {})
    if camera_data is Dictionary:
        var camera_dict := camera_data as Dictionary
        camera_yaw = float(camera_dict.get("yaw", camera_yaw))
        camera_pitch = float(camera_dict.get("pitch", camera_pitch))
        camera_distance = clampf(
            float(camera_dict.get("distance", camera_distance)),
            CAMERA_MIN_DISTANCE,
            CAMERA_MAX_DISTANCE
        )
        var target = camera_dict.get("target", [])
        if target is Array and (target as Array).size() == 3:
            camera_target = Vector3(
                float(target[0]),
                float(target[1]),
                float(target[2])
            )
        _update_camera()

    var parts_data = data.get("parts", [])
    if not (parts_data is Array):
        return

    for value in parts_data:
        if not (value is Dictionary):
            continue
        var entry := value as Dictionary
        var part_id := str(entry.get("part_id", ""))
        var part_index := PartFactory.get_part_index_by_id(part_id)
        if part_index < 0 or not PartFactory.is_placeable(part_index):
            continue

        var anchor_data = entry.get("anchor", [])
        if not (anchor_data is Array) or (anchor_data as Array).size() != 3:
            continue
        var anchor := Vector3i(
            int(anchor_data[0]),
            int(anchor_data[1]),
            int(anchor_data[2])
        )

        var basis := _basis_from_json(entry.get("basis", []))
        var colors: Array[Color] = []
        var color_data = entry.get("colors", [])
        if color_data is Array:
            for color_value in color_data:
                colors.append(Color.from_string(str(color_value), Color.WHITE))
        if colors.is_empty():
            colors = PartFactory.default_colors(part_index)

        var part := PartFactory.create_part(part_index, colors, false)
        part.position = Vector3(
            float(anchor.x) + 0.5,
            float(anchor.z) + 0.5,
            float(anchor.y) + 0.5
        )
        part.basis = basis

        var occupied_cells := _occupied_cells_for(part_index, basis, anchor)
        part.set_meta("grid_position", anchor)
        part.set_meta("rotation_basis", basis)
        part.set_meta("colors", colors.duplicate())
        part.set_meta("occupied_cells", occupied_cells.duplicate())
        placed_root.add_child(part)

        for cell in occupied_cells:
            placed_parts[cell] = part

func _save_current_ship_model() -> void:
    if current_ship_id.is_empty():
        return

    var parts_data: Array[Dictionary] = []
    for child in placed_root.get_children():
        if not (child is Node3D):
            continue
        var part := child as Node3D
        var part_index := int(part.get_meta("part_index", -1))
        if part_index < 0:
            continue

        var anchor: Vector3i = part.get_meta("grid_position", Vector3i.ZERO)
        var colors_value: Array = part.get_meta(
            "colors",
            PartFactory.default_colors(part_index)
        )
        var color_strings: Array[String] = []
        for color_value in colors_value:
            color_strings.append((color_value as Color).to_html(true))

        parts_data.append({
            "part_id": str(PartFactory.get_definition(part_index)["id"]),
            "anchor": [anchor.x, anchor.y, anchor.z],
            "basis": _basis_to_json(part.basis),
            "colors": color_strings,
        })

    ShipStore.save_model(current_ship_id, {
        "version": 1,
        "camera": {
            "yaw": camera_yaw,
            "pitch": camera_pitch,
            "distance": camera_distance,
            "target": [
                camera_target.x,
                camera_target.y,
                camera_target.z,
            ],
        },
        "parts": parts_data,
    })

func _basis_to_json(value: Basis) -> Array[float]:
    return [
        value.x.x, value.x.y, value.x.z,
        value.y.x, value.y.y, value.y.z,
        value.z.x, value.z.y, value.z.z,
    ]

func _basis_from_json(value) -> Basis:
    if not (value is Array) or (value as Array).size() != 9:
        return Basis.IDENTITY

    return Basis(
        Vector3(float(value[0]), float(value[1]), float(value[2])),
        Vector3(float(value[3]), float(value[4]), float(value[5])),
        Vector3(float(value[6]), float(value[7]), float(value[8]))
    ).orthonormalized()

func _capture_current_ship_thumbnail(after_capture := Callable()) -> void:
    if current_ship_id.is_empty() or view_mode != "builder":
        if after_capture.is_valid():
            after_capture.call()
        return

    if thumbnail_capture_pending:
        if after_capture.is_valid():
            thumbnail_after_capture = after_capture
        return

    thumbnail_capture_pending = true
    thumbnail_capture_ship_id = current_ship_id
    thumbnail_after_capture = after_capture

    # Thumbnails represent the ship and last camera angle, not editor aids.
    grid_root.visible = false
    ghost_root.visible = false
    selection_highlight_root.visible = false
    rotation_guide_root.visible = false

    get_tree().process_frame.connect(
        _finish_current_ship_thumbnail_capture,
        CONNECT_ONE_SHOT
    )

func _finish_current_ship_thumbnail_capture() -> void:
    var ship_id := thumbnail_capture_ship_id
    if not ship_id.is_empty():
        var image := get_viewport().get_texture().get_image()
        if image != null and not image.is_empty():
            var width := image.get_width()
            var height := image.get_height()
            var crop_width := mini(width, 640)
            var crop_height := int(round(float(crop_width) * 9.0 / 16.0))
            crop_height = mini(crop_height, height)

            var crop_x := maxi(0, (width - crop_width) / 2)
            var crop_y := maxi(0, (height - crop_height) / 2)
            var thumbnail := image.get_region(
                Rect2i(crop_x, crop_y, crop_width, crop_height)
            )
            thumbnail.resize(320, 180, Image.INTERPOLATE_LANCZOS)
            ShipStore.save_thumbnail(ship_id, thumbnail)

    thumbnail_capture_pending = false
    thumbnail_capture_ship_id = ""

    if view_mode == "builder":
        grid_root.visible = true
        ghost_root.visible = true
        selection_highlight_root.visible = true
        rotation_guide_root.visible = true

    var callback := thumbnail_after_capture
    thumbnail_after_capture = Callable()
    if callback.is_valid():
        callback.call()

func _mark_ship_changed() -> void:
    if view_mode != "builder" or current_ship_id.is_empty():
        return
    _save_current_ship_model()
    _capture_current_ship_thumbnail()

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
    if selector_background != null:
        selector_background.color = palette["background"]
    if world_environment != null:
        world_environment.environment.background_color = palette["background"].darkened(0.18 if dark else 0.02)
        world_environment.environment.ambient_light_color = Color(0.70, 0.78, 0.94) if dark else Color(0.82, 0.86, 0.94)
    _rebuild_grid()
    _refresh_rotation_direction_button_colors()

func _refresh_controls_visibility() -> void:
    if controls_root == null:
        return
    controls_root.visible = (
        view_mode == "builder"
        and AppSettings.should_show_touch_controls()
        and not menu_open
    )
    _refresh_bumper_visibility()
    _refresh_vertical_controls_visibility()

func _refresh_vertical_controls_visibility() -> void:
    if vertical_controls_root == null:
        return
    # The parts drawer is an editing state, not a grid-navigation state.
    # Vertical navigation disappears completely until the drawer is closed.
    vertical_controls_root.visible = not parts_open

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
        return

    # Handle the drawer toggle before Control nodes see the event. This prevents
    # Tab (or a remapped equivalent) from ever falling through into UI focus
    # traversal/accessibility-style navigation.
    if event.is_action_pressed(&"parts_toggle"):
        if not menu_open and view_mode == "builder":
            _set_parts_open(not parts_open)
        get_viewport().set_input_as_handled()
        return

func _unhandled_input(event: InputEvent) -> void:
    if event.is_action_pressed(&"menu_back"):
        _handle_menu_back()
        get_viewport().set_input_as_handled()
        return

    if menu_open:
        return

    if view_mode != "builder":
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
            _mark_ship_changed()
            return
        if mouse_button.button_index == MOUSE_BUTTON_WHEEL_DOWN and mouse_button.pressed:
            _zoom_camera(1.0)
            _mark_ship_changed()
            return
        if mouse_button.button_index == MOUSE_BUTTON_LEFT:
            var was_dragging := camera_dragging
            camera_dragging = mouse_button.pressed
            if was_dragging and not camera_dragging:
                _mark_ship_changed()
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
            _mark_ship_changed()
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
        return

    match menu_state:
        "root":
            _close_menu()
        "model_delete_confirm", "model_rename":
            _show_ship_model_menu(menu_ship_id)
        "model_actions", "import":
            _close_menu()
        "import_paste":
            _show_import_menu()
        _:
            _show_root_menu()

func _open_menu() -> void:
    menu_open = true
    menu_dim.visible = true
    menu_panel.visible = true
    gear_button.visible = false
    if selector_gear_button != null:
        selector_gear_button.visible = false
    controls_root.visible = false
    _show_root_menu()

func _close_menu() -> void:
    waiting_for_binding = false
    menu_open = false
    menu_dim.visible = false
    menu_panel.visible = false
    menu_ship_id = ""

    gear_button.visible = view_mode == "builder"
    if selector_gear_button != null:
        selector_gear_button.visible = view_mode == "selector"
    _refresh_controls_visibility()

func _clear_menu_content() -> void:
    for child in menu_content.get_children():
        child.queue_free()

func _show_root_menu() -> void:
    waiting_for_binding = false
    menu_state = "root"
    menu_ship_id = ""
    _clear_menu_content()

    var title := _menu_title("SPACE MINER")
    menu_content.add_child(title)
    menu_content.add_spacer(false)

    var specs: Array = [
        ["Resume", "resume"],
    ]

    if view_mode == "builder":
        specs.append(["Test Flight", "simulate"])

    specs.append_array([
        ["Display", "display"],
        ["Controls", "controls"],
    ])

    if view_mode == "builder":
        specs.append(["Exit to Ship Selector", "ships"])
    else:
        specs.append(["Exit", "exit"])

    for spec in specs:
        var button := Button.new()
        button.text = spec[0]
        button.custom_minimum_size = Vector2(0.0, 56.0)
        button.pressed.connect(_root_menu_action.bind(spec[1]))
        menu_content.add_child(button)

func _root_menu_action(action: String) -> void:
    match action:
        "resume":
            _close_menu()
        "ships":
            _return_to_ship_selector()
        "simulate":
            _launch_simulation()
        "display":
            _show_display_menu()
        "controls":
            _show_controls_menu()
        "exit":
            if view_mode == "builder":
                _save_current_ship_model()
            get_tree().quit()

func _launch_simulation() -> void:
    if current_ship_id.is_empty():
        return

    _save_current_ship_model()
    ShipStore.request_view("simulation", current_ship_id)
    get_tree().change_scene_to_file("res://simulation.tscn")

func _open_ship_model_menu(model_id: String) -> void:
    menu_ship_id = model_id
    menu_open = true
    menu_dim.visible = true
    menu_panel.visible = true
    gear_button.visible = false
    selector_gear_button.visible = false
    controls_root.visible = false
    _show_ship_model_menu(model_id)

func _show_ship_model_menu(model_id: String) -> void:
    menu_state = "model_actions"
    menu_ship_id = model_id
    _clear_menu_content()

    var metadata := ShipStore.get_model_metadata(model_id)
    var model_name := str(metadata.get("name", "Ship Model"))

    var header := HBoxContainer.new()
    header.add_theme_constant_override("separation", 10)
    menu_content.add_child(header)

    var back := Button.new()
    back.text = "← Back"
    back.pressed.connect(_close_menu)
    header.add_child(back)

    var title := _menu_title(model_name)
    title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    header.add_child(title)

    menu_content.add_spacer(false)

    var rename_button := Button.new()
    rename_button.text = "Rename"
    rename_button.custom_minimum_size = Vector2(0.0, 56.0)
    rename_button.pressed.connect(_show_rename_ship_menu.bind(model_id))
    menu_content.add_child(rename_button)

    var export_button := Button.new()
    export_button.text = "Export JSON"
    export_button.custom_minimum_size = Vector2(0.0, 56.0)
    export_button.pressed.connect(_export_ship_model.bind(model_id))
    menu_content.add_child(export_button)

    var clipboard_button := Button.new()
    clipboard_button.text = "Copy JSON to Clipboard"
    clipboard_button.custom_minimum_size = Vector2(0.0, 56.0)
    clipboard_button.pressed.connect(_copy_ship_json_to_clipboard.bind(model_id))
    menu_content.add_child(clipboard_button)

    var delete_button := Button.new()
    delete_button.text = "Delete"
    delete_button.custom_minimum_size = Vector2(0.0, 56.0)
    delete_button.pressed.connect(_show_delete_ship_confirmation.bind(model_id))
    menu_content.add_child(delete_button)

func _show_rename_ship_menu(model_id: String) -> void:
    menu_state = "model_rename"
    menu_ship_id = model_id
    _clear_menu_content()

    var metadata := ShipStore.get_model_metadata(model_id)
    var model_name := str(metadata.get("name", "Ship Model"))

    var header := HBoxContainer.new()
    header.add_theme_constant_override("separation", 10)
    menu_content.add_child(header)

    var back := Button.new()
    back.text = "← Back"
    back.pressed.connect(_show_ship_model_menu.bind(model_id))
    header.add_child(back)

    var title := _menu_title("Rename")
    title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    header.add_child(title)

    var name_edit := LineEdit.new()
    name_edit.text = model_name
    name_edit.placeholder_text = "Ship name"
    name_edit.custom_minimum_size = Vector2(0.0, 52.0)
    name_edit.select_all()
    menu_content.add_child(name_edit)

    var rename_button := Button.new()
    rename_button.text = "Rename"
    rename_button.custom_minimum_size = Vector2(0.0, 56.0)
    rename_button.pressed.connect(_rename_ship_model.bind(model_id, name_edit))
    menu_content.add_child(rename_button)
    name_edit.text_submitted.connect(func(_text: String):
        _rename_ship_model(model_id, name_edit)
    )
    name_edit.grab_focus()

func _rename_ship_model(model_id: String, name_edit: LineEdit) -> void:
    if not ShipStore.rename_model(model_id, name_edit.text):
        return
    _show_ship_model_menu(model_id)
    _rebuild_ship_selector()

func _copy_ship_json_to_clipboard(model_id: String) -> void:
    var json := ShipStore.get_export_json(model_id)
    if json.is_empty():
        return
    DisplayServer.clipboard_set(json)

func _show_delete_ship_confirmation(model_id: String) -> void:
    menu_state = "model_delete_confirm"
    menu_ship_id = model_id
    _clear_menu_content()

    var metadata := ShipStore.get_model_metadata(model_id)
    var model_name := str(metadata.get("name", "Ship Model"))

    var header := HBoxContainer.new()
    header.add_theme_constant_override("separation", 10)
    menu_content.add_child(header)

    var back := Button.new()
    back.text = "← Back"
    back.pressed.connect(_show_ship_model_menu.bind(model_id))
    header.add_child(back)

    var title := _menu_title("Delete")
    title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    header.add_child(title)

    var prompt := Label.new()
    prompt.text = "Delete %s?" % model_name
    prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    prompt.add_theme_font_size_override("font_size", 22)
    menu_content.add_child(prompt)

    var warning := Label.new()
    warning.text = "This removes the saved ship model and its thumbnail."
    warning.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    warning.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    warning.modulate.a = 0.78
    menu_content.add_child(warning)

    var delete_button := Button.new()
    delete_button.text = "Delete"
    delete_button.custom_minimum_size = Vector2(0.0, 56.0)
    delete_button.pressed.connect(_confirm_delete_ship_model.bind(model_id))
    menu_content.add_child(delete_button)

    var cancel_button := Button.new()
    cancel_button.text = "Cancel"
    cancel_button.custom_minimum_size = Vector2(0.0, 56.0)
    cancel_button.pressed.connect(_show_ship_model_menu.bind(model_id))
    menu_content.add_child(cancel_button)

func _confirm_delete_ship_model(model_id: String) -> void:
    ShipStore.delete_model(model_id)
    _close_menu()
    _rebuild_ship_selector()

func _export_ship_model(model_id: String) -> void:
    var metadata := ShipStore.get_model_metadata(model_id)
    var model_name := str(metadata.get("name", "Ship Model"))
    var filename := model_name.validate_filename() + ".json"
    var filters := PackedStringArray([
        "*.json;Space Miner Ship Model;application/json",
    ])

    # On Android, Godot's native file dialog uses the Storage Access Framework.
    # The OS grants access to the user-selected URI, so broad storage permission
    # is not requested or required.
    if DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE):
        DisplayServer.file_dialog_show(
            "Export Ship Model",
            "",
            filename,
            false,
            DisplayServer.FILE_DIALOG_MODE_SAVE_FILE,
            filters,
            _on_native_ship_export_selected.bind(model_id)
        )
        return

    var dialog := FileDialog.new()
    dialog.title = "Export Ship Model"
    dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
    dialog.access = FileDialog.ACCESS_FILESYSTEM
    dialog.filters = filters
    dialog.current_file = filename
    dialog.file_selected.connect(func(path: String):
        ShipStore.export_model(model_id, path)
        dialog.queue_free()
    )
    dialog.canceled.connect(dialog.queue_free)
    ui_root.add_child(dialog)
    dialog.popup_centered_ratio(0.62)

func _on_native_ship_export_selected(
    status: bool,
    selected_paths: PackedStringArray,
    _selected_filter_index: int,
    model_id: String
) -> void:
    if not status or selected_paths.is_empty():
        return
    ShipStore.export_model(model_id, selected_paths[0])

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

    var highlight_row := HBoxContainer.new()
    highlight_row.add_theme_constant_override("separation", 12)
    menu_content.add_child(highlight_row)

    var highlight_label := Label.new()
    highlight_label.text = "Part highlight"
    highlight_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    highlight_row.add_child(highlight_label)

    var highlight_picker := ColorPickerButton.new()
    highlight_picker.custom_minimum_size = Vector2(70.0, 44.0)
    highlight_picker.color = AppSettings.highlight_color
    highlight_picker.color_changed.connect(AppSettings.set_highlight_color)
    highlight_row.add_child(highlight_picker)

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
    _refresh_vertical_controls_visibility()
    if value:
        _refresh_color_controls()
    _refresh_part_action_label()
    _refresh_rotation_direction_button_colors()
    _refresh_ghost()
    _refresh_selection_highlight()
    _refresh_rotation_guide()

func _perform_dpad(action: StringName) -> void:
    if parts_open:
        # Part rotation is deliberately fixed to construction-grid axes.
        # Orbiting the camera must not change what any rotation input does.
        if not PartFactory.is_color_tool(selected_part):
            _rotate_part_fixed(action)
            _refresh_ghost()
            _refresh_rotation_guide()
        return

    # Placement/navigation remains camera-relative so left/right/up/down still
    # follow the player's view while moving the cursor around the ship.
    var grid_direction := _camera_relative_grid_direction(action)
    if grid_direction == Vector2i.ZERO:
        return

    cursor.x = clampi(cursor.x + grid_direction.x, GRID_MIN_X, GRID_MAX_X)
    cursor.y = clampi(cursor.y + grid_direction.y, GRID_MIN_DEPTH, GRID_MAX_DEPTH)
    _refresh_ghost()
    _refresh_selection_highlight()
    if PartFactory.is_color_tool(selected_part):
        _refresh_color_controls()
    _update_level_label()

func _rotation_direction_color(action: StringName) -> Color:
    match action:
        &"builder_up":
            return Color("#55d6ff")
        &"builder_down":
            return Color("#ffad5c")
        &"builder_left":
            return Color("#c58cff")
        &"builder_right":
            return Color("#72df8f")
        _:
            return Color.WHITE

func _rotation_direction_letter(action: StringName) -> String:
    match action:
        &"builder_up":
            return "U"
        &"builder_down":
            return "D"
        &"builder_left":
            return "L"
        &"builder_right":
            return "R"
        _:
            return "?"

func _refresh_rotation_direction_button_colors() -> void:
    var rotation_mode := parts_open and not PartFactory.is_color_tool(selected_part)

    for action in dpad_direction_buttons:
        var button := dpad_direction_buttons[action] as Button
        if button == null:
            continue

        # Outside the parts drawer the D-pad is navigation, so it should look
        # exactly like a normal control with no rotation color coding.
        if not rotation_mode:
            for style_name in ["normal", "hover", "pressed"]:
                button.remove_theme_stylebox_override(style_name)
            for color_name in ["font_color", "font_hover_color", "font_pressed_color"]:
                button.remove_theme_color_override(color_name)
            continue

        var color := _rotation_direction_color(action)
        var normal := StyleBoxFlat.new()
        normal.bg_color = Color(color.r, color.g, color.b, 0.16)
        normal.border_color = Color(color.r, color.g, color.b, 0.70)
        normal.set_border_width_all(2)
        normal.corner_radius_top_left = 10
        normal.corner_radius_top_right = 10
        normal.corner_radius_bottom_left = 10
        normal.corner_radius_bottom_right = 10

        var hover := normal.duplicate() as StyleBoxFlat
        hover.bg_color = Color(color.r, color.g, color.b, 0.28)

        var pressed := normal.duplicate() as StyleBoxFlat
        pressed.bg_color = Color(color.r, color.g, color.b, 0.40)

        button.add_theme_stylebox_override("normal", normal)
        button.add_theme_stylebox_override("hover", hover)
        button.add_theme_stylebox_override("pressed", pressed)
        button.add_theme_color_override("font_color", color.lightened(0.18))
        button.add_theme_color_override("font_hover_color", color.lightened(0.26))
        button.add_theme_color_override("font_pressed_color", color.lightened(0.34))

func _refresh_rotation_guide() -> void:
    if rotation_guide_root == null:
        return

    for child in rotation_guide_root.get_children():
        child.queue_free()

    if not parts_open or PartFactory.is_color_tool(selected_part):
        return

    var cell_min := Vector3(float(cursor.x), float(cursor.z), float(cursor.y))
    var cell_max := cell_min + Vector3.ONE
    var center := (cell_min + cell_max) * 0.5
    var reference_local := PartFactory.rotation_reference_normal(selected_part)
    var reference_world := (part_basis * reference_local).normalized()

    # One side of every part is designated as its BASE: the broad mounting/
    # contact side when the geometry has one. Mark where that side currently
    # points, then simulate the exact same Basis turn used by the real rotation
    # code for each D-pad action. The colored face therefore means:
    # "press this button and BASE will move here."
    _add_rotation_reference_marker(
        center,
        cell_min,
        cell_max,
        reference_world
    )

    for action in [
        &"builder_up",
        &"builder_down",
        &"builder_left",
        &"builder_right",
    ]:
        var turn := _rotation_turn_for_action(action)
        if turn == Basis.IDENTITY:
            continue

        var predicted_basis := (part_basis * turn).orthonormalized()
        var predicted_reference := (predicted_basis * reference_local).normalized()

        _add_rotation_face_for_direction(
            center,
            cell_min,
            cell_max,
            predicted_reference,
            _rotation_direction_color(action),
            _rotation_direction_letter(action)
        )

func _add_rotation_reference_marker(
    center: Vector3,
    cell_min: Vector3,
    cell_max: Vector3,
    direction: Vector3
) -> void:
    var face_position := _rotation_face_position(
        center,
        cell_min,
        cell_max,
        direction,
        0.030
    )

    var label := Label3D.new()
    label.text = "BASE"
    label.font_size = 48
    label.pixel_size = 0.005
    label.modulate = Color(1.0, 1.0, 1.0, 0.72)
    label.outline_modulate = Color(0.0, 0.0, 0.0, 0.65)
    label.outline_size = 8
    label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
    label.no_depth_test = true
    label.render_priority = 3
    label.position = face_position + direction.normalized() * 0.045
    rotation_guide_root.add_child(label)

func _rotation_face_position(
    center: Vector3,
    cell_min: Vector3,
    cell_max: Vector3,
    direction: Vector3,
    inset: float
) -> Vector3:
    if absf(direction.y) > absf(direction.x) and absf(direction.y) >= absf(direction.z):
        return Vector3(
            center.x,
            cell_max.y - inset if direction.y >= 0.0 else cell_min.y + inset,
            center.z
        )

    if absf(direction.z) > absf(direction.x):
        return Vector3(
            center.x,
            center.y,
            cell_max.z - inset if direction.z >= 0.0 else cell_min.z + inset
        )

    return Vector3(
        cell_max.x - inset if direction.x >= 0.0 else cell_min.x + inset,
        center.y,
        center.z
    )

func _add_rotation_face_for_direction(
    center: Vector3,
    cell_min: Vector3,
    cell_max: Vector3,
    direction: Vector3,
    color: Color,
    letter: String
) -> void:
    var inset := 0.018
    var thickness := 0.018
    var face_position := _rotation_face_position(
        center,
        cell_min,
        cell_max,
        direction,
        inset
    )

    if absf(direction.y) > absf(direction.x) and absf(direction.y) >= absf(direction.z):
        _add_rotation_wall(
            face_position,
            Vector3(0.96, thickness, 0.96),
            color
        )
    elif absf(direction.z) > absf(direction.x):
        _add_rotation_wall(
            face_position,
            Vector3(0.96, 0.96, thickness),
            color
        )
    else:
        _add_rotation_wall(
            face_position,
            Vector3(thickness, 0.96, 0.96),
            color
        )

    _add_rotation_wall_letter(face_position, direction, color, letter)

func _add_rotation_wall_letter(
    face_position: Vector3,
    direction: Vector3,
    color: Color,
    letter: String
) -> void:
    var label := Label3D.new()
    label.text = letter
    label.font_size = 64
    label.pixel_size = 0.006
    label.modulate = Color(color.r, color.g, color.b, 0.68)
    label.outline_modulate = Color(0.0, 0.0, 0.0, 0.55)
    label.outline_size = 8
    label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
    label.no_depth_test = true
    label.render_priority = 2

    # Offset it just beyond the tinted face so the character stays visible
    # without z-fighting with the wall or the part.
    var normal := direction.normalized()
    label.position = face_position + normal * 0.035
    rotation_guide_root.add_child(label)

func _add_rotation_wall(position_value: Vector3, size_value: Vector3, color: Color) -> void:
    var mesh := BoxMesh.new()
    mesh.size = size_value

    var material := StandardMaterial3D.new()
    material.albedo_color = Color(color.r, color.g, color.b, 0.12)
    material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.cull_mode = BaseMaterial3D.CULL_DISABLED
    mesh.material = material

    var instance := MeshInstance3D.new()
    instance.mesh = mesh
    instance.position = position_value
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    rotation_guide_root.add_child(instance)

func _camera_relative_grid_direction(action: StringName) -> Vector2i:
    if camera == null:
        return Vector2i.ZERO

    # The D-pad/WASD describe screen directions, not fixed world axes. Project
    # the camera's current horizontal basis onto the construction plane, then
    # snap the result to the nearest grid cardinal. This makes the controls flip
    # naturally when the user orbits to the opposite side of the ship.
    var camera_right := camera.global_basis.x
    camera_right.y = 0.0
    if camera_right.length_squared() < 0.0001:
        camera_right = Vector3.RIGHT
    else:
        camera_right = camera_right.normalized()

    var camera_forward := -camera.global_basis.z
    camera_forward.y = 0.0
    if camera_forward.length_squared() < 0.0001:
        camera_forward = Vector3.FORWARD
    else:
        camera_forward = camera_forward.normalized()

    var world_direction := Vector3.ZERO
    match action:
        &"builder_up":
            world_direction = camera_forward
        &"builder_down":
            world_direction = -camera_forward
        &"builder_left":
            world_direction = -camera_right
        &"builder_right":
            world_direction = camera_right
        _:
            return Vector2i.ZERO

    if absf(world_direction.x) >= absf(world_direction.z):
        return Vector2i(1 if world_direction.x >= 0.0 else -1, 0)
    return Vector2i(0, 1 if world_direction.z >= 0.0 else -1)

func _rotation_turn_for_action(action: StringName) -> Basis:
    match action:
        &"builder_up":
            return Basis(Vector3.RIGHT, deg_to_rad(-90.0))
        &"builder_down":
            return Basis(Vector3.RIGHT, deg_to_rad(90.0))
        &"builder_left":
            return Basis(Vector3.UP, deg_to_rad(-90.0))
        &"builder_right":
            return Basis(Vector3.UP, deg_to_rad(90.0))
        _:
            return Basis.IDENTITY

func _rotate_part_fixed(action: StringName) -> void:
    # Rotation remains local to the part and independent of camera orientation.
    # The guide calls the same helper before the turn, so its U/D/L/R faces are
    # a direct preview of where the designated REF side will actually move.
    var turn := _rotation_turn_for_action(action)
    if turn == Basis.IDENTITY:
        return

    part_basis = (part_basis * turn).orthonormalized()

func _change_level(delta: int) -> void:
    if parts_open:
        return
    cursor.z = clampi(cursor.z + delta, GRID_MIN_LEVEL, GRID_MAX_LEVEL)
    _refresh_ghost()
    _refresh_selection_highlight()
    if PartFactory.is_color_tool(selected_part):
        _refresh_color_controls()
    _update_level_label()
    _rebuild_grid()

func _cycle_part(delta: int) -> void:
    if not parts_open:
        return
    selected_part = posmod(selected_part + delta, PartFactory.part_count())
    part_basis = Basis.IDENTITY
    paint_slot = 0
    _refresh_ghost()
    _refresh_selection_highlight()
    _rebuild_part_cards()
    _refresh_color_controls()
    _refresh_part_action_label()
    _refresh_rotation_direction_button_colors()
    _refresh_rotation_guide()

func _select_part(index: int) -> void:
    selected_part = clampi(index, 0, PartFactory.part_count() - 1)
    part_basis = Basis.IDENTITY
    paint_slot = 0
    _refresh_ghost()
    _refresh_selection_highlight()
    _rebuild_part_cards()
    _refresh_color_controls()
    _refresh_part_action_label()
    _refresh_rotation_direction_button_colors()
    _refresh_rotation_guide()

func _refresh_part_action_label() -> void:
    if place_button == null:
        return
    place_button.text = "Paint" if PartFactory.is_color_tool(selected_part) else "Place"

func _refresh_color_controls() -> void:
    if color_slot_select == null or color_picker == null:
        return

    color_slot_select.clear()
    color_slot_select.disabled = false
    color_picker.disabled = false

    if PartFactory.is_color_tool(selected_part):
        var target := _current_placed_part()
        if target == null:
            color_slot_select.add_item("No part selected")
            color_slot_select.disabled = true
            color_picker.color = paint_color
            return

        var target_index := int(target.get_meta("part_index", -1))
        if target_index < 0:
            color_slot_select.add_item("No color regions")
            color_slot_select.disabled = true
            return

        for slot_name in PartFactory.color_slot_names(target_index):
            color_slot_select.add_item(slot_name)
        if color_slot_select.item_count > 0:
            paint_slot = clampi(paint_slot, 0, color_slot_select.item_count - 1)
            color_slot_select.select(paint_slot)
        color_picker.color = paint_color
        return

    for slot_name in PartFactory.color_slot_names(selected_part):
        color_slot_select.add_item(slot_name)
    if color_slot_select.item_count > 0:
        color_slot_select.select(0)
        var colors: Array = part_colors[selected_part]
        color_picker.color = colors[0]

func _on_color_slot_selected(index: int) -> void:
    if PartFactory.is_color_tool(selected_part):
        paint_slot = index
        return

    var colors: Array = part_colors[selected_part]
    if index >= 0 and index < colors.size():
        color_picker.color = colors[index]

func _on_color_changed(color: Color) -> void:
    if PartFactory.is_color_tool(selected_part):
        paint_color = color
        return

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

    if PartFactory.is_color_tool(selected_part):
        return

    var colors: Array[Color] = []
    for value in part_colors[selected_part]:
        colors.append(value as Color)

    var ghost := PartFactory.create_part(selected_part, colors, true)
    ghost.position = _cursor_world_position()
    ghost.basis = part_basis
    ghost_root.add_child(ghost)

func _place_current_part() -> void:
    if menu_open:
        return

    if PartFactory.is_color_tool(selected_part):
        AppLogger.event("PAINT requested at cursor=%s" % str(cursor))
        _apply_color_tool()
        return

    if not PartFactory.is_placeable(selected_part):
        return

    var part_id := str(PartFactory.get_definition(selected_part)["id"])
    AppLogger.event(
        "PLACE begin part=%s index=%d cursor=%s" % [
            part_id,
            selected_part,
            str(cursor),
        ]
    )

    var occupied_cells := _occupied_cells_for(selected_part, part_basis, cursor)
    for cell in occupied_cells:
        if not _cell_in_bounds(cell):
            AppLogger.event(
                "PLACE aborted part=%s reason=out_of_bounds cell=%s" % [
                    part_id,
                    str(cell),
                ]
            )
            return

    var conflicts: Array[Node3D] = []
    for cell in occupied_cells:
        if not placed_parts.has(cell):
            continue
        var existing := placed_parts[cell] as Node3D
        if existing != null and not conflicts.has(existing):
            conflicts.append(existing)

    for existing in conflicts:
        _delete_placed_node(existing)

    var colors: Array[Color] = []
    for value in part_colors[selected_part]:
        colors.append(value as Color)

    AppLogger.event("PLACE creating geometry part=%s" % part_id)
    var part := PartFactory.create_part(selected_part, colors, false)
    AppLogger.event(
        "PLACE geometry created part=%s child_count=%d" % [
            part_id,
            part.get_child_count(),
        ]
    )

    part.position = _cursor_world_position()
    part.basis = part_basis
    part.set_meta("grid_position", cursor)
    part.set_meta("rotation_basis", part_basis)
    part.set_meta("colors", colors.duplicate())
    part.set_meta("occupied_cells", occupied_cells.duplicate())
    placed_root.add_child(part)

    for cell in occupied_cells:
        placed_parts[cell] = part

    AppLogger.event(
        "PLACE registered part=%s occupied=%s; starting highlight" % [
            part_id,
            str(occupied_cells),
        ]
    )
    _refresh_selection_highlight()
    _mark_ship_changed()
    AppLogger.event("PLACE complete part=%s" % part_id)

func _remove_current_part() -> void:
    var node := _current_placed_part()
    if node == null:
        return
    _delete_placed_node(node)
    _refresh_selection_highlight()
    _mark_ship_changed()
    if PartFactory.is_color_tool(selected_part):
        _refresh_color_controls()

func _delete_placed_node(node: Node3D) -> void:
    if node == null:
        return

    var cells: Array = node.get_meta("occupied_cells", [])
    for value in cells:
        var cell := value as Vector3i
        if placed_parts.get(cell, null) == node:
            placed_parts.erase(cell)

    if is_instance_valid(node):
        node.queue_free()

func _occupied_cells_for(part_index: int, basis_value: Basis, anchor: Vector3i) -> Array[Vector3i]:
    var result: Array[Vector3i] = []
    for offset in PartFactory.occupied_offsets(part_index):
        var local_world := Vector3(float(offset.x), float(offset.z), float(offset.y))
        var rotated := basis_value * local_world
        var logical_offset := Vector3i(
            int(round(rotated.x)),
            int(round(rotated.z)),
            int(round(rotated.y))
        )
        result.append(anchor + logical_offset)
    return result

func _cell_in_bounds(cell: Vector3i) -> bool:
    return (
        cell.x >= GRID_MIN_X
        and cell.x <= GRID_MAX_X
        and cell.y >= GRID_MIN_DEPTH
        and cell.y <= GRID_MAX_DEPTH
        and cell.z >= GRID_MIN_LEVEL
        and cell.z <= GRID_MAX_LEVEL
    )

func _current_placed_part() -> Node3D:
    if not placed_parts.has(cursor):
        return null
    var node := placed_parts[cursor] as Node3D
    if node == null or not is_instance_valid(node):
        placed_parts.erase(cursor)
        return null
    return node

func _apply_color_tool() -> void:
    var target := _current_placed_part()
    if target == null:
        return

    var target_index := int(target.get_meta("part_index", -1))
    if target_index < 0:
        return

    var stored_colors: Array = target.get_meta("colors", PartFactory.default_colors(target_index))
    var colors: Array[Color] = []
    for value in stored_colors:
        colors.append(value as Color)

    if colors.is_empty():
        return

    # The OptionButton is the authoritative source for the color region at the
    # moment Paint is pressed. Keeping only a cached index allowed the UI label
    # and the slot actually painted to get out of sync.
    var selected_slot := color_slot_select.selected
    if selected_slot < 0 or selected_slot >= colors.size():
        selected_slot = clampi(paint_slot, 0, colors.size() - 1)

    paint_slot = selected_slot
    colors[selected_slot] = paint_color
    target.set_meta("colors", colors.duplicate())

    var slot_names := PartFactory.color_slot_names(target_index)
    var slot_name := "slot_%d" % selected_slot
    if selected_slot < slot_names.size():
        slot_name = slot_names[selected_slot]

    AppLogger.event(
        "PAINT applying part=%s region=%s slot=%d color=%s" % [
            str(PartFactory.get_definition(target_index)["id"]),
            slot_name,
            selected_slot,
            paint_color.to_html(true),
        ]
    )

    PartFactory.apply_colors(target, colors, false)
    _refresh_selection_highlight()
    _mark_ship_changed()

func _refresh_selection_highlight() -> void:
    if selection_highlight_root == null:
        return

    for child in selection_highlight_root.get_children():
        child.queue_free()

    var target := _current_placed_part()
    if target == null:
        return

    var target_index := int(target.get_meta("part_index", -1))
    if target_index < 0:
        return

    var part_id := str(PartFactory.get_definition(target_index)["id"])
    AppLogger.event(
        "HIGHLIGHT begin part=%s cursor=%s" % [
            part_id,
            str(cursor),
        ]
    )

    if part_id == "cube":
        _add_cube_cell_highlight(cursor)
        AppLogger.event("HIGHLIGHT complete part=cube mode=cell_edges")
        return

    if part_id == "half_sphere":
        _add_rounded_surface_highlight(target)
        AppLogger.event("HIGHLIGHT complete part=half_sphere mode=surface_overlay")
        return

    # Non-cube parts use their actual geometric edges instead of an expanded
    # outline shell. The old shell approach could expose whole yellow faces on
    # slopes/cones depending on winding and view angle.
    var cell_min := Vector3(float(cursor.x), float(cursor.z), float(cursor.y))
    var cell_max := cell_min + Vector3.ONE
    var epsilon := Vector3.ONE * 0.004
    _add_mesh_edge_highlights(target, cell_min - epsilon, cell_max + epsilon)
    AppLogger.event("HIGHLIGHT complete part=%s mode=mesh_edges" % part_id)

func _add_mesh_edge_highlights(source: Node, cell_min: Vector3, cell_max: Vector3) -> void:
    if source is MeshInstance3D:
        var source_mesh := source as MeshInstance3D
        if source_mesh.mesh != null:
            _add_mesh_instance_edges(source_mesh, cell_min, cell_max)

    for child in source.get_children():
        _add_mesh_edge_highlights(child, cell_min, cell_max)

func _add_mesh_instance_edges(
    source_mesh: MeshInstance3D,
    cell_min: Vector3,
    cell_max: Vector3
) -> void:
    var mesh := source_mesh.mesh
    var edges: Dictionary = {}

    AppLogger.event(
        "HIGHLIGHT mesh scan begin name=%s surfaces=%d class=%s" % [
            source_mesh.name,
            mesh.get_surface_count(),
            mesh.get_class(),
        ]
    )

    for surface_index in range(mesh.get_surface_count()):
        AppLogger.event(
            "HIGHLIGHT reading surface mesh=%s surface=%d" % [
                source_mesh.name,
                surface_index,
            ]
        )

        var arrays := mesh.surface_get_arrays(surface_index)
        if arrays.is_empty():
            continue

        var vertex_data = arrays[Mesh.ARRAY_VERTEX]
        if not (vertex_data is PackedVector3Array):
            AppLogger.event(
                "HIGHLIGHT skipped surface mesh=%s surface=%d reason=no_vertices" % [
                    source_mesh.name,
                    surface_index,
                ]
            )
            continue
        var vertices := vertex_data as PackedVector3Array
        if vertices.is_empty():
            continue

        var index_data = arrays[Mesh.ARRAY_INDEX]
        if index_data is PackedInt32Array and not (index_data as PackedInt32Array).is_empty():
            var indices := index_data as PackedInt32Array
            for triangle_start in range(0, indices.size() - 2, 3):
                _register_triangle_edges(
                    edges,
                    source_mesh.global_transform * vertices[indices[triangle_start]],
                    source_mesh.global_transform * vertices[indices[triangle_start + 1]],
                    source_mesh.global_transform * vertices[indices[triangle_start + 2]]
                )
        else:
            for triangle_start in range(0, vertices.size() - 2, 3):
                _register_triangle_edges(
                    edges,
                    source_mesh.global_transform * vertices[triangle_start],
                    source_mesh.global_transform * vertices[triangle_start + 1],
                    source_mesh.global_transform * vertices[triangle_start + 2]
                )

    AppLogger.event(
        "HIGHLIGHT topology collected mesh=%s unique_edges=%d" % [
            source_mesh.name,
            edges.size(),
        ]
    )

    var crease_dot_limit := cos(deg_to_rad(32.0))
    var segment_transforms: Array[Transform3D] = []
    const MAX_HIGHLIGHT_EDGES := 512

    for value in edges.values():
        var edge := value as Dictionary
        var normals: Array = edge["normals"]

        var should_draw := normals.size() == 1
        if not should_draw:
            for first_index in range(normals.size()):
                if should_draw:
                    break
                var first_normal := normals[first_index] as Vector3
                for second_index in range(first_index + 1, normals.size()):
                    var second_normal := normals[second_index] as Vector3
                    if first_normal.dot(second_normal) < crease_dot_limit:
                        should_draw = true
                        break

        if not should_draw:
            continue

        var clipped := _clip_segment_to_cell(
            edge["a"] as Vector3,
            edge["b"] as Vector3,
            cell_min,
            cell_max
        )
        if clipped.size() != 2:
            continue

        if segment_transforms.size() >= MAX_HIGHLIGHT_EDGES:
            AppLogger.event(
                "HIGHLIGHT edge cap reached mesh=%s unique_edges=%d cap=%d" % [
                    source_mesh.name,
                    edges.size(),
                    MAX_HIGHLIGHT_EDGES,
                ]
            )
            break

        var segment_transform := _highlight_segment_transform(clipped[0], clipped[1])
        if segment_transform != Transform3D():
            segment_transforms.append(segment_transform)

    _add_highlight_segments(segment_transforms)

    AppLogger.event(
        "HIGHLIGHT mesh=%s surfaces=%d unique_edges=%d drawn_edges=%d" % [
            source_mesh.name,
            mesh.get_surface_count(),
            edges.size(),
            segment_transforms.size(),
        ]
    )

func _register_triangle_edges(
    edges: Dictionary,
    a: Vector3,
    b: Vector3,
    c: Vector3
) -> void:
    var cross := (b - a).cross(c - a)
    if cross.length_squared() < 0.0000001:
        return

    var face_normal := cross.normalized()
    _register_highlight_edge(edges, a, b, face_normal)
    _register_highlight_edge(edges, b, c, face_normal)
    _register_highlight_edge(edges, c, a, face_normal)

func _register_highlight_edge(
    edges: Dictionary,
    a: Vector3,
    b: Vector3,
    face_normal: Vector3
) -> void:
    if a.distance_squared_to(b) < 0.0000001:
        return

    var a_key := _highlight_vertex_key(a)
    var b_key := _highlight_vertex_key(b)
    var key := a_key + "|" + b_key if a_key < b_key else b_key + "|" + a_key

    if not edges.has(key):
        edges[key] = {
            "a": a,
            "b": b,
            "normals": [face_normal],
        }
        return

    var edge := edges[key] as Dictionary
    var normals: Array = edge["normals"]
    normals.append(face_normal)
    edge["normals"] = normals
    edges[key] = edge

func _highlight_vertex_key(value: Vector3) -> String:
    # Welding duplicate triangle vertices is necessary because the procedural
    # meshes are intentionally unindexed. The precision is far tighter than any
    # construction-grid movement.
    return "%d,%d,%d" % [
        int(round(value.x * 10000.0)),
        int(round(value.y * 10000.0)),
        int(round(value.z * 10000.0)),
    ]

func _clip_segment_to_cell(
    a: Vector3,
    b: Vector3,
    cell_min: Vector3,
    cell_max: Vector3
) -> PackedVector3Array:
    var direction := b - a
    var t_min := 0.0
    var t_max := 1.0

    for axis in range(3):
        var origin := _vector_component(a, axis)
        var delta := _vector_component(direction, axis)
        var min_value := _vector_component(cell_min, axis)
        var max_value := _vector_component(cell_max, axis)

        if absf(delta) < 0.000001:
            if origin < min_value or origin > max_value:
                return PackedVector3Array()
            continue

        var t1 := (min_value - origin) / delta
        var t2 := (max_value - origin) / delta
        if t1 > t2:
            var swap := t1
            t1 = t2
            t2 = swap

        t_min = maxf(t_min, t1)
        t_max = minf(t_max, t2)
        if t_min > t_max:
            return PackedVector3Array()

    return PackedVector3Array([
        a + direction * t_min,
        a + direction * t_max,
    ])

func _vector_component(value: Vector3, axis: int) -> float:
    match axis:
        0:
            return value.x
        1:
            return value.y
        _:
            return value.z

func _highlight_segment_transform(a: Vector3, b: Vector3) -> Transform3D:
    var direction := b - a
    var length := direction.length()
    if length < 0.006:
        return Transform3D()

    var y_axis := direction / length
    var helper := Vector3.UP
    if absf(y_axis.dot(helper)) > 0.96:
        helper = Vector3.RIGHT
    var x_axis := helper.cross(y_axis).normalized()
    var z_axis := x_axis.cross(y_axis).normalized()

    return Transform3D(
        Basis(
            x_axis,
            y_axis * length,
            z_axis
        ),
        (a + b) * 0.5
    )

func _add_highlight_segments(transforms: Array[Transform3D]) -> void:
    if transforms.is_empty():
        return

    # A single MultiMesh replaces hundreds of per-edge CylinderMesh resources.
    # The previous approach could rapidly create/destroy many rendering objects
    # while selecting curved parts, which is exactly where the native process
    # was terminating without a GDScript error.
    var cylinder := CylinderMesh.new()
    cylinder.height = 1.0
    cylinder.top_radius = 0.017
    cylinder.bottom_radius = 0.017
    cylinder.radial_segments = 8
    cylinder.rings = 1

    var material := StandardMaterial3D.new()
    material.albedo_color = AppSettings.highlight_color
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    cylinder.material = material

    var multimesh := MultiMesh.new()
    multimesh.transform_format = MultiMesh.TRANSFORM_3D
    multimesh.mesh = cylinder
    multimesh.instance_count = transforms.size()

    for index in range(transforms.size()):
        multimesh.set_instance_transform(index, transforms[index])

    var instance := MultiMeshInstance3D.new()
    instance.multimesh = multimesh
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    selection_highlight_root.add_child(instance)

func _add_rounded_surface_highlight(target: Node3D) -> void:
    # Rounded parts do not have a useful small set of silhouette/crease edges.
    # Highlight the full visible exterior instead. A very small scale expansion
    # keeps the overlay from z-fighting with the original surface.
    _clone_rounded_highlight_meshes(target)

func _clone_rounded_highlight_meshes(source: Node) -> void:
    if source is MeshInstance3D:
        var source_mesh := source as MeshInstance3D
        if source_mesh.mesh != null:
            var overlay := MeshInstance3D.new()
            overlay.mesh = source_mesh.mesh
            overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

            var material := StandardMaterial3D.new()
            var highlight := AppSettings.highlight_color
            highlight.a = 0.34
            material.albedo_color = highlight
            material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
            material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
            material.cull_mode = BaseMaterial3D.CULL_DISABLED
            overlay.material_override = material

            selection_highlight_root.add_child(overlay)

            var expanded := source_mesh.global_transform
            expanded.basis = expanded.basis.scaled(Vector3.ONE * 1.018)
            overlay.global_transform = expanded

    for child in source.get_children():
        _clone_rounded_highlight_meshes(child)

func _add_cube_cell_highlight(cell: Vector3i) -> void:
    var cell_min := Vector3(float(cell.x), float(cell.z), float(cell.y))
    var cell_max := cell_min + Vector3.ONE
    var center := (cell_min + cell_max) * 0.5
    var thickness := 0.035

    for y in [cell_min.y, cell_max.y]:
        for z in [cell_min.z, cell_max.z]:
            _add_highlight_beam(
                Vector3(center.x, y, z),
                Vector3(1.04, thickness, thickness)
            )
    for x in [cell_min.x, cell_max.x]:
        for z in [cell_min.z, cell_max.z]:
            _add_highlight_beam(
                Vector3(x, center.y, z),
                Vector3(thickness, 1.04, thickness)
            )
    for x in [cell_min.x, cell_max.x]:
        for y in [cell_min.y, cell_max.y]:
            _add_highlight_beam(
                Vector3(x, y, center.z),
                Vector3(thickness, thickness, 1.04)
            )

func _add_highlight_beam(position_value: Vector3, size_value: Vector3) -> void:
    var mesh := BoxMesh.new()
    mesh.size = size_value

    var material := StandardMaterial3D.new()
    material.albedo_color = AppSettings.highlight_color
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

    var instance := MeshInstance3D.new()
    instance.mesh = mesh
    instance.material_override = material
    instance.position = position_value
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    selection_highlight_root.add_child(instance)

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
    var upper_bounds: Array[Transform3D] = []
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

    # Draw the full horizontal grid only at and below the selected Z level.
    # Everything above the current selection is intentionally empty so it does
    # not obscure the ship. The outer build-volume cage is added separately.
    for level in range(level_line_min, min(cursor.z, level_line_max) + 1):
        var target: Array[Transform3D] = current if level == cursor.z else below

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

    # Vertical grid segments also stop above the selected cell layer.
    for x in range(x_line_min, x_line_max + 1):
        for depth in range(depth_line_min, depth_line_max + 1):
            for level in range(GRID_MIN_LEVEL, min(cursor.z, GRID_MAX_LEVEL) + 1):
                var target: Array[Transform3D] = current if level == cursor.z else below
                target.append(_beam_transform(
                    Vector3(float(x), float(level) + 0.5, float(depth)),
                    Vector3(thickness, 1.0, thickness)
                ))

    # Preserve a faint outline of the maximum construction volume above the
    # active Z layer. Only the four upper corner posts and the top rectangle are
    # shown; no interior grid lines are rendered above the selection.
    var upper_start := maxf(float(cursor.z + 1), float(level_line_min))
    var upper_height := float(level_line_max) - upper_start

    if upper_height > 0.0:
        var upper_center_y := upper_start + upper_height * 0.5
        for x in [x_line_min, x_line_max]:
            for depth in [depth_line_min, depth_line_max]:
                upper_bounds.append(_beam_transform(
                    Vector3(float(x), upper_center_y, float(depth)),
                    Vector3(thickness, upper_height, thickness)
                ))

    if cursor.z < level_line_max:
        var top_y := float(level_line_max)
        for depth in [depth_line_min, depth_line_max]:
            upper_bounds.append(_beam_transform(
                Vector3(center_x, top_y, float(depth)),
                Vector3(span_x, thickness, thickness)
            ))
        for x in [x_line_min, x_line_max]:
            upper_bounds.append(_beam_transform(
                Vector3(float(x), top_y, center_depth),
                Vector3(thickness, thickness, span_depth)
            ))

    var accent: Color = palette.get("accent", Color("#4fb7d8"))
    _add_grid_multimesh(upper_bounds, Color(accent.r, accent.g, accent.b, 0.055))
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
