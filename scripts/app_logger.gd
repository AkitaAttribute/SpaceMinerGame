extends Node

var log_path := ""
var _engine_logger: BufferedLogger


class BufferedLogger extends Logger:
    var _records: Array[String] = []
    var _mutex := Mutex.new()

    func write_header(line: String) -> void:
        _mutex.lock()
        _records.append(line)
        _mutex.unlock()

    func write_event(message: String) -> void:
        _append("EVENT", message)

    func _log_message(message: String, error: bool) -> void:
        _append("STDERR" if error else "STDOUT", message)

    func _log_error(
        function: String,
        file: String,
        line: int,
        code: String,
        rationale: String,
        _editor_notify: bool,
        error_type: int,
        script_backtraces: Array[ScriptBacktrace]
    ) -> void:
        var type_name := "ERROR"
        match error_type:
            Logger.ERROR_TYPE_WARNING:
                type_name = "WARNING"
            Logger.ERROR_TYPE_SCRIPT:
                type_name = "SCRIPT"
            Logger.ERROR_TYPE_SHADER:
                type_name = "SHADER"

        var description := rationale if not rationale.is_empty() else code
        var message := "%s:%d in %s: %s" % [
            file,
            line,
            function,
            description,
        ]

        for backtrace in script_backtraces:
            if backtrace != null and not backtrace.is_empty():
                message += "\n" + backtrace.format(2, 4)

        _append(type_name, message)

    func _append(level: String, message: String) -> void:
        _mutex.lock()
        _records.append(
            "[%s] [%s] %s" % [
                Time.get_datetime_string_from_system(),
                level,
                message.strip_edges(),
            ]
        )
        _mutex.unlock()

    func snapshot() -> String:
        _mutex.lock()
        var text := "\n".join(_records) + "\n"
        _mutex.unlock()
        return text


    func write_to_file(path: String) -> bool:
        var file := FileAccess.open(path, FileAccess.WRITE)
        if file == null:
            return false

        _mutex.lock()
        for record in _records:
            file.store_line(record)
        _mutex.unlock()

        file.flush()
        file.close()
        return true


func _init() -> void:
    var directory := ""
    if OS.has_feature("editor"):
        directory = ProjectSettings.globalize_path("res://")
    else:
        directory = OS.get_executable_path().get_base_dir()

    # Keep the preferred path known from startup, but do not open, create,
    # truncate, or otherwise touch the file while the game is running.
    log_path = directory.path_join("SpaceMinerGame.log")

    _engine_logger = BufferedLogger.new()
    _engine_logger.write_header("============================================================")
    _engine_logger.write_header("SpaceMinerGame diagnostic log")
    _engine_logger.write_header(
        "Started: %s" % Time.get_datetime_string_from_system()
    )
    _engine_logger.write_header(
        "Engine: %s" % Engine.get_version_info().get("string", "unknown")
    )
    _engine_logger.write_header("Executable: %s" % OS.get_executable_path())
    _engine_logger.write_header("Log: %s" % log_path)
    _engine_logger.write_header(
        "Buffered in memory; written to disk only on normal shutdown."
    )
    _engine_logger.write_header("============================================================")

    OS.add_logger(_engine_logger)
    _engine_logger.write_event("Diagnostic logger registered in memory-only mode.")


func event(message: String) -> void:
    if _engine_logger != null:
        _engine_logger.write_event(message)


func export_buffered_log(path: String) -> bool:
    if _engine_logger == null or path.is_empty():
        return false

    # Add the export marker before taking the snapshot so the saved copy makes
    # it obvious that it was captured manually while the app was still alive.
    _engine_logger.write_event("Manual diagnostic log export requested.")
    var success := _engine_logger.write_to_file(path)

    if success:
        _engine_logger.write_event("Manual diagnostic log export completed.")
    else:
        _engine_logger.write_event(
            "Manual diagnostic log export failed; FileAccess error=%d."
            % FileAccess.get_open_error()
        )

    return success




# Only the upload copy is sanitized. The existing downloaded/shutdown log
# remains complete for local diagnosis.
func sanitized_upload_snapshot() -> String:
    if _engine_logger == null:
        return ""
    _engine_logger.write_event("Public-safe diagnostic log upload requested.")
    var content := _engine_logger.snapshot()

    # Replace user-defined ship names before generic patterns. Only stored names
    # (rather than internal part names, IDs, coordinates or timings) are removed.
    for model in ShipStore.list_models():
        var ship_name := str(model.get("name", "")).strip_edges()
        if not ship_name.is_empty():
            content = content.replace(ship_name, "[ship name]")

    # Some engine log lines include the device/account identity without labels.
    for key in ["COMPUTERNAME", "HOSTNAME", "USERNAME", "USER", "LOGNAME"]:
        if not OS.has_environment(key):
            continue
        var value := OS.get_environment(key).strip_edges()
        if value.length() >= 3:
            content = content.replace(value, "[device/user]")

    # These header fields are absolute device paths. Keep engine version,
    # timestamps, error levels and source script line numbers unmodified.
    content = _redact_upload_pattern(
        content, "(?m)^(Executable|Log):[^\\r\\n]*", "$1: [local path]"
    )
    # Explicit free-text fields and JSON fields that may contain user input.
    content = _redact_upload_pattern(
        content,
        "(?i)\\b(?:ship[_ ]?name|model[_ ]?name|device[_ ]?name|"
        + "host[_ ]?name|computer[_ ]?name|user[_ ]?name|player[_ ]?name)"
        + "\\s*[:=]\\s*[^\\r\\n,;]+",
        "[private name]"
    )
    content = _redact_upload_pattern(
        content,
        "(?i)\\\"(?:name|ship_name|device_name|hostname|username)\\\""
        + "\\s*:\\s*\\\"[^\\\"\\r\\n]*\\\"",
        "\"name\":\"[private name]\""
    )

    # HTTP URLs without queries (including the public updater) are useful.
    # URLs containing query data and credential-looking assignments are not.
    content = _redact_upload_pattern(
        content, "https?://[^\\s\\r\\n]+\\?[^\\s\\r\\n]+",
        "[URL with query omitted]"
    )
    content = _redact_upload_pattern(
        content,
        "(?i)\\b(?:authorization|bearer|password|passwd|secret|"
        + "api[_-]?key|access[_-]?token|refresh[_-]?token)"
        + "\\s*[:= ]\\s*[^\\s,;]+",
        "[credential]"
    )

    # Generated error stacks may expose home directories, Android content
    # providers and system paths. Keep res:// script references intact.
    content = _redact_upload_pattern(
        content, "(?i)content://[^\\r\\n]+", "[local URI]"
    )
    content = _redact_upload_pattern(
        content, "(?i)[A-Z]:[\\\\/][^\\r\\n]+", "[local path]"
    )
    content = _redact_upload_pattern(
        content,
        "(?i)(?:/home/|/Users/|/data/|/storage/|/sdcard/|"
        + "/private/|/var/|/tmp/|/run/user/)[^\\r\\n]+",
        "[local path]"
    )

    content = _redact_upload_pattern(
        content,
        "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}",
        "[email]"
    )
    content = _redact_upload_pattern(
        content, "(?i)\\b(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}\\b",
        "[MAC address]"
    )
    content = _redact_upload_pattern(
        content, "\\b(?:[0-9]{1,3}\\.){3}[0-9]{1,3}\\b",
        "[IP address]"
    )
    return content


func _redact_upload_pattern(
    text: String, pattern: String, replacement: String
) -> String:
    var expression := RegEx.new()
    if expression.compile(pattern) != OK:
        # Fail closed instead of silently uploading text with a broken filter.
        push_error("Diagnostic upload sanitization pattern failed to compile.")
        return "[Diagnostic log redacted: sanitization error]\n"
    return expression.sub(text, replacement, true)

func _write_buffered_log() -> void:
    if _engine_logger == null:
        return

    if _engine_logger.write_to_file(log_path):
        return

    # Only attempt the fallback at shutdown. There is still no diagnostic file
    # I/O during gameplay if the executable directory is not writable.
    log_path = ProjectSettings.globalize_path("user://SpaceMinerGame.log")
    _engine_logger.write_to_file(log_path)


func _exit_tree() -> void:
    if _engine_logger == null:
        return

    _engine_logger.write_event("Normal application shutdown.")
    OS.remove_logger(_engine_logger)
    _write_buffered_log()
    _engine_logger = null
