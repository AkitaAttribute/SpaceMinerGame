extends Node3D

# Minimal simulation-like scene for testing asteroid renderer refresh.
var asteroids: Dictionary = {}
var asteroid_ring_ready := true
var asteroid_loading_in_progress := false
var mining_lasers: Array[Dictionary] = []
var tractor_chunks: Array[Dictionary] = []
