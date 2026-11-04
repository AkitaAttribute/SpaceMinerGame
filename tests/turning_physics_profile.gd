extends SceneTree

# Headless isolation test for ship collision-shape writes and mining Area3D
# updates while turning. Runs on a separate diagnostics branch only.
const SHIP_PARTS := 60
const ASTEROIDS := 420
const SAMPLE_TICKS := 180
const WARMUP_TICKS := 60

func _initialize() -> void:
    call_deferred("_run")


func _run() -> void:
    var ship := CharacterBody3D.new()
    ship.motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
    get_root().add_child(ship)

    var visual_root := Node3D.new()
    ship.add_child(visual_root)
    var sources: Array[Node3D] = []
    var collisions: Array[CollisionShape3D] = []
    var box := BoxMesh.new()
    box.size = Vector3.ONE
    for index in range(SHIP_PARTS):
        var source := Node3D.new()
        source.position = Vector3(
            float(index % 10) - 4.5,
            float(int(index / 10) % 3) - 1.0,
            float(int(index / 30) % 2) - 0.5
        )
        visual_root.add_child(source)
        sources.append(source)
        var collider := CollisionShape3D.new()
        collider.shape = box.create_convex_shape(true, false)
        ship.add_child(collider)
        collisions.append(collider)

    var proximity := Area3D.new()
    proximity.collision_layer = 0
    proximity.collision_mask = 1
    proximity.monitoring = true
    proximity.monitorable = false
    var sphere_shape := CollisionShape3D.new()
    var sphere := SphereShape3D.new()
    sphere.radius = 55.0
    sphere_shape.shape = sphere
    proximity.add_child(sphere_shape)
    ship.add_child(proximity)

    var bodies: Array[AnimatableBody3D] = []
    for index in range(ASTEROIDS):
        var angle := TAU * float(index) / float(ASTEROIDS)
        var body := AnimatableBody3D.new()
        body.name = "Asteroid_%d" % index
        body.position = Vector3(
            cos(angle) * 2400.0,
            0,
            sin(angle) * 2400.0 - 2400.0
        )
        var shape := CollisionShape3D.new()
        var block := BoxShape3D.new()
        block.size = Vector3.ONE * 8.0
        shape.shape = block
        body.add_child(shape)
        get_root().add_child(body)
        if body.global_position.length() > 280.0:
            shape.disabled = true
        bodies.append(body)

    await _scenario(
        "idle_full_sync_area", ship, visual_root,
        sources, collisions, proximity, false, true, true
    )
    await _scenario(
        "turn_full_sync_area", ship, visual_root,
        sources, collisions, proximity, true, true, true
    )
    await _scenario(
        "turn_skip_same_area", ship, visual_root,
        sources, collisions, proximity, true, false, true
    )
    await _scenario(
        "turn_skip_same_no_area", ship, visual_root,
        sources, collisions, proximity, true, false, false
    )
    await _scenario(
        "turn_full_sync_no_area", ship, visual_root,
        sources, collisions, proximity, true, true, false
    )
    for body in bodies:
        body.queue_free()
    ship.queue_free()
    print("TURN_PROFILE_COMPLETE")
    quit(0)


func _scenario(
    name: String, ship: CharacterBody3D, visual_root: Node3D,
    sources: Array[Node3D], colliders: Array[CollisionShape3D],
    proximity: Area3D, turn: bool, always_write: bool,
    area_enabled: bool
) -> void:
    proximity.monitoring = area_enabled
    var sync_us := 0
    var engine_ms := 0.0
    var process_ms := 0.0
    var assignments := 0
    var elapsed := 0
    for tick in range(WARMUP_TICKS + SAMPLE_TICKS):
        if turn:
            ship.rotation.y += 0.025
            visual_root.rotation.z = 0.08 * sin(float(tick) * 0.03)
        else:
            visual_root.rotation.z = 0.0
        var start := Time.get_ticks_usec()
        var applied := _sync_shapes(
            ship, sources, colliders, always_write
        )
        ship.velocity = Vector3.ZERO
        ship.move_and_slide()
        applied += _sync_shapes(ship, sources, colliders, always_write)
        var spent := Time.get_ticks_usec() - start
        await physics_frame
        if tick >= WARMUP_TICKS:
            sync_us += spent
            assignments += applied
            engine_ms += (
                Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
                * 1000.0
            )
            process_ms += (
                Performance.get_monitor(Performance.TIME_PROCESS)
                * 1000.0
            )
            elapsed += 1
    print(
        "TURN_PROFILE scenario=%s sync_avg_ms=%.4f physics_avg_ms=%.4f "
        % [
            name,
            float(sync_us) / maxi(1, elapsed) / 1000.0,
            engine_ms / maxi(1, elapsed),
        ]
        + "process_avg_ms=%.4f shape_writes_per_tick=%.2f"
        % [
            process_ms / maxi(1, elapsed),
            float(assignments) / maxi(1, elapsed),
        ]
    )


func _sync_shapes(
    body: CharacterBody3D,
    sources: Array[Node3D],
    colliders: Array[CollisionShape3D],
    always_write: bool
) -> int:
    var body_inverse := body.global_transform.affine_inverse()
    var writes := 0
    for index in range(colliders.size()):
        var relative := body_inverse * sources[index].global_transform
        if not always_write and colliders[index].transform.is_equal_approx(relative):
            continue
        colliders[index].transform = relative
        writes += 1
    return writes
