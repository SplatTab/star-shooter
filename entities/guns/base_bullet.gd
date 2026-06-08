class_name BaseBullet
extends Node2D

@onready var sprite = $Sprite2D
@export var impact_scene: PackedScene
@export var damage: int = 1
@export var knockback: float = 150
@export var bullet_speed: float = 500
@export var lifetime: float = 5.0
var owner_id: int = -1

func _ready() -> void:
	get_tree().create_timer(lifetime).timeout.connect(func() -> void:\
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

		global_position = result.position # Snaps the bullet to the impact point
		handle_hit(result.collider)
	else:
		# Safe to move forward normally
		global_position += movement