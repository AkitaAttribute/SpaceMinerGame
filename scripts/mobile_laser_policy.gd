extends Node

# Android/mobile presentation policy for mining lasers.
#
# The render-rate smoother was introduced to solve the desktop case where the
# display can render far above the 60 Hz physics rate. On the current mobile
# build both rendering and physics run at 60 Hz, so rebuilding every MultiMesh
# particle again in _process() only duplicates work. Worse, LaserPresenter was
# Windows-only, meaning Android did not receive its per-instance interpolation
# policy or detailed laser diagnostics.
#
# Mobile therefore uses the authoritative physics-rate beam directly and turns
# the existing LaserPresenter diagnostics/policy back on.

var _applied := false


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS

    if not _is_mobile_platform() or OS.has_feature("headless"):
        set_process(false)
        return

    call_deferred("_apply_policy")


func _process(_delta: float) -> void:
    if not _applied:
        _apply_policy()


func _apply_policy() -> void:
    var smoother := get_node_or_null("/root/LaserRenderSmoother")
    var presenter := get_node_or_null("/root/LaserPresenter")
    if smoother == null or presenter == null:
        return

    # Mobile currently presents at the same cadence as physics. Do not rewrite
    # every beam particle a second time on the render path.
    smoother.set_process(false)

    # LaserPresenter disables MultiMesh physics interpolation and contains the
    # existing LASER_STATE / LASER_SAMPLE / LASER_VISUAL_JITTER diagnostics.
    # Its own _ready() historically restricted it to Windows, so explicitly
    # enable the exact same policy on mobile.
    presenter.set("_enabled", true)
    presenter.set_process(true)
    presenter.set_physics_process(true)

    _applied = true
    set_process(false)
    AppLogger.event(
        "MOBILE_LASER_POLICY physics_rate_beam=true render_smoother=false "
        + "laser_presenter=true"
    )


func _is_mobile_platform() -> bool:
    return (
        OS.has_feature("android")
        or OS.has_feature("ios")
        or OS.has_feature("mobile")
    )
