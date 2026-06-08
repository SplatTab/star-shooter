extends CharacterBody2D


const SPEED = 100 
var hp = 4
var speed : float = SPEED
var is_stunned: bool = false
var is_dashing: bool = false
var is_dead: bool = false
@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var hand: Sprite2D = $Hand
@onready var hit_sound: AudioStreamPlayer2D = $HitSound
@onready var blood_particles: CPUParticles2D = $BloodParticles
@onready var walking_particles: CPUParticles2D = $WalkingParticles

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
	if is_stunned: return
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

@rpc("any_peer", "call_local", "reliable")
func create_ghost() -> void:
	var ghost = sprite.duplicate() as AnimatedSprite2D
	ghost.position = position
	ghost.modulate = Color(1, 1, 1, 0.5)
	get_parent().add_child(ghost)
	ghost.pause()
	ghost.animation = sprite.animation
	ghost.frame = sprite.frame
	ghost.flip_h = sprite.flip_h
	get_tree().create_timer(0.3).timeout.connect(func() -> void:
		ghost.queue_free()
	)

func _physics_process(_delta: float) -> void:
	if not is_multiplayer_authority():
		return  # Only process input on the authoritative instance
	if is_dead: return
	var dirx := Input.get_axis("left", "right")
	var diry := Input.get_axis("up", "down")
	var direction = Vector2(dirx, diry).normalized()
	var do_dash = Input.is_action_just_pressed("dash")
	if is_dashing:
		create_ghost.rpc()

	if not is_stunned:
		var desired_animation = "idle"

		if direction:
			walking_particles.emitting = true
			desired_animation = "walk_ad" if diry == 0 else "walk_s" if diry > 0 else "walk_w"
			if do_dash:
				is_dashing = true
				knockback_and_stun(direction * speed * 3, Color(1, 1, 0.5))
			else:
				is_dashing = false
				velocity = direction * speed
			sprite.flip_h = dirx < 0 
		else:
			walking_particles.emitting = false
			velocity.x = move_toward(velocity.x, 0, speed)
			velocity.y = move_toward(velocity.y, 0, speed)
		
		if sprite.animation != desired_animation:
			sprite.play(desired_animation)

	move_and_slide()
