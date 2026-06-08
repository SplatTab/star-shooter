extends Sprite2D

@onready var player = get_parent() as CharacterBody2D

const starting_gun := preload("res://entities/guns/shotgun/shotgun.tscn")
@export var current_gun: BaseGun

var last_hand_side := 1
const HAND_HIP_DISTANCE := 7
const HAND_HIP_VERTICAL_MAX := 4
const HAND_DEADZONE_X := 7

@rpc("authority", "call_local", "reliable")
func equip_gun(gun_scene: PackedScene = starting_gun) -> void:
	if current_gun:
		current_gun.queue_free()
		
	current_gun = gun_scene.instantiate() as BaseGun
	add_child(current_gun)

@rpc("authority", "call_local", "reliable")
func scale_gun(side) -> void:
	if current_gun:
		current_gun.scale.y = abs(current_gun.scale.y) * side

func move_hand(mouse_global: Vector2) -> void:
	# Keep hand close to hip and avoid rapid left/right flips near center
	var relative_mouse := Vector2(mouse_global - player.global_position)
	rotation = atan2(relative_mouse.y, relative_mouse.x)
	var side := last_hand_side
	if abs(relative_mouse.x) > HAND_DEADZONE_X:
		side = int(sign(relative_mouse.x))
		if side == 0:
			side = last_hand_side
		last_hand_side = side
		scale_gun.rpc(last_hand_side)


	var hip_offset := Vector2(HAND_HIP_DISTANCE * side, clamp(relative_mouse.y, -HAND_HIP_VERTICAL_MAX, HAND_HIP_VERTICAL_MAX))
	global_position = player.global_position + hip_offset.rotated(player.global_rotation)

func _process(_delta: float) -> void:
	if not multiplayer.multiplayer_peer or not player.is_multiplayer_authority():
		return

	move_hand(Game.get_world_crosshair_position())
	
	if Input.is_action_pressed("attack"):
		if current_gun == null: equip_gun.rpc()
		if current_gun.shoot():
			player.knockback_and_stun(Vector2(last_hand_side * -current_gun.kickback, 0).rotated(global_rotation) * last_hand_side)