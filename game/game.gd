extends Node

@onready var camera = get_viewport().get_camera_2d()
@onready var virtual_crosshair_position: Vector2 = get_viewport().get_visible_rect().size * 0.5
@onready var crosshair: Sprite2D = $CanvasLayer/Crosshair
@onready var label: Label = $CanvasLayer/Label

func get_world_crosshair_position() -> Vector2:
	return get_viewport().get_canvas_transform().affine_inverse() * virtual_crosshair_position

func _input(event: InputEvent) -> void:
	# Release mouse with the Escape key
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		
	# Capture mouse when the window is clicked
	elif event is InputEventMouseButton and event.pressed:
		if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		return  # Don't move hand if mouse isn't captured

	if event is InputEventMouseMotion:
		# Why is event.position always 320,180
		virtual_crosshair_position += event.relative
		var screen_size = get_viewport().get_visible_rect().size
		virtual_crosshair_position.x = clamp(virtual_crosshair_position.x, 0, screen_size.x)
		virtual_crosshair_position.y = clamp(virtual_crosshair_position.y, 0, screen_size.y)

		crosshair.global_position = Vector2(virtual_crosshair_position.x, virtual_crosshair_position.y)

func _physics_process(_delta: float) -> void:
	if not multiplayer.multiplayer_peer:
		return
	label.text = "FPS: %d\nPlayers: %d Is Host?: %s My Remote Id: %d" % [Engine.get_frames_per_second(), multiplayer.get_peers().size(), multiplayer.is_server(), multiplayer.get_unique_id()]