class_name BaseGun
extends AnimatedSprite2D

@export var bullet_scene: PackedScene
@export var kickback: float = 100
@export var fire_rate: float = 1 # Seconds between shots
@onready var shoot_sound: AudioStreamPlayer2D = $ShootSound
@onready var muzzle_flash: MuzzleFlash = $MuzzleFlash
var can_shoot: bool = true

@onready var fire_point: Area2D = $FirePoint
var fire_point_blocked: bool = false
func _set_fire_point_blocked(extra_arg_0: bool) -> void:
	fire_point_blocked = extra_arg_0

#Everyone spawns bullet and simulates it locally
@rpc("any_peer", "call_local", "reliable")
func spawn_bullet() -> void: 
	var bullet = bullet_scene.instantiate()
	bullet.global_position = fire_point.global_position
	bullet.global_rotation = global_rotation
	bullet.owner_id = multiplayer.get_remote_sender_id()
	get_tree().current_scene.add_child(bullet, true)

@rpc("any_peer", "call_local", "unreliable")
func shoot_visuals() -> void:
	shoot_sound.play()
	muzzle_flash.flash()

# Returns shoot success (false if on cooldown or fire point blocked)
func shoot() -> bool:
	if not can_shoot or fire_point_blocked:
		return false

	spawn_bullet.rpc()
	shoot_visuals.rpc()
	can_shoot = false
	get_tree().create_timer(fire_rate).timeout.connect(func() -> void:
		can_shoot = true
	)
	return true