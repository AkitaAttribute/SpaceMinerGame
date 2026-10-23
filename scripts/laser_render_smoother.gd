extends Node

# Render-only mining-laser presentation.
#
# Simulation remains authoritative for targeting, turret tracking, obstruction,
# mining timers, reservations, tractor chunks, beam visibility, and the 60 Hz
# physics-state beam. This node only rebuilds the visible MultiMesh transforms
# from interpolated scene transforms once per rendered frame so a 165 Hz display
# does not hold 60 Hz beam geometry for ~64% of frames.

const LASER_BARREL_LENGTH := 0.42
const LASER_MINING_SECONDS := 5.0
const LASER_SURFACE_TRANSITION_SECONDS := 1.50
const PARTICLES_PER_UNIT := 6.5
const MIN_PARTICLES := 6
const MAX_PARTICLES := 80
const WIGGLE_AMPLITUDE := 0.035
const WIGGLE_SPEED := 8.0

var _render_time := 0.0
var _scene_id := 0
var _logged_scene := false


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    # Simulation's ordinary scene _process work runs first. The existing
    # LaserPresenter diagnostic probe runs at 900000, so presenting at 800000
    # lets that probe measure the final render-rate beam rather than the stale
    # physics-rate transforms.
    process_priority = 800_000

    if OS.has_feature("headless"):
        set_process(false)
        return

    AppLogger.event(
        "LASER_RENDER_SMOOTHER enabled; visible beam geometry rebuilt at render rate from interpolated endpoints"
    )


func _process(delta: float) -> void:
    _render_time += delta

    var scene := get_tree().current_scene
    if scene == null:
        _scene_id = 0
        _logged_scene = false
        return

    var current_scene_id := scene.get_instance_id()
    if current_scene_id != _scene_id:
        _scene_id = current_scene_id
        _logged_scene = false

    var lasers_value = scene.get("mining_lasers")
    if not (lasers_value is Array):
        return

    var lasers := lasers_value as Array
    if not _logged_scene and not lasers.is_empty():
        _logged_scene = true
        AppLogger.event(
            "LASER_RENDER_SMOOTHER scene=%d lasers=%d"
            % [_scene_id, lasers.size()]
        )

    for laser_value in lasers:
        if not (laser_value is Dictionary):
            continue
        _present_laser(laser_value as Dictionary)


func _present_laser(laser: Dictionary) -> void:
    var beam_value = laser.get("beam", null)
    var pivot_value = laser.get("pivot", null)
    if not (beam_value is MultiMeshInstance3D) or not (pivot_value is Node3D):
        return

    var beam := beam_value as MultiMeshInstance3D
    var pivot := pivot_value as Node3D
    if (
        not is_instance_valid(beam)
        or beam.multimesh == null
        or not is_instance_valid(pivot)
        or not beam.visible
    ):
        return

    var endpoints := _interpolated_endpoints(laser, pivot)
    if not bool(endpoints.get("valid", false)):
        return

    var start := endpoints.get("start", Vector3.ZERO) as Vector3
    var finish := endpoints.get("finish", Vector3.ZERO) as Vector3
    _rebuild_beam(beam, start, finish)


func _interpolated_endpoints(
    laser: Dictionary,
    pivot: Node3D
) -> Dictionary:
    var pivot_transform := pivot.get_global_transform_interpolated()
    var start := (
        pivot_transform.origin
        + pivot_transform.basis.y.normalized() * LASER_BARREL_LENGTH
    )

    var chunk = laser.get("chunk", null)
    if chunk is Node3D and is_instance_valid(chunk):
        return {
            "valid": true,
            "start": start,
            "finish": (chunk as Node3D).get_global_transform_interpolated().origin,
        }

    var target = laser.get("target", null)
    if not (target is Node3D) or not is_instance_valid(target):
        return {"valid": false}

    var target_node := target as Node3D
    var target_transform := target_node.get_global_transform_interpolated()
    var finish := target_transform.origin
    var reserved = laser.get("reserved_cell", null)

    if reserved is Vector3i and target_node.has_method("cell_world_position"):
        # cell_world_position() is authoritative physics space. Convert that
        # point into target-local space, then transform it through the target's
        # interpolated render transform so asteroid motion is smooth too.
        var cell_value = target_node.call("cell_world_position", reserved)
        if cell_value is Vector3:
            var local_cell := (
                target_node.global_transform.affine_inverse()
                * (cell_value as Vector3)
            )
            var interpolated_cell := target_transform * local_cell

            var transition_start := (
                LASER_MINING_SECONDS - LASER_SURFACE_TRANSITION_SECONDS
            )
            var transition := clampf(
                (float(laser.get("fire_time", 0.0)) - transition_start)
                / LASER_SURFACE_TRANSITION_SECONDS,
                0.0,
                1.0
            )
            var smooth_transition := (
                transition * transition * (3.0 - 2.0 * transition)
            )
            finish = target_transform.origin.lerp(
                interpolated_cell,
                smooth_transition
            )

    return {
        "valid": true,
        "start": start,
        "finish": finish,
    }


func _rebuild_beam(
    beam: MultiMeshInstance3D,
    start_world: Vector3,
    finish_world: Vector3
) -> void:
    var distance := start_world.distance_to(finish_world)
    if distance <= 0.000001:
        return

    var count := clampi(
        int(ceil(distance * PARTICLES_PER_UNIT)),
        MIN_PARTICLES,
        MAX_PARTICLES
    )
    beam.multimesh.instance_count = count

    var direction := (finish_world - start_world).normalized()
    var helper := Vector3.UP
    if absf(direction.dot(helper)) > 0.92:
        helper = Vector3.RIGHT
    var side := direction.cross(helper).normalized()
    var up := side.cross(direction).normalized()

    # The MultiMesh stores transforms in the beam node's local space. In the
    # current scene it is effectively world-aligned, but explicitly converting
    # keeps this correct if Effects/beam receives a transform later.
    var beam_world := beam.get_global_transform_interpolated()
    var world_to_beam := beam_world.affine_inverse()

    for index in range(count):
        var t := float(index) / float(maxi(1, count - 1))
        var position_world := start_world.lerp(finish_world, t)

        if index != 0 and index != count - 1:
            var phase := _render_time * WIGGLE_SPEED + float(index) * 1.73
            position_world += side * sin(phase) * WIGGLE_AMPLITUDE
            position_world += up * cos(phase * 1.27) * WIGGLE_AMPLITUDE

        var position_local := world_to_beam * position_world
        beam.multimesh.set_instance_transform(
            index,
            Transform3D(Basis.IDENTITY, position_local)
        )
