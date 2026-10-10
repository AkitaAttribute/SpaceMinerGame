extends Node

signal theme_changed
signal highlight_color_changed
signal controls_visibility_changed
signal controls_scale_changed
signal bindings_changed
signal gamepad_support_changed(enabled: bool)

const CONFIG_PATH := "user://space_miner_settings.cfg"
const SDL_GAMEPAD_IGNORE_EXCEPT_ENV := "SDL_GAMECONTROLLER_IGNORE_DEVICES_EXCEPT"
const SDL_GAMEPAD_IGNORE_ALL_SENTINEL := "0x0000/0x0000"

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
var controls_scale_percent := 100.0
var invert_camera_horizontal := false
var invert_camera_vertical := true
var gamepad_enabled := false

var _disabled_gamepad_bindings: Dictionary = {}
var _owns_sdl_gamepad_ignore := false
var _previous_sdl_gamepad_ignore_exists := false
var _previous_sdl_gamepad_ignore := ""

func _ready() -> void:
    gamepad_enabled = _default_gamepad_enabled()
    _ensure_default_actions()
    _disable_tab_focus_navigation()
    _load_settings()
    _apply_gamepad_support()

func _input(event: InputEvent) -> void:
    if gamepad_enabled:
        return
    if _is_gamepad_input_event(event):
        get_viewport().set_input_as_handled()

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

func _disable_tab_focus_navigation() -> void:
    # Tab is reserved for the parts drawer. Godot's built-in UI actions also
    # use Tab/Shift+Tab for keyboard focus traversal, so remove only Tab from
    # those actions and leave any other configured navigation inputs intact.
    for action in [&"ui_focus_next", &"ui_focus_prev"]:
        if not InputMap.has_action(action):
            continue

        for input_event in InputMap.action_get_events(action).duplicate():
            if not (input_event is InputEventKey):
                continue
            var key_event := input_event as InputEventKey
            if key_event.physical_keycode == KEY_TAB or key_event.keycode == KEY_TAB:
                InputMap.action_erase_event(action, input_event)

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
    controls_scale_percent = float(config.get_value("controls", "scale_percent", 100.0))
    invert_camera_horizontal = bool(config.get_value("controls", "invert_camera_horizontal", false))
    invert_camera_vertical = bool(config.get_value("controls", "invert_camera_vertical", true))
    gamepad_enabled = bool(config.get_value("controls", "gamepad_enabled", _default_gamepad_enabled()))

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
    config.set_value("controls", "scale_percent", controls_scale_percent)
    config.set_value("controls", "invert_camera_horizontal", invert_camera_horizontal)
    config.set_value("controls", "invert_camera_vertical", invert_camera_vertical)
    config.set_value("controls", "gamepad_enabled", gamepad_enabled)

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

func set_controls_scale_percent(value: float) -> void:
    controls_scale_percent = value
    save_settings()
    controls_scale_changed.emit()


func set_invert_camera_horizontal(value: bool) -> void:
    invert_camera_horizontal = value
    save_settings()


func set_invert_camera_vertical(value: bool) -> void:
    invert_camera_vertical = value
    save_settings()


func set_gamepad_enabled(value: bool) -> void:
    if gamepad_enabled == value:
        return
    gamepad_enabled = value
    _apply_gamepad_support()
    save_settings()
    gamepad_support_changed.emit(gamepad_enabled)


func _apply_gamepad_support() -> void:
    _apply_sdl_gamepad_hint()
    if gamepad_enabled:
        _restore_gamepad_bindings()
    else:
        _capture_and_remove_gamepad_bindings()


func _capture_and_remove_gamepad_bindings() -> void:
    if not _disabled_gamepad_bindings.is_empty():
        return

    for action in InputMap.get_actions():
        var removed: Array = []
        for input_event in InputMap.action_get_events(action).duplicate():
            if not _is_gamepad_input_event(input_event):
                continue
            removed.append(input_event.duplicate())
            InputMap.action_erase_event(action, input_event)
        if not removed.is_empty():
            _disabled_gamepad_bindings[action] = removed


func _restore_gamepad_bindings() -> void:
    for action in _disabled_gamepad_bindings:
        if not InputMap.has_action(action):
            continue
        for input_event in _disabled_gamepad_bindings[action]:
            if not InputMap.action_has_event(action, input_event):
                InputMap.action_add_event(action, input_event)
    _disabled_gamepad_bindings.clear()


func _is_gamepad_input_event(input_event: InputEvent) -> bool:
    return (
        input_event is InputEventJoypadButton
        or input_event is InputEventJoypadMotion
    )


func _apply_sdl_gamepad_hint() -> void:
    # Godot 4.7 has no public runtime switch that completely shuts down its
    # joypad subsystem. On SDL desktop platforms, also ask SDL to skip every
    # game controller. InputMap filtering below remains the authoritative
    # in-game block if SDL already discovered a device before this autoload ran.
    if not (
        OS.has_feature("windows")
        or OS.has_feature("linux")
        or OS.has_feature("macos")
    ):
        return

    if gamepad_enabled:
        if _owns_sdl_gamepad_ignore:
            if _previous_sdl_gamepad_ignore_exists:
                OS.set_environment(
                    SDL_GAMEPAD_IGNORE_EXCEPT_ENV,
                    _previous_sdl_gamepad_ignore
                )
            else:
                OS.unset_environment(SDL_GAMEPAD_IGNORE_EXCEPT_ENV)
            _owns_sdl_gamepad_ignore = false
            _previous_sdl_gamepad_ignore_exists = false
            _previous_sdl_gamepad_ignore = ""
        return

    if not _owns_sdl_gamepad_ignore:
        _previous_sdl_gamepad_ignore_exists = OS.has_environment(
            SDL_GAMEPAD_IGNORE_EXCEPT_ENV
        )
        if _previous_sdl_gamepad_ignore_exists:
            _previous_sdl_gamepad_ignore = OS.get_environment(
                SDL_GAMEPAD_IGNORE_EXCEPT_ENV
            )
        _owns_sdl_gamepad_ignore = true

    # SDL_GAMECONTROLLER_IGNORE_DEVICES_EXCEPT means every VID/PID not in the
    # list is skipped. 0000/0000 is deliberately an impossible target.
    OS.set_environment(
        SDL_GAMEPAD_IGNORE_EXCEPT_ENV,
        SDL_GAMEPAD_IGNORE_ALL_SENTINEL
    )


func _default_gamepad_enabled() -> bool:
    # Physical Steam Deck hardware is the only platform where controller
    # support is enabled by default. Users can override this with
    # [controls] gamepad_enabled in space_miner_settings.cfg.
    if not OS.has_feature("linux"):
        return false

    var vendor := _read_linux_dmi_value("/sys/class/dmi/id/sys_vendor")
    var product := _read_linux_dmi_value("/sys/class/dmi/id/product_name")
    var board := _read_linux_dmi_value("/sys/class/dmi/id/board_name")
    var have_dmi := not vendor.is_empty() or not product.is_empty() or not board.is_empty()

    if have_dmi:
        var valve_hardware := vendor.contains("valve")
        var deck_model := (
            product.contains("jupiter")
            or product.contains("galileo")
            or product.contains("steam deck")
            or board.contains("jupiter")
            or board.contains("galileo")
            or board.contains("steam deck")
        )
        return valve_hardware and deck_model

    return (
        OS.has_environment("SteamDeck")
        and OS.get_environment("SteamDeck").strip_edges() == "1"
    )


func _read_linux_dmi_value(path: String) -> String:
    if not FileAccess.file_exists(path):
        return ""
    return FileAccess.get_file_as_string(path).strip_edges().to_lower()


func should_show_touch_controls() -> bool:
    # Check the concrete mobile platform tags as well as Godot's generic
    # "mobile" feature so Android/iOS never depend on a single feature alias.
    return (
        OS.has_feature("android")
        or OS.has_feature("ios")
        or OS.has_feature("mobile")
        or show_controls_on_desktop
    )

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
