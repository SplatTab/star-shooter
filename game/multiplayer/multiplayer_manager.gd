extends Node

const player_scene = preload("res://entities/player/player.tscn")
const room := "testroom"
var current_id: int = -1

func _ready() -> void:
	MultiplayerClient.lobby_joined.connect(_lobby_joined)
	MultiplayerClient.lobby_sealed.connect(_lobby_sealed)
	MultiplayerClient.connected.connect(_connected)
	MultiplayerClient.disconnected.connect(_disconnected)
	MultiplayerClient.migrate_host.connect(_migrate_host)

	multiplayer.connected_to_server.connect(_mp_server_connected)
	multiplayer.connection_failed.connect(_mp_server_disconnect)
	multiplayer.server_disconnected.connect(_mp_server_disconnect)
	multiplayer.peer_connected.connect(_mp_peer_connected)
	multiplayer.peer_disconnected.connect(_mp_peer_disconnected)
	MultiplayerClient.start("test")

func remove_player(id: int):
	var player_node = get_tree().current_scene.get_node_or_null(str(id))
	if player_node:
		print("Removing player %d" % id)
		player_node.queue_free()

func add_player(id: int):
	if get_node_or_null(str(id)):
		return
	var player = player_scene.instantiate()
	player.name = str(id)
	get_tree().current_scene.add_child(player)


func _log(msg: String) -> void:
	print(msg)

func _mp_server_connected() -> void:
	_log("[Multiplayer] Server connected (I am %d)" % MultiplayerClient.rtc_mp.get_unique_id())


func _mp_server_disconnect() -> void:
	_log("[Multiplayer] Server disconnected (I am %d)" % MultiplayerClient.rtc_mp.get_unique_id())


func _mp_peer_connected(id: int) -> void:
	_log("[Multiplayer] Peer %d connected" % id)
	add_player(id)

func _mp_peer_disconnected(id: int) -> void:
	_log("[Multiplayer] Peer %d disconnected" % id)
	remove_player(id)


func _connected(id: int, use_mesh: bool) -> void:
	_log("[Signaling] Server connected with ID: %d. Mesh: %s" % [id, use_mesh])
	if current_id != -1:
		var old_player = get_tree().current_scene.get_node_or_null(str(current_id))
		if old_player:
			old_player.set_multiplayer_authority(id)
			old_player.name = str(id)
			return
	add_player(id)
	current_id = id

func _migrate_host(id: int, newLobby: String) -> void:
	#Get rid of all players thats not their own since they will be re-added when they join the new lobby
	for player in get_tree().current_scene.get_children():
		if not player is Player:
			continue
			
		if not player.is_multiplayer_authority():
			player.queue_free()
	print("Host migrating to lobby %s old id is: %d" % [newLobby, current_id])
	get_tree().current_scene.process_mode = Node.PROCESS_MODE_DISABLED
	MultiplayerClient.stop()
	MultiplayerClient.start(newLobby)

	get_tree().current_scene.process_mode = Node.PROCESS_MODE_INHERIT

func _disconnected() -> void:
	_log("[Signaling] Server disconnected: %d - %s" % [MultiplayerClient.code, MultiplayerClient.reason])


func _lobby_joined(lobby: String) -> void:
	_log("[Signaling] Joined lobby %s" % lobby)

func _lobby_sealed() -> void:
	_log("[Signaling] Lobby has been sealed")
