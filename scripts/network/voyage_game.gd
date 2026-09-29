class_name VoyageGame
extends MultiplayerGame

## The short crossing: leave the home island, cross open water, reach the mainland.
##
## This is the A04 voyage skeleton. It adds three things to [MultiplayerGame] and deliberately
## no more: an authoritative run phase, an objective every peer reads from that phase, and a
## reset that returns the world to a known state.
##
## [b]What it does not do.[/b] There is no paddling, cargo, damage, rescue or weather schedule
## here. Those are later chunks with their own gates, and a skeleton that pretended to have them
## would make the A04 gate untestable.

## Metres from the mainland's centre at which the crossing counts as complete.
##
## Measured horizontally from the island origin, and deliberately generous: arrival should
## trigger when a player is clearly ashore rather than requiring them to find an exact spot.
## Compared against the mainland's own plateau radius at runtime so that resizing the island
## does not silently move the finish line.
const ARRIVAL_MARGIN: float = 12.0

## Seconds between arrival tests. The check is a distance comparison over a handful of bodies,
## but there is no reason to run it every frame.
const ARRIVAL_INTERVAL: float = 0.25

## Metres between neighbouring crew members at the start of a run, measured along the ring.
##
## The same spacing [IslandGame] uses: a player is about 1.55 m across, so this leaves a clear
## gap rather than two bodies the solver has to push apart on arrival.
const SPAWN_SPACING: float = 2.6

## Island the crew is sailing towards. Reaching it ends the run.
@export var mainland: Island

## Island the crew starts on.
@export var home: Island

@onready var _director: RunDirector = $RunDirector

var _arrival_elapsed: float = 0.0


func _ready() -> void:
	super()
	_director.phase_changed.connect(_on_phase_changed)
	_director.run_reset.connect(_on_run_reset)
	_face_destination(_camera.global_position)
	# The objective belongs on screen from the first frame, not from the first phase change.
	_refresh_status()


func _process(delta: float) -> void:
	super(delta)
	if _director.phase != RunDirector.Phase.VOYAGE:
		return
	if not _is_run_authority():
		return
	_arrival_elapsed += delta
	if _arrival_elapsed < ARRIVAL_INTERVAL:
		return
	_arrival_elapsed = 0.0
	if _anyone_ashore():
		_director.advance_to(RunDirector.Phase.ARRIVAL)


## Returns the run director, so tests and UI can read the authoritative phase.
func director() -> RunDirector:
	return _director


## Starts the crossing. Server only; safe to call when already under way.
func begin_voyage() -> void:
	_director.advance_to(RunDirector.Phase.VOYAGE)


## Returns every player to the start and begins a fresh run. Server only.
##
## The plan's gate is that three resets leave one raft and one body per player, so this
## deliberately does NOT free and respawn bodies: it moves the ones that already exist. Freeing
## them would race the spawner, which replicates its own create/destroy messages, and a body
## recreated while a stale despawn is in flight is exactly how a peer ends up with none or two.
func reset_run() -> void:
	if not _is_run_authority():
		return
	_director.reset_run()

	if raft != null:
		# The whole transform, not just the position: the raft is moored pointing at the
		# mainland, and a reset that zeroed its rotation sent the next crew north.
		raft.transform = _raft_start
		raft.linear_velocity = Vector3.ZERO
		raft.angular_velocity = Vector3.ZERO

	var slot := 0
	for child in _players.get_children():
		var body := child as NetworkPlayer
		if body == null:
			continue
		# Intent is cleared as well as position: a player holding a key through a reset would
		# otherwise start the new run already moving, and on the authority that intent arrived
		# over the network rather than from this machine's keyboard.
		var input := body.input_node()
		if input != null:
			input.clear_intent()
		# Each body is given its own slot. Asking _spawn_position would hand every one of them
		# the same spot, because it counts the bodies that exist, and during a reset they all do.
		body.position = _crew_position(slot) if home != null else _spawn_position(
			body.owner_peer_id)
		slot += 1
		body.rotation = Vector3.ZERO
		body.linear_velocity = Vector3.ZERO
		body.angular_velocity = Vector3.ZERO

	begin_voyage()


func _unhandled_input(event: InputEvent) -> void:
	super(event)
	var key := event as InputEventKey
	if key == null or not key.is_pressed() or key.echo:
		return
	if key.keycode == KEY_R and _is_run_authority():
		reset_run()


## Spawns the crew on the home island rather than on the raft.
##
## [MultiplayerGame] seats everyone on the raft; the voyage starts ashore, so the crew has a
## reason to board. Falls back to the inherited raft slot when no home island is assigned.
func _spawn_position(peer_id: int) -> Vector3:
	if home == null:
		return super(peer_id)
	return _crew_position(_players.get_child_count())


## Returns where crew member [param slot] stands at the start of a run.
##
## On a ring inside the home island's plateau, on the side the raft is moored off, with the slots
## spread alternately either side of that bearing. The crew used to start on the far side, from
## where the raft was 58 m away behind the island's crest and a first-time player could see
## neither it nor the mountains the objective names.
func _crew_position(slot: int) -> Vector3:
	var ring := home.plateau_radius * 0.45
	# 0, +1, -1, +2, -2 ... steps of SPAWN_SPACING along the ring from the bearing to the raft.
	var steps := ceili(slot / 2.0) * (1 if slot % 2 == 1 else -1)
	var bearing := _launch_bearing() + float(steps) * (SPAWN_SPACING / maxf(ring, 0.001))
	var spot := Vector2(
		home.global_position.x + cos(bearing) * ring,
		home.global_position.z + sin(bearing) * ring,
	)
	return Vector3(spot.x, home.height_at_world(spot) + 0.35, spot.y)


## Returns the bearing from the home island's centre to where the raft is moored, in the XZ plane.
##
## Measured to the mooring rather than to the raft, so a reset puts the crew back on the side the
## raft is about to be returned to, wherever the last crossing left it.
func _launch_bearing() -> float:
	var toward := _raft_start.origin if raft != null else (
		mainland.global_position if mainland != null else home.global_position + Vector3.RIGHT)
	return atan2(toward.z - home.global_position.z, toward.x - home.global_position.x)


## Turns this peer's view toward the mainland as seen from [param from], so the destination is
## the first thing it sees.
##
## Local presentation, like everything the camera does: each peer turns its own view, and the
## mouse can turn it away again at once. The viewpoint is passed in rather than read off the
## followed body, because on a reset the body is still wherever the last crossing ended when the
## reset is announced — on the mainland itself, from where "toward the mainland" is anywhere.
func _face_destination(from: Vector3) -> void:
	if mainland == null or _camera == null:
		return
	_camera.face(mainland.global_position - from)


## Builds a player body, and turns this peer's view toward the mainland once its own body exists.
##
## The view already opens facing the mainland, but from the scene camera's position, and the mouse
## may have moved it since. Turning it again from the body is what makes the first frame of play
## show the raft below and the mountains beyond it.
func _spawn_player(data: Dictionary) -> Node:
	var body := super(data) as Node3D
	if body != null and int(data.get("peer_id", 1)) == NetworkSession.local_peer_id():
		# Connected after the base class's own ready handler, which is the one that makes the
		# camera follow this body, so the view is turned from where the body actually stands.
		body.ready.connect(func() -> void: _face_destination(body.global_position),
			CONNECT_ONE_SHOT)
	return body


## Hands a joiner the run baseline alongside the weather the base class already sends.
func _on_player_joined(peer_id: int, player_name: String) -> void:
	super(peer_id, player_name)
	if not _is_run_authority():
		return
	if peer_id != NetworkSession.SERVER_PEER_ID:
		_director.send_baseline_to(peer_id)
	# A crew that was waiting in the lobby starts crossing as soon as someone is aboard.
	if _director.phase == RunDirector.Phase.LOBBY:
		begin_voyage()


func _on_session_started(as_server: bool) -> void:
	super(as_server)
	if as_server:
		begin_voyage()


func _on_phase_changed(_phase: RunDirector.Phase, _revision: int) -> void:
	_refresh_status()


func _on_run_reset(_epoch: int) -> void:
	# Every peer hears the reset, so each crew member is turned back toward the mainland. Seen
	# from the home island, where the reset is returning them, not from where they stand now.
	_face_destination(home.global_position if home != null else _camera.global_position)
	_refresh_status()


## True when this peer decides the run: the server, or an offline single-player launch.
func _is_run_authority() -> bool:
	if not multiplayer.has_multiplayer_peer():
		return true
	return multiplayer.is_server()


## True when any player is ashore on the mainland.
func _anyone_ashore() -> bool:
	if mainland == null:
		return false
	var limit := mainland.plateau_radius + ARRIVAL_MARGIN
	for child in _players.get_children():
		var body := child as Node3D
		if body == null:
			continue
		var here := Vector2(body.global_position.x, body.global_position.z)
		var centre := Vector2(mainland.global_position.x, mainland.global_position.z)
		if here.distance_to(centre) < limit:
			return true
	return false


## Where the raft began and which way it pointed, so a reset can put it back as it was.
@onready var _raft_start: Transform3D = raft.transform if raft != null else Transform3D.IDENTITY


func _refresh_status() -> void:
	super()
	if _status == null or _director == null:
		return
	# Appended rather than replacing the roster text, so the objective is added to what the
	# base class already renders instead of competing with it for the same label.
	_status.text = "%s\n\n%s" % [_status.text, _director.objective()]
