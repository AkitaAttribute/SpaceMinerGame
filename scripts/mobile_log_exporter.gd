extends Node

# Mobile Debug menu: local download plus a sanitized anonymous paste upload.
# Keep the existing download control at its current point in the menu.
const PASTE_URL := "https://paste.rs/"
const MAX_UPLOAD_BYTES := 512 * 1024

var _button: Button
var _upload_button: Button
var _copy_button: Button
var _status_label: Label
var _debug_menu_id := 0
var _upload_http: HTTPRequest
var _uploading := false
var _last_uploaded_url := ""
var _status_text := "Save a complete local log, or upload a sanitized copy."


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    _upload_http = HTTPRequest.new()
    _upload_http.use_threads = true
    _upload_http.timeout = 30.0
    add_child(_upload_http)
    _upload_http.request_completed.connect(_on_upload_completed)
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
        and _upload_button != null
        and is_instance_valid(_upload_button)
    ):
        return
    _inject_export_controls(menu)


func _is_debug_menu(menu: VBoxContainer) -> bool:
    return _contains_debug_title(menu)


func _contains_debug_title(node: Node) -> bool:
    if node is Label and (node as Label).text == "Debug":
        return true
    for child in node.get_children():
        if _contains_debug_title(child):
            return true
    return false


func _clear_menu_refs() -> void:
    _debug_menu_id = 0
    _button = null
    _upload_button = null
    _copy_button = null
    _status_label = null
    # Do not erase _last_uploaded_url: users can reopen Debug and recopy it.


func _inject_export_controls(menu: VBoxContainer) -> void:
    var existing := menu.get_node_or_null("MobileDiagnosticDownloadRow")
    if existing is HBoxContainer:
        _debug_menu_id = menu.get_instance_id()
        _button = existing.get_node_or_null("MobileSaveDiagnosticLogButton") as Button
        var upload_row := menu.get_node_or_null("MobileDiagnosticUploadRow")
        if upload_row != null:
            _upload_button = upload_row.get_node_or_null("MobileUploadLogButton") as Button
            _copy_button = upload_row.get_node_or_null("MobileCopyLogLinkButton") as Button
        _status_label = menu.get_node_or_null("MobileDiagnosticLogStatus") as Label
        _refresh_buttons()
        return

    _debug_menu_id = menu.get_instance_id()
    var insert_index := _find_skybox_button_index(menu)

    var separator := HSeparator.new()
    separator.name = "MobileDiagnosticLogSeparator"
    menu.add_child(separator)
    menu.move_child(separator, insert_index)
    insert_index += 1

    # Both full-width rows have an identical compact right-hand slot. The
    # original download stays first at the same menu position, and the two
    # primary buttons have matching width, height and alignment.
    var download_row := HBoxContainer.new()
    download_row.name = "MobileDiagnosticDownloadRow"
    download_row.add_theme_constant_override("separation", 8)
    menu.add_child(download_row)
    menu.move_child(download_row, insert_index)
    insert_index += 1

    _button = Button.new()
    _button.name = "MobileSaveDiagnosticLogButton"
    _button.text = "Download Logs"
    _button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _button.custom_minimum_size = Vector2(0.0, 56.0)
    _button.pressed.connect(_show_save_dialog)
    download_row.add_child(_button)

    var placeholder := Control.new()
    placeholder.custom_minimum_size = Vector2(100.0, 56.0)
    download_row.add_child(placeholder)

    var upload_row := HBoxContainer.new()
    upload_row.name = "MobileDiagnosticUploadRow"
    upload_row.add_theme_constant_override("separation", 8)
    menu.add_child(upload_row)
    menu.move_child(upload_row, insert_index)
    insert_index += 1

    _upload_button = Button.new()
    _upload_button.name = "MobileUploadLogButton"
    _upload_button.text = "Upload Logs"
    _upload_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _upload_button.custom_minimum_size = Vector2(0.0, 56.0)
    _upload_button.pressed.connect(_upload_logs)
    upload_row.add_child(_upload_button)

    _copy_button = Button.new()
    _copy_button.name = "MobileCopyLogLinkButton"
    _copy_button.text = "Copy"
    _copy_button.tooltip_text = "Copy last uploaded log URL"
    _copy_button.custom_minimum_size = Vector2(100.0, 56.0)
    _copy_button.pressed.connect(_copy_last_link)
    upload_row.add_child(_copy_button)

    _status_label = Label.new()
    _status_label.name = "MobileDiagnosticLogStatus"
    _status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _status_label.modulate.a = 0.76
    menu.add_child(_status_label)
    menu.move_child(_status_label, insert_index)
    _set_status(_status_text)
    _refresh_buttons()


func _refresh_buttons() -> void:
    if _upload_button != null and is_instance_valid(_upload_button):
        _upload_button.disabled = _uploading
    if _copy_button != null and is_instance_valid(_copy_button):
        _copy_button.disabled = _last_uploaded_url.is_empty()


func _upload_logs() -> void:
    if _uploading:
        return
    var payload := AppLogger.sanitized_upload_snapshot()
    if payload.is_empty():
        _set_status("No diagnostic log is available to upload.")
        return
    if payload.to_utf8_buffer().size() > MAX_UPLOAD_BYTES:
        _set_status("Log exceeds 512 KB; download it locally instead.")
        return

    _uploading = true
    _refresh_buttons()
    _set_status("Uploading sanitized log…")
    var error := _upload_http.request(
        PASTE_URL,
        PackedStringArray(["Content-Type: text/plain; charset=utf-8"]),
        HTTPClient.METHOD_POST,
        payload
    )
    if error != OK:
        _uploading = false
        _refresh_buttons()
        _set_status("Unable to start upload (error %d)." % error)
        AppLogger.event("LOG_UPLOAD failed to begin; error=%d." % error)


func _on_upload_completed(
    result: int, response_code: int, _headers: PackedStringArray,
    body: PackedByteArray
) -> void:
    _uploading = false
    _refresh_buttons()

    if result != HTTPRequest.RESULT_SUCCESS or response_code != 201:
        if response_code == 206:
            _set_status("Upload rejected: server accepted only part of the log.")
        else:
            _set_status("Upload failed (network %d, HTTP %d)." % [result, response_code])
        AppLogger.event(
            "LOG_UPLOAD failed; network=%d http=%d." % [result, response_code]
        )
        return

    var url := body.get_string_from_utf8().strip_edges()
    var url_regex := RegEx.new()
    if (
        url_regex.compile("^https://paste\\.rs/[A-Za-z0-9_-]+$") != OK
        or url_regex.search(url) == null
    ):
        _set_status("Upload response did not contain a valid paste.rs URL.")
        AppLogger.event("LOG_UPLOAD invalid response URL.")
        return

    _last_uploaded_url = url
    _refresh_buttons()
    DisplayServer.clipboard_set(_last_uploaded_url)
    _set_status("Uploaded and link copied: " + _last_uploaded_url)
    AppLogger.event("LOG_UPLOAD completed successfully.")


func _copy_last_link() -> void:
    if _last_uploaded_url.is_empty():
        return
    DisplayServer.clipboard_set(_last_uploaded_url)
    _set_status("Link copied: " + _last_uploaded_url)


func _find_skybox_button_index(menu: VBoxContainer) -> int:
    for index in range(menu.get_child_count()):
        var child := menu.get_child(index)
        if child is Button and "Skybox" in (child as Button).text:
            return index
    return menu.get_child_count()


func _show_save_dialog() -> void:
    if not DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE):
        _set_status("Native file picker is unavailable on this device.")
        AppLogger.event("MOBILE_LOG_EXPORT native file picker unavailable.")
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


func _set_status(message: String) -> void:
    _status_text = message
    if _status_label != null and is_instance_valid(_status_label):
        _status_label.text = message
