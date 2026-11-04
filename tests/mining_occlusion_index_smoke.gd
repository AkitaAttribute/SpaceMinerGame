extends SceneTree

# Verify indexed voxel traversal exactly matches the previous exhaustive
# ship-hull obstruction test for turning, diagonal, grazing and axial rays.
func _initialize() -> void:
    call_deferred("_run")


func _fail(message: String) -> void:
    push_error("MINING_OCCLUSION_SMOKE: " + message)
    quit(1)


func _run() -> void:
    var simulation_script = load("res://scripts/simulation.gd")
    if not (simulation_script is GDScript):
        _fail("Simulation script not available")
        return
    var simulation: Node3D = (simulation_script as GDScript).new()
    var ship := Node3D.new()
    ship.rotation.y = 0.3
    ship.position = Vector3(4, 2, -6)
    get_root().add_child(ship)
    simulation.set("ship_visual_root", ship)
    simulation.set("model_center", Vector3.ZERO)

    var boxes: Array[Dictionary] = []
    var indexed: Dictionary = {}
    var rng := RandomNumberGenerator.new()
    rng.seed = 20261104
    for i in range(40):
        var cell := Vector3i(
            rng.randi_range(-4, 4),
            rng.randi_range(-4, 4),
            rng.randi_range(-4, 4)
        )
        if indexed.has(cell):
            continue
        var center := Vector3(
            float(cell.x) + 0.5,
            float(cell.z) + 0.5,
            float(cell.y) + 0.5
        )
        var box := AABB(center - Vector3.ONE * 0.5, Vector3.ONE)
        boxes.append({"cell": cell, "aabb": box})
        indexed[cell] = box

    simulation.set("ship_cell_boxes", boxes)
    simulation.set("ship_cell_boxes_by_coord", indexed)

    var rays: Array[Dictionary] = []
    for i in range(1200):
        var start := Vector3(
            rng.randf_range(-7, 7),
            rng.randf_range(-7, 7),
            rng.randf_range(-7, 7)
        )
        var finish := Vector3(
            rng.randf_range(-15, 15),
            rng.randf_range(-15, 15),
            rng.randf_range(-15, 15)
        )
        if i % 6 == 0:
            finish.y = start.y
        if i % 11 == 0:
            finish.x = start.x
        if i % 17 == 0:
            finish = start + Vector3(12, 0, 12)
        var anchor := boxes[i % boxes.size()]["cell"] as Vector3i
        rays.append({"from": start, "to": finish, "anchor": anchor})

    var brute_us := 0
    var indexed_us := 0
    for ray in rays:
        var local_from := ray["from"] as Vector3
        var local_to := ray["to"] as Vector3
        var anchor := ray["anchor"] as Vector3i
        var start_us := Time.get_ticks_usec()
        var expected: bool = simulation.call(
            "_ship_blocks_segment_brute_local",
            local_from, local_to, anchor
        )
        brute_us += Time.get_ticks_usec() - start_us
        start_us = Time.get_ticks_usec()
        var actual: bool = simulation.call(
            "_ship_blocks_segment",
            ship.to_global(local_from), ship.to_global(local_to), anchor
        )
        indexed_us += Time.get_ticks_usec() - start_us
        if expected != actual:
            _fail("ray %d disagreed; from=%s to=%s expected=%s actual=%s"
                % [rays.find(ray), local_from, local_to, expected, actual])
            return

    print("MINING_OCCLUSION_SMOKE_PASS rays=%d brute_ms=%.3f indexed_ms=%.3f"
        % [rays.size(), float(brute_us) / 1000.0, float(indexed_us) / 1000.0])
    ship.free()
    simulation.free()
    quit()
