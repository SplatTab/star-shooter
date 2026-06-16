class_name BaseBullet
extends Node2D

@onready var sprite = $Sprite2D
@export var impact_scene: PackedScene
@export var damage: int = 1
@export var knockback: float = 150
@export var bullet_speed: float = 500
@export var damage_falloff_start: float = 25
@export var damage_falloff_end: float = 250
@export var damage_falloff_multiplier: float = .8
@export var lifetime: float = 5.0
var initial_position: Vector2
var owner_id: int = -1

func _ready() -> void:
	initial_position = global_position
	get_tree().create_timer(lifetime).timeout.connect(func() -> void:
		pop(global_position)
	)
	
func pop(hit_pos: Vector2) -> void:
	if impact_scene:
		var impact = impact_scene.instantiate() as Node2D
		impact.global_position = hit_pos
		get_tree().current_scene.add_child(impact, true)
		impact.emitting = true
		get_tree().create_timer(0.25).timeout.connect(impact.queue_free)

	queue_free()

func handle_hit(body: Node2D) -> void:
	if body.is_in_group("players"):
		if body.get_multiplayer_authority() == owner_id:
			return # Don't hit the shooter

		if multiplayer.is_server():
			var knockback_vector = Vector2(knockback, 0).rotated(rotation)
			body.rpc("hurt", damage, knockback_vector)

	pop(global_position)

func _physics_process(delta: float) -> void:
	var forward_vector = Vector2.RIGHT.rotated(rotation) # Adjust starting direction if needed
	var movement = forward_vector * bullet_speed * delta
	
	var space_state = get_world_2d().direct_space_state
	var query = PhysicsRayQueryParameters2D.create(global_position, global_position + movement)
	
	query.exclude = [self] 

	var result = space_state.intersect_ray(query)
	
	if result:
		var distance = initial_position.distance_to(result.position)
		if distance > damage_falloff_start:
			var falloff_range = damage_falloff_end - damage_falloff_start
			var excess_distance = min(distance - damage_falloff_start, falloff_range)
			var falloff_factor = 1.0 - (excess_distance / falloff_range) * damage_falloff_multiplier
			damage = int(damage * falloff_factor)

			damage = max(damage, 1)

		global_position = result.position # Snaps the bullet to the impact point
		handle_hit(result.collider)
	else:
		# Safe to move forward normally
		global_position += movement