extends Node

# Project-wide scroll gesture behavior.
#
# Any ScrollContainer added to the scene tree is registered automatically.
# The normal ScrollContainer behavior remains in place for blank/non-button
# areas. When a drag begins on a BaseButton inside a scroll area, this helper
# takes over after a small movement threshold, scrolls the container directly,
# and temporarily disables the pressed button until the pointer is released.
# That prevents a drag gesture from turning into an accidental button press.
# A new, distinct press is then required before the button can activate.

const DRAG_THRESHOLD_PX := 10.0
const SIMULATION_SCRIPT_PATH := "res://scripts/simulation.gd"
const DEBUG_NOTE_PREFIX := "Hitboxes show exact physics collision shapes."
const DEBUG_NOTE_TEXT := (
    "Hitboxes show collision shapes. Laser range shows the 40-cell boundary. "
    + "Skybox generation pauses flight."
)

var _registered: Dictionary = {}
var _active_scroll: ScrollContainer
var _pressed_button: BaseButton
var _press_position := Vector2.ZERO
var _last_position := Vector2.ZERO
var _dragging := false
var _using_touch := false
var _touch_index := -1


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    get_tree().node_added.connect(_on_node_added)
    get_tree().node_removed.connect(_on_node_removed)
    set_process_input(true)
    call_deferred("_scan_current_scene")


func _process(_delta: float) -> void:
    _cleanup_registered()
    _ensure_simulation_menu_scroll()
    _shorten_simulation_debug_note()


func _on_node_added(node: Node) -> void:
    if node is ScrollContainer:
        call_deferred("register_scroll_area", node as ScrollContainer)


func _on_node_removed(node: Node) -> void:
    if node is ScrollContainer:
        _registered.erase(node.get_instance_id())
    if node == _active_scroll or node == _pressed_button:
        _cancel_active_gesture()


func _scan_current_scene() -> void:
    var scene := get_tree().current_scene
    if scene == null:
        return
    _scan_node(scene)


func _scan_node(node: Node) -> void:
    if node is ScrollContainer:
        register_scroll_area(node as ScrollContainer)
    for child in node.get_children():
        _scan_node(child)


func register_scroll_area(scroll: ScrollContainer) -> void:
    if scroll == null or not is_instance_valid(scroll):
        return

    _registered[scroll.get_instance_id()] = scroll
    scroll.follow_focus = true
    scroll.set_meta("drag_safe_scroll_area", true)


func _cleanup_registered() -> void:
    var stale: Array[int] = []
    for key in _registered.keys():
        var scroll = _registered[key]
        if scroll == null or not is_instance_valid(scroll):
            stale.append(int(key))
    for key in stale:
        _registered.erase(key)


func _input(event: InputEvent) -> void:
    if event is InputEventMouseButton:
        var mouse_button := event as InputEventMouseButton
        if mouse_button.button_index != MOUSE_BUTTON_LEFT:
            return
        if mouse_button.pressed:
            _begin_pointer(mouse_button.position, false, -1)
        else:
            _end_pointer(false, -1)
        return

    if event is InputEventMouseMotion:
        if _active_scroll == null or _using_touch:
            return
        var motion := event as InputEventMouseMotion
        if (motion.button_mask & MOUSE_BUTTON_MASK_LEFT) == 0:
            return
        _move_pointer(motion.position)
        return

    if event is InputEventScreenTouch:
        var touch := event as InputEventScreenTouch
        if touch.pressed:
            _begin_pointer(touch.position, true, touch.index)
        else:
            _end_pointer(true, touch.index)
        return

    if event is InputEventScreenDrag:
        var drag := event as InputEventScreenDrag
        if (
            _active_scroll == null
            or not _using_touch
            or drag.index != _touch_index
        ):
            return
        _move_pointer(drag.position)


func _begin_pointer(
    position: Vector2,
    using_touch: bool,
    touch_index: int
) -> void:
    if _active_scroll != null:
        return

    var picked := _pick_scroll_and_button(position)
    if picked.is_empty():
        return

    _active_scroll = picked["scroll"] as ScrollContainer
    _pressed_button = picked["button"] as BaseButton
    _press_position = position
    _last_position = position
    _dragging = false
    _using_touch = using_touch
    _touch_index = touch_index


func _move_pointer(position: Vector2) -> void:
    if (
        _active_scroll == null
        or not is_instance_valid(_active_scroll)
        or _pressed_button == null
        or not is_instance_valid(_pressed_button)
    ):
        _cancel_active_gesture()
        return

    var delta := position - _last_position
    var just_started := false

    if not _dragging:
        if position.distance_to(_press_position) < DRAG_THRESHOLD_PX:
            _last_position = position
            return

        _dragging = true
        just_started = true
        _pressed_button.disabled = true

    if just_started:
        # Include the movement that crossed the dead-zone so the list does not
        # feel like it sticks for the first few pixels of a drag.
        delta = position - _press_position

    if (
        _active_scroll.horizontal_scroll_mode
        != ScrollContainer.SCROLL_MODE_DISABLED
    ):
        _active_scroll.scroll_horizontal -= int(round(delta.x))

    if (
        _active_scroll.vertical_scroll_mode
        != ScrollContainer.SCROLL_MODE_DISABLED
    ):
        _active_scroll.scroll_vertical -= int(round(delta.y))

    _last_position = position
    get_viewport().set_input_as_handled()


func _end_pointer(using_touch: bool, touch_index: int) -> void:
    if _active_scroll == null:
        return
    if using_touch != _using_touch:
        return
    if using_touch and touch_index != _touch_index:
        return

    var button := _pressed_button
    var was_dragging := _dragging

    _active_scroll = null
    _pressed_button = null
    _dragging = false
    _using_touch = false
    _touch_index = -1

    if was_dragging:
        # Swallow the release that belongs to the drag. The button remains
        # disabled for the rest of this input dispatch and is restored deferred,
        # so the next distinct press is the earliest it can activate again.
        get_viewport().set_input_as_handled()
        if button != null and is_instance_valid(button):
            call_deferred("_restore_button_after_drag", button)


func _restore_button_after_drag(button: BaseButton) -> void:
    if button != null and is_instance_valid(button):
        button.disabled = false


func _cancel_active_gesture() -> void:
    var button := _pressed_button
    _active_scroll = null
    _pressed_button = null
    _dragging = false
    _using_touch = false
    _touch_index = -1

    if button != null and is_instance_valid(button) and button.disabled:
        call_deferred("_restore_button_after_drag", button)


func _pick_scroll_and_button(position: Vector2) -> Dictionary:
    var best_scroll: ScrollContainer = null
    var best_button: BaseButton = null
    var best_depth := -1

    for value in _registered.values():
        if not (value is ScrollContainer):
            continue

        var scroll := value as ScrollContainer
        if (
            not is_instance_valid(scroll)
            or not scroll.is_visible_in_tree()
            or not scroll.get_global_rect().has_point(position)
        ):
            continue

        var button := _find_button_at(scroll, position)
        if button == null:
            # Blank-space drags are left to ScrollContainer's normal behavior.
            # This helper only intervenes in the failure case where a button
            # would otherwise consume the drag and later fire on release.
            continue

        var depth := _node_depth(scroll)
        if depth > best_depth:
            best_depth = depth
            best_scroll = scroll
            best_button = button

    if best_scroll == null or best_button == null:
        return {}

    return {
        "scroll": best_scroll,
        "button": best_button,
    }


func _find_button_at(node: Node, position: Vector2) -> BaseButton:
    var children := node.get_children()
    for index in range(children.size() - 1, -1, -1):
        var child = children[index]
        if child is CanvasItem and not (child as CanvasItem).is_visible_in_tree():
            continue
        var nested := _find_button_at(child, position)
        if nested != null:
            return nested

    if node is BaseButton:
        var button := node as BaseButton
        if (
            not button.disabled
            and button.mouse_filter != Control.MOUSE_FILTER_IGNORE
            and button.get_global_rect().has_point(position)
        ):
            return button

    return null


func _node_depth(node: Node) -> int:
    var depth := 0
    var current := node.get_parent()
    while current != null:
        depth += 1
        current = current.get_parent()
    return depth


func _ensure_simulation_menu_scroll() -> void:
    var scene := get_tree().current_scene
    if not _is_simulation_scene(scene):
        return

    var menu_value = scene.get("menu_content")
    if not (menu_value is VBoxContainer) or not is_instance_valid(menu_value):
        return

    var menu := menu_value as VBoxContainer
    if menu.get_parent() is ScrollContainer:
        return

    var parent := menu.get_parent()
    if parent == null:
        return

    var scroll := ScrollContainer.new()
    scroll.name = "FlightMenuScroll"
    scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
    scroll.follow_focus = true

    parent.remove_child(menu)
    parent.add_child(scroll)
    scroll.add_child(menu)
    menu.size_flags_horizontal = Control.SIZE_EXPAND_FILL

    register_scroll_area(scroll)


func _shorten_simulation_debug_note() -> void:
    var scene := get_tree().current_scene
    if not _is_simulation_scene(scene):
        return

    var menu_value = scene.get("menu_content")
    if not (menu_value is VBoxContainer) or not is_instance_valid(menu_value):
        return

    _shorten_debug_note_recursive(menu_value as Node)


func _shorten_debug_note_recursive(node: Node) -> void:
    if node is Label:
        var label := node as Label
        if label.text.begins_with(DEBUG_NOTE_PREFIX):
            label.text = DEBUG_NOTE_TEXT

    for child in node.get_children():
        _shorten_debug_note_recursive(child)


func _is_simulation_scene(scene: Node) -> bool:
    if scene == null:
        return false
    var script = scene.get_script()
    return (
        script != null
        and str(script.resource_path) == SIMULATION_SCRIPT_PATH
    )
