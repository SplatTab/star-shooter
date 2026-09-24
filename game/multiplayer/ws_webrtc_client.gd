extends Node

enum Message {
	JOIN,
	ID,
	PEER_CONNECT,
	PEER_DISCONNECT,
	OFFER,
	ANSWER,
	CANDIDATE,
	SEAL,
	MIGRATE_HOST,
	ICE_CONFIG, # 1. Added type 9 matching your new Node.js server setup
}

@export var autojoin: bool = true
@export var lobby: String = ""  # Will create a new lobby if empty.
@export var mesh: bool = true  # Will use the lobby host as relay otherwise.

# 2. Dynamic tracking array to store Cloudflare servers when received from backend
var ice_servers_cache: Array = [ { "urls": ["stun:stun.l.google.com:19302"] } ]

var ws := WebSocketPeer.new()
var code := 1000
var reason: String = "Unknown"
var old_state := WebSocketPeer.STATE_CLOSED
@export var auto_reconnect: bool = true
@export var reconnect_delay: float = 3.0
var current_url: String = ""
var reconnect_timer: float = 0.0

signal lobby_joined(lobby: String)
signal connected(id: int, use_mesh: bool)
signal disconnected()
signal peer_connected(id: int)
signal peer_disconnected(id: int)
signal offer_received(id: int, offer: String)
signal answer_received(id: int, answer: String)
signal candidate_received(id: int, mid: String, index: int, sdp: String)
signal migrate_host(newLobby: String)
signal lobby_sealed()


func connect_to_url(url: String) -> void:
	current_url = url
	reconnect_timer = 0.0 # Reset timer on manual connect
	close()
	code = 1000
	reason = "Unknown"
	ws.connect_to_url(url)



func close() -> void:
	ws.close()

func _process(delta: float) -> void:
	ws.poll()
	var state := ws.get_ready_state()
	if state != old_state and state == WebSocketPeer.STATE_OPEN and autojoin:
		join_lobby(lobby)
	while state == WebSocketPeer.STATE_OPEN and ws.get_available_packet_count():
		if not _parse_msg():
			print("Error parsing message from server.")
	if state != old_state and state == WebSocketPeer.STATE_CLOSED:
		code = ws.get_close_code()
		reason = ws.get_close_reason()
		disconnected.emit()

	# Handle auto-reconnection when closed
	if state == WebSocketPeer.STATE_CLOSED and auto_reconnect and current_url != "":
		reconnect_timer += delta
		if reconnect_timer >= reconnect_delay:
			print("[Network] Attempting to reconnect to: ", current_url)
			reconnect_timer = 0.0
			ws.connect_to_url(current_url) # Retry connection

	old_state = state


func _parse_msg() -> bool:
	var parsed: Dictionary = JSON.parse_string(ws.get_packet().get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("type") or not parsed.has("id") or \
		typeof(parsed.get("data")) != TYPE_STRING:
		return false

	var msg := parsed as Dictionary

	var type := int(msg.type)
	var src_id := int(msg.id)

	# 3. INTERCEPT SERVER CONFIGURATIONS:
	# Parse incoming Cloudflare network configurations and save them to memory immediately
	if type == Message.ICE_CONFIG:
		var parsed_ice = JSON.parse_string(msg.data)
		if typeof(parsed_ice) == TYPE_ARRAY:
			ice_servers_cache = parsed_ice
			print("[Network] Cloudflare ICE/TURN configurations synced safely.")
		return true # Intercepted and parsed successfully.

	elif type == Message.ID:
		connected.emit(src_id, msg.data == "true")
	elif type == Message.JOIN:
		lobby_joined.emit(msg.data)
	elif type == Message.SEAL:
		lobby_sealed.emit()
	elif type == Message.PEER_CONNECT:
		# Client connected.
		peer_connected.emit(src_id)
	elif type == Message.PEER_DISCONNECT:
		# Client connected.
		peer_disconnected.emit(src_id)
	elif type == Message.OFFER:
		# Offer received.
		offer_received.emit(src_id, msg.data)
	elif type == Message.ANSWER:
		# Answer received.
		answer_received.emit(src_id, msg.data)
	elif type == Message.CANDIDATE:
		# Candidate received.
		var candidate: PackedStringArray = msg.data.split("\n", false)
		if candidate.size() != 3:
			return false
		if not candidate[1].is_valid_int():
			return false
		candidate_received.emit(src_id, candidate[0], candidate[1].to_int(), candidate[2])
	elif type == Message.MIGRATE_HOST:
		migrate_host.emit(msg.data)
	else:
		return false

	return true  # Parsed.


func join_lobby(lobby_msg: String) -> Error:
	return _send_msg(Message.JOIN, 0 if mesh else 1, lobby_msg)


func seal_lobby() -> Error:
	return _send_msg(Message.SEAL, 0)


func send_candidate(id: int, mid: String, index: int, sdp: String) -> Error:
	return _send_msg(Message.CANDIDATE, id, "\n%s\n%d\n%s" % [mid, index, sdp])


func send_offer(id: int, offer: String) -> Error:
	return _send_msg(Message.OFFER, id, offer)


func send_answer(id: int, answer: String) -> Error:
	return _send_msg(Message.ANSWER, id, answer)


func _send_msg(type: int, id: int, data: String = "") -> Error:
	return ws.send_text(JSON.stringify({
		"type": type,
		"id": id,
		"data": data,
	}))
