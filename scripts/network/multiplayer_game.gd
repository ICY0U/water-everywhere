class_name MultiplayerGame
extends Node3D

## Runs the networked demo: starts a session, spawns players, and points the camera at yours.
##
## This is the only node that knows the demo is multiplayer at all. The ocean, the waves and
## the foam are untouched by networking — every client derives identical water from the same
## wind speed and the same clock, so none of it is replicated. What is replicated is the
## handful of things two clients could otherwise disagree about: who is playing, where their
## bodies ended up, and what the weather is.
##
## Players are created by a [MultiplayerSpawner]. Spawning through it rather than by hand is
## what makes a client joining midway see everyone already in the water, which is the part that
## is genuinely tedious to write by hand.

## How many times a launch-argument client tries to reach the server before giving up.
const JOIN_ATTEMPTS: int = 12

## Seconds between join attempts.
const JOIN_RETRY_SECONDS: float = 1.0

## Interval between authority clock samples. Clients integrate between these samples.
const OCEAN_CLOCK_INTERVAL: float = 0.5

## Largest correction made in one frame, preventing a late packet from popping every crest.
const OCEAN_CLOCK_MAX_CORRECTION: float = 0.012

## Largest one-way latency the clock will compensate for, in seconds.
##
## A plausible connection is far below this. The cap is here so that a wild round-trip figure —
## a peer mid-handshake, or a link that has just collapsed — cannot throw the sea a long way
## into the future and leave every hull floating off its wave.
const OCEAN_CLOCK_MAX_LATENCY: float = 0.5

## Colours handed out to players in join order, so the two windows are told apart instantly.
const PLAYER_COLORS: Array[Color] = [
	Color(0.886, 0.353, 0.263),
	Color(0.286, 0.639, 0.855),
	Color(0.478, 0.796, 0.376),
	Color(0.929, 0.741, 0.286),
	Color(0.741, 0.451, 0.847),
	Color(0.949, 0.541, 0.310),
	Color(0.376, 0.827, 0.749),
	Color(0.898, 0.451, 0.588),
]

## Scene instanced for each player.
@export var player_scene: PackedScene

## Ocean the players float on.
@export var ocean: Ocean

## Weather, driven over the network so one player changing it changes it for everyone.
@export var weather: WeatherController

## Shared floating starting platform.
@export var raft: Raft

@onready var _spawner: MultiplayerSpawner = $PlayerSpawner
@onready var _players: Node3D = $Players
@onready var _camera: PlayerCamera = $PlayerCamera
@onready var _status: Label = $HUD/Status

## Role this instance was launched with. A [code]NetworkSession.Role[/code] value, held as an
## int because an autoload's enum cannot be used as a type annotation.
var _pending_role: int = NetworkSession.Role.NONE
var _clock_broadcast_elapsed: float = 0.0
var _server_ocean_time: float = 0.0
var _has_server_ocean_time: bool = false

## Why the last session ended, or why one would not start. Shown under "Offline" so a player
## whose host quit can tell that apart from never having pressed a key. Empty when all is well.
var _status_notice: String = ""


func _ready() -> void:
	_spawner.spawn_function = _spawn_player

	NetworkSession.session_started.connect(_on_session_started)
	NetworkSession.session_ended.connect(_on_session_ended)
	NetworkSession.player_joined.connect(_on_player_joined)
	NetworkSession.player_left.connect(_on_player_left)
	NetworkSession.roster_changed.connect(_refresh_status)
	# The HUD names the view the key would switch TO, so it has to be redrawn when it changes.
	_camera.view_mode_changed.connect(func(_mode: PlayerCamera.ViewMode) -> void:
		_refresh_status())
	if ocean != null:
		ocean.water_impacted.connect(_on_authority_water_impacted)

	_pending_role = NetworkSession.role_from_command_line()
	TestWindowLayout.apply(_pending_role)
	_refresh_status()

	# Started deferred so the scene is fully inside the tree first: the spawner cannot
	# replicate a player into a container that is not ready to receive it yet.
	if _pending_role != NetworkSession.Role.NONE:
		_start_from_command_line.call_deferred()


func _process(delta: float) -> void:
	if ocean == null or not NetworkSession.is_active():
		return
	if multiplayer.is_server():
		_clock_broadcast_elapsed += delta
		if _clock_broadcast_elapsed >= OCEAN_CLOCK_INTERVAL:
			_clock_broadcast_elapsed = 0.0
			_receive_ocean_clock.rpc(ocean.elapsed_time)
	elif _has_server_ocean_time:
		# The target advances locally between packets. Correcting toward it rather than snapping
		# avoids a visible discontinuity in waves, cloud shadows and particles.
		_server_ocean_time += delta
		# The sample describes where the sea was when it was sent, so the sea it describes is
		# already one trip old by the time it arrives. Aiming at that instant plus the trip is
		# what puts this client on the same sea the server solved buoyancy against.
		#
		# The offset moves the target; the clamp below still governs how fast the clock may
		# travel toward it. They are deliberately separate — the clamp exists to stop a late
		# packet popping every crest, so a large latency is converged over several frames
		# rather than by loosening the clamp and losing that protection.
		var target := _server_ocean_time + _authority_latency()
		var error := target - ocean.elapsed_time
		ocean.elapsed_time += clampf(
			error, -OCEAN_CLOCK_MAX_CORRECTION, OCEAN_CLOCK_MAX_CORRECTION
		)


## Seconds the authority's clock takes to reach this peer, or 0.0 when it cannot be measured.
##
## ENet keeps a round-trip estimate from its own keepalives, so this costs nothing to read and
## needs no timing packets of our own. Half of it is the one-way trip, which is what a sample
## that travelled in one direction is behind by.
##
## The peer is reached through [member MultiplayerAPI.multiplayer_peer] because
## [code]NetworkSession[/code] keeps its socket private; [method _join_with_retries] already
## reads the peer the same way. Asking for an [ENetMultiplayerPeer] specifically is the guard
## that matters: [OfflineMultiplayerPeer] is installed whenever a session ends, and it reports
## [constant MultiplayerPeer.CONNECTION_CONNECTED] while having no [code]get_peer[/code] at all,
## so a test on connection status alone passes and then calls a method that does not exist.
func _authority_latency() -> float:
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet == null:
		return 0.0
	# Asking for a peer ENet does not know logs an engine error before returning null, and this
	# runs every frame, so the call is avoided rather than its result checked.
	if enet.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return 0.0

	var server_peer := enet.get_peer(NetworkSession.SERVER_PEER_ID)
	if server_peer == null:
		return 0.0

	# get_statistic() reports whole milliseconds.
	var round_trip := float(
		server_peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME)
	) * 0.001
	return clampf(round_trip * 0.5, 0.0, OCEAN_CLOCK_MAX_LATENCY)


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.is_pressed() or key.echo:
		return

	match key.keycode:
		KEY_H:
			if not NetworkSession.is_active():
				_report_start(NetworkSession.host())
		KEY_J:
			if not NetworkSession.is_active():
				_report_start(NetworkSession.join())
		KEY_1, KEY_2, KEY_3:
			_request_weather(key.keycode - KEY_1)
		KEY_C:
			if weather != null:
				_request_weather(weather.presets.size())
		KEY_Q:
			_quit_game()


## Leaves any session and closes the game.
##
## [kbd]Escape[/kbd] is not used for this: it already releases the mouse in
## [PlayerCamera], and a key that sometimes frees the cursor and sometimes ends the game is
## worse than no quit key at all.
##
## Leaving first is what lets the other side say something useful. A host that simply exits
## takes its socket with it and every client falls back to a bare "connection lost"; calling
## [method NetworkSession.leave] hands them [constant NetworkSession.REASON_SERVER_DISCONNECTED]
## to display instead. No farewell is sent from here on purpose — a peer being torn down
## discards whatever is still queued for it, so a message written at this point would not
## arrive, and the reason the other side already has is the honest one.
func _quit_game() -> void:
	if NetworkSession.is_active():
		NetworkSession.leave()
	get_tree().quit()


## Puts a session that would not start at all in front of the player.
##
## [method NetworkSession.host] and [method NetworkSession.join] return before the network is
## reached, so only immediate failures arrive here — a port already in use, an address that will
## not parse. A connection refused or dropped later surfaces through
## [signal NetworkSession.session_ended] instead.
func _report_start(error: Error) -> void:
	_status_notice = "" if error == OK else "Could not start: %s." % error_string(error)
	_refresh_status()


## Hosts or joins according to the launch arguments, for the two-window local test.
##
## A client retries rather than giving up on its first attempt. Both windows are launched at
## once, and whichever starts second may well be ready before the server's socket is listening
## — a race that does not exist when the two are started by hand, and that presents as a client
## sitting on "Offline" beside a perfectly healthy server.
func _start_from_command_line() -> void:
	var chosen_name := NetworkSession.name_from_command_line()
	if _pending_role == NetworkSession.Role.SERVER:
		if chosen_name.is_empty():
			chosen_name = "Host"
		NetworkSession.host(NetworkSession.DEFAULT_PORT, chosen_name)
		return

	if _pending_role != NetworkSession.Role.CLIENT:
		return
	if chosen_name.is_empty():
		chosen_name = "Guest"
	_join_with_retries(chosen_name)


## Tries to join, retrying while the server is still starting up.
func _join_with_retries(chosen_name: String) -> void:
	for attempt in JOIN_ATTEMPTS:
		if NetworkSession.is_active() and NetworkSession.local_peer_id() > 1:
			return
		NetworkSession.join(
			NetworkSession.DEFAULT_ADDRESS, NetworkSession.DEFAULT_PORT, chosen_name
		)
		# ENet reports failure asynchronously, so the outcome is not known until the peer has
		# had a chance to poll. Waiting a beat before judging is what makes the retry mean
		# anything.
		await get_tree().create_timer(JOIN_RETRY_SECONDS).timeout
		if multiplayer.multiplayer_peer != null and (
			multiplayer.multiplayer_peer.get_connection_status()
			== MultiplayerPeer.CONNECTION_CONNECTED
		):
			return
		if attempt < JOIN_ATTEMPTS - 1:
			print("MultiplayerGame: no server yet, retrying (%d/%d)." % [
				attempt + 1, JOIN_ATTEMPTS,
			])

	push_warning("MultiplayerGame: could not reach a server; press J to retry.")
	_status_notice = "No server found after %d attempts." % JOIN_ATTEMPTS
	_refresh_status()


func _on_session_started(as_server: bool) -> void:
	_status_notice = ""
	_refresh_status()
	if as_server:
		# The host is already in its own roster, so its body is spawned here rather than
		# waiting for a join it will never receive.
		if not _spawn_for_peer(NetworkSession.SERVER_PEER_ID):
			push_error("MultiplayerGame: the host could not be given a body.")


func _on_session_ended(reason: String) -> void:
	for child in _players.get_children():
		child.queue_free()
	# A deliberate leave explains itself; anything else happened to the player rather than
	# because of them, and the HUD is the only place they could learn of it.
	_status_notice = "" if reason == NetworkSession.REASON_LEFT else reason
	_refresh_status()


func _on_player_joined(peer_id: int, _player_name: String) -> void:
	# Only the server spawns. Every other peer receives the result through the spawner.
	if not NetworkSession.is_authority():
		return
	if peer_id != NetworkSession.SERVER_PEER_ID:
		if not _spawn_for_peer(peer_id):
			# No body means no camera target and no way to play, and nothing about that state
			# recovers on its own. Refusing the peer outright beats leaving them listed as
			# playing with nothing in the water. reject_peer redraws the HUD as it goes.
			NetworkSession.reject_peer(peer_id, NetworkSession.REASON_SESSION_FULL)
			return
		_send_current_weather_to(peer_id)
	_refresh_status()


func _on_player_left(peer_id: int, _player_name: String) -> void:
	if not NetworkSession.is_authority():
		return
	var body := _players.get_node_or_null(str(peer_id))
	if body != null:
		body.queue_free()
	_refresh_status()


## Asks the spawner to create a body for [param peer_id]. Server only.
##
## Returns whether that peer now has a body. It can genuinely fail: the spawner enforces its own
## [member MultiplayerSpawner.spawn_limit], and discarding a refusal is the difference between a
## player and a ghost listed in every roster with nothing in the water.
func _spawn_for_peer(peer_id: int) -> bool:
	if _players.has_node(str(peer_id)):
		return true
	var body := _spawner.spawn({
		"peer_id": peer_id,
		"name": NetworkSession.name_for(peer_id),
		"position": _spawn_position(peer_id),
		"velocity": raft.linear_velocity if raft != null else Vector3.ZERO,
		"color_index": _free_color_index(),
	})
	return body != null


## Picks the lowest colour not currently in use, so players stay told apart across churn.
##
## A plain child count reuses a colour the moment anyone leaves — join 1/2/3, lose 2, and the
## next player is dealt the same colour as 3. Colour is the only thing distinguishing players
## in this demo, so two identical ones is a real loss of information, and a disconnect is the
## most ordinary event in a session. Falls back to wrapping once all colours are taken.
func _free_color_index() -> int:
	var taken := {}
	for child in _players.get_children():
		var body := child as NetworkPlayer
		if body != null:
			taken[body.player_color] = true

	for index in PLAYER_COLORS.size():
		if not taken.has(PLAYER_COLORS[index]):
			return index
	return _players.get_child_count() % PLAYER_COLORS.size()


## Builds one player body. Runs on every peer, with the same data, via [MultiplayerSpawner].
##
## Returns a node that is deliberately NOT added to the tree: the spawner parents it itself,
## and adding it here would produce a duplicate on the authority.
func _spawn_player(data: Dictionary) -> Node:
	var body := player_scene.instantiate() as NetworkPlayer
	var peer_id: int = data.get("peer_id", 1)

	# Named after the peer so it can be found again when that peer leaves.
	body.name = str(peer_id)
	body.owner_peer_id = peer_id
	body.player_name = data.get("name", "Player %d" % peer_id)
	body.player_color = PLAYER_COLORS[int(data.get("color_index", 0)) % PLAYER_COLORS.size()]
	body.position = data.get("position", Vector3.ZERO)
	body.linear_velocity = data.get("velocity", Vector3.ZERO)
	body.ocean = ocean

	# The camera follows this peer's own body, and only learns which that is once it exists.
	if peer_id == NetworkSession.local_peer_id():
		body.ready.connect(func() -> void: _camera.follow(body), CONNECT_ONE_SHOT)

	return body


## The authority chooses a free slot on the moving raft and replicates that position.
func _spawn_position(_peer_id: int) -> Vector3:
	return raft.spawn_position(_players) if raft != null else Vector3(0, 3, 0)


## Asks the server to change the weather, so every player sees the same sky.
func _request_weather(index: int) -> void:
	if not NetworkSession.is_active():
		if weather != null:
			weather.apply_index(index)
		return
	_apply_weather.rpc_id(NetworkSession.SERVER_PEER_ID, index)


## Changes the weather everywhere. Any peer may ask; the server decides and tells everyone.
@rpc("any_peer", "call_local", "reliable")
func _apply_weather(index: int) -> void:
	if not multiplayer.is_server():
		return
	_broadcast_weather.rpc(index)


## Tells a freshly joined peer what the weather already is. Server only.
##
## Weather is otherwise only sent when it changes, so a peer joining afterwards would keep the
## preset its own [WeatherController] applied on ready. That is not cosmetic: the preset sets
## the wind speed the wave spectrum is derived from, so a client on the wrong preset draws a
## different sea from the one buoyancy was solved against, and every hull floats off its
## surface.
func _send_current_weather_to(peer_id: int) -> void:
	if weather == null:
		return
	var index := weather.current_index()
	if index < 0:
		return
	_broadcast_weather.rpc_id(peer_id, index)


## Applies a weather preset. Server to clients, and to itself.
@rpc("authority", "call_local", "reliable")
func _broadcast_weather(index: int) -> void:
	if weather != null:
		weather.apply_index(index)


## Forwards the authority's discrete impact to every remote peer.
##
## Continuous wakes are reconstructed from streamed transforms by [NetworkPlayer]. An impact
## is a one-frame event and cannot be reconstructed reliably, so its compact physical payload
## is the only water-effect data that crosses the network.
func _on_authority_water_impacted(impact: WaterImpact) -> void:
	if impact == null or not NetworkSession.is_active() or not multiplayer.is_server():
		return
	_receive_water_impact.rpc(
		impact.position,
		impact.normal,
		impact.impact_speed,
		impact.relative_velocity,
		impact.waterline_radius,
		impact.volume,
		impact.impulse,
		impact.energy,
		impact.kind,
		impact.seed,
	)


@rpc("authority", "call_remote", "reliable")
func _receive_water_impact(
	position: Vector3,
	normal: Vector3,
	impact_speed: float,
	relative_velocity: Vector3,
	waterline_radius: float,
	volume: float,
	impulse: float,
	energy: float,
	kind: int,
	seed: int,
) -> void:
	if ocean == null:
		return
	var impact := WaterImpact.new()
	impact.position = position
	impact.normal = normal.normalized()
	impact.impact_speed = maxf(impact_speed, 0.0)
	impact.relative_velocity = relative_velocity
	impact.waterline_radius = maxf(waterline_radius, 0.0)
	impact.volume = maxf(volume, 0.0)
	impact.impulse = maxf(impulse, 0.0)
	impact.energy = maxf(energy, 0.0)
	impact.kind = clampi(kind, Ocean.ImpactKind.ENTRY, Ocean.ImpactKind.SLAM) as Ocean.ImpactKind
	impact.seed = seed
	ocean.report_impact(impact)


@rpc("authority", "call_remote", "unreliable")
func _receive_ocean_clock(authority_time: float) -> void:
	_server_ocean_time = maxf(authority_time, 0.0)
	if not _has_server_ocean_time and ocean != null:
		# First contact is allowed to snap: before this point the client has never displayed a
		# server-agreed sea, and converging slowly would leave it visibly wrong for seconds.
		ocean.elapsed_time = _server_ocean_time
	_has_server_ocean_time = true


func _refresh_status() -> void:
	if _status == null:
		return

	if not NetworkSession.is_active():
		var offline := PackedStringArray(["Offline"])
		if not _status_notice.is_empty():
			offline.append(_status_notice)
		offline.append("")
		offline.append("H  host a session")
		offline.append("J  join 127.0.0.1")
		offline.append("Q  quit")
		_status.text = "\n".join(offline)
		return

	var heading := (
		"SERVER (peer %d)" % NetworkSession.local_peer_id() if NetworkSession.is_authority()
		else "CLIENT (peer %d)" % NetworkSession.local_peer_id()
	)
	var lines := PackedStringArray([heading, ""])
	var ids := NetworkSession.players.keys()
	ids.sort()
	for id: int in ids:
		var marker := "> " if id == NetworkSession.local_peer_id() else "  "
		lines.append("%s%s" % [marker, NetworkSession.players[id]])
	lines.append("")
	lines.append("WASD camera-relative move   Shift sprint   Alt slow   Q/E dive/rise")
	lines.append("Esc release mouse / stop thrust   Left click resume")
	lines.append("V %s   1/2/3 weather   C cycle" % _view_mode_label())
	_status.text = "\n".join(lines)


## Returns what pressing V would switch to, so the hint names the destination rather than the
## mode already on screen.
func _view_mode_label() -> String:
	if _camera == null:
		return "view"
	return (
		"third person" if _camera.view_mode() == PlayerCamera.ViewMode.FIRST_PERSON
		else "first person"
	)
