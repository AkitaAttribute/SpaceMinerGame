extends Node
## Small, stable updater bootstrap for the public PR #1 preview channel.
## This must remain the first autoload so packs override scenes/scripts before they load.

const CHANNEL := "pr-1"
const MANIFEST_URL := "https://github.com/AkitaAttribute/SpaceMinerGame/releases/download/pr-1-preview/manifest.json"
const UPDATE_DIR := "user://updates"
const INSTALLED_METADATA := "user://updates/installed.json"
const PENDING_PACK := "user://updates/download.pck.part"

var _manifest_http: HTTPRequest
var _download_http: HTTPRequest
var _download_dialog: ConfirmationDialog
var _install_dialog: ConfirmationDialog
var _notice_dialog: AcceptDialog

var _available_build := 0
var _current_build := 0
var _pending_url := ""
var _pending_sha256 := ""
var _pending_size := 0
var _installed_pack_path := ""

func _init() -> void:
    _load_installed_pack()

func _ready() -> void:
    if Engine.is_editor_hint() or DisplayServer.get_name() == "headless":
        return
    if OS.get_name() != "Windows" and OS.get_name() != "Android":
        return

    _current_build = _embedded_build()
    var installed := _read_installed_metadata()
    if not _installed_pack_path.is_empty():
        _current_build = maxi(_current_build, int(installed.get("build", 0)))

    _manifest_http = HTTPRequest.new()
    _manifest_http.use_threads = true
    _manifest_http.timeout = 20.0
    add_child(_manifest_http)
    _manifest_http.request_completed.connect(_on_manifest_received)

    _download_http = HTTPRequest.new()
    _download_http.use_threads = true
    _download_http.download_file = PENDING_PACK
    add_child(_download_http)
    _download_http.request_completed.connect(_on_pack_received)

    _download_dialog = ConfirmationDialog.new()
    _download_dialog.title = "Space Miner Update"
    _download_dialog.ok_button_text = "Download"
    _download_dialog.cancel_button_text = "Later"
    _download_dialog.confirmed.connect(_begin_download)
    add_child(_download_dialog)

    _install_dialog = ConfirmationDialog.new()
    _install_dialog.title = "Space Miner Update"
    _install_dialog.ok_button_text = "Install"
    _install_dialog.cancel_button_text = "Later"
    _install_dialog.confirmed.connect(_install_downloaded_pack)
    add_child(_install_dialog)

    _notice_dialog = AcceptDialog.new()
    _notice_dialog.title = "Space Miner Update"
    add_child(_notice_dialog)

    call_deferred("_check_for_update")

func _embedded_build() -> int:
    var version := str(ProjectSettings.get_setting("application/config/version", "0.1.0"))
    return version.get_slice(".", 2).to_int()

func _read_installed_metadata() -> Dictionary:
    if not FileAccess.file_exists(INSTALLED_METADATA):
        return {}
    var file := FileAccess.open(INSTALLED_METADATA, FileAccess.READ)
    if file == null:
        return {}
    var parsed: Variant = JSON.parse_string(file.get_as_text())
    if typeof(parsed) != TYPE_DICTIONARY:
        return {}
    return parsed as Dictionary

func _load_installed_pack() -> void:
    var installed := _read_installed_metadata()
    if str(installed.get("channel", "")) != CHANNEL:
        return
    var path := str(installed.get("path", ""))
    if not path.begins_with(UPDATE_DIR + "/") or not path.ends_with(".pck"):
        return
    if not FileAccess.file_exists(path):
        push_warning("Space Miner update pack missing: " + path)
        return
    if ProjectSettings.load_resource_pack(ProjectSettings.globalize_path(path), true):
        _installed_pack_path = path
        print("Space Miner: loaded PR preview patch ", path)
    else:
        push_error("Space Miner: failed to load update " + path + "; starting bundled version.")

func _check_for_update() -> void:
    var err := _manifest_http.request(MANIFEST_URL)
    if err != OK:
        push_warning("Space Miner update check failed to start: " + str(err))

func _on_manifest_received(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
    if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
        print("Space Miner: update manifest unavailable (", result, "/", response_code, ").")
        return
    var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
    if typeof(parsed) != TYPE_DICTIONARY:
        push_warning("Space Miner: invalid update manifest.")
        return
    var manifest: Dictionary = parsed as Dictionary
    if str(manifest.get("channel", "")) != CHANNEL:
        return
    var build := int(manifest.get("build", 0))
    if build <= _current_build:
        return

    var platform_key := "windows" if OS.get_name() == "Windows" else "android"
    var platform_data: Variant = manifest.get(platform_key, {})
    if typeof(platform_data) != TYPE_DICTIONARY:
        return
    var info: Dictionary = platform_data as Dictionary
    var url := str(info.get("url", ""))
    var sha := str(info.get("sha256", "")).to_lower()
    var size := int(info.get("bytes", 0))
    if not url.begins_with("https://github.com/AkitaAttribute/SpaceMinerGame/releases/download/pr-1-preview/"):
        return
    if sha.length() != 64 or not sha.is_valid_hex_number() or size <= 0:
        return

    _available_build = build
    _pending_url = url
    _pending_sha256 = sha
    _pending_size = size
    _download_dialog.dialog_text = "PR #1 preview build %d is available.\nInstalled build: %d.\n\nDownload this update?" % [build, _current_build]
    _download_dialog.popup_centered(Vector2i(520, 230))

func _begin_download() -> void:
    if _pending_url.is_empty() or _available_build <= _current_build:
        return
    var directory_error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(UPDATE_DIR))
    if directory_error != OK:
        _show_notice("Unable to create the update folder.")
        return
    if FileAccess.file_exists(PENDING_PACK):
        DirAccess.remove_absolute(ProjectSettings.globalize_path(PENDING_PACK))
    _download_http.download_file = PENDING_PACK
    var err := _download_http.request(_pending_url)
    if err != OK:
        _show_notice("Could not begin the download (%d)." % err)
        return
    print("Space Miner: downloading preview build ", _available_build)

func _on_pack_received(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
    if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
        _show_notice("Update download failed (%d / HTTP %d)." % [result, response_code])
        return
    if not FileAccess.file_exists(PENDING_PACK):
        _show_notice("The update file was not saved.")
        return
    var file := FileAccess.open(PENDING_PACK, FileAccess.READ)
    if file == null or file.get_length() != _pending_size:
        _show_notice("The downloaded update has an unexpected size.")
        return
    file.close()
    if FileAccess.get_sha256(PENDING_PACK).to_lower() != _pending_sha256:
        _show_notice("The downloaded update failed SHA-256 verification.")
        return
    _install_dialog.dialog_text = "Build %d has been downloaded and verified.\n\nInstall it now? Changes take effect after restarting Space Miner." % _available_build
    _install_dialog.popup_centered(Vector2i(550, 220))

func _install_downloaded_pack() -> void:
    if not FileAccess.file_exists(PENDING_PACK):
        _show_notice("The downloaded update was not found.")
        return
    # Unique pack filenames keep the previous working version available if a
    # newly installed pack fails to load on the next launch.
    var installed_path := "%s/pr-1-build-%d.pck" % [UPDATE_DIR, _available_build]
    var absolute_target := ProjectSettings.globalize_path(installed_path)
    if FileAccess.file_exists(installed_path):
        DirAccess.remove_absolute(absolute_target)
    var err := DirAccess.rename_absolute(ProjectSettings.globalize_path(PENDING_PACK), absolute_target)
    if err != OK:
        _show_notice("Unable to install the downloaded update (%d)." % err)
        return

    var metadata := {
        "channel": CHANNEL,
        "build": _available_build,
        "path": installed_path,
    }
    var config := FileAccess.open(INSTALLED_METADATA, FileAccess.WRITE)
    if config == null:
        _show_notice("The update was saved, but could not be activated.")
        return
    config.store_string(JSON.stringify(metadata))
    config.close()
    _current_build = _available_build
    _show_notice("Update installed. Fully close and reopen Space Miner to apply build %d.\n\nYour ships and settings remain in user storage." % _available_build)

func _show_notice(message: String) -> void:
    push_warning("Space Miner updater: " + message)
    _notice_dialog.dialog_text = message
    _notice_dialog.popup_centered(Vector2i(530, 200))
