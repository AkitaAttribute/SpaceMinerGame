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
    simulation.set("ship_visual_root", ship_root)

    var asteroid := SpaceAsteroid.new()
    asteroid.configure("last-cell-test", Vector3(0.0, 0.0, -20.0), 42, 3)

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
    simulation.set("ship_cell_boxes", [occluder])

    var blocked: Dictionary = simulation.call(
        "_choose_visible_mining_cell", blocked_laser, 1, asteroid
    )
    if not blocked.is_empty():
        _fail("blocked laser improperly selected final voxel")
        return

    var reserved: Dictionary = simulation.call(
        "_choose_visible_mining_cell", clear_laser, 0, asteroid
    )
    if not reserved.is_empty():
        _fail("reserved voxel was acquired twice")
        return

    # The obstructed laser must yield its reservation; the unobstructed
    # laser can then take the only remaining voxel.
    blocked_laser["reserved_cell"] = null
    entries[1] = blocked_laser
    simulation.set("mining_lasers", entries)

    var selection: Dictionary = simulation.call(
        "_choose_visible_mining_cell", clear_laser, 0, asteroid
    )
    if selection.is_empty() or selection.get("cell") != last_cell:
        _fail("last voxel not selectable after obstructed reservation released")
        return

    var prepared := asteroid.prepare_detach_cell(last_cell)
    if prepared.is_empty():
        _fail("cannot prepare final voxel for mining")
        return
    var detached := asteroid.commit_prepared_detach(prepared)
    if detached.is_empty() or asteroid.has_cells():
        _fail("final voxel did not detach completely")
        return

    print("LAST_CELL_SMOKE_PASS blocked reservation released; final voxel detached")
    simulation.free()
    ship_root.free()
    clear_pivot.free()
    blocked_pivot.free()
    asteroid.free()
    quit()
