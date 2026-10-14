extends Node

# Independent worker heartbeat used to distinguish a main-thread stall from a
# process/system-wide scheduling stall. Records are kept in memory on the
# worker, then appended to the single SpaceMinerGame.log at shutdown.

const SAMPLE_USEC := 2000
const GAP_THRESHOLD_MS := 20.0
const PERIODIC_SECONDS := 10.0

var _enabled := false
var _thread := Thread.new()
var _stop_mutex := Mutex.new()
var _stop_requested := false
var _records: Array[String] = []
var _start_ticks_usec := 0
var _gap_count := 0
var _max_gap_ms := 0.0


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    _enabled = not (
        OS.has_feature("android")
        or OS.has_feature("ios")
        or OS.has_feature("mobile")
        or OS.has_feature("headless")
    )

    if not _enabled:
        return

    _start_ticks_usec = Time.get_ticks_usec()
    AppLogger.event(
        "THREAD_HEARTBEAT enabled sample=%.3fms threshold=%.1fms"
        % [float(SAMPLE_USEC) / 1000.0, GAP_THRESHOLD_MS]
    )

    var error := _thread.start(_heartbeat_thread)
    if error != OK:
        AppLogger.event("THREAD_START_FAILED error=%d" % error)


func _heartbeat_thread() -> void:
    var last_ticks := Time.get_ticks_usec()
    var next_periodic_ticks := last_ticks + int(PERIODIC_SECONDS * 1000000.0)
    var periodic_max_gap := 0.0
    var periodic_gap_count := 0

    while true:
        OS.delay_usec(SAMPLE_USEC)
        var now_ticks := Time.get_ticks_usec()
        var gap_ms := float(now_ticks - last_ticks) / 1000.0
        last_ticks = now_ticks

        if _should_stop():
            break

        periodic_max_gap = maxf(periodic_max_gap, gap_ms)

        if gap_ms >= GAP_THRESHOLD_MS:
            _gap_count += 1
            periodic_gap_count += 1
            _max_gap_ms = maxf(_max_gap_ms, gap_ms)
            _records.append(
                "THREAD_GAP t=%.3fs tick_usec=%d gap=%.2fms count=%d"
                % [
                    float(now_ticks - _start_ticks_usec) / 1000000.0,
                    now_ticks,
                    gap_ms,
                    _gap_count,
                ]
            )

        if now_ticks >= next_periodic_ticks:
            _records.append(
                (
                    "THREAD_PERIODIC t=%.3fs tick_usec=%d window_max_gap=%.2fms "
                    + "gaps_over_%.0fms=%d"
                )
                % [
                    float(now_ticks - _start_ticks_usec) / 1000000.0,
                    now_ticks,
                    periodic_max_gap,
                    GAP_THRESHOLD_MS,
                    periodic_gap_count,
                ]
            )
            periodic_max_gap = 0.0
            periodic_gap_count = 0
            next_periodic_ticks = now_ticks + int(PERIODIC_SECONDS * 1000000.0)


func _should_stop() -> bool:
    _stop_mutex.lock()
    var result := _stop_requested
    _stop_mutex.unlock()
    return result


func _request_stop() -> void:
    _stop_mutex.lock()
    _stop_requested = true
    _stop_mutex.unlock()


func _exit_tree() -> void:
    if not _enabled:
        return

    _request_stop()
    if _thread.is_started():
        _thread.wait_to_finish()

    # AppLogger is the only component that writes a diagnostic file. Avoid
    # calling it from the worker while it is running; merge records here after
    # the worker has stopped.
    for record in _records:
        AppLogger.event(record)

    AppLogger.event(
        "THREAD_EXIT t=%.3fs gaps_over_%.0fms=%d max_gap=%.2fms"
        % [
            float(Time.get_ticks_usec() - _start_ticks_usec) / 1000000.0,
            GAP_THRESHOLD_MS,
            _gap_count,
            _max_gap_ms,
        ]
    )
