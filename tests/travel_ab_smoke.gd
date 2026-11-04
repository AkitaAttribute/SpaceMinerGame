extends SceneTree

func _initialize() -> void:
    call_deferred("_run")


func _fail(message: String) -> void:
    push_error("TRAVEL_AB_SMOKE: " + message)
    quit(1)


func _run() -> void:
    var fixture_script = load("res://tests/travel_ab_fixture.gd")
    if not (fixture_script is GDScript):
        _fail("fixture script unavailable")
        return
    var fixture: Node3D = (fixture_script as GDScript).new()
    get_root().add_child(fixture)

    var ship := CharacterBody3D.new()
    ship.name = "Ship"
    fixture.add_child(ship)
    fixture.set("ship_body", ship)

    var area := Area3D.new()
    area.name = "MiningProximity"
    area.collision_mask = 1
    area.monitoring = true
    var collision := CollisionShape3D.new()
    var sphere := SphereShape3D.new()
    sphere.radius = 50.0
    collision.shape = sphere
    area.add_child(collision)
    ship.add_child(area)

    var asteroid := SpaceAsteroid.new()
    asteroid.sync_to_physics = false
    asteroid.configure("ab-fixture", Vector3(0, 0, -35), 2026, 3)
    fixture.add_child(asteroid)
    fixture.set("asteroids", {"one": asteroid})

    var script_value = load("res://scripts/travel_regression_probe.gd")
    if not (script_value is GDScript):
        _fail("probe script unavailable")
        return
    var probe: Node = (script_value as GDScript).new()
    fixture.add_child(probe)
    probe.set_process(false)
    probe.set_physics_process(false)

    probe.call("_start_test", Time.get_ticks_usec())
    var original_visual = asteroid.get("_visual") as Node3D
    if original_visual == null or not original_visual.visible:
        _fail("visible asteroid fixture missing")
        return

    # Force an entire A/B cycle without waiting 7 seconds per phase.
    for index in range(11):
        var expected: String = [
            "baseline", "proximity_off", "baseline", "far_spin_off",
            "baseline", "asteroid_visuals_off", "baseline",
            "collision_sync_off", "baseline", "mining_logic_off",
            "baseline"
        ][index]
        if index > 0:
            probe.call("_next_phase", Time.get_ticks_usec())
        var phase = (probe.get("PHASES") as Array)[int(probe.get("_phase_index"))]
        if phase != expected:
            _fail("phase ordering changed")
            return

        if expected == "asteroid_visuals_off" and original_visual.visible:
            _fail("visual-only diagnostic phase failed to hide asteroid")
            return
        if expected == "collision_sync_off" and not fixture.get_meta(
            "travel_probe_skip_collision_sync", false
        ):
            _fail("collision transform bypass not enabled")
            return
        if expected == "mining_logic_off" and not fixture.get_meta(
            "travel_probe_skip_mining", false
        ):
            _fail("laser logic bypass not enabled")
            return

    probe.call("_restore_baseline")
    if not original_visual.visible:
        _fail("asteroid visibility not restored")
        return
    if fixture.get_meta("travel_probe_skip_collision_sync", false):
        _fail("ship collider synchronization not restored")
        return
    if fixture.get_meta("travel_probe_skip_mining", false):
        _fail("laser update logic not restored")
        return
    for _i in range(3):
        await physics_frame
    if area.collision_mask != 1 or not area.monitoring:
        _fail("proximity Area3D not restored")
        return

    print("TRAVEL_AB_SMOKE_PASS all 11 phases and full game-state restoration")
    probe.set("_started", false)
    probe.free()
    fixture.free()
    quit()
