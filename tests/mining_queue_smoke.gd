extends SceneTree

# Multi-laser queue and ship proximity regression. No player saves are loaded.
func _initialize() -> void:
    call_deferred("_run")


func _fail(message: String) -> void:
    push_error("MINING_QUEUE_SMOKE: " + message)
    quit(1)


func _run() -> void:
    var asteroid := SpaceAsteroid.new()
    asteroid.sync_to_physics = false
    asteroid.configure("queue-a", Vector3(0, 0, -25), 201, 3)
    get_root().add_child(asteroid)

    var other := SpaceAsteroid.new()
    other.sync_to_physics = false
    other.configure("queue-b", Vector3(0, 0, -90), 202, 3)
    get_root().add_child(other)

    var always_reachable := func(_point: Vector3) -> bool:
        return true

    var assigned: Dictionary = {}
    var workers: Array[int] = []
    for i in range(20):
        var worker := 10000 + i
        workers.append(worker)
        var claim := asteroid.claim_mining_cell(
            worker, Vector3(0, 0, -15), always_reachable
        )
        if claim.is_empty():
            _fail("failed to assign distinct surface voxel to worker %d" % i)
            return
        var cell := claim.get("cell", Vector3i.ZERO) as Vector3i
        if assigned.has(cell):
            _fail("two lasers received the same surface voxel")
            return
        assigned[cell] = true

    if asteroid.mining_assignment_count() != 20:
        _fail("not all 20 laser assignments were retained")
        return
    var original := asteroid.claim_mining_cell(
        workers[0], Vector3(0, 0, -15), always_reachable
    )
    if not assigned.has(original.get("cell")):
        _fail("repeated claim did not return stable queued assignment")
        return
    if asteroid.mining_assignment_count() != 20:
        _fail("repeat assignment duplicated a queued job")
        return

    # The same laser can independently work on a different asteroid.
    var independent := other.claim_mining_cell(
        workers[0], Vector3(0, 0, -15), always_reachable
    )
    if independent.is_empty() or other.mining_assignment_count() != 1:
        _fail("worker could not have independent asteroid-local assignment")
        return

    asteroid.release_mining_cell(workers[0])
    if asteroid.mining_assignment_count() != 19:
        _fail("release did not free exactly one queued job")
        return
    var replacement := asteroid.claim_mining_cell(
        29999, Vector3(0, 0, -15), always_reachable
    )
    if replacement.is_empty() or asteroid.mining_assignment_count() != 20:
        _fail("released work could not be reassigned")
        return

    # Check that Area3D handles broad phase once for the ship; the ship's
    # own collision layer must not become an asteroid candidate.
    var script = load("res://scripts/simulation.gd")
    if not (script is GDScript):
        _fail("simulation script unavailable")
        return
    var simulation: Node3D = (script as GDScript).new()
    var ship := CharacterBody3D.new()
    ship.name = "TestShip"
    get_root().add_child(ship)
    simulation.set("ship_body", ship)
    var pivot := Node3D.new()
    ship.add_child(pivot)
    var lasers: Array[Dictionary] = [{"pivot": pivot}]
    simulation.set("mining_lasers", lasers)
    simulation.call("_build_mining_detection_area")

    for i in range(4):
        await physics_frame
    var nearby := simulation.get("nearby_mining_asteroids") as Dictionary
    if not nearby.has(asteroid.get_instance_id()):
        _fail("near asteroid was not registered by the ship Area3D")
        return
    if nearby.has(other.get_instance_id()):
        _fail("out-of-range asteroid was registered by the ship Area3D")
        return

    asteroid.global_position = Vector3(0, 0, -100)
    for i in range(4):
        await physics_frame
    nearby = simulation.get("nearby_mining_asteroids") as Dictionary
    if nearby.has(asteroid.get_instance_id()):
        _fail("departed asteroid remained in proximity registry")
        return

    print("MINING_QUEUE_SMOKE_PASS 20 unique jobs; multi-asteroid; proximity entry/exit")
    simulation.free()
    ship.free()
    asteroid.free()
    other.free()
    quit()
