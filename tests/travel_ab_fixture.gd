extends Node3D

var asteroid_loading_in_progress := false
var asteroids: Dictionary = {}
var nearby_mining_asteroids: Dictionary = {}
var ship_collision_bindings: Array[Dictionary] = []
var mobile_turn_phase := "turn"
var yaw_rate := 0.12
var ship_body: CharacterBody3D


func _sync_ship_collision_transforms() -> void:
    pass
