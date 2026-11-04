extends SceneTree

# Standalone headless regression for a one-voxel remnant. It must not enter
# the normal game scene or alter any player saves.


func _initialize() -> void:
    call_deferred("_run")


func _fail(message: String) -> void:
    push_error("LAST_CELL_SMOKE: " + message)
    quit(1)


func _run() -> void:
    var script_value = load("res://scripts/simulation.gd")
    if not (script_value is GDScript):
        _fail("cannot load simulation script")
        return

    var simulation: Node3D = (script_value as GDScript).new()
    var ship_root := Node3D.new()
    get_root().add_child(ship_root)
    simulation.set("ship_visual_root", ship_root)

    var asteroid := SpaceAsteroid.new()
    # Keep the test asteroid's transform stable when attaching it to the
    # SceneTree; physics synchronization is irrelevant in this headless test.
    asteroid.sync_to_physics = false
    asteroid.configure("last-cell-test", Vector3(0.0, 0.0, -20.0), 42, 3)
    get_root().add_child(asteroid)
    asteroid.global_position = Vector3(0.0, 0.0, -20.0)

    # Retain only an off-center voxel, matching the late-mining geometry that
    # used to leave autopilot orbiting while one blocked turret monopolized it.
    var last_cell := Vector3i(0, 0, 1)
    var removed: Dictionary = {}
    for x in range(-1, 2):
        for y in range(-1, 2):
            for z in range(-1, 2):
                var cell := Vector3i(x, y, z)
                if cell != last_cell:
                    removed["%d,%d,%d" % [x, y, z]] = true
    asteroid.set("_removed_cells", removed)
    asteroid.set("_remaining_cells", 1)
    var final_surface: Array[Vector3i] = [last_cell]
    asteroid.set("_surface_cells", final_surface)

    var clear_pivot := Node3D.new()
    clear_pivot.position = Vector3(3.0, 0.0, 0.0)
    var blocked_pivot := Node3D.new()
    blocked_pivot.position = Vector3.ZERO
    ship_root.add_child(clear_pivot)
    ship_root.add_child(blocked_pivot)

    var clear_laser := {
        "target": asteroid,
        "pivot": clear_pivot,
        "anchor_cell": Vector3i(0, 0, 0),
        "reserved_cell": null,
    }
    var blocked_laser := {
        "target": asteroid,
        "pivot": blocked_pivot,
        "anchor_cell": Vector3i(1, 0, 0),
        "reserved_cell": last_cell,
    }
    var entries: Array[Dictionary] = [clear_laser, blocked_laser]
    simulation.set("mining_lasers", entries)

    # A hull part intersects the blocked laser's shot, but not the other
    # laser's shot from the side.
    var occluder := {
        "cell": Vector3i(9, 9, 9),
        "aabb": AABB(Vector3(-0.5, -0.5, -8.0), Vector3.ONE),
    }
    var boxes: Array[Dictionary] = [occluder]
    simulation.set("ship_cell_boxes", boxes)

    var blocked_muzzle := blocked_pivot.global_position + Vector3.UP * 0.42
    var remaining_world := asteroid.cell_world_position(last_cell)
    var ray_is_blocked: bool = simulation.call(
        "_ship_blocks_segment",
        blocked_muzzle,
        remaining_world,
        blocked_laser["anchor_cell"]
    )
    if not ray_is_blocked:
        _fail(
            "fixture invalid: obstacle does not intercept laser; muzzle=%s target=%s blockers=%s"
            % [str(blocked_muzzle), str(remaining_world), str(simulation.get("ship_cell_boxes"))]
        )
        return

    # The asteroid owns assignments, rather than having lasers scan one
    # another's local reservation dictionaries.
    var blocked_worker := blocked_pivot.get_instance_id()
    var clear_worker := clear_pivot.get_instance_id()
    var blocked_assignment := asteroid.claim_mining_cell(
        blocked_worker, blocked_muzzle, func(_position: Vector3) -> bool:
            return true
    )
    if blocked_assignment.get("cell") != last_cell:
        _fail("blocked worker did not acquire its initial assignment")
        return

    var clear_muzzle := clear_pivot.global_position + Vector3.UP * 0.42
    var clear_check := func(position: Vector3) -> bool:
        return not bool(simulation.call(
            "_ship_blocks_segment", clear_muzzle, position,
            clear_laser["anchor_cell"]
        ))
    var reserved := asteroid.claim_mining_cell(
        clear_worker, clear_muzzle, clear_check
    )
    if not reserved.is_empty():
        _fail("another worker acquired an already reserved cell")
        return

    # Once an obstructed miner releases its job, it must not reacquire an
    # unreachable voxel, but the clear miner must receive that same cell.
    asteroid.release_mining_cell(blocked_worker)
    var blocked_check := func(position: Vector3) -> bool:
        return not bool(simulation.call(
            "_ship_blocks_segment", blocked_muzzle, position,
            blocked_laser["anchor_cell"]
        ))
    var blocked_again := asteroid.claim_mining_cell(
        blocked_worker, blocked_muzzle, blocked_check
    )
    if not blocked_again.is_empty():
        _fail("blocked worker re-acquired the obstructed voxel")
        return

    var selection := asteroid.claim_mining_cell(
        clear_worker, clear_muzzle, clear_check
    )
    if selection.is_empty() or selection.get("cell") != last_cell:
        _fail("last voxel not assigned after blocked reservation released")
        return
    if asteroid.mining_assignment_count() != 1:
        _fail("queue does not contain precisely the eligible miner")
        return

    var prepared := asteroid.prepare_detach_cell(last_cell)
    if prepared.is_empty():
        _fail("cannot prepare final voxel for mining")
        return
    var detached := asteroid.commit_prepared_detach(prepared)
    if detached.is_empty() or asteroid.has_cells() or asteroid.mining_assignment_count() != 0:
        _fail("final voxel did not detach completely")
        return

    print("LAST_CELL_SMOKE_PASS blocked reservation released; final voxel detached")
    simulation.free()
    ship_root.free()
    asteroid.free()
    quit()
