extends Node

# Preview-only instrumentation. This node is created by Simulation on mobile
# only on the diagnostics/travel-regression-ab branch. It does not permanently
# change ship saves, graphics settings, physics tick rate, or asteroid count.
#
# Short repeated A/B windows isolate newly introduced components and the
# remaining rendering/transform work. Each baseline directly brackets a test.
const PHASE_SECONDS := 7.0
const WARMUP_SECONDS := 1.0
const PHASES: Array[String] = [
    "baseline",
    "proximity_off",
    "baseline",
    "far_spin_off",
    "baseline",
    "asteroid_visuals_off",
    "baseline",
    "collision_sync_off",
    "baseline",
    "mining_logic_off",
    "baseline",
]
const SLOW_FRAME_THRESHOLD_MS := 35.0
const HITCH_LOG_COOLDOWN_USEC := 1000000
const MONITOR_SAMPLE_EVERY_FRAMES := 4

var scene: Node3D
var _area: Area3D
var _presenter: Node
var _original_mask := 1
var _original_monitoring := true
var _visual_visibility: Dictionary = {}
var _started := false
var _phase_index := -1
var _cycle := 0
var _phase_started_usec := 0
var _last_frame_usec := 0
var _last_hitch_usec := 0
var _last_physics_start_usec := 0
var _tick_span_usec := 0
var _ticks_since_render := 0
var _tick_span_since_render_usec := 0
var _samples: Dictionary = {}
var _last_frame_ticks := 0


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    process_priority = 950000
    process_physics_priority = 950000
    scene = get_parent() as Node3D
    if scene == null:
        set_process(false)
        set_physics_process(false)
        return
    var marker: Node = preload(
        "res://scripts/travel_regression_physics_marker.gd"
    ).new()
    marker.set("probe", self)
    scene.add_child(marker)
    _presenter = get_node_or_null("/root/AsteroidMetallicPresenter")


func _start_physics_tick() -> void:
    if _started:
        _last_physics_start_usec = Time.get_ticks_usec()


func _physics_process(_delta: float) -> void:
    if not _started or _last_physics_start_usec <= 0:
        return
    var spent := Time.get_ticks_usec() - _last_physics_start_usec
    _tick_span_usec += spent
    _ticks_since_render += 1
    _tick_span_since_render_usec += spent


func _process(delta: float) -> void:
    if scene == null or not is_instance_valid(scene):
        return
    if bool(scene.get("asteroid_loading_in_progress")):
        return
    var now := Time.get_ticks_usec()
    if not _started:
        _start_test(now)
        return

    var raw_ms := float(now - _last_frame_usec) / 1000.0
    _last_frame_usec = now
    var phase_seconds := float(now - _phase_started_usec) / 1000000.0
    if phase_seconds >= PHASE_SECONDS:
        _finish_phase(now)
        _next_phase(now)
        _ticks_since_render = 0
        _tick_span_since_render_usec = 0
        return

    if phase_seconds < WARMUP_SECONDS:
        _ticks_since_render = 0
        _tick_span_since_render_usec = 0
        return

    _sample_frame(raw_ms, delta * 1000.0)
    _ticks_since_render = 0
    _tick_span_since_render_usec = 0


func _start_test(now: int) -> void:
    _started = true
    _last_frame_usec = now
    _area = scene.get_node_or_null("Ship/MiningProximity") as Area3D
    if _area != null:
        _original_mask = _area.collision_mask
        _original_monitoring = _area.monitoring
    AppLogger.event(
        "TRAVEL_AB_START mobile=true phases=%d duration_s=%.1f "
        % [PHASES.size(), PHASE_SECONDS]
        + "warmup_s=%.1f asteroid_count=%d "
        % [WARMUP_SECONDS, _asteroid_count()]
        + "ship_shapes=%d proximity_present=%s "
        % [
            _ship_shape_count(),
            str(_area != null),
        ]
        + "driver=%s backend=%s "
        % [
            RenderingServer.get_current_rendering_driver_name(),
            RenderingServer.get_current_rendering_method(),
        ]
        + "vsync=%d refresh_hz=%.2f max_fps=%d physics_tps=%d"
        % [
            int(DisplayServer.window_get_vsync_mode()),
            DisplayServer.screen_get_refresh_rate(),
            Engine.max_fps,
            Engine.physics_ticks_per_second,
        ]
    )
    _next_phase(now)


func _next_phase(now: int) -> void:
    _restore_baseline()
    _phase_index += 1
    if _phase_index >= PHASES.size():
        _phase_index = 0
        _cycle += 1
    var phase := PHASES[_phase_index]
    _samples = _empty_samples()
    _phase_started_usec = now
    match phase:
        "proximity_off":
            if _area != null:
                _area.set_deferred("monitoring", false)
                _area.set_deferred("collision_mask", 0)
        "far_spin_off":
            if _presenter != null and is_instance_valid(_presenter):
                _presenter.set("_diagnostic_pause_far_spin", true)
        "asteroid_visuals_off":
            _set_asteroid_visuals_visible(false)
        "collision_sync_off":
            scene.set_meta("travel_probe_skip_collision_sync", true)
        "mining_logic_off":
            scene.set_meta("travel_probe_skip_mining", true)
    AppLogger.event(
        "TRAVEL_AB_PHASE_START cycle=%d index=%d mode=%s "
        % [_cycle, _phase_index, phase]
        + "nearby=%d speed=%.2f yaw_rate=%.3f"
        % [_nearby_count(), _ship_speed(), float(scene.get("yaw_rate"))]
    )


func _restore_baseline() -> void:
    if _area != null and is_instance_valid(_area):
        _area.set_deferred("collision_mask", _original_mask)
        _area.set_deferred("monitoring", _original_monitoring)
    if _presenter != null and is_instance_valid(_presenter):
        _presenter.set("_diagnostic_pause_far_spin", false)
    _set_asteroid_visuals_visible(true)
    if scene != null and is_instance_valid(scene):
        scene.set_meta("travel_probe_skip_collision_sync", false)
        scene.set_meta("travel_probe_skip_mining", false)
        # Catch up hull geometry after the collision-sync experiment.
        if scene.has_method("_sync_ship_collision_transforms"):
            scene.call("_sync_ship_collision_transforms")


func _set_asteroid_visuals_visible(visible: bool) -> void:
    if scene == null or not is_instance_valid(scene):
        return
    if visible and _visual_visibility.is_empty():
        return
    var asteroid_value = scene.get("asteroids")
    if not (asteroid_value is Dictionary):
        return
    for value in (asteroid_value as Dictionary).values():
        if not (value is SpaceAsteroid) or not is_instance_valid(value):
            continue
        var visual_value = (value as SpaceAsteroid).get("_visual")
        if not (visual_value is Node3D) or not is_instance_valid(visual_value):
            continue
        var visual := visual_value as Node3D
        var asteroid_id := (value as SpaceAsteroid).get_instance_id()
        if visible:
            if _visual_visibility.has(asteroid_id):
                visual.visible = bool(_visual_visibility[asteroid_id])
        else:
            _visual_visibility[asteroid_id] = visual.visible
            visual.visible = false
    if visible:
        _visual_visibility.clear()


func _empty_samples() -> Dictionary:
    return {
        "frame_ms": [],
        "delta_ms": 0.0,
        "delta_underreported": 0,
        "ticks": 0,
        "max_ticks": 0,
        "tick_script_us": 0,
        "render_cpu_ms": 0.0,
        "render_setup_ms": 0.0,
        "gpu_ms": 0.0,
        "engine_process_ms": 0.0,
        "engine_physics_ms": 0.0,
        "draws": 0,
        "primitives": 0,
        "monitor_samples": 0,
        "turn_ms": [],
        "straight_ms": [],
        "idle_ms": [],
        "nearby_max": 0,
    }


func _sample_frame(raw_ms: float, delta_ms: float) -> void:
    var frames := _samples["frame_ms"] as Array
    frames.append(raw_ms)
    _samples["delta_ms"] = float(_samples["delta_ms"]) + delta_ms
    if raw_ms - delta_ms > 10.0:
        _samples["delta_underreported"] = int(
            _samples["delta_underreported"]
        ) + 1
    _samples["ticks"] = int(_samples["ticks"]) + _ticks_since_render
    _samples["max_ticks"] = maxi(
        int(_samples["max_ticks"]), _ticks_since_render
    )
    _samples["tick_script_us"] = (
        int(_samples["tick_script_us"]) + _tick_span_since_render_usec
    )
    _samples["nearby_max"] = maxi(
        int(_samples["nearby_max"]), _nearby_count()
    )

    var movement := str(scene.get("mobile_turn_phase"))
    if movement != "turn" and movement != "straight":
        movement = "idle"
    (_samples[movement + "_ms"] as Array).append(raw_ms)

    var frame_index := frames.size()
    if frame_index % MONITOR_SAMPLE_EVERY_FRAMES == 0:
        var viewport_rid := get_viewport().get_viewport_rid()
        _samples["render_cpu_ms"] = (
            float(_samples["render_cpu_ms"])
            + RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid)
        )
        _samples["render_setup_ms"] = (
            float(_samples["render_setup_ms"])
            + RenderingServer.get_frame_setup_time_cpu()
        )
        _samples["gpu_ms"] = (
            float(_samples["gpu_ms"])
            + RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid)
        )
        _samples["engine_process_ms"] = (
            float(_samples["engine_process_ms"])
            + Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
        )
        _samples["engine_physics_ms"] = (
            float(_samples["engine_physics_ms"])
            + Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
        )
        _samples["draws"] = (
            int(_samples["draws"])
            + int(Performance.get_monitor(
                Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME
            ))
        )
        _samples["primitives"] = (
            int(_samples["primitives"])
            + int(Performance.get_monitor(
                Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME
            ))
        )
        _samples["monitor_samples"] = int(_samples["monitor_samples"]) + 1

    var now := Time.get_ticks_usec()
    if (
        raw_ms >= 80.0
        and now - _last_hitch_usec >= HITCH_LOG_COOLDOWN_USEC
    ):
        _last_hitch_usec = now
        AppLogger.event(
            "TRAVEL_AB_HITCH mode=%s raw_wall_ms=%.2f delta_ms=%.2f "
            % [PHASES[_phase_index], raw_ms, delta_ms]
            + "physics_ticks_before_frame=%d physics_script_span_ms=%.2f "
            % [
                _ticks_since_render,
                float(_tick_span_since_render_usec) / 1000.0,
            ]
            + "movement=%s speed=%.2f yaw_rate=%.3f nearby=%d"
            % [
                movement,
                _ship_speed(),
                float(scene.get("yaw_rate")),
                _nearby_count(),
            ]
        )


func _percentile(values: Array, fraction: float) -> float:
    if values.is_empty():
        return 0.0
    var sorted := values.duplicate()
    sorted.sort()
    var index := mini(
        sorted.size() - 1,
        maxi(0, int(ceil(float(sorted.size()) * fraction)) - 1)
    )
    return float(sorted[index])


func _finish_phase(now: int) -> void:
    var frames := _samples["frame_ms"] as Array
    var window_s := maxf(
        0.001,
        (float(now - _phase_started_usec) / 1000000.0)
        - WARMUP_SECONDS
    )
    var count := maxi(1, frames.size())
    var monitor_count := maxi(1, int(_samples["monitor_samples"]))
    var turns := _samples["turn_ms"] as Array
    var straights := _samples["straight_ms"] as Array
    var idles := _samples["idle_ms"] as Array
    AppLogger.event(
        "TRAVEL_AB_RESULT cycle=%d index=%d mode=%s frames=%d "
        % [_cycle, _phase_index, PHASES[_phase_index], frames.size()]
        + "window_s=%.2f fps=%.1f raw_p50_ms=%.1f raw_p95_ms=%.1f "
        % [
            window_s,
            float(frames.size()) / window_s,
            _percentile(frames, 0.50),
            _percentile(frames, 0.95),
        ]
        + "raw_p99_ms=%.1f delta_avg_ms=%.1f delta_underreported=%d "
        % [
            _percentile(frames, 0.99),
            float(_samples["delta_ms"]) / float(count),
            int(_samples["delta_underreported"]),
        ]
        + "turn_frames=%d turn_p95_ms=%.1f "
        % [turns.size(), _percentile(turns, 0.95)]
        + "straight_frames=%d straight_p95_ms=%.1f idle_frames=%d "
        % [
            straights.size(), _percentile(straights, 0.95),
            idles.size(),
        ]
        + "physics_ticks=%d max_ticks_per_frame=%d "
        % [
            int(_samples["ticks"]),
            int(_samples["max_ticks"]),
        ]
        + "physics_callbacks_avg_ms=%.3f "
        % [
            float(_samples["tick_script_us"])
            / maxi(1, int(_samples["ticks"])) / 1000.0,
        ]
        + "engine_process_avg_ms=%.2f engine_physics_avg_ms=%.2f "
        % [
            float(_samples["engine_process_ms"]) / monitor_count,
            float(_samples["engine_physics_ms"]) / monitor_count,
        ]
        + "render_cpu_avg_ms=%.2f setup_avg_ms=%.2f gpu_report_avg_ms=%.2f "
        % [
            float(_samples["render_cpu_ms"]) / monitor_count,
            float(_samples["render_setup_ms"]) / monitor_count,
            float(_samples["gpu_ms"]) / monitor_count,
        ]
        + "draws_avg=%.1f primitives_avg=%.1f nearby_max=%d"
        % [
            float(_samples["draws"]) / monitor_count,
            float(_samples["primitives"]) / monitor_count,
            int(_samples["nearby_max"]),
        ]
    )


func _asteroid_count() -> int:
    var value = scene.get("asteroids")
    return (value as Dictionary).size() if value is Dictionary else 0


func _nearby_count() -> int:
    var value = scene.get("nearby_mining_asteroids")
    return (value as Dictionary).size() if value is Dictionary else 0


func _ship_shape_count() -> int:
    var value = scene.get("ship_collision_bindings")
    return (value as Array).size() if value is Array else 0


func _ship_speed() -> float:
    var value = scene.get("ship_body")
    if value is CharacterBody3D and is_instance_valid(value):
        return (value as CharacterBody3D).velocity.length()
    return 0.0


func _exit_tree() -> void:
    if _started:
        _finish_phase(Time.get_ticks_usec())
    _restore_baseline()
    if _started:
        AppLogger.event("TRAVEL_AB_STOP restored normal game behavior")
