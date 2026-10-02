extends Node

signal generation_started
signal generation_progress(progress: float, status: String)
signal generation_paused
signal generation_completed(path: String)
signal generation_failed(message: String)
signal active_sky_changed(path: String)

const SKY_DIR := "user://skyboxes"
const INDEX_PATH := SKY_DIR + "/index.json"
const CHECKPOINT_A_PATH := SKY_DIR + "/generation_checkpoint_a.json"
const CHECKPOINT_B_PATH := SKY_DIR + "/generation_checkpoint_b.json"

const SKY_FORMAT := "SPACE_FIELD_V1"
const GENERATION_FORMAT := "SPACE_FIELD_GENERATION_V1"
const INDEX_FORMAT := "SPACE_FIELD_INDEX_V1"

const STAR_COUNT := 10000
const CLOUD_COUNT := 6
const PARTICLES_PER_CLOUD := 300
const NEBULA_COUNT := CLOUD_COUNT * PARTICLES_PER_CLOUD
const STAR_RADIUS := 6200.0
const NEBULA_RADIUS := 5900.0

const ITEMS_PER_FRAME := 96
const CHECKPOINT_INTERVAL := 384

var _generating := false
var _generation_state: Dictionary = {}
var _rng_state := 1
var _items_since_checkpoint := 0
var _previous_tree_paused := false


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    _ensure_storage()
    set_process(false)


func _process(_delta: float) -> void:
    if not _generating:
        return

    var remaining := ITEMS_PER_FRAME

    while remaining > 0 and _generating:
        var phase := str(_generation_state.get("phase", "stars"))

        if phase == "stars":
            var stars := _generation_state.get("stars", []) as Array
            if stars.size() >= STAR_COUNT:
                _prepare_nebula_clouds()
                _generation_state["phase"] = "nebulae"
                _save_checkpoint()
                _emit_progress()
                continue

            stars.append(_generate_star_record())
            _generation_state["stars"] = stars
            remaining -= 1
            _items_since_checkpoint += 1

        elif phase == "nebulae":
            var nebulae := _generation_state.get("nebulae", []) as Array
            if nebulae.size() >= NEBULA_COUNT:
                _complete_generation()
                return

            nebulae.append(_generate_nebula_record(nebulae.size()))
            _generation_state["nebulae"] = nebulae
            remaining -= 1
            _items_since_checkpoint += 1

        else:
            _fail_generation("Unknown sky generation phase.")
            return

        if _items_since_checkpoint >= CHECKPOINT_INTERVAL:
            _save_checkpoint()

    _emit_progress()


func start_generation() -> bool:
    if _generating:
        return false

    _ensure_storage()
    _clear_checkpoints()

    var timestamp_ms := int(Time.get_unix_time_from_system() * 1000.0)
    var job_id := "%d_%d" % [timestamp_ms, Time.get_ticks_msec()]
    var seed := (timestamp_ms ^ Time.get_ticks_usec()) & 0xffffffff
    if seed == 0:
        seed = 0x5ACE2026

    _rng_state = seed
    _items_since_checkpoint = 0
    _generation_state = {
        "format": GENERATION_FORMAT,
        "version": 1,
        "status": "in_progress",
        "job_id": job_id,
        "name": _make_sky_name(),
        "created_unix": int(Time.get_unix_time_from_system()),
        "seed": seed,
        "rng_state": _rng_state,
        "checkpoint_sequence": 0,
        "phase": "stars",
        "star_count": STAR_COUNT,
        "nebula_count": NEBULA_COUNT,
        "star_radius": STAR_RADIUS,
        "nebula_radius": NEBULA_RADIUS,
        "stars": [],
        "nebulae": [],
        "clouds": [],
    }

    _generating = true
    _begin_blocking()
    set_process(true)
    _save_checkpoint()
    generation_started.emit()
    _emit_progress()
    return true


func resume_generation() -> bool:
    if _generating:
        return false

    var checkpoint := _load_best_checkpoint()
    if checkpoint.is_empty():
        return false

    _generation_state = checkpoint
    _generation_state["status"] = "in_progress"
    _rng_state = int(_generation_state.get("rng_state", 1))
    _items_since_checkpoint = 0

    _generating = true
    _begin_blocking()
    set_process(true)
    generation_started.emit()
    _emit_progress()
    return true


func pause_generation() -> void:
    if not _generating:
        return

    _generation_state["status"] = "paused"
    _save_checkpoint()
    _generating = false
    set_process(false)
    _end_blocking()
    generation_paused.emit()


func is_generating() -> bool:
    return _generating


func has_checkpoint() -> bool:
    return not _load_best_checkpoint().is_empty()


func get_checkpoint_summary() -> Dictionary:
    var checkpoint := _load_best_checkpoint()
    if checkpoint.is_empty():
        return {}

    var stars := checkpoint.get("stars", []) as Array
    var nebulae := checkpoint.get("nebulae", []) as Array
    var completed := stars.size() + nebulae.size()
    var total := STAR_COUNT + NEBULA_COUNT

    return {
        "name": str(checkpoint.get("name", "Interrupted Sky")),
        "progress": float(completed) / float(maxi(1, total)),
        "stars": stars.size(),
        "nebulae": nebulae.size(),
    }


func discard_checkpoint() -> void:
    if _generating:
        return
    _clear_checkpoints()


func list_skies() -> Array[Dictionary]:
    var index := _load_index()
    var result: Array[Dictionary] = []

    for value in index.get("skies", []):
        if not (value is Dictionary):
            continue
        var entry := value as Dictionary
        var path := str(entry.get("path", ""))
        if not path.is_empty() and FileAccess.file_exists(path):
            result.append(entry)

    return result


func get_active_sky_id() -> String:
    return str(_load_index().get("active", ""))


func get_active_sky_path() -> String:
    var index := _load_index()
    var active_id := str(index.get("active", ""))
    if active_id.is_empty():
        return ""

    for value in index.get("skies", []):
        if not (value is Dictionary):
            continue
        var entry := value as Dictionary
        if str(entry.get("id", "")) != active_id:
            continue

        var path := str(entry.get("path", ""))
        if FileAccess.file_exists(path):
            return path
        break

    return ""


func get_active_sky_name() -> String:
    var index := _load_index()
    var active_id := str(index.get("active", ""))
    if active_id.is_empty():
        return "Built-in Sky"

    for value in index.get("skies", []):
        if value is Dictionary:
            var entry := value as Dictionary
            if str(entry.get("id", "")) == active_id:
                return str(entry.get("name", "Generated Sky"))

    return "Built-in Sky"


func set_active_sky(sky_id: String) -> bool:
    var index := _load_index()

    if sky_id.is_empty():
        index["active"] = ""
        if not _write_json_atomic(INDEX_PATH, index):
            return false
        active_sky_changed.emit("")
        return true

    for value in index.get("skies", []):
        if not (value is Dictionary):
            continue
        var entry := value as Dictionary
        if str(entry.get("id", "")) != sky_id:
            continue

        var path := str(entry.get("path", ""))
        if not FileAccess.file_exists(path):
            return false

        index["active"] = sky_id
        if not _write_json_atomic(INDEX_PATH, index):
            return false
        active_sky_changed.emit(path)
        return true

    return false


func _begin_blocking() -> void:
    _previous_tree_paused = get_tree().paused
    get_tree().paused = true


func _end_blocking() -> void:
    get_tree().paused = _previous_tree_paused


func _emit_progress() -> void:
    var stars := _generation_state.get("stars", []) as Array
    var nebulae := _generation_state.get("nebulae", []) as Array
    var completed := stars.size() + nebulae.size()
    var total := STAR_COUNT + NEBULA_COUNT
    var progress := float(completed) / float(maxi(1, total))

    var status := ""
    if str(_generation_state.get("phase", "stars")) == "stars":
        status = "Generating stars: %s / %s" % [
            _format_number(stars.size()),
            _format_number(STAR_COUNT),
        ]
    else:
        status = "Generating nebula particles: %s / %s" % [
            _format_number(nebulae.size()),
            _format_number(NEBULA_COUNT),
        ]

    generation_progress.emit(progress, status)


func _generate_star_record() -> Array:
    var direction := _random_unit_vector()
    var luminosity := pow(_randf(), 4.2)
    var size := 3.4 + 14.0 * luminosity

    if _randf() < 0.006:
        size += 7.0 + 10.0 * _randf()

    var alpha := 0.34 + 0.66 * pow(_randf(), 1.6)
    var selector := _randf()
    var base := Vector3(0.98, 0.99, 1.00)

    if selector < 0.13:
        base = Vector3(0.82, 0.89, 1.00)
    elif selector < 0.57:
        base = Vector3(0.98, 0.99, 1.00)
    elif selector < 0.88:
        base = Vector3(1.00, 0.96, 0.86)
    elif selector < 0.96:
        base = Vector3(0.93, 0.96, 1.00)
    else:
        base = Vector3(1.00, 0.84, 0.68)

    var jitter := (_randf() - 0.5) * 0.025
    return [
        snappedf(direction.x, 0.0001),
        snappedf(direction.y, 0.0001),
        snappedf(direction.z, 0.0001),
        snappedf(size, 0.01),
        snappedf(clampf(base.x + jitter, 0.0, 1.0), 0.001),
        snappedf(clampf(base.y + jitter, 0.0, 1.0), 0.001),
        snappedf(clampf(base.z + jitter, 0.0, 1.0), 0.001),
        snappedf(alpha, 0.001),
    ]


func _prepare_nebula_clouds() -> void:
    var existing := _generation_state.get("clouds", []) as Array
    if not existing.is_empty():
        return

    var centers: Array[Vector3] = []
    var clouds: Array = []
    var min_dot := cos(0.62)

    for cloud_index in range(CLOUD_COUNT):
        var center := Vector3.FORWARD

        for _attempt in range(1000):
            var candidate := _random_unit_vector()
            var separated := true
            for other in centers:
                if candidate.dot(other) >= min_dot:
                    separated = false
                    break
            if separated:
                center = candidate
                break

        centers.append(center)

        var reference := Vector3.UP
        if absf(center.y) > 0.9:
            reference = Vector3.RIGHT

        var tangent := reference.cross(center).normalized()
        var bitangent := center.cross(tangent).normalized()
        var angle := _randf() * TAU
        var cos_angle := cos(angle)
        var sin_angle := sin(angle)

        var rotated_tangent := tangent * cos_angle + bitangent * sin_angle
        var rotated_bitangent := -tangent * sin_angle + bitangent * cos_angle

        var base_colors := [
            Vector3(0.28, 0.42, 0.78),
            Vector3(0.48, 0.26, 0.68),
            Vector3(0.16, 0.56, 0.64),
            Vector3(0.66, 0.24, 0.38),
            Vector3(0.48, 0.42, 0.72),
            Vector3(0.22, 0.48, 0.72),
        ]
        var base := base_colors[cloud_index % base_colors.size()] as Vector3

        clouds.append({
            "center": _vector_to_array(center),
            "tangent": _vector_to_array(rotated_tangent),
            "bitangent": _vector_to_array(rotated_bitangent),
            "sigma_a": 0.034 + _randf() * 0.028,
            "sigma_b": 0.020 + _randf() * 0.026,
            "color": _vector_to_array(base),
        })

    _generation_state["clouds"] = clouds


func _generate_nebula_record(index: int) -> Array:
    var clouds := _generation_state.get("clouds", []) as Array
    var cloud_index := int(floor(float(index) / float(PARTICLES_PER_CLOUD)))
    cloud_index = clampi(cloud_index, 0, clouds.size() - 1)

    var cloud := clouds[cloud_index] as Dictionary
    var center := _array_to_vector(cloud.get("center", []))
    var tangent := _array_to_vector(cloud.get("tangent", []))
    var bitangent := _array_to_vector(cloud.get("bitangent", []))
    var sigma_a := float(cloud.get("sigma_a", 0.04))
    var sigma_b := float(cloud.get("sigma_b", 0.03))
    var base := _array_to_vector(cloud.get("color", []))

    var ga := clampf(_gaussian(), -3.1, 3.1)
    var gb := clampf(_gaussian(), -3.1, 3.1)
    var u := ga * sigma_a
    var v := gb * sigma_b

    var direction := (
        center
        + tangent * u
        + bitangent * v
    ).normalized()

    var radial := sqrt(
        pow(u / maxf(0.000001, sigma_a), 2.0)
        + pow(v / maxf(0.000001, sigma_b), 2.0)
    )
    var falloff := maxf(0.15, 1.0 - radial / 4.3)
    var size := 70.0 + _randf() * 125.0 + (1.0 - falloff) * 35.0
    var alpha := (0.020 + _randf() * 0.040) * falloff
    var jitter := (_randf() - 0.5) * 0.055

    return [
        snappedf(direction.x, 0.0001),
        snappedf(direction.y, 0.0001),
        snappedf(direction.z, 0.0001),
        snappedf(size, 0.01),
        snappedf(clampf(base.x + jitter, 0.0, 1.0), 0.001),
        snappedf(clampf(base.y + jitter * 0.7, 0.0, 1.0), 0.001),
        snappedf(clampf(base.z + jitter, 0.0, 1.0), 0.001),
        snappedf(alpha, 0.001),
    ]


func _complete_generation() -> void:
    _generation_state["status"] = "complete"

    var job_id := str(_generation_state.get("job_id", "sky"))
    var final_path := SKY_DIR + "/sky_%s.json" % job_id
    var final_data := {
        "format": SKY_FORMAT,
        "version": 1,
        "id": job_id,
        "name": str(_generation_state.get("name", "Generated Sky")),
        "created_unix": int(_generation_state.get("created_unix", 0)),
        "seed": int(_generation_state.get("seed", 0)),
        "star_radius": STAR_RADIUS,
        "nebula_radius": NEBULA_RADIUS,
        "stars": _generation_state.get("stars", []),
        "nebulae": _generation_state.get("nebulae", []),
    }

    if not _write_json_atomic(final_path, final_data):
        _fail_generation("Could not save the completed sky JSON.")
        return

    _register_sky(final_path, final_data)
    _clear_checkpoints()

    _generating = false
    set_process(false)
    _end_blocking()
    generation_completed.emit(final_path)


func _fail_generation(message: String) -> void:
    if not _generation_state.is_empty():
        _generation_state["status"] = "paused"
        _save_checkpoint()

    _generating = false
    set_process(false)
    _end_blocking()
    generation_failed.emit(message)


func _save_checkpoint() -> bool:
    if _generation_state.is_empty():
        return false

    _generation_state["rng_state"] = _rng_state
    var sequence := int(_generation_state.get("checkpoint_sequence", 0)) + 1
    _generation_state["checkpoint_sequence"] = sequence
    var path := CHECKPOINT_A_PATH if sequence % 2 == 0 else CHECKPOINT_B_PATH

    var ok := _write_json_atomic(path, _generation_state)
    if ok:
        _items_since_checkpoint = 0
    return ok


func _load_best_checkpoint() -> Dictionary:
    var best: Dictionary = {}
    var best_sequence := -1

    for path in [CHECKPOINT_A_PATH, CHECKPOINT_B_PATH]:
        var candidate := _read_json(path)
        if candidate.is_empty():
            continue
        if str(candidate.get("format", "")) != GENERATION_FORMAT:
            continue
        if str(candidate.get("status", "")) not in ["in_progress", "paused"]:
            continue

        var sequence := int(candidate.get("checkpoint_sequence", 0))
        if sequence > best_sequence:
            best = candidate
            best_sequence = sequence

    return best


func _clear_checkpoints() -> void:
    for path in [
        CHECKPOINT_A_PATH,
        CHECKPOINT_B_PATH,
        CHECKPOINT_A_PATH + ".tmp",
        CHECKPOINT_B_PATH + ".tmp",
    ]:
        if FileAccess.file_exists(path):
            DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _register_sky(path: String, data: Dictionary) -> void:
    var index := _load_index()
    var skies := index.get("skies", []) as Array
    var sky_id := str(data.get("id", ""))

    for array_index in range(skies.size() - 1, -1, -1):
        var value = skies[array_index]
        if value is Dictionary and str((value as Dictionary).get("id", "")) == sky_id:
            skies.remove_at(array_index)

    skies.push_front({
        "id": sky_id,
        "name": str(data.get("name", "Generated Sky")),
        "path": path,
        "created_unix": int(data.get("created_unix", 0)),
        "stars": (data.get("stars", []) as Array).size(),
        "nebulae": (data.get("nebulae", []) as Array).size(),
    })

    index["skies"] = skies
    index["active"] = sky_id
    _write_json_atomic(INDEX_PATH, index)
    active_sky_changed.emit(path)


func _load_index() -> Dictionary:
    var index := _read_json(INDEX_PATH)
    if str(index.get("format", "")) != INDEX_FORMAT:
        return {
            "format": INDEX_FORMAT,
            "version": 1,
            "active": "",
            "skies": [],
        }

    if not (index.get("skies", []) is Array):
        index["skies"] = []
    return index


func _read_json(path: String) -> Dictionary:
    if not FileAccess.file_exists(path):
        return {}

    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        return {}

    var parsed = JSON.parse_string(file.get_as_text())
    file.close()

    if parsed is Dictionary:
        return parsed as Dictionary
    return {}


func _write_json_atomic(path: String, data: Dictionary) -> bool:
    _ensure_storage()

    var temp_path := path + ".tmp"
    var file := FileAccess.open(temp_path, FileAccess.WRITE)
    if file == null:
        return false

    file.store_string(JSON.stringify(data))
    file.flush()
    file.close()

    var target_absolute := ProjectSettings.globalize_path(path)
    var temp_absolute := ProjectSettings.globalize_path(temp_path)

    if FileAccess.file_exists(path):
        var remove_error := DirAccess.remove_absolute(target_absolute)
        if remove_error != OK:
            return false

    return DirAccess.rename_absolute(temp_absolute, target_absolute) == OK


func _ensure_storage() -> void:
    DirAccess.make_dir_recursive_absolute(
        ProjectSettings.globalize_path(SKY_DIR)
    )


func _random_unit_vector() -> Vector3:
    var y := _randf() * 2.0 - 1.0
    var angle := _randf() * TAU
    var horizontal := sqrt(maxf(0.0, 1.0 - y * y))
    return Vector3(
        horizontal * cos(angle),
        y,
        horizontal * sin(angle)
    )


func _gaussian() -> float:
    var u := maxf(_randf(), 0.000000000001)
    var v := _randf()
    return sqrt(-2.0 * log(u)) * cos(TAU * v)


func _randf() -> float:
    _rng_state = (
        (1664525 * _rng_state + 1013904223)
        & 0xffffffff
    )
    return float(_rng_state) / 4294967296.0


func _vector_to_array(value: Vector3) -> Array:
    return [value.x, value.y, value.z]


func _array_to_vector(value) -> Vector3:
    if not (value is Array) or (value as Array).size() < 3:
        return Vector3.ZERO
    var array := value as Array
    return Vector3(
        float(array[0]),
        float(array[1]),
        float(array[2])
    )


func _make_sky_name() -> String:
    var now := Time.get_datetime_dict_from_system()
    return "Sky %04d-%02d-%02d %02d-%02d-%02d" % [
        int(now.get("year", 0)),
        int(now.get("month", 0)),
        int(now.get("day", 0)),
        int(now.get("hour", 0)),
        int(now.get("minute", 0)),
        int(now.get("second", 0)),
    ]


func _format_number(value: int) -> String:
    var text := str(value)
    var output := ""
    var digits := 0

    for index in range(text.length() - 1, -1, -1):
        if digits > 0 and digits % 3 == 0:
            output = "," + output
        output = text[index] + output
        digits += 1

    return output
