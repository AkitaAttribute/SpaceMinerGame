extends Node

signal theme_changed
signal highlight_color_changed
signal controls_visibility_changed
signal bindings_changed

const CONFIG_PATH := "user://space_miner_settings.cfg"

const ACTION_ORDER: Array[StringName] = [
    &"builder_up",
    &"builder_down",
    &"builder_left",
    &"builder_right",
    &"level_up",
    &"level_down",
    &"parts_toggle",
    &"menu_back",
    &"part_previous",
    &"part_next",
    &"place_part",
    &"remove_part",
]

const ACTION_LABELS := {
    &"builder_up": "D-pad Up / Rotate Up",
    &"builder_down": "D-pad Down / Rotate Down",
    &"builder_left": "D-pad Left / Rotate Left",
    &"builder_right": "D-pad Right / Rotate Right",
    &"level_up": "Vertical Up",
    &"level_down": "Vertical Down",
    &"parts_toggle": "Open / Close Parts",
    &"menu_back": "Menu / Back / Resume",
    &"part_previous": "Previous Part",
    &"part_next": "Next Part",
    &"place_part": "Place Part",
    &"remove_part": "Remove Part",
}

var theme_mode := "system"
var highlight_color := Color("#ffd83d")
var show_controls_on_desktop := false

func _ready() -> void:
    _ensure_default_actions()
    _load_settings()

func _ensure_default_actions() -> void:
    var defaults := {
        &"builder_up": [KEY_W, KEY_UP],
        &"builder_down": [KEY_S, KEY_DOWN],
        &"builder_left": [KEY_A, KEY_LEFT],
        &"builder_right": [KEY_D, KEY_RIGHT],
        &"level_up": [KEY_E],
        &"level_down": [KEY_Q],
        &"parts_toggle": [KEY_TAB],
        &"menu_back": [KEY_ESCAPE],
        &"part_previous": [KEY_COMMA],
        &"part_next": [KEY_PERIOD],
        &"place_part": [KEY_SPACE],
        &"remove_part": [KEY_DELETE],
    }

    for action in ACTION_ORDER:
        if not InputMap.has_action(action):
            InputMap.add_action(action)
        if InputMap.action_get_events(action).is_empty():
            var keycodes: Array = defaults.get(action, [])
            for keycode in keycodes:
                var event := InputEventKey.new()
                event.physical_keycode = keycode
                InputMap.action_add_event(action, event)

func _load_settings() -> void:
    var config := ConfigFile.new()
    if config.load(CONFIG_PATH) != OK:
        return

    theme_mode = str(config.get_value("display", "theme_mode", "system"))
    if theme_mode not in ["system", "light", "dark"]:
        theme_mode = "system"

    var stored_highlight = config.get_value("display", "highlight_color", Color("#ffd83d"))
    if stored_highlight is Color:
        highlight_color = stored_highlight

    show_controls_on_desktop = bool(config.get_value("controls", "show_on_desktop", false))

    for action in ACTION_ORDER:
        var section := "binding/%s" % String(action)
        if not config.has_section_key(section, "keys"):
            continue
        var stored: Array = config.get_value(section, "keys", [])
        if stored.is_empty():
            continue
        InputMap.action_erase_events(action)
        for code in stored:
            var event := InputEventKey.new()
            event.physical_keycode = int(code)
            InputMap.action_add_event(action, event)

func save_settings() -> void:
    var config := ConfigFile.new()
    config.set_value("display", "theme_mode", theme_mode)
    config.set_value("display", "highlight_color", highlight_color)
    config.set_value("controls", "show_on_desktop", show_controls_on_desktop)

    for action in ACTION_ORDER:
        var codes: Array[int] = []
        for input_event in InputMap.action_get_events(action):
            if input_event is InputEventKey:
                var key_event := input_event as InputEventKey
                codes.append(int(key_event.physical_keycode))
        config.set_value("binding/%s" % String(action), "keys", codes)

    config.save(CONFIG_PATH)

func set_theme_mode(value: String) -> void:
    if value not in ["system", "light", "dark"]:
        return
    theme_mode = value
    save_settings()
    theme_changed.emit()

func set_highlight_color(value: Color) -> void:
    highlight_color = value
    save_settings()
    highlight_color_changed.emit()

func is_dark_theme() -> bool:
    if theme_mode == "dark":
        return true
    if theme_mode == "light":
        return false
    if DisplayServer.is_dark_mode_supported():
        return DisplayServer.is_dark_mode()
    return false

func set_show_controls_on_desktop(value: bool) -> void:
    show_controls_on_desktop = value
    save_settings()
    controls_visibility_changed.emit()

func should_show_touch_controls() -> bool:
    return OS.has_feature("mobile") or show_controls_on_desktop

func get_action_label(action: StringName) -> String:
    return str(ACTION_LABELS.get(action, String(action)))

func get_binding_count(action: StringName) -> int:
    var count := 0
    for input_event in InputMap.action_get_events(action):
        if input_event is InputEventKey:
            count += 1
    return count

func get_binding_text(action: StringName, slot: int) -> String:
    var key_events := _key_events_for_action(action)
    if slot < 0 or slot >= key_events.size():
        return "Unbound"
    var key_event := key_events[slot]
    var text := key_event.as_text_physical_keycode()
    if text.is_empty():
        text = OS.get_keycode_string(key_event.physical_keycode)
    return text

func set_binding(action: StringName, slot: int, key_event: InputEventKey) -> void:
    if not InputMap.has_action(action):
        InputMap.add_action(action)

    var key_events := _key_events_for_action(action)
    var replacement := InputEventKey.new()
    replacement.physical_keycode = key_event.physical_keycode if key_event.physical_keycode != 0 else key_event.keycode
    replacement.ctrl_pressed = key_event.ctrl_pressed
    replacement.alt_pressed = key_event.alt_pressed
    replacement.shift_pressed = key_event.shift_pressed
    replacement.meta_pressed = key_event.meta_pressed

    while key_events.size() <= slot:
        key_events.append(null)
    key_events[slot] = replacement

    InputMap.action_erase_events(action)
    for event in key_events:
        if event != null:
            InputMap.action_add_event(action, event)

    save_settings()
    bindings_changed.emit()

func clear_binding(action: StringName, slot: int) -> void:
    var key_events := _key_events_for_action(action)
    if slot < 0 or slot >= key_events.size():
        return
    key_events.remove_at(slot)
    InputMap.action_erase_events(action)
    for event in key_events:
        InputMap.action_add_event(action, event)
    save_settings()
    bindings_changed.emit()

func _key_events_for_action(action: StringName) -> Array[InputEventKey]:
    var result: Array[InputEventKey] = []
    for input_event in InputMap.action_get_events(action):
        if input_event is InputEventKey:
            result.append(input_event as InputEventKey)
    return result
