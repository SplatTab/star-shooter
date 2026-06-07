extends Node

const player_scene = preload("res://entities/player/player.tscn")
var peer = ENetMultiplayerPeer.new()
const PORT = 12345

func start_server():
	peer.create_server(PORT)
	multiplayer.multiplayer_peer = peer
	peer.peer_connected.connect(peer_connected)
	peer.peer_disconnected.connect(peer_disconnected)
	print("Server started on port %d" % PORT)

func join_server(address):
	peer.create_client(address, PORT)
	multiplayer.multiplayer_peer = peer
	peer.peer_connected.connect(peer_connected)
	peer.peer_disconnected.connect(peer_disconnected)
	multiplayer.server_disconnected.connect(func():

		get_tree().reload_current_scene()
	)
	print("Joining server at %s:%d" % [address, PORT])

var networked = false
func _process(_delta):
	if networked:
		return  # Already connected, no need to check for input
	if Input.is_key_pressed(KEY_S):
		start_server()
		add_player(1)
		networked = true
	elif Input.is_key_pressed(KEY_J):
		join_server("localhost")  # Change to server IP if not local
		networked = true

func peer_connected(id):
	add_player(id)

func peer_disconnected(id):
	print("Player disconnected: ", id)
	var player_node = get_node_or_null(str(id))
	if player_node:
		player_node.queue_free()

func add_player(peer_id):
	if not multiplayer.is_server():
		return
	print("Player connected: ", peer_id)
	var player = player_scene.instantiate()
	player.name = str(peer_id)
	get_tree().current_scene.add_child(player)
