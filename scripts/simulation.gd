extends Node3D

const LASER_RANGE := 40.0
const LASER_MINING_SECONDS := 5.0
const LASER_TRACK_SPEED := deg_to_rad(52.0)
const LASER_ALIGNMENT_DOT := 0.985
const LASER_BARREL_LENGTH := 0.42

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

const ASTEROID_KEEP_DISTANCE := 500.0
const ASTEROID_UPDATE_INTERVAL := 1.5
const ASTEROID_HALF_DIAGONAL := 17.4
const ASTEROID_SPAWN_SURFACE_GAP := 32.0
const ASTEROID_LAUNCH_CENTER_CLEARANCE := 72.0
const ASTEROID_MIN_CENTER_SEPARATION := 120.0
const ASTEROID_TARGET_COUNT := 2
const ASTEROID_SPAWN_MIN_RADIUS := 105.0
const ASTEROID_SPAWN_MAX_RADIUS := 180.0
const ASTEROID_SPAWN_ATTEMPTS := 24
const INITIAL_ASTEROID_FORWARD_DISTANCE := 95.0
const INITIAL_ASTEROID_SIDE_DISTANCE := 28.0

const CAMERA_MOUSE_SENSITIVITY := 0.0026
const CAMERA_TOUCH_SENSITIVITY := 0.0042
const CAMERA_MIN_PITCH := deg_to_rad(-8.0)
const CAMERA_MAX_PITCH := deg_to_rad(68.0)
const CAMERA_DEFAULT_PITCH := deg_to_rad(25.0)

const TRACTOR_START_SPEED := 3.0
const TRACTOR_ACCELERATION := 4.5
const TRACTOR_MAX_SPEED := 10.0

var ship_id := ""
var ship_body: CharacterBody3D
var ship_visual_root: Node3D
var ship_collision: CollisionShape3D
var camera: Camera3D

var asteroid_root: Node3D
var effects_root: Node3D
var asteroids: Dictionary = {}
var mining_lasers: Array[Dictionary] = []
var thruster_particles: Array[GPUParticles3D] = []
var tractor_chunks: Array[Dictionary] = []
var ship_cell_boxes: Array[Dictionary] = []

var model_center := Vector3.ZERO
var model_radius := 2.0
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

var debug_hitboxes_visible := false
var ship_debug_hitbox: MeshInstance3D
var debug_laser_range_visible := false
var laser_range_debug_root: Node3D

var mobile_joystick: VirtualJoystick
var mobile_last_turn_sign := 1.0


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS

    var request := ShipStore.take_view_request()
    ship_id = str(request.get("ship_id", ""))
    if ship_id.is_empty():
        ShipStore.request_view("selector")
        get_tree().change_scene_to_file("res://main.tscn")
        return

    _build_environment()
    _build_simulation_roots()
    _load_ship()
    launch_position = ship_body.global_position
    _build_camera()
    _spawn_initial_asteroids()
    _build_ui()

    if not _is_mobile_platform() and "--simulation-smoke" not in OS.get_cmdline_user_args():
        Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

    if "--simulation-smoke" in OS.get_cmdline_user_args():
        var timer := get_tree().create_timer(7.0)
        timer.timeout.connect(get_tree().quit, CONNECT_ONE_SHOT)


func _build_environment() -> void:
    var world := WorldEnvironment.new()
    var environment := Environment.new()
    environment.background_mode = Environment.BG_COLOR
    environment.background_color = Color("#050914")
    environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    environment.ambient_light_color = Color("#27344c")
    environment.ambient_light_energy = 0.16
    environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
    world.environment = environment
    add_child(world)


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

    ship_collision = CollisionShape3D.new()
    ship_body.add_child(ship_collision)


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

    var collision_shape := BoxShape3D.new()
    collision_shape.size = collision_size
    ship_collision.shape = collision_shape
    _rebuild_ship_debug_hitbox()

    model_radius = maxf(
        1.5,
        maxf(collision_size.x, collision_size.z) * 0.5
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
        material.albedo_color = Color("#5f83c6")
        material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
        fallback.material = material

        var mesh_instance := MeshInstance3D.new()
        mesh_instance.mesh = fallback
        ship_visual_root.add_child(mesh_instance)


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
                "beam": beam,
            })
            _rebuild_laser_range_debug()


func _colors_from_entry(entry: Dictionary, part_index: int) -> Array[Color]:
    var colors: Array[Color] = []
    var color_data = entry.get("colors", [])
    if color_data is Array:
        for value in color_data:
            colors.append(Color.from_string(str(value), Color.WHITE))
    if colors.is_empty():
        colors = PartFactory.default_colors(part_index)
    return colors


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


func _build_camera() -> void:
    camera = Camera3D.new()
    camera.name = "ThirdPersonCamera"
    camera.current = true
    camera.fov = 60.0
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

    _build_mining_laser_status_panel(root)

    menu_dim = ColorRect.new()
    menu_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    menu_dim.color = SpaceMinerTheme.palette(AppSettings.is_dark_theme())["overlay"]
    menu_dim.mouse_filter = Control.MOUSE_FILTER_STOP
    menu_dim.visible = false
    root.add_child(menu_dim)

    menu_panel = PanelContainer.new()
    menu_panel.set_anchors_preset(Control.PRESET_CENTER)
    menu_panel.position = Vector2(-240.0, -220.0)
    menu_panel.size = Vector2(480.0, 440.0)
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


func _unhandled_input(event: InputEvent) -> void:
    if event.is_action_pressed(&"menu_back"):
        if menu_open:
            _close_menu()
        else:
            _open_menu()
        get_viewport().set_input_as_handled()
        return

    if menu_open:
        return

    if not _is_mobile_platform() and event is InputEventMouseMotion:
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

    var note := Label.new()
    note.text = "Hitboxes show exact physics collision shapes. Laser range shows the 40-cell activation boundary measured from each laser's 1x1x1 builder cell."
    note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    note.modulate.a = 0.76
    menu_content.add_child(note)


func _close_menu() -> void:
    menu_open = false
    menu_dim.visible = false
    menu_panel.visible = false
    gear_button.visible = true
    if not _is_mobile_platform():
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

    if not debug_hitboxes_visible:
        return
    if ship_collision == null or ship_collision.shape == null:
        return
    if not (ship_collision.shape is BoxShape3D):
        return

    var collision_box := ship_collision.shape as BoxShape3D
    var material := StandardMaterial3D.new()
    material.albedo_color = Color(0.15, 0.75, 1.0, 1.0)
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.no_depth_test = true

    ship_debug_hitbox = MeshInstance3D.new()
    ship_debug_hitbox.name = "DebugShipHitbox"
    ship_debug_hitbox.mesh = _make_debug_box_outline(
        collision_box.size,
        material
    )
    ship_debug_hitbox.position = ship_collision.position
    ship_debug_hitbox.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    ship_body.add_child(ship_debug_hitbox)


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
    elif what == NOTIFICATION_APPLICATION_FOCUS_IN and not menu_open:
        Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _physics_process(delta: float) -> void:
    if menu_open:
        _set_thruster_emission(false)
        return

    _update_ship_motion(delta)
    _update_asteroids(delta)
    _update_tractor_chunks(delta)
    _update_mining_lasers(delta)
    _update_camera(delta)


func _update_ship_motion(delta: float) -> void:
    if collision_recovery_active:
        _update_collision_recovery(delta)
        return

    var throttle := 0.0
    var steer := 0.0

    var forward := _ship_forward_world()
    var right := forward.cross(Vector3.UP).normalized()
    var current_forward_speed := ship_body.velocity.dot(forward)

    if _is_mobile_platform():
        var mobile_input := _mobile_flight_input()
        steer = mobile_input.x
        throttle = mobile_input.y
    else:
        var forward_input := Input.get_action_strength(&"builder_up")
        var reverse_input := Input.get_action_strength(&"builder_down")
        steer = (
            Input.get_action_strength(&"builder_right")
            - Input.get_action_strength(&"builder_left")
        )

        if reverse_input > 0.0:
            # S always requests reverse thrust. While moving forward it brakes;
            # once moving backward it continues to propel the ship backward.
            throttle = -reverse_input
        elif forward_input > 0.0:
            throttle = forward_input
        elif absf(steer) > 0.0:
            # A/D alone provides propulsion, but preserves the current travel
            # direction. If the ship is already reversing, steering alone must
            # not suddenly inject forward thrust.
            throttle = (
                -absf(steer)
                if current_forward_speed < -0.05
                else absf(steer)
            )

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
    if absf(direction_sign) < 0.5:
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
            ASTEROID_HALF_DIAGONAL
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
    var forward := _ship_forward_world()
    var right := forward.cross(Vector3.UP).normalized()
    var initial_position := (
        launch_position
        + forward * INITIAL_ASTEROID_FORWARD_DISTANCE
        + right * INITIAL_ASTEROID_SIDE_DISTANCE
    )

    # This position is deliberately constructed outside every launch/camera
    # exclusion distance. Spawn it immediately, then maintain only one
    # additional nearby asteroid.
    _spawn_asteroid("starter", initial_position, 1001)
    _maintain_asteroid_population()


func _update_asteroids(delta: float) -> void:
    for asteroid in asteroids.values():
        if is_instance_valid(asteroid):
            (asteroid as SpaceAsteroid).update_spin(delta)

    asteroid_update_time += delta
    if asteroid_update_time >= ASTEROID_UPDATE_INTERVAL:
        asteroid_update_time = 0.0
        _remove_distant_asteroids()
        _maintain_asteroid_population()


func _remove_distant_asteroids() -> void:
    var remove_keys: Array[String] = []

    for key in asteroids:
        var asteroid := asteroids.get(key, null) as SpaceAsteroid
        if asteroid == null or not is_instance_valid(asteroid):
            remove_keys.append(str(key))
            continue

        var distance := asteroid.global_position.distance_to(
            ship_body.global_position
        )

        # Never despawn an asteroid while the player can see it. The previous
        # 220-cell cutoff could repeatedly remove/recreate a distant asteroid
        # near the edge of the active area, which looked like a flickering cube
        # and caused expensive 20^3 surface-mesh rebuild spikes.
        if (
            distance > ASTEROID_KEEP_DISTANCE
            and camera != null
            and camera.is_position_behind(asteroid.global_position)
        ):
            asteroid.queue_free()
            remove_keys.append(str(key))

    for key in remove_keys:
        asteroids.erase(key)


func _maintain_asteroid_population() -> void:
    # Population is count-based rather than travel/sector gated. This means
    # asteroids exist immediately even if the player sits still for minutes,
    # while the low target count keeps the field intentionally sparse.
    var valid_count := 0
    for value in asteroids.values():
        if value != null and is_instance_valid(value):
            valid_count += 1

    var attempts := 0
    while valid_count < ASTEROID_TARGET_COUNT and attempts < ASTEROID_SPAWN_ATTEMPTS:
        attempts += 1
        asteroid_spawn_sequence += 1

        var seed_value: int = int(abs(hash(
            "%s:%d" % [ship_id, asteroid_spawn_sequence]
        )))
        var rng := RandomNumberGenerator.new()
        rng.seed = seed_value

        var angle := rng.randf_range(0.0, TAU)
        var radius := rng.randf_range(
            ASTEROID_SPAWN_MIN_RADIUS,
            ASTEROID_SPAWN_MAX_RADIUS
        )
        var candidate := (
            ship_body.global_position
            + Vector3(cos(angle), 0.0, sin(angle)) * radius
        )

        if not _asteroid_spawn_is_clear(candidate):
            continue

        var key := "field_%d" % asteroid_spawn_sequence
        _spawn_asteroid(key, candidate, seed_value)
        valid_count += 1


func _asteroid_spawn_is_clear(world_position: Vector3) -> bool:
    # The launch bubble is permanent, while current ship/camera clearance and
    # asteroid-to-asteroid spacing prevent overlap as replacements are spawned.
    if (
        world_position.distance_to(launch_position)
        < ASTEROID_LAUNCH_CENTER_CLEARANCE
    ):
        return false

    var ship_clearance := (
        ASTEROID_HALF_DIAGONAL
        + model_radius
        + ASTEROID_SPAWN_SURFACE_GAP
    )
    if world_position.distance_to(ship_body.global_position) < ship_clearance:
        return false

    if camera != null:
        var camera_clearance := (
            ASTEROID_HALF_DIAGONAL
            + ASTEROID_SPAWN_SURFACE_GAP
        )
        if world_position.distance_to(camera.global_position) < camera_clearance:
            return false

    for value in asteroids.values():
        if value == null or not is_instance_valid(value):
            continue

        var asteroid := value as SpaceAsteroid
        if (
            world_position.distance_to(asteroid.global_position)
            < ASTEROID_MIN_CENTER_SEPARATION
        ):
            return false

    return true


func _spawn_asteroid(
    key: String,
    world_position: Vector3,
    seed_value: int
) -> void:
    if not _asteroid_spawn_is_clear(world_position):
        return

    var asteroid := SpaceAsteroid.new()
    asteroid.name = "Asteroid_" + key.replace(":", "_")
    asteroid.configure(key, world_position, seed_value)
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
            _set_laser_status(laser_index, false, "Error")
            continue

        if chunk != null and is_instance_valid(chunk):
            _set_laser_status(laser_index, true, "")
            var chunk_node := chunk as Node3D
            var target_position := chunk_node.global_position
            _track_laser_pivot(pivot, target_position, delta)
            var muzzle := _laser_muzzle_world(pivot)
            _update_beam_particles(beam, muzzle, target_position)
            beam.visible = true
            mining_lasers[laser_index] = laser
            continue

        if chunk != null:
            laser["chunk"] = null

        var target = laser.get("target", null)
        if not _laser_target_in_range(target, laser):
            target = _choose_laser_target(laser)
            laser["target"] = target
            laser["fire_time"] = 0.0

        if target == null or not is_instance_valid(target):
            _set_laser_status(laser_index, false, "Out of Range")
            _track_laser_pivot_to_rest(pivot, delta)
            beam.visible = false
            laser["fire_time"] = 0.0
            mining_lasers[laser_index] = laser
            continue

        var asteroid := target as SpaceAsteroid
        if asteroid == null:
            _set_laser_status(laser_index, false, "Error")
            beam.visible = false
            laser["fire_time"] = 0.0
            mining_lasers[laser_index] = laser
            continue

        var target_position := asteroid.global_position
        _track_laser_pivot(pivot, target_position, delta)

        var muzzle := _laser_muzzle_world(pivot)
        var desired_direction := (
            target_position - pivot.global_position
        ).normalized()
        var current_direction := pivot.global_basis.y.normalized()

        var aligned := current_direction.dot(desired_direction) >= LASER_ALIGNMENT_DOT
        var blocked := _ship_blocks_segment(
            muzzle,
            target_position,
            laser["anchor_cell"] as Vector3i
        )

        if blocked:
            _set_laser_status(laser_index, false, "Obstructed")
            beam.visible = false
            laser["fire_time"] = 0.0
        else:
            _set_laser_status(laser_index, true, "")

            if aligned:
                beam.visible = true
                _update_beam_particles(beam, muzzle, target_position)
                laser["fire_time"] = float(laser["fire_time"]) + delta

                if float(laser["fire_time"]) >= LASER_MINING_SECONDS:
                    var detached := asteroid.detach_closest_cell(muzzle)
                    laser["fire_time"] = 0.0
                    if not detached.is_empty():
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


func _laser_target_in_range(target, laser: Dictionary) -> bool:
    if target == null or not is_instance_valid(target):
        return false

    var asteroid := target as SpaceAsteroid
    if not asteroid.has_cells():
        return false

    return _laser_cell_hitbox_distance(laser, asteroid) <= LASER_RANGE


func _choose_laser_target(laser: Dictionary):
    var best = null
    var best_distance := INF

    for value in asteroids.values():
        if value == null or not is_instance_valid(value):
            continue

        var asteroid := value as SpaceAsteroid
        if not asteroid.has_cells():
            continue

        var distance := _laser_cell_hitbox_distance(laser, asteroid)
        if distance <= LASER_RANGE and distance < best_distance:
            best_distance = distance
            best = asteroid

    return best


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
