extends SceneTree

# Regression: moving a blocked laser must not bypass its queue cooldown.
# Only a newly released/exposed voxel may prompt an early retry.
func _initialize() -> void:
    call_deferred("_run")


func _fail(message: String) -> void:
    push_error("MINING_RETRY_SMOKE: " + message)
    quit(1)


func _run() -> void:
    var script_value = load("res://scripts/simulation.gd")
    if not (script_value is GDScript):
        _fail("simulation script unavailable")
        return
    var simulation := (script_value as GDScript).new()
    var asteroid := SpaceAsteroid.new()
    asteroid.sync_to_physics = false
    asteroid.configure("retry-test", Vector3(0.0, 0.0, -20.0), 106, 3)
    get_root().add_child(asteroid)

    var initial_revision := asteroid.mining_availability_revision()
    var worker_id := 1234
    var claim := asteroid.claim_mining_cell(
        worker_id, Vector3.ZERO,
        func(_point: Vector3) -> bool: return true
    )
    if claim.is_empty():
        _fail("fixture could not claim the available block")
        return
    if asteroid.mining_availability_revision() != initial_revision:
        _fail("claim incorrectly signals newly available mining work")
        return

    var laser := {
        "next_cell_search": 1.5,
        "next_cell_event_search": 0.5,
        "last_failed_revision": initial_revision,
    }
    simulation.set("beam_time", 0.25)
    if bool(simulation.call("_mining_cell_retry_due", laser, asteroid)):
        _fail("early retry while waiting for cooldown")
        return

    # The ship can travel/turn through arbitrary distances. There is no
    # movement threshold that may override this blocked-miner wait.
    simulation.set("beam_time", 0.75)
    if bool(simulation.call("_mining_cell_retry_due", laser, asteroid)):
        _fail("retry without new available work")
        return

    asteroid.release_mining_cell(worker_id)
    if asteroid.mining_availability_revision() == initial_revision:
        _fail("released block did not signal newly available work")
        return
    simulation.set("beam_time", 0.30)
    if bool(simulation.call("_mining_cell_retry_due", laser, asteroid)):
        _fail("availability change bypassed minimum event spacing")
        return
    simulation.set("beam_time", 0.75)
    if not bool(simulation.call("_mining_cell_retry_due", laser, asteroid)):
        _fail("released voxel did not trigger a permitted retry")
        return

    laser["last_failed_revision"] = asteroid.mining_availability_revision()
    if bool(simulation.call("_mining_cell_retry_due", laser, asteroid)):
        _fail("same availability change triggered repeat scan")
        return
    simulation.set("beam_time", 1.51)
    if not bool(simulation.call("_mining_cell_retry_due", laser, asteroid)):
        _fail("periodic cooldown never resumes")
        return

    print("MINING_RETRY_SMOKE_PASS movement-independent cooldown, release wakes one retry")
    simulation.free()
    asteroid.free()
    quit()
