extends Node

# Compatibility autoload only.
#
# Mining-laser rendering is intentionally owned entirely by Simulation:
# - Simulation computes the real turret muzzle and aim point.
# - Simulation updates the original particle MultiMesh with
#   _update_beam_particles().
# - Simulation owns obstruction/alignment visibility.
# - FramePacer performs no laser work; its hot path remains nonblocking
#   semaphore polling followed by force_draw().
#
# This node must not hide, clone, replace, interpolate, reposition, or otherwise
# mutate mining-laser render nodes. It exists only because the project still has
# a LaserPresenter autoload entry and older code may reference the singleton.

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    set_process(false)
    set_physics_process(false)

    if OS.has_feature("windows") and not OS.has_feature("headless"):
        AppLogger.event(
            "LASER_PRESENTER passthrough_original_multimesh enabled; "
            + "Simulation owns beam geometry/visibility; "
            + "FramePacer performs no laser work"
        )


# Compatibility shim for any stale caller. The known-good frame pacer no longer
# invokes this function, and it intentionally performs no presentation work.
func prepare_for_present(_interpolation_fraction: float) -> int:
    return 0
