extends Node

var log_path := ""
var _engine_logger: SameDirectoryLogger


class SameDirectoryLogger extends Logger:
    var _file: FileAccess
    var _mutex := Mutex.new()

    func _init(file: FileAccess) -> void:
        _file = file

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
        if _file == null:
            return

        _mutex.lock()
        _file.store_line(
            "[%s] [%s] %s" % [
                Time.get_datetime_string_from_system(),
                level,
                message.strip_edges(),
            ]
        )
        # Flush every entry. This is intentionally more aggressive than normal
        # production logging so the final breadcrumb survives a hard crash.
        _file.flush()
        _mutex.unlock()


func _init() -> void:
    var directory := ""
    if OS.has_feature("editor"):
        directory = ProjectSettings.globalize_path("res://")
    else:
        directory = OS.get_executable_path().get_base_dir()

    log_path = directory.path_join("SpaceMinerGame.log")
    var file := FileAccess.open(log_path, FileAccess.WRITE)

    # The requested location is beside the executable. If that directory is not
    # writable, keep diagnostics alive in user:// rather than silently losing them.
    if file == null:
        log_path = ProjectSettings.globalize_path("user://SpaceMinerGame.log")
        file = FileAccess.open(log_path, FileAccess.WRITE)

    if file == null:
        return

    file.store_line("============================================================")
    file.store_line("SpaceMinerGame diagnostic log")
    file.store_line("Started: %s" % Time.get_datetime_string_from_system())
    file.store_line("Engine: %s" % Engine.get_version_info().get("string", "unknown"))
    file.store_line("Executable: %s" % OS.get_executable_path())
    file.store_line("Log: %s" % log_path)
    file.store_line("============================================================")
    file.flush()

    _engine_logger = SameDirectoryLogger.new(file)
    OS.add_logger(_engine_logger)
    _engine_logger.write_event("Diagnostic logger registered.")


func event(message: String) -> void:
    if _engine_logger != null:
        _engine_logger.write_event(message)


func _exit_tree() -> void:
    if _engine_logger == null:
        return

    _engine_logger.write_event("Normal application shutdown.")
    OS.remove_logger(_engine_logger)
    _engine_logger = null
