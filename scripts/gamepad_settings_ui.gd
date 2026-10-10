extends Node

# The native Godot export template reads the same persisted setting before SDL
# initializes. This autoload only owns the settings-menu presentation and the
# desired value for the *next* launch; it deliberately never changes the live
# controller backend.

const SETTING_ROW_NAME := "GamepadSupportSetting"
const RESTART_NOTE_NAME := "GamepadSupportRestartNote"

var _active_at_launch := false


func _ready() -> void:
    # AppSettings is loaded immediately before this autoload and already applies
    # the Steam Deck default / persisted override to this value.
    _active_at_launch = AppSettings.gamepad_enabled
    get_tree().node_added.connect(_on_node_added)
    call_deferred("_inject_if_controls_open")
    AppLogger.event(
        "GAMEPAD startup desired=%s active_this_run=%s restart_required=false"
        % [
            str(AppSettings.gamepad_enabled),
            str(_active_at_launch),
        ]
    )


func _on_node_added(node: Node) -> void:
    # main.gd builds the settings pages dynamically. The Controls title is a
    # reliable signal that the page has just been reconstructed.
    if node is Label and (node as Label).text == "Controls":
        call_deferred("_inject_if_controls_open")


func _inject_if_controls_open() -> void:
    var scene := get_tree().current_scene
    if scene == null:
        return

    if str(scene.get("menu_state")) != "controls":
        return

    var content_value = scene.get("menu_content")
    if not (content_value is VBoxContainer):
        return

    var content := content_value as VBoxContainer
    if content.get_node_or_null(SETTING_ROW_NAME) != null:
        return

    var row := HBoxContainer.new()
    row.name = SETTING_ROW_NAME
    row.add_theme_constant_override("separation", 12)

    var label := Label.new()
    label.text = "Gamepad support"
    label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    row.add_child(label)

    var toggle := CheckButton.new()
    toggle.button_pressed = AppSettings.gamepad_enabled
    row.add_child(toggle)

    var note := Label.new()
    note.name = RESTART_NOTE_NAME
    note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    note.modulate.a = 0.76
    _update_restart_note(note)

    toggle.toggled.connect(func(value: bool):
        _set_desired_gamepad_enabled(value)
        _update_restart_note(note)
    )

    content.add_child(row)
    content.move_child(row, mini(1, content.get_child_count() - 1))
    content.add_child(note)
    content.move_child(note, mini(2, content.get_child_count() - 1))


func _set_desired_gamepad_enabled(value: bool) -> void:
    if AppSettings.gamepad_enabled == value:
        return

    # Assign directly instead of calling AppSettings.set_gamepad_enabled().
    # That older method changes the live process. Native controller startup is
    # intentionally fixed for the lifetime of this process, exactly like a
    # traditional no-gamepad launch option.
    AppSettings.gamepad_enabled = value
    AppSettings.save_settings()

    AppLogger.event(
        "GAMEPAD preference changed desired=%s active_this_run=%s restart_required=%s"
        % [
            str(value),
            str(_active_at_launch),
            str(value != _active_at_launch),
        ]
    )


func _update_restart_note(note: Label) -> void:
    if note == null or not is_instance_valid(note):
        return

    var desired := AppSettings.gamepad_enabled
    if desired != _active_at_launch:
        note.text = (
            "Restart required. Gamepad support is currently %s for this run "
            + "and will be %s after restart."
        ) % [
            "enabled" if _active_at_launch else "disabled",
            "enabled" if desired else "disabled",
        ]
    else:
        note.text = (
            "Gamepad support is currently %s. Changes to this setting take "
            + "effect after restarting Space Miner."
        ) % ("enabled" if _active_at_launch else "disabled")
