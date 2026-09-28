class_name VirtualJoystick
extends Control

signal vector_changed(value: Vector2)

@export var base_radius := 82.0
@export var knob_radius := 34.0
@export var deadzone := 0.12

var value := Vector2.ZERO
var _touch_id := -1
var _mouse_active := false


func _ready() -> void:
    mouse_filter = Control.MOUSE_FILTER_STOP
    focus_mode = Control.FOCUS_NONE
    queue_redraw()


func reset() -> void:
    _touch_id = -1
    _mouse_active = false
    _set_value(Vector2.ZERO)


func _gui_input(event: InputEvent) -> void:
    if event is InputEventScreenTouch:
        var touch := event as InputEventScreenTouch
        if touch.pressed:
            if _touch_id < 0:
                _touch_id = touch.index
                _update_from_position(touch.position)
                accept_event()
        elif touch.index == _touch_id:
            reset()
            accept_event()
        return

    if event is InputEventScreenDrag:
        var drag := event as InputEventScreenDrag
        if drag.index == _touch_id:
            _update_from_position(drag.position)
            accept_event()
        return

    # Mouse support is useful for local testing, though the joystick itself is
    # only instantiated on mobile by the simulation scene.
    if event is InputEventMouseButton:
        var mouse_button := event as InputEventMouseButton
        if mouse_button.button_index == MOUSE_BUTTON_LEFT:
            _mouse_active = mouse_button.pressed
            if _mouse_active:
                _update_from_position(mouse_button.position)
            else:
                reset()
            accept_event()
        return

    if event is InputEventMouseMotion and _mouse_active:
        _update_from_position((event as InputEventMouseMotion).position)
        accept_event()


func _update_from_position(local_position: Vector2) -> void:
    var center := size * 0.5
    var offset := local_position - center
    var normalized := offset / maxf(base_radius, 1.0)

    if normalized.length() > 1.0:
        normalized = normalized.normalized()

    if normalized.length() < deadzone:
        normalized = Vector2.ZERO
    else:
        var remapped_length := (
            (normalized.length() - deadzone)
            / maxf(0.0001, 1.0 - deadzone)
        )
        normalized = normalized.normalized() * remapped_length

    _set_value(normalized)


func _set_value(new_value: Vector2) -> void:
    if value.is_equal_approx(new_value):
        return
    value = new_value
    vector_changed.emit(value)
    queue_redraw()


func _draw() -> void:
    var center := size * 0.5

    # Deliberately subtle: this should read as a touch target over the game,
    # not as a large opaque HUD element.
    draw_circle(center, base_radius, Color(0.72, 0.78, 0.90, 0.13))
    draw_arc(
        center,
        base_radius,
        0.0,
        TAU,
        64,
        Color(0.82, 0.88, 1.0, 0.32),
        2.0,
        true
    )

    var knob_position := center + value * base_radius
    draw_circle(
        knob_position,
        knob_radius,
        Color(0.82, 0.88, 1.0, 0.28)
    )
    draw_arc(
        knob_position,
        knob_radius,
        0.0,
        TAU,
        48,
        Color(0.90, 0.94, 1.0, 0.46),
        2.0,
        true
    )
