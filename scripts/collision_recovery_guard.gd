extends Node

# Keeps collision-recovery separation targets attached to moving asteroids.
#
# Simulation computes collision_recovery_target_position once when impact starts,
# but asteroids continue orbiting. Completion is later tested against the
# asteroid's current position. A fixed old target can therefore cease to satisfy
# the current safe-radius test, leaving collision_recovery_active true forever;
# normal input is ignored in that state and ship velocity is zeroed every tick.
#
# This guard updates the target after Simulation advances the asteroid so the
# following physics tick always aims at a valid current-world clearance point.

const SIMULATION_SCRIPT_PATH := "res://scripts/simulation.gd"
const STATUS_LOG_INTERVAL := 0.50

var _was_active := false
var _status_elapsed := 0.0


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    # Simulation runs at the default priority 0. Run afterwards so its asteroid
    # orbital update is already reflected in the target for the next tick.
    process_physics_priority = 850_000


func _physics_process(delta: float) -> void:
    var scene := get_tree().current_scene
    if not _is_simulation_scene(scene):
        _was_active = false
        _status_elapsed = 0.0
        return

    var active := bool(scene.get("collision_recovery_active"))
    if not active:
        if _was_active:
            AppLogger.event("COLLISION_RECOVERY_GUARD end")
        _was_active = false
        _status_elapsed = 0.0
        return

    if not _was_active:
        _was_active = true
        _status_elapsed = STATUS_LOG_INTERVAL
        AppLogger.event("COLLISION_RECOVERY_GUARD begin")

    _track_current_asteroid_position(scene)

    _status_elapsed += delta
    if _status_elapsed >= STATUS_LOG_INTERVAL:
        _status_elapsed = 0.0
        _log_status(scene)


func _track_current_asteroid_position(scene: Node) -> void:
    var asteroid_value = scene.get("collision_recovery_asteroid")
    var ship_value = scene.get("ship_body")
    var safe_radius := float(scene.get("collision_recovery_safe_radius"))

    if (
        not (asteroid_value is Node3D)
        or not is_instance_valid(asteroid_value)
        or not (ship_value is Node3D)
        or not is_instance_valid(ship_value)
        or safe_radius <= 0.0
    ):
        return

    var asteroid := asteroid_value as Node3D
    var ship := ship_value as Node3D
    var radial := ship.global_position - asteroid.global_position
    radial.y = 0.0

    if radial.length_squared() <= 0.000001:
        var normal_value = scene.get("collision_recovery_normal")
        if normal_value is Vector3:
            radial = normal_value as Vector3
            radial.y = 0.0

    if radial.length_squared() <= 0.000001:
        radial = Vector3.FORWARD
    else:
        radial = radial.normalized()

    var target := asteroid.global_position + radial * safe_radius
    target.y = 0.0

    scene.set("collision_recovery_normal", radial)
    scene.set("collision_recovery_target_position", target)


func _log_status(scene: Node) -> void:
    var ship_value = scene.get("ship_body")
    var asteroid_value = scene.get("collision_recovery_asteroid")
    var elapsed := float(scene.get("collision_recovery_elapsed"))
    var safe_radius := float(scene.get("collision_recovery_safe_radius"))
    var distance := -1.0

    if (
        ship_value is Node3D
        and is_instance_valid(ship_value)
        and asteroid_value is Node3D
        and is_instance_valid(asteroid_value)
    ):
        distance = (ship_value as Node3D).global_position.distance_to(
            (asteroid_value as Node3D).global_position
        )

    AppLogger.event(
        "COLLISION_RECOVERY_GUARD active elapsed=%.3f distance=%.3f safe=%.3f"
        % [elapsed, distance, safe_radius]
    )


func _is_simulation_scene(scene: Node) -> bool:
    if scene == null:
        return false
    var script = scene.get_script()
    return (
        script != null
        and str(script.resource_path) == SIMULATION_SCRIPT_PATH
    )
