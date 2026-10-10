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
