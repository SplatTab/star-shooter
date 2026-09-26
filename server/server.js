const http = require('http');
const WebSocket = require('ws');
const crypto = require('crypto');

const MAX_PEERS = 4096;
const MAX_LOBBIES = 1024;
const MAX_MESSAGE_SIZE = 64 * 1024;

const PORT = Number.isInteger(Number.parseInt(process.env.PORT, 10))
	? Number.parseInt(process.env.PORT, 10)
	: 9081;

const CLOUDFLARE_TURN_KEY_ID =
	process.env.CF_TURN_KEY_ID || 'your_turn_key_id_here';

const CLOUDFLARE_TURN_KEY_SECRET =
	process.env.CF_TURN_KEY_SECRET || 'your_turn_key_secret_here';

const ALFNUM =
	'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

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
	ICE_CONFIG: 9,
};


// ---------------------------------------------------------
// Utility
// ---------------------------------------------------------

function randomId() {
	return crypto.randomInt(1, 0x7fffffff);
}

function randomSecret() {
	let out = '';

	for (let i = 0; i < 16; i++) {
		const index = crypto.randomInt(0, ALFNUM.length);
		out += ALFNUM[index];
	}

	return out;
}

function ProtoMessage(type, id, data = '') {
	return JSON.stringify({
		type: type,
		id: id,
		data: data,
	});
}

function sendMessage(ws, type, id, data = '') {
	if (ws.readyState !== WebSocket.OPEN) {
		return false;
	}

	ws.send(ProtoMessage(type, id, data));
	return true;
}


// ---------------------------------------------------------
// Cloudflare TURN
// ---------------------------------------------------------

/**
 * Generates dynamic, short-lived TURN credentials
 * for Cloudflare Realtime via REST API.
 */
async function getCloudflareTurnCredentials() {
	try {
		const response = await fetch(
			`https://rtc.live.cloudflare.com/v1/turn/keys/${CLOUDFLARE_TURN_KEY_ID}/credentials/generate-ice-servers`,
			{
				method: 'POST',
				headers: {
					'Authorization': `Bearer ${CLOUDFLARE_TURN_KEY_SECRET}`,
					'Content-Type': 'application/json',
				},
				body: JSON.stringify({
					ttl: 3600,
				}),
			}
		);

		if (!response.ok) {
			throw new Error(
				`Cloudflare API returned HTTP ${response.status}`
			);
		}

		const data = await response.json();

		if (!Array.isArray(data.iceServers)) {
			throw new Error(
				'Cloudflare response did not contain a valid iceServers array'
			);
		}

		const supportedIceServers = [];

		for (const server of data.iceServers) {
			const urls = Array.isArray(server.urls)
				? server.urls
				: [server.urls];

			const supportedUrls = urls.filter((url) => {
				if (typeof url !== 'string') {
					return false;
				}

				// STUN is fine.
				if (url.startsWith('stun:')) {
					return true;
				}

				// Only accept explicitly UDP TURN.
				if (
					url.startsWith('turn:') &&
					url.includes('transport=udp')
				) {
					return true;
				}

				return false;
			});

			if (supportedUrls.length === 0) {
				continue;
			}

			const filteredServer = {
				urls: supportedUrls,
			};

			if (server.username) {
				filteredServer.username = server.username;
			}

			if (server.credential) {
				filteredServer.credential = server.credential;
			}

			supportedIceServers.push(filteredServer);
		}

		if (supportedIceServers.length === 0) {
			throw new Error(
				'Cloudflare returned no STUN or UDP TURN servers supported by libjuice'
			);
		}

		console.log(
			'Supported ICE configuration:',
			JSON.stringify(supportedIceServers)
		);

		return supportedIceServers;

	} catch (err) {
		console.error(
			'Cloudflare REST API request failed, using STUN fallback:',
			err.message
		);

		return [
			{
				urls: ['stun:stun.cloudflare.com:3478'],
			},
		];
	}
}


// ---------------------------------------------------------
// HTTP / WebSocket server
// ---------------------------------------------------------

const server = http.createServer((req, res) => {
	res.writeHead(200, {
		'Content-Type': 'text/plain',
	});

	res.end('Hello WebRTC Server\n');
});

const wss = new WebSocket.Server({
	server,
	maxPayload: MAX_MESSAGE_SIZE,
});

server.listen(PORT, '0.0.0.0', () => {
	console.log(
		`HTTP/WebSocket core wrapper running on interface 0.0.0.0:${PORT}`
	);
});

wss.on('listening', () => {
	console.log(`WebSocket signaling server listening on port ${PORT}`);
});

wss.on('error', (err) => {
	if (err.code === 'EADDRINUSE') {
		console.error(
			`Port ${PORT} is already in use. Set PORT to another value.`
		);

		process.exit(1);
	}

	console.error('WebSocket server error:', err);
});


// ---------------------------------------------------------
// Protocol error
// ---------------------------------------------------------

class ProtoError extends Error {
	constructor(code, message) {
		super(message);
		this.code = code;
	}
}


// ---------------------------------------------------------
// Peer
// ---------------------------------------------------------

class Peer {
	constructor(id, ws) {
		this.id = id;
		this.ws = ws;
		this.lobby = '';

		this.timeout = setTimeout(() => {
			if (!this.lobby && ws.readyState === WebSocket.OPEN) {
				ws.close(4000, STR_NO_LOBBY);
			}
		}, NO_LOBBY_TIMEOUT);
	}

	clearTimeout() {
		if (this.timeout) {
			clearTimeout(this.timeout);
			this.timeout = null;
		}
	}
}


// ---------------------------------------------------------
// Lobby
// ---------------------------------------------------------

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

		// Tell the new peer its assigned ID.
		sendMessage(
			peer.ws,
			CMD.ID,
			assigned,
			this.mesh ? 'true' : ''
		);

		// Tell existing peers about the new peer,
		// and tell the new peer about existing peers.
		for (const p of this.peers) {
			sendMessage(
				p.ws,
				CMD.PEER_CONNECT,
				assigned
			);

			sendMessage(
				peer.ws,
				CMD.PEER_CONNECT,
				this.getPeerId(p)
			);
		}

		this.peers.push(peer);
	}

	leave(peer) {
		const idx = this.peers.findIndex(
			(p) => p === peer
		);

		if (idx === -1) {
			return false;
		}

		const assigned = this.getPeerId(peer);
		const wasHost = assigned === 1;

		if (wasHost) {
			/*
			 * Your current architecture uses client-side
			 * migration. The remaining peers are told to
			 * create/join a new lobby.
			 */
			const newLobby = randomSecret();

			for (const p of this.peers) {
				if (p !== peer) {
					sendMessage(
						p.ws,
						CMD.MIGRATE_HOST,
						1,
						newLobby
					);
				}
			}
		} else {
			// Normal peer departure.
			for (const p of this.peers) {
				if (p !== peer) {
					sendMessage(
						p.ws,
						CMD.PEER_DISCONNECT,
						assigned
					);
				}
			}
		}

		this.peers.splice(idx, 1);

		// If the lobby is being dissolved, cancel
		// the seal timer.
		if (wasHost && this.closeTimer >= 0) {
			clearTimeout(this.closeTimer);
			this.closeTimer = -1;
		}

		return wasHost;
	}

	seal(peer) {
		if (peer.id !== this.host) {
			throw new ProtoError(
				4000,
				STR_ONLY_HOST_CAN_SEAL
			);
		}

		if (this.sealed) {
			return;
		}

		this.sealed = true;

		for (const p of this.peers) {
			sendMessage(
				p.ws,
				CMD.SEAL,
				0
			);
		}

		console.log(
			`Peer ${peer.id} sealed lobby ${this.name} with ${this.peers.length} peers`
		);

		this.closeTimer = setTimeout(() => {
			for (const p of this.peers) {
				if (p.ws.readyState === WebSocket.OPEN) {
					p.ws.close(
						1000,
						STR_SEAL_COMPLETE
					);
				}
			}
		}, SEAL_CLOSE_TIMEOUT);
	}
}


// ---------------------------------------------------------
// Lobby management
// ---------------------------------------------------------

const lobbies = new Map();

function createUniqueLobbyName() {
	let name;

	do {
		name = randomSecret();
	} while (lobbies.has(name));

	return name;
}

async function joinLobby(peer, pLobby, mesh) {
	let lobbyName = pLobby;

	if (peer.lobby) {
		throw new ProtoError(
			4000,
			STR_ALREADY_IN_LOBBY
		);
	}

	// Quick play finds an existing open lobby.
	if (lobbyName === 'quickPlay') {
		lobbyName = '';

		const openLobby = Array.from(lobbies.entries())
			.find(([, lobby]) =>
				!lobby.sealed &&
				lobby.peers.length < MAX_PEERS
			);

		if (openLobby) {
			lobbyName = openLobby[0];
		}
	}

	// Empty lobby name means create a new lobby.
	if (lobbyName === '') {
		lobbyName = createUniqueLobbyName();
	}

	// Create lobby if it doesn't already exist.
	if (!lobbies.has(lobbyName)) {
		if (lobbies.size >= MAX_LOBBIES) {
			throw new ProtoError(
				4000,
				STR_TOO_MANY_LOBBIES
			);
		}

		lobbies.set(
			lobbyName,
			new Lobby(
				lobbyName,
				peer.id,
				mesh
			)
		);

		console.log(
			`Peer ${peer.id} created lobby ${lobbyName}`
		);

		console.log(
			`Open lobbies: ${lobbies.size}`
		);
	}

	const lobby = lobbies.get(lobbyName);

	if (!lobby) {
		throw new ProtoError(
			4000,
			STR_SERVER_ERROR
		);
	}

	if (lobby.sealed) {
		throw new ProtoError(
			4000,
			STR_LOBBY_IS_SEALED
		);
	}

	if (lobby.peers.length >= MAX_PEERS) {
		throw new ProtoError(
			4000,
			STR_TOO_MANY_PEERS
		);
	}

	/*
	 * IMPORTANT:
	 *
	 * Set peer.lobby BEFORE awaiting the Cloudflare request.
	 * Otherwise the 1-second NO_LOBBY_TIMEOUT can fire while
	 * we're waiting for Cloudflare and leave an orphaned lobby.
	 */
	peer.lobby = lobbyName;
	peer.clearTimeout();

	console.log(
		`Peer ${peer.id} joining lobby ${lobbyName} with ${lobby.peers.length} peers`
	);

	/*
	 * Send ICE configuration before JOIN/PEER_CONNECT.
	 * This ensures the client has its TURN configuration
	 * before it creates WebRTC peers.
	 */
	const iceServers =
		await getCloudflareTurnCredentials();

	if (peer.ws.readyState !== WebSocket.OPEN) {
		return;
	}

	sendMessage(
		peer.ws,
		CMD.ICE_CONFIG,
		0,
		JSON.stringify(iceServers)
	);

	// Tell client which lobby it joined.
	sendMessage(
		peer.ws,
		CMD.JOIN,
		0,
		lobbyName
	);

	// Finally announce the peer to the lobby.
	lobby.join(peer);
}


// ---------------------------------------------------------
// Message parsing
// ---------------------------------------------------------

async function parseMsg(peer, msg) {
	let json;

	try {
		json = JSON.parse(msg);
	} catch (e) {
		throw new ProtoError(
			4000,
			STR_INVALID_FORMAT
		);
	}

	if (
		typeof json !== 'object' ||
		json === null ||
		Array.isArray(json)
	) {
		throw new ProtoError(
			4000,
			STR_INVALID_FORMAT
		);
	}

	const type =
		typeof json.type === 'number'
			? Math.floor(json.type)
			: -1;

	const id =
		typeof json.id === 'number'
			? Math.floor(json.id)
			: -1;

	const data =
		typeof json.data === 'string'
			? json.data
			: '';

	if (type < 0 || id < 0) {
		throw new ProtoError(
			4000,
			STR_INVALID_FORMAT
		);
	}

	// Reject unknown commands.
	if (!Object.values(CMD).includes(type)) {
		throw new ProtoError(
			4000,
			STR_INVALID_CMD
		);
	}

	// JOIN is the only command allowed before
	// the peer has joined a lobby.
	if (type === CMD.JOIN) {
		await joinLobby(
			peer,
			data,
			id === 0
		);

		return;
	}

	if (!peer.lobby) {
		throw new ProtoError(
			4000,
			STR_NEED_LOBBY
		);
	}

	const lobby = lobbies.get(peer.lobby);

	if (!lobby) {
		throw new ProtoError(
			4000,
			STR_SERVER_ERROR
		);
	}

	// -----------------------------------------------------
	// Seal
	// -----------------------------------------------------

	if (type === CMD.SEAL) {
		lobby.seal(peer);
		return;
	}

	// -----------------------------------------------------
	// WebRTC signaling
	// -----------------------------------------------------

	if (
		type === CMD.OFFER ||
		type === CMD.ANSWER ||
		type === CMD.CANDIDATE
	) {
		let destId = id;

		// ID 1 always represents the lobby host
		// from the client's perspective.
		if (id === 1) {
			destId = lobby.host;
		}

		const dest = lobby.peers.find(
			(e) => e.id === destId
		);

		if (!dest) {
			throw new ProtoError(
				4000,
				STR_INVALID_DEST
			);
		}

		sendMessage(
			dest.ws,
			type,
			lobby.getPeerId(peer),
			data
		);

		return;
	}

	/*
	 * These commands are server -> client only
	 * and should never be sent by clients.
	 */
	if (
		type === CMD.ID ||
		type === CMD.PEER_CONNECT ||
		type === CMD.PEER_DISCONNECT ||
		type === CMD.MIGRATE_HOST ||
		type === CMD.ICE_CONFIG
	) {
		throw new ProtoError(
			4000,
			STR_INVALID_CMD
		);
	}

	throw new ProtoError(
		4000,
		STR_INVALID_CMD
	);
}


// ---------------------------------------------------------
// WebSocket connections
// ---------------------------------------------------------

wss.on('connection', (ws) => {
	// Global connection limit.
	if (wss.clients.size > MAX_PEERS) {
		ws.close(
			4000,
			STR_TOO_MANY_PEERS
		);

		return;
	}

	const id = randomId();
	const peer = new Peer(id, ws);

	// Heartbeat state.
	ws.isAlive = true;

	ws.on('pong', () => {
		ws.isAlive = true;
	});

	ws.on('message', async (msg, isBinary) => {
		if (isBinary) {
			ws.close(
				4000,
				STR_INVALID_TRANSFER_MODE
			);

			return;
		}

		try {
			await parseMsg(
				peer,
				msg.toString()
			);
		} catch (err) {
			if (err instanceof ProtoError) {
				if (ws.readyState === WebSocket.OPEN) {
					ws.close(
						err.code,
						err.message
					);
				}
			} else {
				console.error(
					'Unexpected server error:',
					err
				);

				if (ws.readyState === WebSocket.OPEN) {
					ws.close(
						4000,
						STR_SERVER_ERROR
					);
				}
			}
		}
	});

	ws.on('close', () => {
		peer.clearTimeout();

		if (!peer.lobby) {
			return;
		}

		const lobbyName = peer.lobby;
		const lobby = lobbies.get(lobbyName);

		if (!lobby) {
			return;
		}

		const wasHost = lobby.leave(peer);

		if (wasHost) {
			lobbies.delete(lobbyName);

			console.log(
				`Lobby ${lobbyName} dissolved. Open lobbies: ${lobbies.size}`
			);
		} else if (lobby.peers.length === 0) {
			// Remove empty lobbies so they don't accumulate.
			lobbies.delete(lobbyName);

			console.log(
				`Lobby ${lobbyName} became empty. Open lobbies: ${lobbies.size}`
			);
		}
	});
});


// ---------------------------------------------------------
// WebSocket heartbeat
// ---------------------------------------------------------

const heartbeat = setInterval(() => {
	for (const ws of wss.clients) {
		if (ws.isAlive === false) {
			ws.terminate();
			continue;
		}

		ws.isAlive = false;
		ws.ping();
	}
}, PING_INTERVAL);


// ---------------------------------------------------------
// Graceful shutdown
// ---------------------------------------------------------

function shutdown() {
	console.log('Shutting down server...');

	clearInterval(heartbeat);

	for (const ws of wss.clients) {
		ws.close(
			1001,
			'Server shutting down'
		);
	}

	server.close(() => {
		console.log('Server closed.');
		process.exit(0);
	});
}

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);