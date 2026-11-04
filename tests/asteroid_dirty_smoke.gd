extends SceneTree

func _initialize() -> void:
    call_deferred("_run")


func _fail(message: String) -> void:
    push_error("ASTEROID_DIRTY_SMOKE: " + message)
    quit(1)


func _run() -> void:
    var scene_script = load("res://tests/asteroid_dirty_fixture.gd")
    if not (scene_script is GDScript):
        _fail("Fixture scene script unavailable")
        return
    var scene: Node3D = (scene_script as GDScript).new()
    get_root().add_child(scene)
    current_scene = scene

    var asteroid := SpaceAsteroid.new()
    asteroid.sync_to_physics = false
    asteroid.configure("dirty-test", Vector3(0, 0, -40), 106, 3)
    scene.add_child(asteroid)
    var asteroids: Dictionary = {"asteroid": asteroid}
    scene.set("asteroids", asteroids)

    var optimizer := get_root().get_node_or_null("AsteroidEffectSurfaceOptimizer")
    var presenter := get_root().get_node_or_null("AsteroidMetallicPresenter")
    if optimizer == null or presenter == null:
        _fail("Missing asteroid optimization autoloads")
        return

    for _i in range(12):
        await process_frame
    if not bool(optimizer.get("_logged_initial_summary")):
        _fail("Initial single-pass asteroid mesh never finished")
        return

    var dirty := optimizer.get("_dirty_asteroids") as Dictionary
    if not dirty.is_empty():
        _fail("Initial mesh left stale dirty notifications")
        return

    var id := asteroid.get_instance_id()
    var initial_version := int(asteroid.get("_geometry_version"))
    asteroid.set("_geometry_version", initial_version + 1)
    presenter.call("_ensure_asteroid_mesh_current", asteroid)
    dirty = optimizer.get("_dirty_asteroids") as Dictionary
    if not dirty.has(id):
        _fail("Presenter did not mark rebuilt asteroid dirty")
        return

    for _i in range(4):
        await process_frame
    dirty = optimizer.get("_dirty_asteroids") as Dictionary
    if not dirty.is_empty():
        _fail("Dirty asteroid was not consumed by final mesh optimizer")
        return

    var optimized_versions := optimizer.get("_optimized_versions") as Dictionary
    if int(optimized_versions.get(id, -1)) != initial_version + 1:
        _fail("Dirty asteroid geometry revision was not re-optimized")
        return

    print("ASTEROID_DIRTY_SMOKE_PASS initial meshes, dirty signal, reoptimization")
    current_scene = null
    scene.free()
    quit()
