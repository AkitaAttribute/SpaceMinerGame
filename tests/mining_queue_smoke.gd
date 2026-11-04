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

    # Shared distance cache must retain nearby asteroids without any moving
    # Area3D, and must not include the ship or distant bodies.
    var script = load("res://scripts/simulation.gd")
    if not (script is GDScript):
        _fail("simulation script unavailable")
        return
    var simulation: Node3D = (script as GDScript).new()
    var ship := CharacterBody3D.new()
    ship.name = "TestShip"
    get_root().add_child(ship)
    simulation.set("ship_body", ship)
    simulation.set("asteroids", {"first": asteroid, "second": other})
    var pivot := Node3D.new()
    ship.add_child(pivot)
    var lasers: Array[Dictionary] = [{"pivot": pivot}]
    simulation.set("mining_lasers", lasers)
    simulation.call("_build_mining_detection_area")

    if ship.get_node_or_null("MiningProximity") != null:
        _fail("mining cache reintroduced a physics Area3D")
        return

    simulation.call("_refresh_mining_proximity", 0.20, true)
    var nearby := simulation.get("nearby_mining_asteroids") as Dictionary
    if not nearby.has(asteroid.get_instance_id()):
        _fail("near asteroid missing from shared distance cache")
        return
    if nearby.has(other.get_instance_id()):
        _fail("out-of-range asteroid added to distance cache")
        return
    var first_revision := int(simulation.get("nearby_mining_revision"))
    simulation.call("_refresh_mining_proximity", 0.03)
    if int(simulation.get("nearby_mining_revision")) != first_revision:
        _fail("cache revision changed without a proximity transition")
        return

    asteroid.global_position = Vector3(0, 0, -100)
    simulation.call("_refresh_mining_proximity", 0.20, true)
    nearby = simulation.get("nearby_mining_asteroids") as Dictionary
    if nearby.has(asteroid.get_instance_id()):
        _fail("departed asteroid remained in distance cache")
        return

    other.global_position = Vector3(0, 0, -30)
    simulation.call("_refresh_mining_proximity", 0.20, true)
    nearby = simulation.get("nearby_mining_asteroids") as Dictionary
    if not nearby.has(other.get_instance_id()):
        _fail("arriving asteroid was not registered")
        return
    if nearby.has(ship.get_instance_id()):
        _fail("ship was incorrectly registered as an asteroid")
        return

    print("MINING_QUEUE_SMOKE_PASS 20 unique jobs; multi-asteroid; distance-cache entry/exit; no physics Area3D")
    simulation.free()
    ship.free()
    asteroid.free()
    other.free()
    quit()
