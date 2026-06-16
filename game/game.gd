extends Node

var spawn_points: SpawnPoints
@onready var camera = get_viewport().get_camera_2d()
@onready var virtual_crosshair_position: Vector2 = get_viewport().get_visible_rect().size * 0.5
@onready var crosshair: Sprite2D = $CanvasLayer/Crosshair

func get_world_crosshair_position() -> Vector2:
	return get_viewport().get_canvas_transform().affine_inverse() * virtual_crosshair_position

func _input(event: InputEvent) -> void:
	# Release mouse with the Escape key
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		
	# Capture mouse when the window is clicked
	elif event is InputEventMouseButton and event.pressed:
		if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
			Input.mouse_mode = Input.MOUSE_MODE_HIDDEN

	if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		return  # Don't move hand if mouse isn't captured

	if event is InputEventMouseMotion:
		# Why is event.position always 320,180
		virtual_crosshair_position += event.relative
		var screen_size = get_viewport().get_visible_rect().size
		virtual_crosshair_position.x = clamp(virtual_crosshair_position.x, 0, screen_size.x)
		virtual_crosshair_position.y = clamp(virtual_crosshair_position.y, 0, screen_size.y)

		crosshair.global_position = Vector2(virtual_crosshair_position.x, virtual_crosshair_position.y)

@onready var health_bar: ProgressBar = $CanvasLayer/HealthBar
@onready var damage_bar: ProgressBar = $CanvasLayer/HealthBar/DamageBar
@onready var damage_bar_timer: Timer = $CanvasLayer/HealthBar/DamageBarTimer

func update_health_bar(new_health: int) -> void:
	var old_health = health_bar.value
	health_bar.value = new_health

	if new_health < old_health:
		damage_bar_timer.start()
	else:
		damage_bar.value = new_health

func init_health_bar(_health: int) -> void:
	health_bar.max_value = _health
	health_bar.value = _health
	damage_bar.max_value = _health
	damage_bar.value = _health

func _on_damage_bar_timer_timeout() -> void:
	var damage_bar_tween = damage_bar.create_tween()
	damage_bar_tween.tween_property(damage_bar, "value", health_bar.value, 0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

# @onready var label: Label = $CanvasLayer/Label
# func _physics_process(_delta: float) -> void:
# 	if not multiplayer.multiplayer_peer:
# 		return
# 	label.text = "FPS: %d\nPlayers: %d Is Host?: %s My Remote Id: %d" % [Engine.get_frames_per_second(), multiplayer.get_peers().size(), multiplayer.is_server(), multiplayer.get_unique_id()]
