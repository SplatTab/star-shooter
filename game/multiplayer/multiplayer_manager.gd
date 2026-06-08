extends Node

const player_scene = preload("res://entities/player/player.tscn")
const host := "ws://localhost:9081"
const room := "testroom"

func _ready() -> void:
	MultiplayerClient.lobby_joined.connect(_lobby_joined)
	MultiplayerClient.lobby_sealed.connect(_lobby_sealed)
	MultiplayerClient.connected.connect(_connected)
	MultiplayerClient.disconnected.connect(_disconnected)

	multiplayer.connected_to_server.connect(_mp_server_connected)
	multiplayer.connection_failed.connect(_mp_server_disconnect)
	multiplayer.server_disconnected.connect(_mp_server_disconnect)
	multiplayer.peer_connected.connect(_mp_peer_connected)
	multiplayer.peer_disconnected.connect(_mp_peer_disconnected)
	MultiplayerClient.start(host, "quickPlay")

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
	get_tree().reload_current_scene()


func _mp_peer_connected(id: int) -> void:
	_log("[Multiplayer] Peer %d connected" % id)
	add_player(id)

func _mp_peer_disconnected(id: int) -> void:
	_log("[Multiplayer] Peer %d disconnected" % id)
	remove_player(id)


func _connected(id: int, use_mesh: bool) -> void:
	_log("[Signaling] Server connected with ID: %d. Mesh: %s" % [id, use_mesh])
	add_player(id)


func _disconnected() -> void:
	_log("[Signaling] Server disconnected: %d - %s" % [MultiplayerClient.code, MultiplayerClient.reason])
	get_tree().reload_current_scene()


func _lobby_joined(lobby: String) -> void:
	_log("[Signaling] Joined lobby %s" % lobby)

func _lobby_sealed() -> void:
	_log("[Signaling] Lobby has been sealed")

func _on_quick_play_pressed() -> void:
	MultiplayerClient.start(host, "quickPlay")

func _on_host_lobby_pressed() -> void:
	MultiplayerClient.start(host)

func _on_disconnect_pressed() -> void:
	MultiplayerClient.stop()
	get_tree().reload_current_scene()
