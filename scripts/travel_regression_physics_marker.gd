extends Node

# Bracket the entire physics-script callback interval with the late probe.
var probe: Node


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    process_physics_priority = -950000


func _physics_process(_delta: float) -> void:
    if probe != null and is_instance_valid(probe):
        probe.call("_start_physics_tick")
