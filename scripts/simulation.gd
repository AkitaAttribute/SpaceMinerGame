extends Node3D

const LASER_RANGE := 40.0
const LASER_MINING_SECONDS := 5.0
const LASER_TRACK_SPEED := deg_to_rad(68.0)
const LASER_ALIGNMENT_DOT := 0.985
const LASER_BARREL_LENGTH := 0.42
const LASER_PREPARE_SECONDS := 0.40
const LASER_SURFACE_TRANSITION_SECONDS := 1.50

const AUTO_ORBIT_MIN_CLEARANCE := 8.0
const AUTO_ORBIT_TARGET_LASER_DISTANCE := 20.0
const AUTO_ORBIT_RANGE_MARGIN := 7.0
const AUTO_ORBIT_RADIAL_BAND := 10.0
const AUTO_ORBIT_BASE_THROTTLE := 0.72

const MAX_FORWARD_SPEED := 8.0
const MAX_REVERSE_SPEED := 3.0
const ENGINE_ACCELERATION := 4.8
const LONGITUDINAL_DRAG := 0.075
const LATERAL_DRAG := 2.8
const RUDDER_GAIN := 0.032
const YAW_DAMPING := 1.7
const MAX_YAW_RATE := deg_to_rad(58.0)
const COLLISION_RECOVERY_DURATION := 1.35
const COLLISION_RECOVERY_CLEARANCE := 5.0
const COLLISION_RECOVERY_TURN := PI * 0.5

const MAX_HEEL := deg_to_rad(11.0)
const HEEL_SPRING := 9.0
const HEEL_DAMPING := 5.4
const HEEL_STABILITY := 1.35

const ASTEROID_SPAWN_SURFACE_GAP := 24.0
const ASTEROID_LAUNCH_CENTER_CLEARANCE := 56.0
const ASTEROID_MIN_CENTER_SEPARATION := 8.0
const RING_ASTEROID_COUNT := 420
const ASTEROID_MIN_SIZE := 3
const ASTEROID_MAX_SIZE := 9

const PLANET_CENTER := Vector3(0.0, 0.0, -2400.0)
const PLANET_RADIUS := 520.0
const PLANET_TEXTURE_WIDTH := 256
const PLANET_TEXTURE_HEIGHT := 128

const RING_BASE_RADIUS := 2400.0
const RING_RADIAL_HALF_WIDTH := 105.0
const RING_VERTICAL_HALF_THICKNESS := 18.0
const RING_SLOT_JITTER := 0.18
const RING_LINEAR_SPEED := 1.20
const FAR_RING_UPDATE_INTERVAL := 0.20
const MIN_ASTEROID_DETAIL_DISTANCE := 250.0
const ASTEROID_PHYSICS_ACTIVE_DISTANCE := 280.0

const CAMERA_MOUSE_SENSITIVITY := 0.0026
const CAMERA_TOUCH_SENSITIVITY := 0.0042
const CAMERA_MIN_PITCH := deg_to_rad(-8.0)
const CAMERA_MAX_PITCH := deg_to_rad(68.0)
const CAMERA_DEFAULT_PITCH := deg_to_rad(25.0)

const TRACTOR_START_SPEED := 4.0
const TRACTOR_ACCELERATION := 5.5
const TRACTOR_MAX_SPEED := 10.0

const PERF_SAMPLE_WINDOW := 180
const PERF_DISPLAY_INTERVAL := 0.50
const PERF_LOG_INTERVAL := 5.0

var ship_id := ""
var ship_body: CharacterBody3D
var ship_visual_root: Node3D
var ship_collision_shapes: Array[CollisionShape3D] = []
var ship_collision_bindings: Array[Dictionary] = []
var camera: Camera3D
var world_environment: WorldEnvironment

var asteroid_root: Node3D
var effects_root: Node3D
var planet: MeshInstance3D
var asteroids: Dictionary = {}
var mining_lasers: Array[Dictionary] = []
var thruster_particles: Array[GPUParticles3D] = []
var tractor_chunks: Array[Dictionary] = []
var ship_cell_boxes: Array[Dictionary] = []

var model_center := Vector3.ZERO
var model_radius := 2.0
var model_collision_radius := 2.0
var ship_forward_local := Vector3.FORWARD
var launch_position := Vector3.ZERO

var surge_speed := 0.0
var sway_speed := 0.0
var yaw_rate := 0.0
var heel_angle := 0.0
var heel_velocity := 0.0

var collision_recovery_active := false
var collision_recovery_elapsed := 0.0
var collision_recovery_start_yaw := 0.0
var collision_recovery_target_yaw := 0.0
var collision_recovery_normal := Vector3.ZERO
var collision_recovery_target_position := Vector3.ZERO
var collision_recovery_safe_radius := 0.0
var collision_recovery_asteroid: SpaceAsteroid
var collision_recovery_saved_velocity := Vector3.ZERO
var asteroid_update_time := 0.0
var asteroid_spawn_sequence := 0
var asteroid_rng := RandomNumberGenerator.new()
var asteroid_render_update_time := 0.0
var beam_time := 0.0

var camera_position_smooth := Vector3.ZERO
var camera_target_smooth := Vector3.ZERO
var camera_yaw_offset := 0.0
var camera_pitch := CAMERA_DEFAULT_PITCH

var ui_layer: CanvasLayer
var gear_button: Button
var menu_dim: ColorRect
var menu_panel: PanelContainer
var menu_content: VBoxContainer
var menu_open := false

var laser_status_panel: PanelContainer
var laser_status_rows: Array[Dictionary] = []

var auto_orbit_enabled := false
var auto_orbit_target: SpaceAsteroid
var auto_orbit_direction := 1.0
var auto_orbit_panel: PanelContainer
var auto_orbit_off_indicator: PanelContainer
var auto_orbit_on_indicator: PanelContainer

var debug_hitboxes_visible := false
var ship_debug_hitbox: Node3D
var debug_laser_range_visible := false
var laser_range_debug_root: Node3D

var performance_metrics_visible := false
var performance_panel: PanelContainer
var performance_label: Label
var performance_samples: Dictionary = {}
var performance_display_elapsed := 0.0
var performance_log_elapsed := 0.0
var performance_pipeline_baseline: Dictionary = {}
var performance_near_asteroids := 0
var performance_collision_range_asteroids := 0

var mobile_joystick: VirtualJoystick
var mobile_last_turn_sign := 1.0
var desktop_cursor_hold := false


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    SkyCatalog.active_sky_changed.connect(_on_active_sky_changed)

    var request := ShipStore.take_view_request()
    ship_id = str(request.get("ship_id", ""))
    if ship_id.is_empty():
        ShipStore.request_view("selector")
        get_tree().change_scene_to_file("res://main.tscn")
        return

    _build_environment()
    _build_simulation_roots()
    _build_planet()
    _load_ship()
    launch_position = ship_body.global_position
    _build_camera()
    asteroid_rng.randomize()
    _spawn_initial_asteroids()
    _build_ui()

    if not _is_mobile_platform() and "--simulation-smoke" not in OS.get_cmdline_user_args():
        Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

    if "--simulation-smoke" in OS.get_cmdline_user_args():
        var timer := get_tree().create_timer(7.0)
        timer.timeout.connect(get_tree().quit, CONNECT_ONE_SHOT)


func _build_environment() -> void:
    world_environment = WorldEnvironment.new()
    world_environment.name = "WorldEnvironment"

    var environment := Environment.new()
    _apply_active_panorama(environment)

    environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    environment.ambient_light_color = Color("#27344c")
    environment.ambient_light_energy = 0.16
    environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC

    world_environment.environment = environment
    add_child(world_environment)


func _apply_active_panorama(environment: Environment) -> void:
    var panorama_path := SkyCatalog.get_active_panorama_path()

    if panorama_path.is_empty():
        environment.sky = null
        environment.background_mode = Environment.BG_COLOR
        environment.background_color = Color.BLACK
        return

    var image := Image.new()
    if image.load(panorama_path) != OK:
        environment.sky = null
        environment.background_mode = Environment.BG_COLOR
        environment.background_color = Color.BLACK
        push_warning("Unable to load generated panorama: %s" % panorama_path)
        return

    # The baked sky is static. Mipmaps let the panorama sampler average
    # sub-screen texels instead of causing high-frequency star shimmer while
    # the camera rotates.
    if not image.has_mipmaps():
        image.generate_mipmaps()

    var texture := ImageTexture.create_from_image(image)
    var sky_material := PanoramaSkyMaterial.new()
    sky_material.panorama = texture

    var sky := Sky.new()
    sky.sky_material = sky_material

    environment.sky = sky
    environment.background_mode = Environment.BG_SKY


func _on_active_sky_changed(_path: String) -> void:
    if world_environment == null or not is_instance_valid(world_environment):
        return
    if world_environment.environment == null:
        return

    _apply_active_panorama(world_environment.environment)


func _build_planet() -> void:
    planet = MeshInstance3D.new()
    planet.name = "RingPlanet"

    var sphere := SphereMesh.new()
    sphere.radius = PLANET_RADIUS
    sphere.height = PLANET_RADIUS * 2.0
    sphere.radial_segments = 96
    sphere.rings = 48

    var material := StandardMaterial3D.new()
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.roughness = 1.0
    material.cull_mode = BaseMaterial3D.CULL_BACK
    material.albedo_texture = _create_planet_heatmap_texture()
    sphere.material = material

    planet.mesh = sphere
    planet.position = PLANET_CENTER
    planet.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    add_child(planet)


func _create_planet_heatmap_texture() -> ImageTexture:
    var image := Image.create_empty(
        PLANET_TEXTURE_WIDTH,
        PLANET_TEXTURE_HEIGHT,
        false,
        Image.FORMAT_RGBA8
    )

    var deep_water := Color("#102b5b")
    var shallow_water := Color("#2c78aa")
    var low_land := Color("#4c8a57")
    var high_land := Color("#c59a5f")
    var mountain := Color("#75533c")

    for y in range(PLANET_TEXTURE_HEIGHT):
        var v := (
            float(y)
            / float(maxi(1, PLANET_TEXTURE_HEIGHT - 1))
        )
        var latitude := (v - 0.5) * PI
        var cos_lat := cos(latitude)
        var py := sin(latitude)

        for x in range(PLANET_TEXTURE_WIDTH):
            var u := (
                float(x)
                / float(maxi(1, PLANET_TEXTURE_WIDTH - 1))
            )
            var longitude := (u - 0.5) * TAU
            var px := cos_lat * cos(longitude)
            var pz := cos_lat * sin(longitude)

            # Seamless spherical low-frequency bands make continent-sized
            # regions without requiring a second mesh or an imported texture.
            var field := (
                sin(px * 4.2 + py * 1.7) * 0.34
                + sin(pz * 5.1 - py * 2.3) * 0.28
                + sin((px + pz) * 7.3 + py * 3.1) * 0.20
                + sin((px - pz) * 11.0 - py * 1.4) * 0.12
            )
            field -= maxf(0.0, absf(py) - 0.82) * 0.65

            var color := deep_water
            if field < 0.02:
                var water_heat := clampf(
                    inverse_lerp(-0.78, 0.02, field),
                    0.0,
                    1.0
                )
                color = deep_water.lerp(shallow_water, water_heat)
            else:
                var land_heat := clampf(
                    inverse_lerp(0.02, 0.72, field),
                    0.0,
                    1.0
                )
                color = low_land.lerp(high_land, land_heat)
                if land_heat > 0.72:
                    color = color.lerp(
                        mountain,
                        inverse_lerp(0.72, 1.0, land_heat)
                    )

            image.set_pixel(x, y, color)

    image.generate_mipmaps()
    return ImageTexture.create_from_image(image)


func _build_simulation_roots() -> void:
    asteroid_root = Node3D.new()
    asteroid_root.name = "Asteroids"
    add_child(asteroid_root)

    effects_root = Node3D.new()
    effects_root.name = "Effects"
    add_child(effects_root)

    ship_body = CharacterBody3D.new()
    ship_body.name = "Ship"
    ship_body.motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
    ship_body.floor_stop_on_slope = false
    ship_body.safe_margin = 0.05
    add_child(ship_body)

    ship_visual_root = Node3D.new()
    ship_visual_root.name = "ShipVisual"
    ship_body.add_child(ship_visual_root)


func _load_ship() -> void:
    var data := ShipStore.load_model(ship_id)
    var parts_value = data.get("parts", [])
    var part_records: Array[Dictionary] = []

    var bounds_min := Vector3(INF, INF, INF)
    var bounds_max := Vector3(-INF, -INF, -INF)
    var occupied_records: Array[Dictionary] = []
    var thruster_forward_sum := Vector3.ZERO
    var thruster_count := 0

    if parts_value is Array:
        for value in parts_value:
            if not (value is Dictionary):
                continue
            var entry := value as Dictionary
            var part_id := str(entry.get("part_id", ""))
            var part_index := PartFactory.get_part_index_by_id(part_id)
            if part_index < 0 or not PartFactory.is_placeable(part_index):
                continue

            var anchor_data = entry.get("anchor", [])
            if not (anchor_data is Array) or (anchor_data as Array).size() != 3:
                continue

            var anchor := Vector3i(
                int(anchor_data[0]),
                int(anchor_data[1]),
                int(anchor_data[2])
            )
            var basis := _basis_from_json(entry.get("basis", []))
            var colors := _colors_from_entry(entry, part_index)
            var occupied := _occupied_cells_for(part_index, basis, anchor)

            part_records.append({
                "part_id": part_id,
                "part_index": part_index,
                "anchor": anchor,
                "basis": basis,
                "colors": colors,
                "occupied": occupied,
            })

            if part_id == "thruster_t1" or part_id == "thruster_t2":
                # Thruster nozzles exhaust toward local +Z, so propulsion /
                # ship-forward is local -Z (Godot's Vector3.FORWARD).
                thruster_forward_sum += basis * Vector3.FORWARD
                thruster_count += 1

            for cell in occupied:
                var center := _cell_world_center(cell)
                bounds_min.x = minf(bounds_min.x, center.x - 0.5)
                bounds_min.y = minf(bounds_min.y, center.y - 0.5)
                bounds_min.z = minf(bounds_min.z, center.z - 0.5)
                bounds_max.x = maxf(bounds_max.x, center.x + 0.5)
                bounds_max.y = maxf(bounds_max.y, center.y + 0.5)
                bounds_max.z = maxf(bounds_max.z, center.z + 0.5)
                occupied_records.append({
                    "cell": cell,
                    "center": center,
                })

    if part_records.is_empty():
        bounds_min = Vector3(-0.5, -0.5, -0.5)
        bounds_max = Vector3(0.5, 0.5, 0.5)

    model_center = (bounds_min + bounds_max) * 0.5
    var collision_size := bounds_max - bounds_min
    collision_size.x = maxf(collision_size.x, 0.9)
    collision_size.y = maxf(collision_size.y, 0.9)
    collision_size.z = maxf(collision_size.z, 0.9)

    model_radius = maxf(
        1.5,
        maxf(collision_size.x, collision_size.z) * 0.5
    )
    model_collision_radius = maxf(
        1.5,
        Vector2(collision_size.x, collision_size.z).length() * 0.5
    )

    if thruster_count > 0:
        var candidate_forward := thruster_forward_sum / float(thruster_count)
        candidate_forward.y = 0.0
        if candidate_forward.length_squared() > 0.01:
            ship_forward_local = candidate_forward.normalized()
        else:
            ship_forward_local = Vector3.FORWARD
    else:
        ship_forward_local = Vector3.FORWARD

    for record in occupied_records:
        var center := (record["center"] as Vector3) - model_center
        ship_cell_boxes.append({
            "cell": record["cell"],
            "aabb": AABB(center - Vector3.ONE * 0.5, Vector3.ONE),
        })

    for record in part_records:
        _instantiate_ship_part(record)

    if part_records.is_empty():
        var fallback := BoxMesh.new()
        fallback.size = Vector3.ONE
        var material := StandardMaterial3D.new()
        material.albedo_color = Color("#1e88e5")
        material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
        fallback.material = material

        var mesh_instance := MeshInstance3D.new()
        mesh_instance.mesh = fallback
        ship_visual_root.add_child(mesh_instance)

    _build_ship_collision_from_visuals()
    _rebuild_ship_debug_hitbox()


func _instantiate_ship_part(record: Dictionary) -> void:
    var part_index := int(record["part_index"])
    var colors: Array[Color] = []
    for value in record["colors"]:
        colors.append(value as Color)

    var part := PartFactory.create_part(part_index, colors, false)
    var anchor := record["anchor"] as Vector3i
    var basis := record["basis"] as Basis

    part.position = _cell_world_center(anchor) - model_center
    part.basis = basis
    part.set_meta("sim_part_id", str(record["part_id"]))
    ship_visual_root.add_child(part)

    var part_id := str(record["part_id"])
    if part_id == "thruster_t1" or part_id == "thruster_t2":
        var nozzle_offset := 0.04 if part_id == "thruster_t1" else 1.54
        var exhaust := _create_thruster_particles()
        exhaust.position = Vector3(0.0, 0.0, nozzle_offset)
        part.add_child(exhaust)
        thruster_particles.append(exhaust)

    if part_id == "mining_laser":
        var pivot := part.find_child("MiningLaserPivot", true, false) as Node3D
        if pivot != null:
            var beam := _create_beam_particles()
            effects_root.add_child(beam)
            beam.visible = false

            mining_lasers.append({
                "pivot": pivot,
                "anchor_cell": anchor,
                "target": null,
                "chunk": null,
                "fire_time": 0.0,
                "reserved_cell": null,
                "prepared_detach": {},
                "beam": beam,
            })
            _rebuild_laser_range_debug()


func _colors_from_entry(entry: Dictionary, part_index: int) -> Array[Color]:
    var colors: Array[Color] = []
    var color_data = entry.get("colors", [])
    if color_data is Array:
        for value in color_data:
            colors.append(Color.from_string(str(value), Color.WHITE))
    return PartFactory.normalize_colors(part_index, colors)


func _basis_from_json(value) -> Basis:
    if not (value is Array) or (value as Array).size() != 9:
        return Basis.IDENTITY

    return Basis(
        Vector3(float(value[0]), float(value[1]), float(value[2])),
        Vector3(float(value[3]), float(value[4]), float(value[5])),
        Vector3(float(value[6]), float(value[7]), float(value[8]))
    ).orthonormalized()


func _occupied_cells_for(
    part_index: int,
    basis_value: Basis,
    anchor: Vector3i
) -> Array[Vector3i]:
    var result: Array[Vector3i] = []
    for offset in PartFactory.occupied_offsets(part_index):
        var local_world := Vector3(
            float(offset.x),
            float(offset.z),
            float(offset.y)
        )
        var rotated := basis_value * local_world
        result.append(
            anchor + Vector3i(
                int(round(rotated.x)),
                int(round(rotated.z)),
                int(round(rotated.y))
            )
        )
    return result


func _cell_world_center(cell: Vector3i) -> Vector3:
    return Vector3(
        float(cell.x) + 0.5,
        float(cell.z) + 0.5,
        float(cell.y) + 0.5
    )


func _build_ship_collision_from_visuals() -> void:
    for collision_shape in ship_collision_shapes:
        if collision_shape != null and is_instance_valid(collision_shape):
            collision_shape.queue_free()

    ship_collision_shapes.clear()
    ship_collision_bindings.clear()
    _append_ship_collision_meshes(ship_visual_root)
    _sync_ship_collision_transforms()


func _append_ship_collision_meshes(node: Node) -> void:
    if node is MeshInstance3D:
        var source := node as MeshInstance3D
        if source.mesh != null:
            # CharacterBody3D requires convex moving collision. Each rendered
            # piece contributes its own convex hull, so slopes, pyramids,
            # hemispheres, roofs, thrusters and the laser follow their real
            # exterior geometry instead of one ship-sized bounding box.
            var shape := source.mesh.create_convex_shape(true, false)
            if shape != null:
                var collision := CollisionShape3D.new()
                collision.name = "ShipShape_%d" % ship_collision_shapes.size()
                collision.shape = shape
                ship_body.add_child(collision)
                ship_collision_shapes.append(collision)
                ship_collision_bindings.append({
                    "shape": collision,
                    "source": source,
                    "debug": null,
                })

    for child in node.get_children():
        _append_ship_collision_meshes(child)


func _sync_ship_collision_transforms() -> void:
    if ship_body == null or not is_instance_valid(ship_body):
        return

    var body_inverse := ship_body.global_transform.affine_inverse()

    for binding in ship_collision_bindings:
        var collision = binding.get("shape", null)
        var source = binding.get("source", null)
        if (
            collision == null
            or not is_instance_valid(collision)
            or source == null
            or not is_instance_valid(source)
        ):
            continue

        var relative := (
            body_inverse
            * (source as MeshInstance3D).global_transform
        )
        (collision as CollisionShape3D).transform = relative

        var debug_mesh = binding.get("debug", null)
        if debug_mesh != null and is_instance_valid(debug_mesh):
            (debug_mesh as MeshInstance3D).transform = relative


func _build_camera() -> void:
    camera = Camera3D.new()
    camera.name = "ThirdPersonCamera"
    camera.current = true
    camera.fov = 60.0
    # The opposite side of the 2,400-unit ring is almost 4,900 units from
    # the ship. Keep the entire planetary ring inside the camera frustum.
    camera.far = 7000.0
    add_child(camera)

    var forward := _ship_forward_world()
    var distance := maxf(28.0, model_radius * 4.2 + 18.0)
    camera_target_smooth = ship_body.global_position + forward * 2.2
    camera_position_smooth = _camera_orbit_position(
        camera_target_smooth,
        forward,
        distance
    )
    camera.global_position = camera_position_smooth
    camera.look_at(camera_target_smooth, Vector3.UP)


func _build_ui() -> void:
    ui_layer = CanvasLayer.new()
    ui_layer.layer = 20
    add_child(ui_layer)

    var root := Control.new()
    root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    root.theme = SpaceMinerTheme.build(AppSettings.is_dark_theme())
    ui_layer.add_child(root)

    if _is_mobile_platform():
        mobile_joystick = VirtualJoystick.new()
        mobile_joystick.name = "FlightJoystick"
        mobile_joystick.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
        mobile_joystick.offset_left = -242.0
        mobile_joystick.offset_top = -242.0
        mobile_joystick.offset_right = -22.0
        mobile_joystick.offset_bottom = -22.0
        mobile_joystick.joystick_size = 164.0
        mobile_joystick.tip_size = 62.0
        mobile_joystick.deadzone_ratio = 0.10
        mobile_joystick.joystick_mode = VirtualJoystick.JOYSTICK_FIXED
        mobile_joystick.visibility_mode = VirtualJoystick.VISIBILITY_ALWAYS
        mobile_joystick.action_up = &"builder_up"
        mobile_joystick.action_down = &"builder_down"
        mobile_joystick.action_left = &"builder_left"
        mobile_joystick.action_right = &"builder_right"

        var joystick_style := StyleBoxFlat.new()
        joystick_style.bg_color = Color(0.72, 0.78, 0.90, 0.11)
        joystick_style.border_color = Color(0.84, 0.89, 1.0, 0.28)
        joystick_style.set_border_width_all(2)
        joystick_style.set_corner_radius_all(999)

        var joystick_pressed := joystick_style.duplicate() as StyleBoxFlat
        joystick_pressed.bg_color = Color(0.72, 0.78, 0.90, 0.16)

        var tip_style := StyleBoxFlat.new()
        tip_style.bg_color = Color(0.84, 0.89, 1.0, 0.24)
        tip_style.border_color = Color(0.90, 0.94, 1.0, 0.40)
        tip_style.set_border_width_all(2)
        tip_style.set_corner_radius_all(999)

        var tip_pressed := tip_style.duplicate() as StyleBoxFlat
        tip_pressed.bg_color = Color(0.84, 0.89, 1.0, 0.32)

        mobile_joystick.add_theme_stylebox_override("normal_joystick", joystick_style)
        mobile_joystick.add_theme_stylebox_override("pressed_joystick", joystick_pressed)
        mobile_joystick.add_theme_stylebox_override("normal_tip", tip_style)
        mobile_joystick.add_theme_stylebox_override("pressed_tip", tip_pressed)
        root.add_child(mobile_joystick)

    gear_button = Button.new()
    gear_button.text = "⚙"
    gear_button.set_anchors_preset(Control.PRESET_TOP_RIGHT)
    gear_button.position = Vector2(-82.0, 18.0)
    gear_button.size = Vector2(58.0, 52.0)
    gear_button.add_theme_font_size_override("font_size", 28)
    gear_button.modulate.a = 0.76
    gear_button.pressed.connect(_open_menu)
    root.add_child(gear_button)

    _build_auto_orbit_toggle(root)
    _build_mining_laser_status_panel(root)
    _build_performance_panel(root)

    menu_dim = ColorRect.new()
    menu_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    menu_dim.color = SpaceMinerTheme.palette(AppSettings.is_dark_theme())["overlay"]
    menu_dim.mouse_filter = Control.MOUSE_FILTER_STOP
    menu_dim.visible = false
    root.add_child(menu_dim)

    menu_panel = PanelContainer.new()
    menu_panel.set_anchors_preset(Control.PRESET_CENTER)
    menu_panel.position = Vector2(-240.0, -300.0)
    menu_panel.size = Vector2(480.0, 600.0)
    menu_panel.visible = false
    root.add_child(menu_panel)

    var margin := MarginContainer.new()
    margin.add_theme_constant_override("margin_left", 22)
    margin.add_theme_constant_override("margin_right", 22)
    margin.add_theme_constant_override("margin_top", 18)
    margin.add_theme_constant_override("margin_bottom", 22)
    menu_panel.add_child(margin)

    menu_content = VBoxContainer.new()
    menu_content.add_theme_constant_override("separation", 12)
    margin.add_child(menu_content)


func _build_performance_panel(root: Control) -> void:
    performance_panel = PanelContainer.new()
    performance_panel.name = "PerformanceMetrics"
    performance_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
    performance_panel.offset_left = 16.0
    performance_panel.offset_top = 16.0
    performance_panel.offset_right = 536.0
    performance_panel.offset_bottom = 390.0
    performance_panel.visible = false
    performance_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

    var panel_style := StyleBoxFlat.new()
    panel_style.bg_color = Color(0.015, 0.022, 0.038, 0.92)
    panel_style.border_color = Color(0.60, 0.70, 0.85, 0.36)
    panel_style.set_border_width_all(1)
    panel_style.set_corner_radius_all(10)
    performance_panel.add_theme_stylebox_override("panel", panel_style)
    root.add_child(performance_panel)

    var margin := MarginContainer.new()
    margin.add_theme_constant_override("margin_left", 12)
    margin.add_theme_constant_override("margin_right", 12)
    margin.add_theme_constant_override("margin_top", 10)
    margin.add_theme_constant_override("margin_bottom", 10)
    performance_panel.add_child(margin)

    performance_label = Label.new()
    performance_label.text = "Performance metrics initializing..."
    performance_label.add_theme_font_size_override("font_size", 13)
    performance_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    margin.add_child(performance_label)


func _build_auto_orbit_toggle(root: Control) -> void:
    auto_orbit_panel = PanelContainer.new()
    auto_orbit_panel.name = "AutoOrbitToggle"
    auto_orbit_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
    auto_orbit_panel.offset_left = -188.0
    auto_orbit_panel.offset_top = 78.0
    auto_orbit_panel.offset_right = -24.0
    auto_orbit_panel.offset_bottom = 114.0

    var panel_style := StyleBoxFlat.new()
    panel_style.bg_color = Color(0.025, 0.04, 0.075, 0.88)
    panel_style.border_color = Color(0.65, 0.72, 0.84, 0.30)
    panel_style.set_border_width_all(1)
    panel_style.set_corner_radius_all(12)
    auto_orbit_panel.add_theme_stylebox_override("panel", panel_style)
    root.add_child(auto_orbit_panel)

    var margin := MarginContainer.new()
    margin.add_theme_constant_override("margin_left", 9)
    margin.add_theme_constant_override("margin_right", 9)
    margin.add_theme_constant_override("margin_top", 7)
    margin.add_theme_constant_override("margin_bottom", 7)
    auto_orbit_panel.add_child(margin)

    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", 8)
    margin.add_child(row)

    auto_orbit_off_indicator = PanelContainer.new()
    auto_orbit_off_indicator.custom_minimum_size = Vector2(18.0, 18.0)
    row.add_child(auto_orbit_off_indicator)

    var label := Label.new()
    label.text = "Auto Pilot"
    label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    label.add_theme_font_size_override("font_size", 14)
    label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    row.add_child(label)

    auto_orbit_on_indicator = PanelContainer.new()
    auto_orbit_on_indicator.custom_minimum_size = Vector2(18.0, 18.0)
    row.add_child(auto_orbit_on_indicator)

    var click := Button.new()
    click.name = "AutoOrbitButton"
    click.flat = true
    click.text = ""
    click.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    click.pressed.connect(_toggle_auto_orbit)
    auto_orbit_panel.add_child(click)

    _refresh_auto_orbit_toggle()


func _auto_orbit_indicator_style(color: Color) -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = color
    style.border_color = Color(1.0, 1.0, 1.0, 0.16)
    style.set_border_width_all(1)
    style.set_corner_radius_all(6)
    return style


func _refresh_auto_orbit_toggle() -> void:
    if auto_orbit_off_indicator == null or auto_orbit_on_indicator == null:
        return

    var inactive := Color(0.34, 0.37, 0.43, 0.92)
    var off_color := (
        inactive
        if auto_orbit_enabled
        else Color(0.86, 0.22, 0.22, 1.0)
    )
    var on_color := (
        Color(0.20, 0.82, 0.36, 1.0)
        if auto_orbit_enabled
        else inactive
    )

    auto_orbit_off_indicator.add_theme_stylebox_override(
        "panel",
        _auto_orbit_indicator_style(off_color)
    )
    auto_orbit_on_indicator.add_theme_stylebox_override(
        "panel",
        _auto_orbit_indicator_style(on_color)
    )


func _toggle_auto_orbit() -> void:
    auto_orbit_enabled = not auto_orbit_enabled

    if auto_orbit_enabled:
        _acquire_auto_orbit_target()
    else:
        auto_orbit_target = null
        yaw_rate = 0.0

    _refresh_auto_orbit_toggle()


func _build_mining_laser_status_panel(root: Control) -> void:
    laser_status_rows.clear()

    if mining_lasers.is_empty():
        return

    laser_status_panel = PanelContainer.new()
    laser_status_panel.name = "MiningLaserStatus"
    laser_status_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
    laser_status_panel.offset_left = 14.0
    laser_status_panel.offset_right = 154.0
    laser_status_panel.offset_bottom = -14.0
    laser_status_panel.offset_top = (
        -14.0
        - 12.0
        - float(mining_lasers.size()) * 20.0
    )
    laser_status_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

    var panel_style := StyleBoxFlat.new()
    panel_style.bg_color = Color(0.025, 0.04, 0.075, 0.84)
    panel_style.border_color = Color(0.65, 0.72, 0.84, 0.32)
    panel_style.set_border_width_all(1)
    panel_style.set_corner_radius_all(10)
    laser_status_panel.add_theme_stylebox_override("panel", panel_style)
    root.add_child(laser_status_panel)

    var margin := MarginContainer.new()
    margin.add_theme_constant_override("margin_left", 7)
    margin.add_theme_constant_override("margin_right", 7)
    margin.add_theme_constant_override("margin_top", 5)
    margin.add_theme_constant_override("margin_bottom", 5)
    laser_status_panel.add_child(margin)

    var rows := VBoxContainer.new()
    rows.add_theme_constant_override("separation", 2)
    margin.add_child(rows)

    for laser_index in range(mining_lasers.size()):
        var row := HBoxContainer.new()
        row.custom_minimum_size = Vector2(122.0, 18.0)
        row.add_theme_constant_override("separation", 6)
        rows.add_child(row)

        var dot := PanelContainer.new()
        dot.custom_minimum_size = Vector2(10.0, 10.0)
        dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
        dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
        row.add_child(dot)

        var message := Label.new()
        message.custom_minimum_size = Vector2(102.0, 18.0)
        message.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
        message.add_theme_font_size_override("font_size", 13)
        message.text = "Out of Range"
        row.add_child(message)

        laser_status_rows.append({
            "dot": dot,
            "message": message,
            "state": "",
        })
        _set_laser_status(laser_index, false, "Out of Range")


func _laser_status_dot_style(is_ok: bool) -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = (
        Color(0.28, 0.92, 0.42, 1.0)
        if is_ok
        else Color(0.95, 0.24, 0.24, 1.0)
    )
    style.set_corner_radius_all(999)
    return style


func _set_laser_status(
    laser_index: int,
    is_ok: bool,
    message_text: String
) -> void:
    if laser_index < 0 or laser_index >= laser_status_rows.size():
        return

    var row := laser_status_rows[laser_index]
    var state_key := ("ok" if is_ok else "error") + ":" + message_text
    if str(row.get("state", "")) == state_key:
        return

    var dot := row.get("dot", null) as PanelContainer
    var message := row.get("message", null) as Label
    if dot == null or message == null:
        return

    dot.add_theme_stylebox_override(
        "panel",
        _laser_status_dot_style(is_ok)
    )
    message.text = "" if is_ok else message_text
    row["state"] = state_key
    laser_status_rows[laser_index] = row


func _is_mobile_platform() -> bool:
    return (
        OS.has_feature("android")
        or OS.has_feature("ios")
        or OS.has_feature("mobile")
    )


func _input(event: InputEvent) -> void:
    if SkyCatalog.is_generating():
        return

    if _is_mobile_platform():
        return

    if event is InputEventKey:
        var key_event := event as InputEventKey
        if key_event.keycode == KEY_TAB:
            desktop_cursor_hold = key_event.pressed

            if desktop_cursor_hold:
                # Holding Tab temporarily turns the mouse back into a UI
                # cursor. Camera orbit is suppressed until Tab is released.
                Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
            elif not menu_open:
                Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

            get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
    if SkyCatalog.is_generating():
        return

    if event.is_action_pressed(&"menu_back"):
        if menu_open:
            _close_menu()
        else:
            _open_menu()
        get_viewport().set_input_as_handled()
        return

    if menu_open:
        return

    if (
        not _is_mobile_platform()
        and not desktop_cursor_hold
        and event is InputEventMouseMotion
    ):
        var mouse_motion := event as InputEventMouseMotion
        _orbit_camera_from_delta(
            mouse_motion.relative,
            CAMERA_MOUSE_SENSITIVITY
        )
        get_viewport().set_input_as_handled()
        return

    if _is_mobile_platform() and event is InputEventScreenDrag:
        var touch_drag := event as InputEventScreenDrag
        _orbit_camera_from_delta(
            touch_drag.relative,
            CAMERA_TOUCH_SENSITIVITY
        )
        get_viewport().set_input_as_handled()


func _orbit_camera_from_delta(delta_pixels: Vector2, sensitivity: float) -> void:
    var horizontal_sign := 1.0 if AppSettings.invert_camera_horizontal else -1.0
    var vertical_sign := 1.0 if AppSettings.invert_camera_vertical else -1.0

    camera_yaw_offset += (
        delta_pixels.x
        * sensitivity
        * horizontal_sign
    )
    camera_pitch = clampf(
        camera_pitch
        + delta_pixels.y * sensitivity * vertical_sign,
        CAMERA_MIN_PITCH,
        CAMERA_MAX_PITCH
    )


func _open_menu() -> void:
    menu_open = true
    if not _is_mobile_platform():
        Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
    menu_dim.visible = true
    menu_panel.visible = true
    gear_button.visible = false

    for child in menu_content.get_children():
        child.queue_free()

    var title := Label.new()
    title.text = "FLIGHT TEST"
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    title.add_theme_font_size_override("font_size", 26)
    menu_content.add_child(title)

    for spec in [
        ["Resume", "resume"],
        ["Controls", "controls"],
        ["Debug", "debug"],
        ["Return to Builder", "builder"],
        ["Exit to Ship Selector", "selector"],
    ]:
        var button := Button.new()
        button.text = spec[0]
        button.custom_minimum_size = Vector2(0.0, 56.0)
        button.pressed.connect(_flight_menu_action.bind(spec[1]))
        menu_content.add_child(button)


func _show_flight_controls_menu() -> void:
    for child in menu_content.get_children():
        child.queue_free()

    var header := HBoxContainer.new()
    header.add_theme_constant_override("separation", 10)
    menu_content.add_child(header)

    var back := Button.new()
    back.text = "← Back"
    back.pressed.connect(_open_menu)
    header.add_child(back)

    var title := Label.new()
    title.text = "Controls"
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    title.add_theme_font_size_override("font_size", 26)
    header.add_child(title)

    var invert_horizontal := CheckButton.new()
    invert_horizontal.text = "Invert horizontal camera movement"
    invert_horizontal.button_pressed = AppSettings.invert_camera_horizontal
    invert_horizontal.toggled.connect(func(value: bool):
        AppSettings.set_invert_camera_horizontal(value)
    )
    menu_content.add_child(invert_horizontal)

    var invert_vertical := CheckButton.new()
    invert_vertical.text = "Invert vertical camera movement"
    invert_vertical.button_pressed = AppSettings.invert_camera_vertical
    invert_vertical.toggled.connect(func(value: bool):
        AppSettings.set_invert_camera_vertical(value)
    )
    menu_content.add_child(invert_vertical)


func _show_flight_debug_menu() -> void:
    for child in menu_content.get_children():
        child.queue_free()

    var header := HBoxContainer.new()
    header.add_theme_constant_override("separation", 10)
    menu_content.add_child(header)

    var back := Button.new()
    back.text = "← Back"
    back.pressed.connect(_open_menu)
    header.add_child(back)

    var title := Label.new()
    title.text = "Debug"
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    title.add_theme_font_size_override("font_size", 26)
    header.add_child(title)

    var hitboxes := CheckButton.new()
    hitboxes.text = "Show hitbox outlines"
    hitboxes.button_pressed = debug_hitboxes_visible
    hitboxes.toggled.connect(_set_debug_hitboxes_visible)
    menu_content.add_child(hitboxes)

    var laser_range := CheckButton.new()
    laser_range.text = "Show mining laser range"
    laser_range.button_pressed = debug_laser_range_visible
    laser_range.toggled.connect(_set_debug_laser_range_visible)
    menu_content.add_child(laser_range)

    var performance_metrics := CheckButton.new()
    performance_metrics.text = "Show performance metrics"
    performance_metrics.button_pressed = performance_metrics_visible
    performance_metrics.toggled.connect(_set_performance_metrics_visible)
    menu_content.add_child(performance_metrics)

    var checkpoint := SkyCatalog.get_checkpoint_summary()
    var generation := Button.new()
    generation.text = (
        "Resume Skybox Generation"
        if not checkpoint.is_empty()
        else "Generate Skybox"
    )
    generation.custom_minimum_size = Vector2(0.0, 56.0)
    generation.pressed.connect(
        _open_sky_generation_dialog.bind(not checkpoint.is_empty())
    )
    menu_content.add_child(generation)

    if not checkpoint.is_empty():
        var checkpoint_label := Label.new()
        checkpoint_label.text = (
            "Interrupted generation: %s (%d%%)"
            % [
                str(checkpoint.get("name", "Sky")),
                int(round(float(checkpoint.get("progress", 0.0)) * 100.0)),
            ]
        )
        checkpoint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        checkpoint_label.modulate.a = 0.76
        menu_content.add_child(checkpoint_label)

        var discard := Button.new()
        discard.text = "Discard Interrupted Generation"
        discard.custom_minimum_size = Vector2(0.0, 48.0)
        discard.pressed.connect(_discard_sky_generation_checkpoint)
        menu_content.add_child(discard)

    var sky_label := Label.new()
    sky_label.text = "Active sky"
    sky_label.modulate.a = 0.82
    menu_content.add_child(sky_label)

    var sky_selector := OptionButton.new()
    sky_selector.custom_minimum_size = Vector2(0.0, 48.0)
    sky_selector.add_item("Black Background")
    sky_selector.set_item_metadata(0, "")

    var active_id := SkyCatalog.get_active_sky_id()
    var selected_index := 0
    for sky in SkyCatalog.list_skies():
        var item_index := sky_selector.item_count
        var sky_id := str(sky.get("id", ""))
        sky_selector.add_item(str(sky.get("name", "Generated Sky")))
        sky_selector.set_item_metadata(item_index, sky_id)
        if sky_id == active_id:
            selected_index = item_index

    sky_selector.select(selected_index)
    sky_selector.item_selected.connect(func(index: int):
        SkyCatalog.set_active_sky(
            str(sky_selector.get_item_metadata(index))
        )
    )
    menu_content.add_child(sky_selector)

    var note := Label.new()
    note.text = "Hitboxes show exact physics collision shapes. Laser range shows the 40-cell activation boundary measured from each laser's 1x1x1 builder cell. Sky generation pauses flight, checkpoints source/bake state, and produces a static panorama PNG."
    note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    note.modulate.a = 0.76
    menu_content.add_child(note)




func _open_sky_generation_dialog(resume_existing: bool) -> void:
    var dialog := SkyGenerationDialog.new()
    add_child(dialog)

    if resume_existing:
        dialog.start_resume()
    else:
        dialog.start_new()


func _discard_sky_generation_checkpoint() -> void:
    SkyCatalog.discard_checkpoint()
    _show_flight_debug_menu()


func _close_menu() -> void:
    menu_open = false
    menu_dim.visible = false
    menu_panel.visible = false
    gear_button.visible = true
    if not _is_mobile_platform() and not desktop_cursor_hold:
        Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _flight_menu_action(action: String) -> void:
    match action:
        "resume":
            _close_menu()
        "controls":
            _show_flight_controls_menu()
        "debug":
            _show_flight_debug_menu()
        "builder":
            if not _is_mobile_platform():
                Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
            ShipStore.request_view("builder", ship_id)
            get_tree().change_scene_to_file("res://main.tscn")
        "selector":
            if not _is_mobile_platform():
                Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
            ShipStore.request_view("selector")
            get_tree().change_scene_to_file("res://main.tscn")


func _set_performance_metrics_visible(value: bool) -> void:
    performance_metrics_visible = value

    if performance_panel != null:
        performance_panel.visible = value

    if value:
        performance_samples.clear()
        performance_display_elapsed = 0.0
        performance_log_elapsed = 0.0
        performance_pipeline_baseline = {
            "mesh": int(Performance.get_monitor(
                Performance.PIPELINE_COMPILATIONS_MESH
            )),
            "surface": int(Performance.get_monitor(
                Performance.PIPELINE_COMPILATIONS_SURFACE
            )),
            "draw": int(Performance.get_monitor(
                Performance.PIPELINE_COMPILATIONS_DRAW
            )),
        }
        _update_performance_metrics_display()
        AppLogger.event(
            "PERF enabled. Rolling window=%d frames." % PERF_SAMPLE_WINDOW
        )
    else:
        AppLogger.event("PERF disabled.")


func _performance_record_elapsed(key: String, start_usec: int) -> void:
    var elapsed_ms := float(
        Time.get_ticks_usec() - start_usec
    ) / 1000.0
    _performance_record(key, elapsed_ms)


func _performance_record(key: String, value_ms: float) -> void:
    var samples := performance_samples.get(key, []) as Array
    samples.append(value_ms)

    if samples.size() > PERF_SAMPLE_WINDOW:
        samples.remove_at(0)

    performance_samples[key] = samples


func _performance_stats(key: String) -> Vector3:
    var samples := performance_samples.get(key, []) as Array
    if samples.is_empty():
        return Vector3.ZERO

    var total := 0.0
    var maximum := 0.0
    var sorted := samples.duplicate()

    for value in samples:
        var sample := float(value)
        total += sample
        maximum = maxf(maximum, sample)

    sorted.sort()
    var percentile_index := clampi(
        int(ceil(float(sorted.size()) * 0.95)) - 1,
        0,
        sorted.size() - 1
    )
    var p95 := float(sorted[percentile_index])

    return Vector3(
        total / float(samples.size()),
        p95,
        maximum
    )


func _performance_format_stats(label: String, key: String) -> String:
    var stats := _performance_stats(key)
    return "%-14s %6.2f / %6.2f / %6.2f ms" % [
        label,
        stats.x,
        stats.y,
        stats.z,
    ]


func _performance_monitor_ms(monitor: Performance.Monitor) -> float:
    return Performance.get_monitor(monitor) * 1000.0


func _performance_mb(bytes_value: float) -> float:
    return bytes_value / (1024.0 * 1024.0)


func _performance_snapshot_text() -> String:
    var frame := _performance_stats("frame")
    var fps := Performance.get_monitor(Performance.TIME_FPS)
    var engine_process_ms := _performance_monitor_ms(
        Performance.TIME_PROCESS
    )
    var engine_physics_ms := _performance_monitor_ms(
        Performance.TIME_PHYSICS_PROCESS
    )

    var render_objects := int(Performance.get_monitor(
        Performance.RENDER_TOTAL_OBJECTS_IN_FRAME
    ))
    var render_primitives := int(Performance.get_monitor(
        Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME
    ))
    var draw_calls := int(Performance.get_monitor(
        Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME
    ))

    var texture_mb := _performance_mb(Performance.get_monitor(
        Performance.RENDER_TEXTURE_MEM_USED
    ))
    var buffer_mb := _performance_mb(Performance.get_monitor(
        Performance.RENDER_BUFFER_MEM_USED
    ))
    var video_mb := _performance_mb(Performance.get_monitor(
        Performance.RENDER_VIDEO_MEM_USED
    ))

    var physics_active := int(Performance.get_monitor(
        Performance.PHYSICS_3D_ACTIVE_OBJECTS
    ))
    var physics_pairs := int(Performance.get_monitor(
        Performance.PHYSICS_3D_COLLISION_PAIRS
    ))
    var nodes := int(Performance.get_monitor(
        Performance.OBJECT_NODE_COUNT
    ))

    var mesh_compiles := int(Performance.get_monitor(
        Performance.PIPELINE_COMPILATIONS_MESH
    )) - int(performance_pipeline_baseline.get("mesh", 0))
    var surface_compiles := int(Performance.get_monitor(
        Performance.PIPELINE_COMPILATIONS_SURFACE
    )) - int(performance_pipeline_baseline.get("surface", 0))
    var draw_compiles := int(Performance.get_monitor(
        Performance.PIPELINE_COMPILATIONS_DRAW
    )) - int(performance_pipeline_baseline.get("draw", 0))

    var lines: Array[String] = [
        "PERFORMANCE  avg / p95 / max",
        "FPS %5.1f   frame %6.2f / %6.2f / %6.2f ms" % [
            fps,
            frame.x,
            frame.y,
            frame.z,
        ],
        "Engine process %6.2f ms   physics %6.2f ms" % [
            engine_process_ms,
            engine_physics_ms,
        ],
        _performance_format_stats("Script physics", "script_physics_total"),
        _performance_format_stats("Collision sync", "collision_sync"),
        _performance_format_stats("Ship motion", "ship_motion"),
        _performance_format_stats("Asteroids", "asteroids"),
        _performance_format_stats("Tractor", "tractor"),
        _performance_format_stats("Mining lasers", "mining_lasers"),
        _performance_format_stats("Camera", "camera"),
        "",
        "Render objects %d   draws %d   primitives %d" % [
            render_objects,
            draw_calls,
            render_primitives,
        ],
        "VRAM %.1f MB   textures %.1f   buffers %.1f" % [
            video_mb,
            texture_mb,
            buffer_mb,
        ],
        "Physics3D active %d   pairs %d   scene nodes %d" % [
            physics_active,
            physics_pairs,
            nodes,
        ],
        "Asteroids %d   near %d   collision-range %d" % [
            asteroids.size(),
            performance_near_asteroids,
            performance_collision_range_asteroids,
        ],
        "Lasers %d   tractor chunks %d" % [
            mining_lasers.size(),
            tractor_chunks.size(),
        ],
        "Pipeline compiles since enabled: mesh +%d  surface +%d  draw +%d" % [
            maxi(0, mesh_compiles),
            maxi(0, surface_compiles),
            maxi(0, draw_compiles),
        ],
    ]

    return "\n".join(lines)


func _update_performance_metrics_display() -> void:
    if performance_label == null:
        return
    performance_label.text = _performance_snapshot_text()


func _set_debug_laser_range_visible(value: bool) -> void:
    debug_laser_range_visible = value
    _rebuild_laser_range_debug()


func _rebuild_laser_range_debug() -> void:
    if (
        laser_range_debug_root != null
        and is_instance_valid(laser_range_debug_root)
    ):
        laser_range_debug_root.queue_free()
        laser_range_debug_root = null

    if not debug_laser_range_visible:
        return
    if ship_visual_root == null or not is_instance_valid(ship_visual_root):
        return

    laser_range_debug_root = Node3D.new()
    laser_range_debug_root.name = "DebugMiningLaserRanges"
    ship_visual_root.add_child(laser_range_debug_root)

    var material := StandardMaterial3D.new()
    material.albedo_color = Color(0.32, 1.0, 0.52, 1.0)
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.no_depth_test = true

    var range_mesh := _make_laser_range_outline(material)

    for laser in mining_lasers:
        var anchor := laser.get("anchor_cell", Vector3i.ZERO) as Vector3i
        var instance := MeshInstance3D.new()
        instance.name = "LaserRange_%d_%d_%d" % [
            anchor.x,
            anchor.y,
            anchor.z,
        ]
        instance.mesh = range_mesh
        instance.position = _cell_world_center(anchor) - model_center
        instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        laser_range_debug_root.add_child(instance)


func _make_laser_range_outline(material: Material) -> ImmediateMesh:
    # The activation test measures from the edge of the laser's 1x1x1 cell,
    # not from its center. These three orthogonal rings therefore trace the
    # exact LASER_RANGE offset from that cube in their respective cross-sections
    # rather than drawing a simple center-radius sphere.
    const SEGMENTS := 128
    var mesh := ImmediateMesh.new()
    mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)

    for plane in range(3):
        var previous := Vector3.ZERO
        var first := Vector3.ZERO

        for index in range(SEGMENTS + 1):
            var angle := TAU * float(index % SEGMENTS) / float(SEGMENTS)
            var direction := Vector3.ZERO

            match plane:
                0:
                    direction = Vector3(cos(angle), 0.0, sin(angle))
                1:
                    direction = Vector3(cos(angle), sin(angle), 0.0)
                _:
                    direction = Vector3(0.0, cos(angle), sin(angle))

            var point := _laser_range_boundary_point(direction)

            if index == 0:
                first = point
            else:
                mesh.surface_add_vertex(previous)
                mesh.surface_add_vertex(point)

            previous = point

        mesh.surface_add_vertex(previous)
        mesh.surface_add_vertex(first)

    mesh.surface_end()
    return mesh


func _laser_range_boundary_point(direction: Vector3) -> Vector3:
    var unit := direction.normalized()
    var low := 0.0
    var high := LASER_RANGE + 1.0
    var half_cell := 0.5

    # Solve distance(point, 1x1x1 cell) == LASER_RANGE along this ray.
    # 24 iterations is far more precise than the rendered line thickness.
    for _iteration in range(24):
        var distance_from_center := (low + high) * 0.5
        var point := unit * distance_from_center
        var dx := maxf(absf(point.x) - half_cell, 0.0)
        var dy := maxf(absf(point.y) - half_cell, 0.0)
        var dz := maxf(absf(point.z) - half_cell, 0.0)
        var distance_from_cell := sqrt(dx * dx + dy * dy + dz * dz)

        if distance_from_cell < LASER_RANGE:
            low = distance_from_center
        else:
            high = distance_from_center

    return unit * ((low + high) * 0.5)


func _set_debug_hitboxes_visible(value: bool) -> void:
    debug_hitboxes_visible = value
    _rebuild_ship_debug_hitbox()

    for asteroid in asteroids.values():
        if asteroid != null and is_instance_valid(asteroid):
            (asteroid as SpaceAsteroid).set_debug_hitboxes_visible(value)


func _rebuild_ship_debug_hitbox() -> void:
    if ship_debug_hitbox != null and is_instance_valid(ship_debug_hitbox):
        ship_debug_hitbox.queue_free()
        ship_debug_hitbox = null

    for binding in ship_collision_bindings:
        binding["debug"] = null

    if not debug_hitboxes_visible:
        return
    if ship_collision_bindings.is_empty():
        return

    var material := StandardMaterial3D.new()
    material.albedo_color = Color(0.15, 0.75, 1.0, 1.0)
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.no_depth_test = true
    material.cull_mode = BaseMaterial3D.CULL_DISABLED

    ship_debug_hitbox = Node3D.new()
    ship_debug_hitbox.name = "DebugShipHitbox"
    ship_body.add_child(ship_debug_hitbox)

    for binding in ship_collision_bindings:
        var source = binding.get("source", null)
        var collision = binding.get("shape", null)
        if (
            source == null
            or not is_instance_valid(source)
            or collision == null
            or not is_instance_valid(collision)
        ):
            continue

        var debug_mesh := MeshInstance3D.new()
        debug_mesh.mesh = _make_mesh_wireframe(
            (source as MeshInstance3D).mesh,
            material
        )
        debug_mesh.transform = (collision as CollisionShape3D).transform
        debug_mesh.cast_shadow = (
            GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        )
        ship_debug_hitbox.add_child(debug_mesh)
        binding["debug"] = debug_mesh


func _make_mesh_wireframe(
    source_mesh: Mesh,
    material: Material
) -> ImmediateMesh:
    var result := ImmediateMesh.new()

    for surface_index in range(source_mesh.get_surface_count()):
        var arrays := source_mesh.surface_get_arrays(surface_index)
        if arrays.is_empty():
            continue

        var vertices = arrays[Mesh.ARRAY_VERTEX]
        if not (vertices is PackedVector3Array):
            continue

        var vertex_array := vertices as PackedVector3Array
        var indices = arrays[Mesh.ARRAY_INDEX]
        var edge_keys: Dictionary = {}
        var edges: Array[Vector2i] = []

        if indices is PackedInt32Array and (indices as PackedInt32Array).size() >= 3:
            var index_array := indices as PackedInt32Array
            for triangle_start in range(0, index_array.size() - 2, 3):
                var a := int(index_array[triangle_start])
                var b := int(index_array[triangle_start + 1])
                var d := int(index_array[triangle_start + 2])
                _append_unique_mesh_edge(edge_keys, edges, a, b)
                _append_unique_mesh_edge(edge_keys, edges, b, d)
                _append_unique_mesh_edge(edge_keys, edges, d, a)
        else:
            for triangle_start in range(0, vertex_array.size() - 2, 3):
                var a := triangle_start
                var b := triangle_start + 1
                var d := triangle_start + 2
                _append_unique_mesh_edge(edge_keys, edges, a, b)
                _append_unique_mesh_edge(edge_keys, edges, b, d)
                _append_unique_mesh_edge(edge_keys, edges, d, a)

        if edges.is_empty():
            continue

        result.surface_begin(Mesh.PRIMITIVE_LINES, material)
        for edge in edges:
            if (
                edge.x < 0
                or edge.y < 0
                or edge.x >= vertex_array.size()
                or edge.y >= vertex_array.size()
            ):
                continue
            result.surface_add_vertex(vertex_array[edge.x])
            result.surface_add_vertex(vertex_array[edge.y])
        result.surface_end()

    return result


func _append_unique_mesh_edge(
    edge_keys: Dictionary,
    edges: Array[Vector2i],
    first: int,
    second: int
) -> void:
    var low := mini(first, second)
    var high := maxi(first, second)
    var key := "%d:%d" % [low, high]
    if edge_keys.has(key):
        return

    edge_keys[key] = true
    edges.append(Vector2i(low, high))


func _make_debug_box_outline(
    size: Vector3,
    material: Material
) -> ImmediateMesh:
    var half := size * 0.5
    var corners: Array[Vector3] = [
        Vector3(-half.x, -half.y, -half.z),
        Vector3(half.x, -half.y, -half.z),
        Vector3(half.x, half.y, -half.z),
        Vector3(-half.x, half.y, -half.z),
        Vector3(-half.x, -half.y, half.z),
        Vector3(half.x, -half.y, half.z),
        Vector3(half.x, half.y, half.z),
        Vector3(-half.x, half.y, half.z),
    ]
    var edges := [
        Vector2i(0, 1), Vector2i(1, 2),
        Vector2i(2, 3), Vector2i(3, 0),
        Vector2i(4, 5), Vector2i(5, 6),
        Vector2i(6, 7), Vector2i(7, 4),
        Vector2i(0, 4), Vector2i(1, 5),
        Vector2i(2, 6), Vector2i(3, 7),
    ]

    var mesh := ImmediateMesh.new()
    mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
    for edge in edges:
        mesh.surface_add_vertex(corners[edge.x])
        mesh.surface_add_vertex(corners[edge.y])
    mesh.surface_end()
    return mesh


func _notification(what: int) -> void:
    if _is_mobile_platform():
        return

    if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
        Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
    elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
        desktop_cursor_hold = Input.is_key_pressed(KEY_TAB)
        if menu_open or desktop_cursor_hold:
            Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
        else:
            Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _process(delta: float) -> void:
    if not performance_metrics_visible:
        return

    _performance_record("frame", delta * 1000.0)
    performance_display_elapsed += delta
    performance_log_elapsed += delta

    if performance_display_elapsed >= PERF_DISPLAY_INTERVAL:
        performance_display_elapsed = 0.0
        _update_performance_metrics_display()

    if performance_log_elapsed >= PERF_LOG_INTERVAL:
        performance_log_elapsed = 0.0
        AppLogger.event(
            "PERF " + _performance_snapshot_text().replace("\n", " | ")
        )


func _physics_process(delta: float) -> void:
    if SkyCatalog.is_generating():
        _set_thruster_emission(false)
        return

    if menu_open:
        _set_thruster_emission(false)
        return

    if not performance_metrics_visible:
        _sync_ship_collision_transforms()
        _update_ship_motion(delta)
        _update_asteroids(delta)
        _update_tractor_chunks(delta)
        _update_mining_lasers(delta)
        _sync_ship_collision_transforms()
        _update_camera(delta)
        return

    var physics_start := Time.get_ticks_usec()
    var section_start := physics_start

    _sync_ship_collision_transforms()
    _performance_record_elapsed("collision_sync", section_start)

    section_start = Time.get_ticks_usec()
    _update_ship_motion(delta)
    _performance_record_elapsed("ship_motion", section_start)

    section_start = Time.get_ticks_usec()
    _update_asteroids(delta)
    _performance_record_elapsed("asteroids", section_start)

    section_start = Time.get_ticks_usec()
    _update_tractor_chunks(delta)
    _performance_record_elapsed("tractor", section_start)

    section_start = Time.get_ticks_usec()
    _update_mining_lasers(delta)
    _performance_record_elapsed("mining_lasers", section_start)

    section_start = Time.get_ticks_usec()
    _sync_ship_collision_transforms()
    _performance_record_elapsed("collision_sync", section_start)

    section_start = Time.get_ticks_usec()
    _update_camera(delta)
    _performance_record_elapsed("camera", section_start)

    _performance_record_elapsed("script_physics_total", physics_start)


func _update_ship_motion(delta: float) -> void:
    if collision_recovery_active:
        _update_collision_recovery(delta)
        return

    var throttle := 0.0
    var steer := 0.0
    var desktop_reverse_held := false

    var forward := _ship_forward_world()
    var right := forward.cross(Vector3.UP).normalized()
    var current_forward_speed := ship_body.velocity.dot(forward)

    if auto_orbit_enabled:
        var auto_input := _auto_orbit_input(forward)
        steer = auto_input.x
        throttle = auto_input.y
    elif _is_mobile_platform():
        var mobile_input := _mobile_flight_input()
        steer = mobile_input.x
        throttle = mobile_input.y
    else:
        var forward_input := Input.get_action_strength(&"builder_up")
        var reverse_input := Input.get_action_strength(&"builder_down")
        desktop_reverse_held = reverse_input > 0.0
        steer = (
            Input.get_action_strength(&"builder_right")
            - Input.get_action_strength(&"builder_left")
        )

        if desktop_reverse_held:
            # A/D only behave as reverse steering while S is physically held.
            # S supplies all reverse thrust; steering never adds forward thrust
            # during that input combination.
            throttle = -reverse_input
        elif forward_input > 0.0:
            throttle = forward_input
        elif absf(steer) > 0.0:
            # Once S is released, A/D immediately return to normal forward
            # propulsion even if the ship still has residual reverse momentum.
            throttle = absf(steer)

    # Resolve inertial velocity along the actual thrust-defined hull axes.
    surge_speed = current_forward_speed
    sway_speed = ship_body.velocity.dot(right)

    var surge_acceleration := (
        throttle * ENGINE_ACCELERATION
        - LONGITUDINAL_DRAG * surge_speed * absf(surge_speed)
    )
    var sway_acceleration := (
        -LATERAL_DRAG
        * sway_speed
        * maxf(0.35, absf(sway_speed))
    )

    ship_body.velocity += forward * surge_acceleration * delta
    ship_body.velocity += right * sway_acceleration * delta
    ship_body.velocity.y = 0.0

    surge_speed = ship_body.velocity.dot(forward)
    sway_speed = ship_body.velocity.dot(right)
    surge_speed = clampf(
        surge_speed,
        -MAX_REVERSE_SPEED,
        MAX_FORWARD_SPEED
    )
    ship_body.velocity = forward * surge_speed + right * sway_speed
    ship_body.velocity.y = 0.0

    var steering_speed := maxf(absf(surge_speed), 0.35)
    var direction_sign := signf(surge_speed)
    if auto_orbit_enabled:
        direction_sign = 1.0
    elif not _is_mobile_platform():
        # Desktop steering mode is input-driven, not momentum-driven. Reverse
        # steering exists only while S is held, so releasing S cannot leave
        # A/D latched in reverse while the old reverse velocity bleeds off.
        direction_sign = -1.0 if desktop_reverse_held else 1.0
    elif absf(direction_sign) < 0.5:
        direction_sign = 1.0

    var yaw_acceleration := (
        -steer
        * direction_sign
        * RUDDER_GAIN
        * steering_speed
        * steering_speed
        - YAW_DAMPING * yaw_rate
    )
    yaw_rate += yaw_acceleration * delta
    yaw_rate = clampf(yaw_rate, -MAX_YAW_RATE, MAX_YAW_RATE)
    ship_body.rotation.y += yaw_rate * delta

    var pre_collision_velocity := ship_body.velocity
    var collided := ship_body.move_and_slide()
    ship_body.global_position.y = 0.0
    ship_body.velocity.y = 0.0

    if collided:
        var away_normal := Vector3.ZERO
        var valid_normals := 0
        var hit_asteroid: SpaceAsteroid = null

        for collision_index in range(ship_body.get_slide_collision_count()):
            var collision := ship_body.get_slide_collision(collision_index)
            var normal := collision.get_normal()
            normal.y = 0.0
            if normal.length_squared() > 0.001:
                away_normal += normal.normalized()
                valid_normals += 1

            var collider = collision.get_collider()
            if collider is SpaceAsteroid:
                hit_asteroid = collider as SpaceAsteroid

        if valid_normals > 0 and away_normal.length_squared() > 0.001:
            _begin_collision_recovery(
                away_normal.normalized(),
                hit_asteroid,
                pre_collision_velocity
            )

    forward = _ship_forward_world()
    right = forward.cross(Vector3.UP).normalized()
    sway_speed = ship_body.velocity.dot(right)
    surge_speed = ship_body.velocity.dot(forward)

    var lateral_acceleration := -surge_speed * yaw_rate
    var target_heel := atan(
        lateral_acceleration / (9.81 * HEEL_STABILITY)
    )
    target_heel = clampf(target_heel, -MAX_HEEL, MAX_HEEL)

    var heel_acceleration := (
        (target_heel - heel_angle) * HEEL_SPRING
        - heel_velocity * HEEL_DAMPING
    )
    heel_velocity += heel_acceleration * delta
    heel_angle += heel_velocity * delta
    ship_visual_root.rotation.z = heel_angle

    var movement_active := (
        absf(throttle) > 0.05
        or absf(steer) > 0.05
    )
    _set_thruster_emission(movement_active)


func _begin_collision_recovery(
    away_normal: Vector3,
    asteroid: SpaceAsteroid,
    preserved_velocity: Vector3
) -> void:
    collision_recovery_active = true
    collision_recovery_elapsed = 0.0
    collision_recovery_normal = away_normal
    collision_recovery_asteroid = asteroid
    collision_recovery_saved_velocity = preserved_velocity
    collision_recovery_saved_velocity.y = 0.0

    # Pause momentum during recovery. The pre-impact movement vector is stored
    # intact and restored only after the rotation and five-cell clearance are
    # both complete.
    ship_body.velocity = Vector3.ZERO
    surge_speed = 0.0
    sway_speed = 0.0
    yaw_rate = 0.0

    collision_recovery_start_yaw = ship_body.rotation.y

    var current_forward := _ship_forward_world()
    var plus_forward := current_forward.rotated(
        Vector3.UP,
        COLLISION_RECOVERY_TURN
    )
    var minus_forward := current_forward.rotated(
        Vector3.UP,
        -COLLISION_RECOVERY_TURN
    )

    var turn_amount := COLLISION_RECOVERY_TURN
    if minus_forward.dot(away_normal) > plus_forward.dot(away_normal):
        turn_amount = -COLLISION_RECOVERY_TURN

    collision_recovery_target_yaw = (
        collision_recovery_start_yaw + turn_amount
    )

    if asteroid != null and is_instance_valid(asteroid):
        # Use a conservative radius around the full 20x20x20 asteroid. The
        # shortest safe escape is directly outward from its center. Including
        # the ship radius means the entire ship, not just its origin, clears
        # the asteroid by at least five builder cells in every direction.
        var asteroid_center := asteroid.global_position
        var radial := ship_body.global_position - asteroid_center
        radial.y = 0.0

        if radial.length_squared() <= 0.001:
            radial = away_normal
        else:
            radial = radial.normalized()

        collision_recovery_normal = radial
        collision_recovery_safe_radius = (
            asteroid.bounding_radius()
            + model_radius
            + COLLISION_RECOVERY_CLEARANCE
        )
        collision_recovery_target_position = (
            asteroid_center
            + radial * collision_recovery_safe_radius
        )
        collision_recovery_target_position.y = 0.0
    else:
        # Fallback when the collider is unavailable: still separate five cells
        # along the contact normal.
        collision_recovery_safe_radius = 0.0
        collision_recovery_target_position = (
            ship_body.global_position
            + away_normal * COLLISION_RECOVERY_CLEARANCE
        )
        collision_recovery_target_position.y = 0.0


func _update_collision_recovery(delta: float) -> void:
    # No normal input, acceleration, or retained momentum is allowed during
    # recovery. In particular, nothing may push the ship back toward the
    # asteroid before the full five-cell clearance has been reached.
    ship_body.velocity = Vector3.ZERO
    surge_speed = 0.0
    sway_speed = 0.0
    yaw_rate = 0.0

    collision_recovery_elapsed += delta
    var turn_progress := clampf(
        collision_recovery_elapsed / COLLISION_RECOVERY_DURATION,
        0.0,
        1.0
    )
    var smooth_turn := (
        turn_progress
        * turn_progress
        * (3.0 - 2.0 * turn_progress)
    )
    ship_body.rotation.y = lerp_angle(
        collision_recovery_start_yaw,
        collision_recovery_target_yaw,
        smooth_turn
    )

    # Move directly toward the nearest point that satisfies the radial safety
    # requirement. This is deterministic positional correction, not thrust.
    var remaining_distance := ship_body.global_position.distance_to(
        collision_recovery_target_position
    )
    if remaining_distance > 0.0001:
        var required_speed := (
            remaining_distance
            / maxf(
                0.05,
                COLLISION_RECOVERY_DURATION - minf(
                    collision_recovery_elapsed,
                    COLLISION_RECOVERY_DURATION - 0.05
                )
            )
        )
        ship_body.global_position = ship_body.global_position.move_toward(
            collision_recovery_target_position,
            required_speed * delta
        )
        ship_body.global_position.y = 0.0

    heel_velocity = 0.0
    heel_angle = move_toward(heel_angle, 0.0, delta * 1.8)
    ship_visual_root.rotation.z = heel_angle
    _set_thruster_emission(false)

    var position_clear := (
        ship_body.global_position.distance_to(
            collision_recovery_target_position
        ) <= 0.01
    )

    if (
        collision_recovery_asteroid != null
        and is_instance_valid(collision_recovery_asteroid)
    ):
        var radial_distance := ship_body.global_position.distance_to(
            collision_recovery_asteroid.global_position
        )
        position_clear = (
            radial_distance >= collision_recovery_safe_radius - 0.01
        )

    if turn_progress >= 1.0 and position_clear:
        ship_body.rotation.y = collision_recovery_target_yaw

        # Restore the pre-impact momentum magnitude, but redirect it along the
        # ship's new forward heading after the avoidance turn. This prevents
        # the ship from immediately drifting back along its old collision path.
        var restored_speed := collision_recovery_saved_velocity.length()
        var restored_forward := _ship_forward_world()
        ship_body.velocity = restored_forward * restored_speed
        ship_body.velocity.y = 0.0
        surge_speed = restored_speed
        sway_speed = 0.0

        collision_recovery_saved_velocity = Vector3.ZERO
        collision_recovery_active = false
        collision_recovery_elapsed = 0.0
        collision_recovery_safe_radius = 0.0
        collision_recovery_asteroid = null
        yaw_rate = 0.0


func _acquire_auto_orbit_target() -> void:
    var best: SpaceAsteroid = null
    var best_distance := INF

    for value in asteroids.values():
        if value == null or not is_instance_valid(value):
            continue

        var asteroid := value as SpaceAsteroid
        if not asteroid.has_cells():
            continue

        var distance := ship_body.global_position.distance_squared_to(
            asteroid.global_position
        )
        if distance < best_distance:
            best_distance = distance
            best = asteroid

    auto_orbit_target = best

    if auto_orbit_target == null:
        return

    var radial := (
        ship_body.global_position
        - auto_orbit_target.global_position
    )
    radial.y = 0.0
    if radial.length_squared() < 0.001:
        radial = -_ship_forward_world()
    radial = radial.normalized()

    var tangent := Vector3.UP.cross(radial).normalized()
    var forward := _ship_forward_world()
    auto_orbit_direction = (
        1.0
        if forward.dot(tangent) >= forward.dot(-tangent)
        else -1.0
    )


func _auto_orbit_input(forward: Vector3) -> Vector2:
    if (
        auto_orbit_target == null
        or not is_instance_valid(auto_orbit_target)
        or not auto_orbit_target.has_cells()
    ):
        _acquire_auto_orbit_target()

    if auto_orbit_target == null:
        return Vector2.ZERO

    var radial := (
        ship_body.global_position
        - auto_orbit_target.global_position
    )
    radial.y = 0.0
    var center_distance := radial.length()
    if center_distance < 0.001:
        radial = -forward
        center_distance = 0.001
    else:
        radial /= center_distance

    var tangent := (
        Vector3.UP.cross(radial).normalized()
        * auto_orbit_direction
    )

    # Conservative center-radius clearance uses the current asteroid's actual
    # 3-to-9-cell size plus the ship collision radius.
    var clearance := (
        center_distance
        - auto_orbit_target.bounding_radius()
        - model_collision_radius
    )

    var laser_distance := _auto_orbit_worst_laser_distance(
        auto_orbit_target
    )

    var radial_strength := 0.0
    if laser_distance < INF:
        radial_strength = clampf(
            (
                AUTO_ORBIT_TARGET_LASER_DISTANCE
                - laser_distance
            ) / AUTO_ORBIT_RADIAL_BAND,
            -0.85,
            0.85
        )

    # When outside the useful mining band, prioritize closing distance over
    # orbiting. When inside the collision buffer, prioritize escape.
    if (
        laser_distance < INF
        and laser_distance > LASER_RANGE - AUTO_ORBIT_RANGE_MARGIN
    ):
        radial_strength = -1.55

    if clearance < AUTO_ORBIT_MIN_CLEARANCE:
        radial_strength = 1.8

    var radial_speed := ship_body.velocity.dot(radial)
    if (
        clearance < AUTO_ORBIT_MIN_CLEARANCE + 6.0
        and radial_speed < 0.0
    ):
        radial_strength += clampf(
            -radial_speed / 4.0,
            0.0,
            1.0
        )

    var desired := (
        tangent + radial * radial_strength
    ).normalized()

    if (
        laser_distance < INF
        and laser_distance > LASER_RANGE + 8.0
    ):
        desired = (
            -radial * 1.5 + tangent * 0.30
        ).normalized()
    elif clearance < AUTO_ORBIT_MIN_CLEARANCE:
        desired = (
            radial * 1.7 + tangent * 0.25
        ).normalized()

    var heading_error := atan2(
        forward.cross(desired).y,
        forward.dot(desired)
    )
    var steer := clampf(
        -heading_error / deg_to_rad(48.0),
        -1.0,
        1.0
    )

    var throttle := AUTO_ORBIT_BASE_THROTTLE
    if absf(heading_error) > deg_to_rad(95.0):
        throttle = 0.22
    elif absf(heading_error) > deg_to_rad(60.0):
        throttle = 0.42

    # Inside the safety buffer, do not keep feeding forward velocity toward
    # the asteroid while the hull is still rotating away.
    if (
        clearance < AUTO_ORBIT_MIN_CLEARANCE + 2.0
        and radial_speed < 0.0
        and forward.dot(radial) < 0.15
    ):
        throttle = 0.0

    return Vector2(steer, throttle)


func _auto_orbit_worst_laser_distance(
    asteroid: SpaceAsteroid
) -> float:
    if mining_lasers.is_empty():
        return INF

    var worst := 0.0
    var found := false

    for laser in mining_lasers:
        var pivot = laser.get("pivot", null)
        if pivot == null or not is_instance_valid(pivot):
            continue

        worst = maxf(
            worst,
            _laser_cell_hitbox_distance(laser, asteroid)
        )
        found = true

    return worst if found else INF


func _update_camera(delta: float) -> void:
    var forward := _ship_forward_world()
    var distance := maxf(28.0, model_radius * 4.2 + 18.0)

    var desired_target := ship_body.global_position + forward * 2.2
    var desired_position := _camera_orbit_position(
        desired_target,
        forward,
        distance
    )
    desired_position = _resolve_camera_obstruction(
        desired_target,
        desired_position
    )

    # Fixed FOV, stable world-up horizon, no camera roll/head-bob, and
    # exponential position smoothing are intentional comfort choices.
    var position_alpha := 1.0 - exp(-4.8 * delta)
    var target_alpha := 1.0 - exp(-7.0 * delta)
    camera_position_smooth = camera_position_smooth.lerp(
        desired_position,
        position_alpha
    )
    camera_target_smooth = camera_target_smooth.lerp(
        desired_target,
        target_alpha
    )

    camera.global_position = camera_position_smooth
    camera.look_at(camera_target_smooth, Vector3.UP)


func _mobile_flight_input() -> Vector2:
    var stick := Input.get_vector(
        &"builder_left",
        &"builder_right",
        &"builder_up",
        &"builder_down"
    )
    var magnitude := stick.length()
    if magnitude <= 0.001:
        return Vector2.ZERO

    # Joystick up is forward. Any nonzero stick displacement supplies positive
    # propulsion; its angle away from forward controls how urgently the ship
    # tries to turn. 90 degrees or more requests maximum steering.
    var angle_from_forward := atan2(stick.x, -stick.y)
    var turn_sign := signf(angle_from_forward)

    if absf(turn_sign) < 0.5 and stick.y > 0.0:
        turn_sign = mobile_last_turn_sign
    elif absf(turn_sign) >= 0.5:
        mobile_last_turn_sign = turn_sign

    var turn_urgency := clampf(
        absf(angle_from_forward) / (PI * 0.5),
        0.0,
        1.0
    )

    return Vector2(turn_sign * turn_urgency, magnitude)


func _ship_forward_world() -> Vector3:
    var forward := ship_body.global_basis * ship_forward_local
    forward.y = 0.0
    if forward.length_squared() < 0.001:
        return Vector3.FORWARD
    return forward.normalized()


func _camera_orbit_position(
    target: Vector3,
    ship_forward: Vector3,
    distance: float
) -> Vector3:
    var back := -ship_forward
    back.y = 0.0
    if back.length_squared() < 0.001:
        back = Vector3.BACK
    else:
        back = back.normalized()

    back = back.rotated(Vector3.UP, camera_yaw_offset)
    var horizontal_distance := cos(camera_pitch) * distance
    var vertical_distance := sin(camera_pitch) * distance

    return (
        target
        + back * horizontal_distance
        + Vector3.UP * vertical_distance
    )


func _resolve_camera_obstruction(
    target: Vector3,
    desired_position: Vector3
) -> Vector3:
    var world := get_world_3d()
    if world == null or ship_body == null:
        return desired_position

    var query := PhysicsRayQueryParameters3D.create(target, desired_position)
    query.exclude = [ship_body.get_rid()]
    query.collide_with_areas = false
    query.collide_with_bodies = true

    var hit := world.direct_space_state.intersect_ray(query)
    if hit.is_empty():
        return desired_position

    var hit_position := hit.get("position", desired_position) as Vector3
    var toward_ship := (target - hit_position).normalized()
    return hit_position + toward_ship * 0.8


func _spawn_initial_asteroids() -> void:
    # Build the complete ring once. Every asteroid remains present and keeps
    # orbiting, including bodies on the far side of the planet.
    _populate_full_asteroid_ring()


func _update_asteroids(delta: float) -> void:
    var detail_distance := _asteroid_detail_distance()
    var near_count := 0
    var collision_range_count := 0

    asteroid_render_update_time += delta
    var update_far_physics := (
        asteroid_render_update_time >= FAR_RING_UPDATE_INTERVAL
    )
    if update_far_physics:
        asteroid_render_update_time = 0.0

    for asteroid_value in asteroids.values():
        if asteroid_value == null or not is_instance_valid(asteroid_value):
            continue

        var asteroid := asteroid_value as SpaceAsteroid
        var distance := ship_body.global_position.distance_to(
            asteroid.global_position
        )

        if distance <= detail_distance:
            near_count += 1
            # Nearby asteroids retain the original full update path.
            asteroid.update_spin(delta)
        else:
            # Far asteroids still move every frame so render/frustum state
            # cannot lag behind their real orbital position. Only cosmetic
            # spin and physics are reduced at distance.
            asteroid.update_far_orbit(delta)

        if distance <= ASTEROID_PHYSICS_ACTIVE_DISTANCE:
            collision_range_count += 1

        if update_far_physics:
            asteroid.set_collision_active(
                distance <= ASTEROID_PHYSICS_ACTIVE_DISTANCE
            )

    if performance_metrics_visible:
        performance_near_asteroids = near_count
        performance_collision_range_asteroids = collision_range_count


func _asteroid_detail_distance() -> float:
    # User-facing rule: full rotational/detailed rendering is only necessary
    # out to approximately the current distance from the ship to the near edge
    # of the planet. At the starting ring this is about 1,880 world units.
    return maxf(
        MIN_ASTEROID_DETAIL_DISTANCE,
        ship_body.global_position.distance_to(PLANET_CENTER) - PLANET_RADIUS
    )


func _populate_full_asteroid_ring() -> void:
    if not asteroids.is_empty():
        return

    var phase := asteroid_rng.randf_range(0.0, TAU)
    var slot_angle := TAU / float(RING_ASTEROID_COUNT)

    for slot in range(RING_ASTEROID_COUNT):
        asteroid_spawn_sequence += 1

        var size_value := asteroid_rng.randi_range(
            ASTEROID_MIN_SIZE,
            ASTEROID_MAX_SIZE
        )
        var candidate_radius := (
            sqrt(3.0) * float(size_value) * 0.5
        )

        # Every angular slot must produce one asteroid. We retry radial and
        # vertical lanes instead of dropping the slot, so no permanent arc can
        # disappear from the ring.
        var base_angle := fposmod(
            phase + float(slot) * slot_angle,
            TAU
        )
        var chosen_position := Vector3.ZERO
        var chosen_radius := RING_BASE_RADIUS
        var chosen_height := 0.0
        var chosen_angle := base_angle
        var found := false

        for attempt in range(12):
            var jitter_scale := (
                RING_SLOT_JITTER
                if attempt < 8
                else RING_SLOT_JITTER * 0.35
            )
            var angle := fposmod(
                base_angle
                + asteroid_rng.randf_range(
                    -slot_angle * jitter_scale,
                    slot_angle * jitter_scale
                ),
                TAU
            )

            var radial_lane := (
                RING_BASE_RADIUS
                + asteroid_rng.randf_range(
                    -RING_RADIAL_HALF_WIDTH,
                    RING_RADIAL_HALF_WIDTH
                )
            )
            var height := asteroid_rng.randf_range(
                -RING_VERTICAL_HALF_THICKNESS,
                RING_VERTICAL_HALF_THICKNESS
            )
            var candidate := PLANET_CENTER + Vector3(
                cos(angle) * radial_lane,
                height,
                sin(angle) * radial_lane
            )

            if not _asteroid_spawn_is_clear(
                candidate,
                candidate_radius
            ):
                continue

            chosen_position = candidate
            chosen_radius = radial_lane
            chosen_height = height
            chosen_angle = angle
            found = true
            break

        if not found:
            # A crowded or launch-adjacent slot still gets an asteroid. Move
            # it to a deterministic outer/inner lane instead of leaving a
            # visible hole in the ring.
            var lane_sign := -1.0 if slot % 2 == 0 else 1.0
            chosen_radius = (
                RING_BASE_RADIUS
                + lane_sign
                * (RING_RADIAL_HALF_WIDTH + 24.0)
            )
            chosen_height = (
                -RING_VERTICAL_HALF_THICKNESS
                if slot % 3 == 0
                else RING_VERTICAL_HALF_THICKNESS
            )
            chosen_angle = base_angle
            chosen_position = PLANET_CENTER + Vector3(
                cos(chosen_angle) * chosen_radius,
                chosen_height,
                sin(chosen_angle) * chosen_radius
            )

        var seed_value := int(asteroid_rng.randi())
        var palette_type := (
            "ice"
            if asteroid_rng.randf() < 0.5
            else "dirt"
        )
        var key := "ring_%d" % asteroid_spawn_sequence

        _spawn_asteroid(
            key,
            chosen_position,
            seed_value,
            size_value,
            palette_type,
            chosen_radius,
            chosen_angle,
            chosen_height,
            true
        )

    AppLogger.event(
        "RING populated requested=%d actual=%d"
        % [RING_ASTEROID_COUNT, asteroids.size()]
    )


func _asteroid_spawn_is_clear(
    world_position: Vector3,
    candidate_radius: float
) -> bool:
    if (
        world_position.distance_to(launch_position)
        < ASTEROID_LAUNCH_CENTER_CLEARANCE
    ):
        return false

    var ship_clearance := (
        candidate_radius
        + model_collision_radius
        + ASTEROID_SPAWN_SURFACE_GAP
    )
    if world_position.distance_to(ship_body.global_position) < ship_clearance:
        return false

    if camera != null:
        var camera_clearance := (
            candidate_radius
            + ASTEROID_SPAWN_SURFACE_GAP
        )
        if world_position.distance_to(camera.global_position) < camera_clearance:
            return false

    for value in asteroids.values():
        if value == null or not is_instance_valid(value):
            continue

        var asteroid := value as SpaceAsteroid
        var required_separation := (
            candidate_radius
            + asteroid.bounding_radius()
            + ASTEROID_MIN_CENTER_SEPARATION
        )
        if (
            world_position.distance_to(asteroid.global_position)
            < required_separation
        ):
            return false

    return true


func _spawn_asteroid(
    key: String,
    world_position: Vector3,
    seed_value: int,
    size_value: int,
    palette_type: String,
    ring_radius: float,
    ring_angle: float,
    ring_height: float,
    guaranteed_slot := false
) -> void:
    if not guaranteed_slot:
        var candidate_radius := (
            sqrt(3.0) * float(size_value) * 0.5
        )
        if not _asteroid_spawn_is_clear(
            world_position,
            candidate_radius
        ):
            return

    var asteroid := SpaceAsteroid.new()
    asteroid.name = "Asteroid_" + key.replace(":", "_")
    asteroid.configure(
        key,
        world_position,
        seed_value,
        size_value,
        palette_type
    )
    asteroid.configure_orbit(
        PLANET_CENTER,
        ring_radius,
        ring_angle,
        ring_height,
        RING_LINEAR_SPEED
    )
    asteroid_root.add_child(asteroid)
    asteroid.set_debug_hitboxes_visible(debug_hitboxes_visible)
    asteroids[key] = asteroid


func _update_mining_lasers(delta: float) -> void:
    beam_time += delta

    for laser_index in range(mining_lasers.size()):
        var laser := mining_lasers[laser_index]
        var pivot := laser.get("pivot", null) as Node3D
        var beam := laser.get("beam", null) as MultiMeshInstance3D
        var chunk = laser.get("chunk", null)

        if (
            pivot == null
            or not is_instance_valid(pivot)
            or beam == null
            or not is_instance_valid(beam)
        ):
            _set_laser_hard_error(
                laser_index,
                laser,
                "missing pivot or beam node"
            )
            mining_lasers[laser_index] = laser
            continue

        if chunk != null and is_instance_valid(chunk):
            _set_laser_status(laser_index, true, "")
            var chunk_node := chunk as Node3D
            var chunk_position := chunk_node.global_position
            _track_laser_pivot(pivot, chunk_position, delta)
            var chunk_muzzle := _laser_muzzle_world(pivot)
            _update_beam_particles(beam, chunk_muzzle, chunk_position)
            beam.visible = true
            mining_lasers[laser_index] = laser
            continue

        if chunk != null:
            laser["chunk"] = null

        var target = laser.get("target", null)
        if not _laser_target_in_range(target, laser):
            target = _choose_laser_target(laser, laser_index)
            laser["target"] = target
            laser["fire_time"] = 0.0
            laser["reserved_cell"] = null
            laser["prepared_detach"] = {}

        if target == null or not is_instance_valid(target):
            _clear_laser_hard_error(laser)
            _set_laser_status(laser_index, false, "Out of Range")
            # Hold the turret exactly where it was when range was lost. Do not
            # return to its construction/rest orientation.
            beam.visible = false
            laser["fire_time"] = 0.0
            laser["reserved_cell"] = null
            laser["prepared_detach"] = {}
            mining_lasers[laser_index] = laser
            continue

        var asteroid := target as SpaceAsteroid
        if asteroid == null:
            _set_laser_hard_error(
                laser_index,
                laser,
                "target was not a SpaceAsteroid"
            )
            beam.visible = false
            laser["fire_time"] = 0.0
            laser["reserved_cell"] = null
            laser["prepared_detach"] = {}
            mining_lasers[laser_index] = laser
            continue

        # Reserve a unique surface voxel per laser. This is the mining queue:
        # another laser targeting the same asteroid must select a different
        # cell and cannot steal a cell already assigned to an active laser.
        var reserved_value = laser.get("reserved_cell", null)
        if not (reserved_value is Vector3i):
            var exclusions := _reserved_mining_cells(
                asteroid,
                laser_index
            )
            var selection := asteroid.closest_surface_cell_excluding(
                _laser_muzzle_world(pivot),
                exclusions
            )
            if selection.is_empty():
                laser["reserved_cell"] = null
                laser["prepared_detach"] = {}
                laser["fire_time"] = 0.0
                beam.visible = false

                var replacement := _choose_laser_target(
                    laser,
                    laser_index,
                    asteroid
                ) as SpaceAsteroid

                if replacement != null:
                    laser["target"] = replacement
                else:
                    # Another laser may currently own every usable cell on this
                    # target. This is a normal queue state, not an error. Keep
                    # the current target and retry as reservations clear.
                    laser["target"] = asteroid

                _clear_laser_hard_error(laser)
                _set_laser_status(laser_index, true, "")
                mining_lasers[laser_index] = laser
                continue

            laser["reserved_cell"] = (
                selection.get("cell", Vector3i.ZERO) as Vector3i
            )
            reserved_value = laser["reserved_cell"]

        var reserved_cell := reserved_value as Vector3i
        var fire_time := float(laser.get("fire_time", 0.0))
        var prepared := laser.get("prepared_detach", {}) as Dictionary

        if fire_time >= LASER_PREPARE_SECONDS and prepared.is_empty():
            prepared = asteroid.prepare_detach_cell(reserved_cell)
            laser["prepared_detach"] = prepared

        var cell_position := asteroid.cell_world_position(reserved_cell)
        var aim_position := asteroid.global_position
        var transition_start := (
            LASER_MINING_SECONDS
            - LASER_SURFACE_TRANSITION_SECONDS
        )
        var transition := clampf(
            (fire_time - transition_start)
            / LASER_SURFACE_TRANSITION_SECONDS,
            0.0,
            1.0
        )
        var smooth_transition := (
            transition
            * transition
            * (3.0 - 2.0 * transition)
        )
        aim_position = asteroid.global_position.lerp(
            cell_position,
            smooth_transition
        )

        _track_laser_pivot(pivot, aim_position, delta)

        var muzzle := _laser_muzzle_world(pivot)
        var desired_direction := (
            aim_position - pivot.global_position
        ).normalized()
        var current_direction := pivot.global_basis.y.normalized()

        var aligned := (
            current_direction.dot(desired_direction)
            >= LASER_ALIGNMENT_DOT
        )

        # Obstruction is intentionally ONLY solid ship-builder cells. Tractor
        # chunks and every particle/beam effect live outside ship_cell_boxes,
        # so they can never block another mining laser.
        var blocked := _ship_blocks_segment(
            muzzle,
            aim_position,
            laser["anchor_cell"] as Vector3i
        )

        if blocked:
            var replacement := _choose_laser_target(
                laser,
                laser_index,
                asteroid
            ) as SpaceAsteroid

            if replacement != null:
                # A laser is independent: it may abandon an obstructed target
                # and mine a different clear asteroid even while other lasers
                # on the same ship keep their own targets.
                laser["target"] = replacement
                laser["fire_time"] = 0.0
                laser["reserved_cell"] = null
                laser["prepared_detach"] = {}
                beam.visible = false
                _set_laser_status(laser_index, true, "")
                mining_lasers[laser_index] = laser
                continue

            _set_laser_status(laser_index, false, "Obstructed")
            beam.visible = false
            laser["fire_time"] = 0.0
            laser["prepared_detach"] = {}
        else:
            _clear_laser_hard_error(laser)
            _set_laser_status(laser_index, true, "")

            var already_firing := fire_time > 0.0
            if aligned or already_firing:
                beam.visible = true
                _update_beam_particles(beam, muzzle, aim_position)
                fire_time += delta
                laser["fire_time"] = fire_time

                if fire_time >= LASER_MINING_SECONDS:
                    if prepared.is_empty():
                        prepared = asteroid.prepare_detach_cell(
                            reserved_cell
                        )
                        laser["prepared_detach"] = prepared

                    if not prepared.is_empty():
                        var detached := asteroid.commit_prepared_detach(
                            prepared
                        )

                        if detached.is_empty():
                            # Another laser may have committed a different
                            # reserved voxel first, making our prepared mesh
                            # version stale. Re-prepare THIS reserved cell from
                            # the new asteroid state without resetting the
                            # completed mining cycle, then commit next frame.
                            var refreshed := asteroid.prepare_detach_cell(
                                reserved_cell
                            )
                            if refreshed.is_empty():
                                laser["reserved_cell"] = null
                                laser["prepared_detach"] = {}
                                laser["fire_time"] = transition_start
                            else:
                                laser["prepared_detach"] = refreshed
                                laser["fire_time"] = LASER_MINING_SECONDS
                        else:
                            laser["fire_time"] = 0.0
                            laser["reserved_cell"] = null
                            laser["prepared_detach"] = {}

                            var chunk_node := _create_tractor_chunk(
                                detached["position"] as Vector3,
                                detached["color"] as Color
                            )
                            laser["chunk"] = chunk_node
                            tractor_chunks.append({
                                "node": chunk_node,
                                "laser_index": laser_index,
                                "speed": TRACTOR_START_SPEED,
                                "color": detached["color"],
                            })
            else:
                beam.visible = false
                laser["fire_time"] = 0.0

        mining_lasers[laser_index] = laser


func _reserved_mining_cells(
    asteroid: SpaceAsteroid,
    except_laser_index: int
) -> Array[Vector3i]:
    var result: Array[Vector3i] = []

    for index in range(mining_lasers.size()):
        if index == except_laser_index:
            continue

        var other := mining_lasers[index]
        var other_target = other.get("target", null)
        if other_target != asteroid:
            continue

        var other_cell = other.get("reserved_cell", null)
        if other_cell is Vector3i:
            result.append(other_cell as Vector3i)

    return result


func _laser_target_in_range(target, laser: Dictionary) -> bool:
    if target == null or not is_instance_valid(target):
        return false

    var asteroid := target as SpaceAsteroid
    if not asteroid.has_cells():
        return false

    return _laser_cell_hitbox_distance(laser, asteroid) <= LASER_RANGE


func _choose_laser_target(
    laser: Dictionary,
    laser_index: int,
    excluded_target: SpaceAsteroid = null
):
    var best = null
    var best_distance := INF

    for value in asteroids.values():
        if value == null or not is_instance_valid(value):
            continue

        var asteroid := value as SpaceAsteroid
        if asteroid == excluded_target or not asteroid.has_cells():
            continue

        # Cheap center-distance rejection keeps the full ring from doing exact
        # hitbox checks for obviously distant candidates.
        var broad_distance := ship_body.global_position.distance_to(
            asteroid.global_position
        )
        if (
            broad_distance
            > LASER_RANGE
            + asteroid.bounding_radius()
            + model_collision_radius
            + 4.0
        ):
            continue

        var distance := _laser_cell_hitbox_distance(laser, asteroid)
        if distance > LASER_RANGE or distance >= best_distance:
            continue
        if _laser_target_is_obstructed(laser, asteroid):
            continue
        if not _laser_target_has_available_cell(
            laser,
            laser_index,
            asteroid
        ):
            continue

        best_distance = distance
        best = asteroid

    return best


func _laser_target_has_available_cell(
    laser: Dictionary,
    laser_index: int,
    asteroid: SpaceAsteroid
) -> bool:
    var pivot = laser.get("pivot", null)
    if pivot == null or not is_instance_valid(pivot):
        return false

    var exclusions := _reserved_mining_cells(
        asteroid,
        laser_index
    )
    var selection := asteroid.closest_surface_cell_excluding(
        _laser_muzzle_world(pivot as Node3D),
        exclusions
    )
    return not selection.is_empty()


func _laser_target_is_obstructed(
    laser: Dictionary,
    asteroid: SpaceAsteroid
) -> bool:
    var pivot = laser.get("pivot", null)
    if pivot == null or not is_instance_valid(pivot):
        return true

    var pivot_node := pivot as Node3D
    return _ship_blocks_segment(
        pivot_node.global_position,
        asteroid.global_position,
        laser.get("anchor_cell", Vector3i.ZERO) as Vector3i
    )


func _set_laser_hard_error(
    laser_index: int,
    laser: Dictionary,
    reason: String
) -> void:
    var previous := str(laser.get("diagnostic_error", ""))
    if previous != reason:
        AppLogger.event(
            "MINING LASER ERROR index=%d reason=%s target=%s reserved=%s"
            % [
                laser_index,
                reason,
                str(laser.get("target", null)),
                str(laser.get("reserved_cell", null)),
            ]
        )
        laser["diagnostic_error"] = reason

    _set_laser_status(laser_index, false, "Error")


func _clear_laser_hard_error(laser: Dictionary) -> void:
    if laser.has("diagnostic_error"):
        laser.erase("diagnostic_error")


func _laser_cell_hitbox_distance(
    laser: Dictionary,
    asteroid: SpaceAsteroid
) -> float:
    var anchor := laser.get("anchor_cell", Vector3i.ZERO) as Vector3i
    var cell_local_center := _cell_world_center(anchor) - model_center
    var cell_world_center := ship_visual_root.to_global(cell_local_center)
    var cell_world_basis := ship_visual_root.global_basis.orthonormalized()

    return asteroid.distance_from_world_cell_to_hitbox(
        cell_world_center,
        cell_world_basis,
        0.5
    )


func _track_laser_pivot(
    pivot: Node3D,
    target_position: Vector3,
    delta: float
) -> void:
    var parent := pivot.get_parent() as Node3D
    if parent == null:
        return

    var world_direction := (
        target_position - pivot.global_position
    ).normalized()
    var local_direction := (
        parent.global_basis.inverse() * world_direction
    ).normalized()

    var desired_basis := _basis_with_y(local_direction)
    var current_quaternion := pivot.basis.get_rotation_quaternion()
    var desired_quaternion := desired_basis.get_rotation_quaternion()
    var angle := current_quaternion.angle_to(desired_quaternion)

    if angle < 0.0001:
        pivot.basis = desired_basis
        return

    var amount := minf(1.0, LASER_TRACK_SPEED * delta / angle)
    pivot.basis = Basis(
        current_quaternion.slerp(desired_quaternion, amount)
    ).orthonormalized()


func _track_laser_pivot_to_rest(pivot: Node3D, delta: float) -> void:
    var current_quaternion := pivot.basis.get_rotation_quaternion()
    var desired_quaternion := Quaternion.IDENTITY
    var angle := current_quaternion.angle_to(desired_quaternion)
    if angle < 0.0001:
        pivot.basis = Basis.IDENTITY
        return

    var amount := minf(1.0, LASER_TRACK_SPEED * 0.55 * delta / angle)
    pivot.basis = Basis(
        current_quaternion.slerp(desired_quaternion, amount)
    ).orthonormalized()


func _basis_with_y(direction: Vector3) -> Basis:
    var y_axis := direction.normalized()
    var helper := Vector3.FORWARD
    if absf(y_axis.dot(helper)) > 0.94:
        helper = Vector3.RIGHT

    var x_axis := helper.cross(y_axis).normalized()
    var z_axis := x_axis.cross(y_axis).normalized()
    return Basis(x_axis, y_axis, z_axis).orthonormalized()


func _laser_muzzle_world(pivot: Node3D) -> Vector3:
    return pivot.global_position + pivot.global_basis.y.normalized() * LASER_BARREL_LENGTH


func _ship_blocks_segment(
    world_from: Vector3,
    world_to: Vector3,
    laser_cell: Vector3i
) -> bool:
    var local_from := ship_visual_root.to_local(world_from)
    var local_to := ship_visual_root.to_local(world_to)

    for record in ship_cell_boxes:
        var cell := record["cell"] as Vector3i
        if cell == laser_cell:
            continue

        var box := record["aabb"] as AABB
        if _segment_intersects_aabb(local_from, local_to, box):
            return true

    return false


func _segment_intersects_aabb(
    segment_from: Vector3,
    segment_to: Vector3,
    box: AABB
) -> bool:
    var direction := segment_to - segment_from
    var t_min := 0.0
    var t_max := 1.0

    for axis in range(3):
        var origin := _vector_component(segment_from, axis)
        var delta := _vector_component(direction, axis)
        var minimum := _vector_component(box.position, axis)
        var maximum := _vector_component(box.end, axis)

        if absf(delta) < 0.000001:
            if origin < minimum or origin > maximum:
                return false
            continue

        var t1 := (minimum - origin) / delta
        var t2 := (maximum - origin) / delta
        if t1 > t2:
            var swap := t1
            t1 = t2
            t2 = swap

        t_min = maxf(t_min, t1)
        t_max = minf(t_max, t2)
        if t_min > t_max:
            return false

    return t_max > 0.015


func _vector_component(value: Vector3, axis: int) -> float:
    match axis:
        0:
            return value.x
        1:
            return value.y
        _:
            return value.z


func _create_beam_particles() -> MultiMeshInstance3D:
    var particle_mesh := BoxMesh.new()
    particle_mesh.size = Vector3(0.055, 0.055, 0.055)

    var material := StandardMaterial3D.new()
    material.albedo_color = Color("#52ff83")
    material.emission_enabled = true
    material.emission = Color("#52ff83")
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    particle_mesh.material = material

    var multimesh := MultiMesh.new()
    multimesh.transform_format = MultiMesh.TRANSFORM_3D
    multimesh.mesh = particle_mesh
    multimesh.instance_count = 0

    var instance := MultiMeshInstance3D.new()
    instance.multimesh = multimesh
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    return instance


func _update_beam_particles(
    beam: MultiMeshInstance3D,
    start: Vector3,
    finish: Vector3
) -> void:
    var distance := start.distance_to(finish)
    var count := clampi(int(ceil(distance * 6.5)), 6, 80)
    beam.multimesh.instance_count = count

    var direction := (finish - start).normalized()
    var helper := Vector3.UP
    if absf(direction.dot(helper)) > 0.92:
        helper = Vector3.RIGHT
    var side := direction.cross(helper).normalized()
    var up := side.cross(direction).normalized()

    for index in range(count):
        var t := float(index) / float(maxi(1, count - 1))
        var position := start.lerp(finish, t)

        if index != 0 and index != count - 1:
            var phase := beam_time * 8.0 + float(index) * 1.73
            position += side * sin(phase) * 0.035
            position += up * cos(phase * 1.27) * 0.035

        beam.multimesh.set_instance_transform(
            index,
            Transform3D(Basis.IDENTITY, position)
        )


func _create_thruster_particles() -> GPUParticles3D:
    var particles := GPUParticles3D.new()
    particles.amount = 26
    particles.lifetime = 0.55
    particles.randomness = 0.45
    particles.emitting = false
    particles.visibility_aabb = AABB(
        Vector3(-1.0, -1.0, -0.3),
        Vector3(2.0, 2.0, 4.0)
    )

    var process := ParticleProcessMaterial.new()
    process.direction = Vector3(0.0, 0.0, 1.0)
    process.spread = 12.0
    process.initial_velocity_min = 1.7
    process.initial_velocity_max = 3.5
    process.gravity = Vector3.ZERO
    process.color = Color("#ff9a45")
    particles.process_material = process

    var cube := BoxMesh.new()
    cube.size = Vector3(0.08, 0.08, 0.08)
    var material := StandardMaterial3D.new()
    material.albedo_color = Color("#ff9a45")
    material.emission_enabled = true
    material.emission = Color("#ff7a2f")
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    cube.material = material
    particles.draw_pass_1 = cube

    return particles


func _set_thruster_emission(value: bool) -> void:
    for particles in thruster_particles:
        if is_instance_valid(particles):
            particles.emitting = value


func _create_tractor_chunk(position: Vector3, color: Color) -> Node3D:
    var node := MeshInstance3D.new()
    var cube := BoxMesh.new()
    cube.size = Vector3.ONE * 0.94

    var material := StandardMaterial3D.new()
    material.albedo_color = color
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    cube.material = material

    node.mesh = cube
    node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    effects_root.add_child(node)
    node.global_position = position
    return node


func _update_tractor_chunks(delta: float) -> void:
    for index in range(tractor_chunks.size() - 1, -1, -1):
        var state := tractor_chunks[index]
        var node = state.get("node", null)
        if node == null or not is_instance_valid(node):
            tractor_chunks.remove_at(index)
            continue

        var chunk := node as Node3D
        var destination := ship_body.global_position
        var distance := chunk.global_position.distance_to(destination)

        var speed := minf(
            TRACTOR_MAX_SPEED,
            float(state.get("speed", TRACTOR_START_SPEED))
            + TRACTOR_ACCELERATION * delta
        )
        state["speed"] = speed

        chunk.global_position = chunk.global_position.move_toward(
            destination,
            speed * delta
        )
        chunk.rotate_y(delta * 2.2)
        chunk.rotate_x(delta * 1.35)

        if distance <= maxf(0.85, model_radius * 0.35):
            var color := state.get("color", Color.WHITE) as Color
            var laser_index := int(state.get("laser_index", -1))
            _spawn_collection_burst(chunk.global_position, color)
            chunk.queue_free()
            tractor_chunks.remove_at(index)

            if laser_index >= 0 and laser_index < mining_lasers.size():
                var laser := mining_lasers[laser_index]
                laser["chunk"] = null
                laser["fire_time"] = 0.0
                mining_lasers[laser_index] = laser
        else:
            tractor_chunks[index] = state


func _spawn_collection_burst(position: Vector3, color: Color) -> void:
    var particles := GPUParticles3D.new()
    particles.amount = 28
    particles.lifetime = 0.65
    particles.one_shot = true
    particles.explosiveness = 0.96
    particles.emitting = true

    var process := ParticleProcessMaterial.new()
    process.direction = Vector3.UP
    process.spread = 180.0
    process.initial_velocity_min = 1.2
    process.initial_velocity_max = 3.0
    process.gravity = Vector3.ZERO
    process.color = color
    particles.process_material = process

    var cube := BoxMesh.new()
    cube.size = Vector3.ONE * 0.075
    var material := StandardMaterial3D.new()
    material.albedo_color = color
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    cube.material = material
    particles.draw_pass_1 = cube

    effects_root.add_child(particles)
    particles.global_position = position

    var timer := get_tree().create_timer(1.0)
    timer.timeout.connect(particles.queue_free, CONNECT_ONE_SHOT)
