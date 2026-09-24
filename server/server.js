const http = require('http');
const WebSocket = require('ws');
const crypto = require('crypto');

const MAX_PEERS = 4096;
const MAX_LOBBIES = 1024;

const PORT = Number.isInteger(Number.parseInt(process.env.PORT, 10))
	? Number.parseInt(process.env.PORT, 10)
	: 9081;

const CLOUDFLARE_TURN_KEY_ID = process.env.CF_TURN_KEY_ID || "your_turn_key_id_here";
const CLOUDFLARE_TURN_KEY_SECRET = process.env.CF_TURN_KEY_SECRET || "your_turn_key_secret_here";

const ALFNUM = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

const NO_LOBBY_TIMEOUT = 1000;
const SEAL_CLOSE_TIMEOUT = 10000;
const PING_INTERVAL = 10000;

const STR_NO_LOBBY = 'Have not joined lobby yet';
const STR_ONLY_HOST_CAN_SEAL = 'Only host can seal the lobby';
const STR_SEAL_COMPLETE = 'Seal complete';
const STR_TOO_MANY_LOBBIES = 'Too many lobbies open, disconnecting';
const STR_ALREADY_IN_LOBBY = 'Already in a lobby';
const STR_LOBBY_IS_SEALED = 'Lobby is sealed';
const STR_INVALID_FORMAT = 'Invalid message format';
const STR_NEED_LOBBY = 'Invalid message when not in a lobby';
const STR_SERVER_ERROR = 'Server error, lobby not found';
const STR_INVALID_DEST = 'Invalid destination';
const STR_INVALID_CMD = 'Invalid command';
const STR_TOO_MANY_PEERS = 'Too many peers connected';
const STR_INVALID_TRANSFER_MODE = 'Invalid transfer mode, must be text';

const CMD = {
	JOIN: 0,
	ID: 1,
	PEER_CONNECT: 2,
	PEER_DISCONNECT: 3,
	OFFER: 4,
	ANSWER: 5,
	CANDIDATE: 6,
	SEAL: 7,
	MIGRATE_HOST: 8,
	ICE_CONFIG: 9, // Added new structural command key to pass to Godot
};

function randomInt(low, high) {
	return Math.floor(Math.random() * (high - low + 1) + low);
}

function randomId() {
	return Math.abs(new Int32Array(crypto.randomBytes(4).buffer)[0]);
}

function randomSecret() {
	let out = '';
	for (let i = 0; i < 16; i++) {
		out += ALFNUM[randomInt(0, ALFNUM.length - 1)];
	}
	return out;
}

function ProtoMessage(type, id, data) {
	return JSON.stringify({
		'type': type,
		'id': id,
		'data': data || '',
	});
}

/**
 * Generates dynamic, short-lived TURN credentials for Cloudflare Realtime.
 * Uses Time-As-Username tracking tracking spec (RFC 5766).
 */
function getCloudflareTurnCredentials() {
	// Set expiration to 24 hours from right now (expressed in Unix epoch seconds)
	const expiryUnixTime = Math.floor(Date.now() / 1000) + 86400;
	const username = `${expiryUnixTime}:${CLOUDFLARE_TURN_KEY_ID}`;
	
	// Sign the token username utilizing standard HMAC-SHA1 encryption hashing
	const hmac = crypto.createHmac('sha1', CLOUDFLARE_TURN_KEY_SECRET);
	hmac.update(username);
	const credential = hmac.digest('base64');

	// Standard structural format required by WebRTCPeerConnection.initialize()
	return [
		{ 
			urls: ["stun:stun.cloudflare.com:3478"] 
		},
		{
			// The browser will try these endpoints in order using these credentials
			urls: [
				"turn:turn.cloudflare.com:3478?transport=udp",
				"turn:turn.cloudflare.com:3478?transport=tcp",
				"turns:turn.cloudflare.com:5349?transport=tcp" // Encrypted fallback
			],
			username: username,
			credential: credential
		}
	];
}

const server = http.createServer((req, res) => {
	res.writeHead(200, { 'Content-Type': 'text/plain' });
	res.end('Hello WebRTC Server\n');
});

const wss = new WebSocket.Server({ server });

server.listen(PORT, '0.0.0.0', () => {
	console.log(`HTTP/WebSocket core wrapper running on interface 0.0.0.0:${PORT}`);
});

wss.on('listening', () => {
	console.log(`WebSocket signaling server listening on port ${PORT}`);
});

wss.on('error', (err) => {
	if (err.code === 'EADDRINUSE') {
		console.error(`Port ${PORT} is already in use. Set PORT to another value.`);
		process.exit(1);
	}
	throw err;
});

class ProtoError extends Error {
	constructor(code, message) {
		super(message);
		this.code = code;
	}
}

class Peer {
	constructor(id, ws) {
		this.id = id;
		this.ws = ws;
		this.lobby = '';
		this.timeout = setTimeout(() => {
			if (!this.lobby) {
				ws.close(4000, STR_NO_LOBBY);
			}
		}, NO_LOBBY_TIMEOUT);
	}
}

class Lobby {
	constructor(name, host, mesh) {
		this.name = name;
		this.host = host;
		this.mesh = mesh;
		this.peers = [];
		this.sealed = false;
		this.closeTimer = -1;
	}

	getPeerId(peer) {
		if (this.host === peer.id) {
			return 1;
		}
		return peer.id;
	}

	join(peer) {
		const assigned = this.getPeerId(peer);
		peer.ws.send(ProtoMessage(CMD.ID, assigned, this.mesh ? 'true' : ''));
		this.peers.forEach((p) => {
			p.ws.send(ProtoMessage(CMD.PEER_CONNECT, assigned));
			peer.ws.send(ProtoMessage(CMD.PEER_CONNECT, this.getPeerId(p)));
		});
		this.peers.push(peer);
	}

	find_new_host() {
		if (this.peers.length === 0) {
			return -1;
		}
		return this.peers[1];
	}

	leave(peer) {
		const idx = this.peers.findIndex((p) => peer === p);
		if (idx === -1) {
			return false;
		}
		const assigned = this.getPeerId(peer);
		const close = assigned === 1;
		const newLobby = randomSecret();

		this.peers.forEach((p) => {
			if (close) {
				p.ws.send(ProtoMessage(CMD.MIGRATE_HOST, 1, newLobby));
			} else {
				p.ws.send(ProtoMessage(CMD.PEER_DISCONNECT, assigned));
			}
		});
		this.peers.splice(idx, 1);
		if (close && this.closeTimer >= 0) {
			clearTimeout(this.closeTimer);
			this.closeTimer = -1;
		}
		return close;
	}

	seal(peer) {
		if (peer.id !== this.host) {
			throw new ProtoError(4000, STR_ONLY_HOST_CAN_SEAL);
		}
		this.sealed = true;
		this.peers.forEach((p) => {
			p.ws.send(ProtoMessage(CMD.SEAL, 0));
		});
		console.log(`Peer ${peer.id} sealed lobby ${this.name} with ${this.peers.length} peers`);
		this.closeTimer = setTimeout(() => {
			this.peers.forEach((p) => {
				p.ws.close(1000, STR_SEAL_COMPLETE);
			});
		}, SEAL_CLOSE_TIMEOUT);
	}
}

const lobbies = new Map();
let peersCount = 0;

function joinLobby(peer, pLobby, mesh) {
	let lobbyName = pLobby;
	if (peer.lobby) {
		throw new ProtoError(4000, STR_ALREADY_IN_LOBBY);
	}

	if (lobbyName === 'quickPlay') {
		lobbyName = '';
		const openLobby = Array.from(lobbies.entries())
			.find(([, lobby]) => !lobby.sealed && lobby.peers.length < MAX_PEERS);
		if (openLobby) {
			lobbyName = openLobby[0];
		}
	}

	if (lobbyName === '') {
		lobbyName = randomSecret();
	}

	if (!lobbies.has(lobbyName)) {
		if (lobbies.size >= MAX_LOBBIES) {
			throw new ProtoError(4000, STR_TOO_MANY_LOBBIES);
		}
		lobbies.set(lobbyName, new Lobby(lobbyName, peer.id, mesh));
		console.log(`Peer ${peer.id} created lobby ${lobbyName}`);
		console.log(`Open lobbies: ${lobbies.size}`);
	}

	const lobby = lobbies.get(lobbyName);

	if (lobby.sealed) {
		throw new ProtoError(4000, STR_LOBBY_IS_SEALED);
	}
	peer.lobby = lobbyName;
	console.log(`Peer ${peer.id} joining lobby ${lobbyName} with ${lobby.peers.length} peers`);
	lobby.join(peer);
	
	// Send confirmation message to client
	peer.ws.send(ProtoMessage(CMD.JOIN, 0, lobbyName));

	// FIREWALL TRAVERSAL: Inject secure short-lived Cloudflare credentials to the peer right after joining
	try {
		const iceServers = getCloudflareTurnCredentials();
		peer.ws.send(ProtoMessage(CMD.ICE_CONFIG, 0, JSON.stringify(iceServers)));
	} catch (err) {
		console.error("Failed to generate Cloudflare configurations:", err.message);
	}
}

function parseMsg(peer, msg) {
	let json = null;
	try {
		json = JSON.parse(msg);
	} catch (e) {
		throw new ProtoError(4000, STR_INVALID_FORMAT);
	}

	const type = typeof (json['type']) === 'number' ? Math.floor(json['type']) : -1;
	const id = typeof (json['id']) === 'number' ? Math.floor(json['id']) : -1;
	const data = typeof (json['data']) === 'string' ? json['data'] : '';

	if (type < 0 || id < 0) {
		throw new ProtoError(4000, STR_INVALID_FORMAT);
	}

	if (type === CMD.JOIN) {
		joinLobby(peer, data, id === 0);
		return;
	}

	if (!peer.lobby) {
		throw new ProtoError(4000, STR_NEED_LOBBY);
	}
	const lobby = lobbies.get(peer.lobby);
	if (!lobby) {
		throw new ProtoError(4000, STR_SERVER_ERROR);
	}

	if (type === CMD.SEAL) {
		lobby.seal(peer);
		return;
	}

	if (type === CMD.OFFER || type === CMD.ANSWER || type === CMD.CANDIDATE) {
		let destId = id;
		if (id === 1) {
			destId = lobby.host;
		}
		const dest = lobby.peers.find((e) => e.id === destId);
		if (!dest) {
			throw new ProtoError(4000, STR_INVALID_DEST);
		}
		dest.ws.send(ProtoMessage(type, lobby.getPeerId(peer), data));
		return;
	}
	throw new ProtoError(4000, STR_INVALID_CMD);
}

wss.on('connection', (ws) => {
	if (peersCount >= MAX_PEERS) {
		ws.close(4000, STR_TOO_MANY_PEERS);
		return;
	}
	peersCount++;
	const id = randomId();
	const peer = new Peer(id, ws);

	ws.on('message', (message) => {
		const messageString = Buffer.isBuffer(message) ? message.toString('utf8') : message;
		
		if (typeof messageString !== 'string') {
			ws.close(4000, STR_INVALID_TRANSFER_MODE);
			return;
		}
		try {
			parseMsg(peer, messageString);
		} catch (e) {
			const code = e.code || 4000;
			console.log(`Error parsing message from ${id}: ${e.message}`);
			ws.close(code, e.message);
		}
	});

	ws.on('close', (code, reason) => {
		peersCount--;
		console.log(`Connection with peer ${peer.id} closed `
			+ `with reason ${code}: ${reason}`);
		if (peer.lobby && lobbies.has(peer.lobby)
			&& lobbies.get(peer.lobby).leave(peer)) {
			lobbies.delete(peer.lobby);
			console.log(`Deleted lobby ${peer.lobby}`);
			console.log(`Open lobbies: ${lobbies.size}`);
			peer.lobby = '';
		}
		if (peer.timeout >= 0) {
			clearTimeout(peer.timeout);
			peer.timeout = -1;
		}
	});
	ws.on('error', (error) => {
		console.error(error);
	});
});

const interval = setInterval(() => { // eslint-disable-line no-unused-vars
	wss.clients.forEach((ws) => {
		ws.ping();
	});
}, PING_INTERVAL);
