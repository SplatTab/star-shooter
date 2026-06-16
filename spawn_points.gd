class_name SpawnPoints
extends Node

func _ready() -> void:
	Game.spawn_points = self

func get_random_spawn() -> Vector2:
	var spawn_points = get_children()
	if spawn_points.size() == 0:
		return Vector2.ZERO
	var random_index = randi() % spawn_points.size()
	return spawn_points[random_index].position + Vector2(randf_range(-30, 30), randf_range(-30, 30))