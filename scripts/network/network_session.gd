extends Node

## Owns the multiplayer connection: hosting, joining, and who is in the game.
##
## Registered as the [code]NetworkSession[/code] autoload, so a session survives scene changes
## and any node can ask who is connected without reaching through the tree for a peer.
##
## Deliberately carries no [code]class_name[/code]: a global class and an autoload cannot share
## an identifier, and the autoload name is the one every caller uses. The enums and constants
## below are therefore reached through the singleton — [code]NetworkSession.Role.SERVER[/code]
## — which is where a reader would look for them anyway.
##
## [b]Why the server is authoritative.[/b] Every client computes the same ocean independently —
## the wave spectrum is derived from wind speed and driven by a shared clock, so the water needs
## no replication at all. What cannot be left to each client is anything they might
## [i]disagree[/i] about: where a floating crate ended up after two players shoved it. Physics
## for shared objects therefore runs on the server alone and its results are replicated, while
## the water underneath them is recomputed everywhere for free.
##
## [b]Local testing.[/b] Launch arguments after [code]--[/code] decide the role, so the editor's
## Debug > Customize Run Instances can start a server and a client from one keypress. See
## [method role_from_command_line].
##
## @tutorial(High-level multiplayer): https://docs.godotengine.org/en/stable/tutorials/networking/high_level_multiplayer.html

## Emitted once this peer is part of a running session, hosting or joined.
signal session_started(as_server: bool)

## Emitted when the session ends, whether deliberately or by losing the server.
##
## [param reason] is a sentence fit to show a player: the HUD prints it, so "the host quit" and
## "nothing was listening on that port" are distinguishable from never having tried to connect.
## Compare it against [constant REASON_LEFT] to tell this peer's own doing from something done
## to it.
signal session_ended(reason: String)

## Emitted when a player joins, after their name is known.
signal player_joined(peer_id: int, player_name: String)

## Emitted when a player leaves.
signal player_left(peer_id: int, player_name: String)

## Emitted when the roster changes for any reason, for UI that just wants to redraw.
signal roster_changed

## Port used when none is given.
const DEFAULT_PORT: int = 27015

## Address a client connects to when none is given.
const DEFAULT_ADDRESS: String = "127.0.0.1"

## Largest number of players allowed in one session, the host included.
##
## Also the [member MultiplayerSpawner.spawn_limit] of the demo scene: one body per player, so
## the two must agree. See [method host] for why the figure handed to ENet is one lower.
const MAX_PLAYERS: int = 8

## Peer id the server always has. Godot fixes this; it is named here so the intent reads.
const SERVER_PEER_ID: int = 1

## Reason for a session this peer ended itself. The one reason the HUD does not show: a player
## who pressed the key already knows what they did.
const REASON_LEFT: String = "Left the session."

## Reason for a connection that never came up.
const REASON_CONNECTION_FAILED: String = "Could not reach a server."

## Reason for a host that went away mid-session.
const REASON_SERVER_DISCONNECTED: String = "The host closed the session."

## Reason for a peer the server admitted but has no room to give a body to.
const REASON_SESSION_FULL: String = "The session is full."

## What role this peer plays in a session.
enum Role {
	## Not connected to anything.
	NONE,
	## Hosting, and also playing.
	SERVER,
	## Connected to someone else's session.
	CLIENT,
}

## This peer's role. [constant Role.NONE] until a session starts.
var role: Role = Role.NONE

## Display names of everyone in the session, keyed by peer id.
##
## The server owns this dictionary; clients receive it whole whenever it changes, which is
## simpler than replaying joins and leaves and cannot drift out of step.
var players: Dictionary = {}

## Name this peer wants to be known by. Sent to the server on connecting.
var local_player_name: String = ""

var _peer: ENetMultiplayerPeer = null


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


## Starts hosting on [param port]. Returns [code]OK[/code], or the error that stopped it.
func host(port: int = DEFAULT_PORT, player_name: String = "") -> Error:
	leave()

	_peer = ENetMultiplayerPeer.new()
	# ENet counts clients, and the host is not one of its own clients — but it is a player, and
	# it consumes a body out of the spawner's limit like everyone else. Asking ENet for
	# MAX_PLAYERS clients therefore admits MAX_PLAYERS + 1 players, and the last to arrive is
	# refused a body while still appearing in every roster.
	var error := _peer.create_server(port, MAX_PLAYERS - 1)
	if error != OK:
		push_error("NetworkSession: could not host on port %d (error %d)." % [port, error])
		_peer = null
		return error

	multiplayer.multiplayer_peer = _peer
	role = Role.SERVER
	local_player_name = _resolve_name(player_name)

	# The host is a player too, so it appears in its own roster immediately. Nothing arrives
	# over the network to announce it: peer_connected never fires for oneself.
	players[SERVER_PEER_ID] = local_player_name
	roster_changed.emit()
	player_joined.emit(SERVER_PEER_ID, local_player_name)
	session_started.emit(true)
	print("NetworkSession: hosting on port %d as '%s'." % [port, local_player_name])
	return OK


## Joins a session at [param address]. Returns [code]OK[/code], or the error that stopped it.
func join(
	address: String = DEFAULT_ADDRESS, port: int = DEFAULT_PORT, player_name: String = ""
) -> Error:
	leave()

	_peer = ENetMultiplayerPeer.new()
	var error := _peer.create_client(address, port)
	if error != OK:
		push_error("NetworkSession: could not reach %s:%d (error %d)." % [address, port, error])
		_peer = null
		return error

	multiplayer.multiplayer_peer = _peer
	role = Role.CLIENT
	local_player_name = _resolve_name(player_name)
	print("NetworkSession: connecting to %s:%d as '%s'." % [address, port, local_player_name])
	return OK


## Ends the session and clears the roster. Safe to call when not connected.
func leave(reason: String = REASON_LEFT) -> void:
	if role == Role.NONE:
		return

	# Assigning an OfflineMultiplayerPeer rather than null: null leaves the API in a state
	# where is_server() and get_unique_id() still answer as though connected.
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_peer = null
	role = Role.NONE
	players.clear()
	roster_changed.emit()
	session_ended.emit(reason)


## Removes [param peer_id] from the session, telling them why first. Server only.
##
## The player is told before the socket closes, because a peer that is simply dropped cannot
## distinguish being refused from the host crashing.
##
## [b]Not[/b] [method MultiplayerPeer.disconnect_peer], which is the trap here: it reaches
## ENet's [code]enet_peer_disconnect[/code], and that resets the peer's outgoing queues before
## sending the disconnect — throwing the rejection away unsent. Measured, not assumed: the
## client received "the host closed the session" instead. Asking the ENet peer to disconnect
## [i]later[/i] keeps the queue and closes once it has drained and been acknowledged.
func reject_peer(peer_id: int, reason: String) -> void:
	if role != Role.SERVER or _peer == null or peer_id == SERVER_PEER_ID:
		return

	_receive_rejection.rpc_id(peer_id, reason)
	_remove_from_roster(peer_id)

	# get_peer() logs an engine error for an id it does not know, so it is asked only about one
	# ENet is still holding. A peer that vanished in the meantime needs no disconnecting.
	if multiplayer.get_peers().has(peer_id):
		_peer.get_peer(peer_id).peer_disconnect_later()
	push_warning("NetworkSession: rejected peer %d — %s" % [peer_id, reason])


## Returns whether this peer is in a session at all.
func is_active() -> bool:
	return role != Role.NONE


## Returns whether this peer is the authority over shared physics.
##
## Everything that two players could disagree about is decided here and replicated. A client
## asking this is asking "may I move that crate", and the answer is no.
func is_authority() -> bool:
	return role == Role.SERVER


## Returns this peer's id, or 0 when not connected.
func local_peer_id() -> int:
	if role == Role.NONE:
		return 0
	return multiplayer.get_unique_id()


## Returns the display name for [param peer_id], or a placeholder if it is not known yet.
func name_for(peer_id: int) -> String:
	return players.get(peer_id, "Player %d" % peer_id)


## Returns the role requested on the command line, for the two-window local test.
##
## Reads the arguments after [code]--[/code], which the engine reserves for the user, so
## Debug > Customize Run Instances can start one server and one client from a single F5.
## Recognises [code]--server[/code] and [code]--client[/code]; anything else gives
## [constant Role.NONE] so a normal launch is unaffected.
static func role_from_command_line() -> Role:
	for argument in OS.get_cmdline_user_args():
		match argument:
			"--server", "--host":
				return Role.SERVER
			"--client", "--join":
				return Role.CLIENT
	return Role.NONE


## Returns the name requested on the command line, or an empty string.
##
## Accepts [code]--name=Something[/code], so a test launch can label its windows.
static func name_from_command_line() -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--name="):
			return argument.trim_prefix("--name=")
	return ""


## Returns the address requested on the command line, or an empty string.
##
## Accepts [code]--address=example.org[/code]. Without it a client can only ever reach
## [constant DEFAULT_ADDRESS], which made the advertised two-player game same-machine only: the
## rest of the plumbing already takes an address, and nothing ever passed one.
static func address_from_command_line() -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--address="):
			return argument.trim_prefix("--address=").strip_edges()
	return ""


## Returns the port requested on the command line, or [constant DEFAULT_PORT].
##
## Accepts [code]--port=27015[/code]. Host and client read the same argument, so one pair of
## launch commands can put two machines on a port that is not the default.
static func port_from_command_line() -> int:
	for argument in OS.get_cmdline_user_args():
		if not argument.begins_with("--port="):
			continue
		var text := argument.trim_prefix("--port=")
		# Rejected rather than clamped: a typo that silently became a valid-but-different port
		# would present as "the other machine cannot see me", which is a miserable thing to
		# debug for the sake of accepting nonsense.
		if text.is_valid_int() and int(text) > 0 and int(text) <= 65535:
			return int(text)
		push_warning("NetworkSession: ignoring unusable --port=%s." % text)
	return DEFAULT_PORT


## Returns a usable display name, falling back to something that identifies the window.
func _resolve_name(requested: String) -> String:
	if not requested.is_empty():
		return requested
	var from_arguments := name_from_command_line()
	if not from_arguments.is_empty():
		return from_arguments
	return "Host" if role == Role.SERVER else "Player"


# ---------------------------------------------------------------------------
# Roster replication
#
# The server owns the roster and pushes it whole. Sending the entire dictionary rather than
# join and leave events costs a few dozen bytes and removes a class of bug outright: a client
# that missed one event would otherwise stay wrong until it reconnected.
# ---------------------------------------------------------------------------

## Sends this peer's chosen name to the server. Called by a client once connected.
@rpc("any_peer", "call_remote", "reliable")
func _register_player(player_name: String) -> void:
	if not multiplayer.is_server():
		return

	var peer_id := multiplayer.get_remote_sender_id()
	# Client-supplied, so it is treated as untrusted text rather than used as given.
	var clean_name := _sanitise_name(player_name, peer_id)
	players[peer_id] = clean_name

	_receive_roster.rpc(players)
	roster_changed.emit()
	player_joined.emit(peer_id, clean_name)
	print("NetworkSession: %s (peer %d) joined." % [clean_name, peer_id])


## Replaces the local roster with the server's. Server to clients only.
@rpc("authority", "call_remote", "reliable")
func _receive_roster(roster: Dictionary) -> void:
	players = roster.duplicate()
	roster_changed.emit()


## Ends this peer's session with the reason the server gave. Server to one client only.
@rpc("authority", "call_remote", "reliable")
func _receive_rejection(reason: String) -> void:
	if multiplayer.is_server():
		return
	# Leaving here rather than waiting for the socket to close is what puts the server's reason
	# in front of the player: the server_disconnected that follows would otherwise replace it
	# with the generic one. leave() returns early once the role is NONE, so it does not.
	leave(reason)


## Returns a display name safe to show, from text a client supplied.
##
## A name arrives from over the network, so it is length-limited and stripped of control
## characters and newlines before anything renders it.
func _sanitise_name(raw: String, peer_id: int) -> String:
	var clean := ""
	for character in raw.strip_edges():
		# Keep printable characters only; a newline in a Label3D would break the tag layout,
		# and control characters have no business in a name.
		if character.unicode_at(0) >= 32:
			clean += character
	clean = clean.substr(0, 20).strip_edges()
	if clean.is_empty():
		return "Player %d" % peer_id
	return clean
## Drops [param peer_id] from the roster and tells every remaining peer. Server only.
##
## Shared by an ordinary disconnect and by [method reject_peer], so a rejected player leaves by
## exactly the path a departing one does. Silent for a peer that connected but never registered:
## there is no roster entry to announce the loss of.
func _remove_from_roster(peer_id: int) -> void:
	if not players.has(peer_id):
		return

	var departed: String = players[peer_id]
	players.erase(peer_id)
	_receive_roster.rpc(players)
	roster_changed.emit()
	player_left.emit(peer_id, departed)
	print("NetworkSession: %s (peer %d) left." % [departed, peer_id])



func _on_peer_connected(peer_id: int) -> void:
	# Only the server acts here. It does not yet know the newcomer's name; that arrives when
	# they call _register_player, which is what actually adds them to the roster.
	if multiplayer.is_server():
		print("NetworkSession: peer %d connected, awaiting registration." % peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	_remove_from_roster(peer_id)


func _on_connected_to_server() -> void:
	_register_player.rpc_id(SERVER_PEER_ID, local_player_name)
	session_started.emit(false)
	print("NetworkSession: connected as peer %d." % multiplayer.get_unique_id())


func _on_connection_failed() -> void:
	push_warning("NetworkSession: connection failed.")
	leave(REASON_CONNECTION_FAILED)


func _on_server_disconnected() -> void:
	push_warning("NetworkSession: the server closed the connection.")
	leave(REASON_SERVER_DISCONNECTED)
