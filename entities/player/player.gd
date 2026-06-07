extends CharacterBody2D


const SPEED = 100 
const JUMP_HEIGHT = 25
const JUMP_COOLDOWN = 0.2
const TIME_TO_JUMP = .2
const JUMP_ANTICIPATION_TIME = 0.05
const JUMP_STRETCH_TIME = 0.07
const LAND_RECOVERY_TIME = 0.06
const JUMP_SQUASH_SCALE = Vector2(1.12, 0.88)
const JUMP_STRETCH_SCALE = Vector2(0.88, 1.12)
const LAND_SQUASH_SCALE = Vector2(1.35, 0.8)
const GRAVITY = (2 * JUMP_HEIGHT) / pow(TIME_TO_JUMP, 2)
var hp = 4
var speed : float = SPEED
var is_stunned: bool = false
var can_jump: bool = false
var is_jumping: bool = false
var is_dead: bool = false
@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var hand: Sprite2D = $Hand
@onready var hit_sound: AudioStreamPlayer2D = $HitSound
@onready var blood_particles: CPUParticles2D = $BloodParticles

func _enter_tree() -> void:
	set_multiplayer_authority(name.to_int())

func _ready():
	blood_particles.emitting = true
	if is_multiplayer_authority():
		get_viewport().get_camera_2d().reparent(self)

func die() -> void:
	pass
	# remove_from_group("players")
	# is_dead = true
	# hand.visible = false # Hide hand when player dies
	# sprite.play("death")
	# blood_particles.emitting = true
	# blood_particles.one_shot = false
	# blood_particles.position = Vector2(0, 5)
	# hand.visible = false
	# hand.process_mode = Node.PROCESS_MODE_DISABLED
	# Global.hud.death_screen()

func knockback_and_stun(knockback: Vector2, stun_color: Color = Color.WHITE) -> void:
	is_stunned = true
	if knockback:
		velocity = knockback
	if stun_color != Color.WHITE:
		sprite.modulate = stun_color

	get_tree().create_timer(0.1).timeout.connect(func() -> void:
		sprite.modulate = Color.WHITE
		is_stunned = false
	)


@rpc("any_peer", "call_local", "reliable")
func hurt(damage: int, knockback: Vector2 = Vector2.ZERO) -> void:
	if is_dead or is_stunned: return

	if damage > 0:
		hp -= damage
		hit_sound.play()
		if hp <= 0 and not is_dead:
			die()
		blood_particles.emitting = true

	knockback_and_stun(knockback, Color(1, 0.5, 0.5))
	
	return

func _physics_process(_delta: float) -> void:
	if not is_multiplayer_authority():
		return  # Only process input on the authoritative instance
	if is_dead: return
	var dirx := Input.get_axis("left", "right")
	var diry := Input.get_axis("up", "down")
	var direction = Vector2(dirx, diry).normalized()

	if not is_stunned and not is_jumping:
		var desired_animation = "idle"

		if direction:
			desired_animation = "walk_ad" if diry == 0 else "walk_s" if diry > 0 else "walk_w"
			velocity = direction * speed
			sprite.flip_h = dirx < 0 
		else:
			velocity.x = move_toward(velocity.x, 0, speed)
			velocity.y = move_toward(velocity.y, 0, speed)
		
		if sprite.animation != desired_animation:
			sprite.play(desired_animation)

	move_and_slide()
