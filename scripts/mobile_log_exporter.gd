extends Node

# Adds a mobile-only diagnostic export action to Simulation's existing Debug
# menu without coupling the large simulation script to Android storage APIs.
# The native Android save dialog uses the Storage Access Framework, and the
# returned content:// URI can be written directly by FileAccess.

var _button: Button
var _status_label: Label
var _debug_menu_id := 0


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    set_process(_is_mobile_platform())


func _is_mobile_platform() -> bool:
    return (
        OS.has_feature("android")
        or OS.has_feature("ios")
        or OS.has_feature("mobile")
    )


func _process(_delta: float) -> void:
    var scene := get_tree().current_scene
    if scene == null:
        _clear_menu_refs()
        return

    if not bool(scene.get("menu_open")):
        _clear_menu_refs()
        return

    var menu_value = scene.get("menu_content")
    if not (menu_value is VBoxContainer) or not is_instance_valid(menu_value):
        _clear_menu_refs()
        return

    var menu := menu_value as VBoxContainer
    if not _is_debug_menu(menu):
        _clear_menu_refs()
        return

    var menu_id := menu.get_instance_id()
    if (
        _debug_menu_id == menu_id
        and _button != null
        and is_instance_valid(_button)
        and _button.get_parent() == menu
    ):
        return

    _inject_export_controls(menu)


func _is_debug_menu(menu: VBoxContainer) -> bool:
    for child in menu.get_children():
        if child is Label and (child as Label).text == "Debug":
            return true
    return false


func _clear_menu_refs() -> void:
    _debug_menu_id = 0
    _button = null
    _status_label = null


func _inject_export_controls(menu: VBoxContainer) -> void:
    _debug_menu_id = menu.get_instance_id()

    var separator := HSeparator.new()
    separator.name = "MobileDiagnosticLogSeparator"
    menu.add_child(separator)

    _button = Button.new()
    _button.name = "MobileSaveDiagnosticLogButton"
    _button.text = "Save Diagnostic Log…"
    _button.custom_minimum_size = Vector2(0.0, 56.0)
    _button.pressed.connect(_show_save_dialog)
    menu.add_child(_button)

    _status_label = Label.new()
    _status_label.name = "MobileDiagnosticLogStatus"
    _status_label.text = (
        "Saves the current in-memory laser/performance diagnostic log."
    )
    _status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _status_label.modulate.a = 0.76
    menu.add_child(_status_label)


func _show_save_dialog() -> void:
    if not DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE):
        _set_status("Native file picker is unavailable on this device.")
        AppLogger.event(
            "MOBILE_LOG_EXPORT native file picker unavailable."
        )
        return

    var filters := PackedStringArray([
        "*.log;Diagnostic Log;text/plain",
        "*.txt;Text File;text/plain",
    ])

    AppLogger.event("MOBILE_LOG_EXPORT opening native save dialog.")
    var error := DisplayServer.file_dialog_show(
        "Save Diagnostic Log",
        "",
        _suggested_filename(),
        false,
        DisplayServer.FILE_DIALOG_MODE_SAVE_FILE,
        filters,
        _on_file_dialog_result
    )

    if error != OK:
        _set_status("Could not open file picker (error %d)." % error)
        AppLogger.event(
            "MOBILE_LOG_EXPORT file dialog failed to open; error=%d."
            % error
        )


func _on_file_dialog_result(
    status: bool,
    selected_paths: PackedStringArray,
    _selected_filter_index: int
) -> void:
    if not status or selected_paths.is_empty():
        _set_status("Save cancelled.")
        AppLogger.event("MOBILE_LOG_EXPORT save dialog cancelled.")
        return

    var destination := selected_paths[0]
    if AppLogger.export_buffered_log(destination):
        _set_status("Diagnostic log saved.")
    else:
        _set_status("Failed to save diagnostic log.")


func _suggested_filename() -> String:
    var now := Time.get_datetime_dict_from_system()
    return "SpaceMinerGame-%04d%02d%02d-%02d%02d%02d.log" % [
        int(now.get("year", 0)),
        int(now.get("month", 0)),
        int(now.get("day", 0)),
        int(now.get("hour", 0)),
        int(now.get("minute", 0)),
        int(now.get("second", 0)),
    ]


func _set_status(text: String) -> void:
    if _status_label != null and is_instance_valid(_status_label):
        _status_label.text = text
