extends Node

const ROOT_DIR := "user://ships"
const INDEX_PATH := ROOT_DIR + "/index.json"

var _models: Array[Dictionary] = []


func _ready() -> void:
    _ensure_storage()
    _load_index()


func list_models() -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    for model in _models:
        result.append(model.duplicate(true))
    return result


func get_model_metadata(model_id: String) -> Dictionary:
    for model in _models:
        if str(model.get("id", "")) == model_id:
            return model.duplicate(true)
    return {}

func rename_model(model_id: String, requested_name: String) -> bool:
    var trimmed := requested_name.strip_edges()
    if trimmed.is_empty():
        return false

    var final_name := _unique_name(trimmed, model_id)
    for model in _models:
        if str(model.get("id", "")) == model_id:
            model["name"] = final_name
            model["updated_at"] = Time.get_datetime_string_from_system()
            _save_index()
            return true
    return false


func get_export_payload(model_id: String) -> Dictionary:
    var metadata := get_model_metadata(model_id)
    if metadata.is_empty():
        return {}

    var model_data := load_model(model_id)
    return {
        "format": "SpaceMinerShip",
        "version": 1,
        "name": str(metadata.get("name", "Ship")),
        "camera": model_data.get("camera", {}),
        "parts": model_data.get("parts", []),
    }


func get_export_json(model_id: String) -> String:
    var payload := get_export_payload(model_id)
    if payload.is_empty():
        return ""
    return JSON.stringify(payload, "  ")


func import_json(raw_json: String) -> Dictionary:
    var parsed = JSON.parse_string(raw_json)
    if not (parsed is Dictionary):
        return {
            "ok": false,
            "error": "The pasted/imported data is not a JSON object.",
        }

    var payload := parsed as Dictionary
    var format_name := str(payload.get("format", ""))
    if not format_name.is_empty() and format_name != "SpaceMinerShip":
        return {
            "ok": false,
            "error": "This JSON is not a Space Miner ship model.",
        }

    var parts = payload.get("parts", [])
    if not (parts is Array):
        return {
            "ok": false,
            "error": "The ship model has an invalid parts array.",
        }

    var camera = payload.get("camera", {})
    if not (camera is Dictionary):
        return {
            "ok": false,
            "error": "The ship model has invalid camera data.",
        }

    var requested_name := str(payload.get("name", "Imported Ship")).strip_edges()
    if requested_name.is_empty():
        requested_name = "Imported Ship"

    var model_id := "%d_%d" % [
        int(Time.get_unix_time_from_system()),
        Time.get_ticks_msec(),
    ]
    var metadata := {
        "id": model_id,
        "name": _unique_name(requested_name),
        "thumbnail": _thumbnail_path(model_id),
        "updated_at": Time.get_datetime_string_from_system(),
    }
    _models.append(metadata)
    _save_index()

    save_model(model_id, {
        "version": 1,
        "parts": (parts as Array).duplicate(true),
        "camera": (camera as Dictionary).duplicate(true),
    })

    return {
        "ok": true,
        "model": metadata.duplicate(true),
    }


func import_file(path: String) -> Dictionary:
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        return {
            "ok": false,
            "error": "The selected file could not be opened.",
        }
    return import_json(file.get_as_text())


func create_model() -> Dictionary:
    _ensure_storage()

    var used_names: Dictionary = {}
    for model in _models:
        used_names[str(model.get("name", ""))] = true

    var number := 1
    while used_names.has("Ship %d" % number):
        number += 1

    var model_id := "%d_%d" % [
        int(Time.get_unix_time_from_system()),
        Time.get_ticks_msec(),
    ]
    var metadata := {
        "id": model_id,
        "name": "Ship %d" % number,
        "thumbnail": _thumbnail_path(model_id),
        "updated_at": Time.get_datetime_string_from_system(),
    }
    _models.append(metadata)
    _save_index()

    save_model(model_id, {
        "version": 1,
        "parts": [],
        "camera": {},
    })

    return metadata.duplicate(true)


func load_model(model_id: String) -> Dictionary:
    var path := _model_path(model_id)
    if not FileAccess.file_exists(path):
        return {
            "version": 1,
            "parts": [],
            "camera": {},
        }

    var text := FileAccess.get_file_as_string(path)
    if text.is_empty():
        return {
            "version": 1,
            "parts": [],
            "camera": {},
        }

    var parsed = JSON.parse_string(text)
    if parsed is Dictionary:
        return (parsed as Dictionary).duplicate(true)

    return {
        "version": 1,
        "parts": [],
        "camera": {},
    }


func save_model(model_id: String, data: Dictionary) -> bool:
    _ensure_storage()
    var path := _model_path(model_id)
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        return false

    file.store_string(JSON.stringify(data, "  "))
    file.flush()

    for model in _models:
        if str(model.get("id", "")) == model_id:
            model["updated_at"] = Time.get_datetime_string_from_system()
            break
    _save_index()
    return true


func save_thumbnail(model_id: String, image: Image) -> bool:
    if image == null or image.is_empty():
        return false
    _ensure_storage()
    var result := image.save_png(_thumbnail_path(model_id))
    return result == OK


func load_thumbnail(model_id: String) -> Texture2D:
    var path := _thumbnail_path(model_id)
    if not FileAccess.file_exists(path):
        return null

    var image := Image.new()
    if image.load(path) != OK:
        return null
    return ImageTexture.create_from_image(image)


func export_model(model_id: String, destination_path: String) -> bool:
    var data := get_export_json(model_id)
    if data.is_empty():
        return false

    var target := destination_path
    if not target.begins_with("content://") and target.get_extension().to_lower() != "json":
        target += ".json"

    var output := FileAccess.open(target, FileAccess.WRITE)
    if output == null:
        return false

    output.store_string(data)
    output.flush()
    return true


func delete_model(model_id: String) -> bool:
    var found := false
    for index in range(_models.size() - 1, -1, -1):
        if str(_models[index].get("id", "")) == model_id:
            _models.remove_at(index)
            found = true
            break

    if not found:
        return false

    var model_path := _model_path(model_id)
    if FileAccess.file_exists(model_path):
        DirAccess.remove_absolute(ProjectSettings.globalize_path(model_path))

    var thumbnail_path := _thumbnail_path(model_id)
    if FileAccess.file_exists(thumbnail_path):
        DirAccess.remove_absolute(ProjectSettings.globalize_path(thumbnail_path))

    _save_index()
    return true


func _unique_name(requested_name: String, exclude_model_id := "") -> String:
    var base := requested_name.strip_edges()
    if base.is_empty():
        base = "Ship"

    var used: Dictionary = {}
    for model in _models:
        if str(model.get("id", "")) == exclude_model_id:
            continue
        used[str(model.get("name", ""))] = true

    if not used.has(base):
        return base

    var suffix := 2
    while used.has("%s %d" % [base, suffix]):
        suffix += 1
    return "%s %d" % [base, suffix]


func _ensure_storage() -> void:
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT_DIR))


func _load_index() -> void:
    _models.clear()
    if not FileAccess.file_exists(INDEX_PATH):
        _save_index()
        return

    var text := FileAccess.get_file_as_string(INDEX_PATH)
    var parsed = JSON.parse_string(text)
    if not (parsed is Array):
        _save_index()
        return

    for value in parsed:
        if value is Dictionary:
            _models.append((value as Dictionary).duplicate(true))


func _save_index() -> void:
    _ensure_storage()
    var file := FileAccess.open(INDEX_PATH, FileAccess.WRITE)
    if file == null:
        return

    file.store_string(JSON.stringify(_models, "  "))
    file.flush()


func _model_path(model_id: String) -> String:
    return ROOT_DIR + "/" + model_id + ".json"


func _thumbnail_path(model_id: String) -> String:
    return ROOT_DIR + "/" + model_id + ".png"
