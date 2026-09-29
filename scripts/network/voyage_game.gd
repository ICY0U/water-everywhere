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

## How far out from the home island's centre the crew is put ashore, as a fraction of its plateau.
##
## Toward the rim on the jetty's side, so the first thing a player sees is the way down to the
## raft rather than the middle of a sand dune.
const SPAWN_RING_FRACTION: float = 0.7

## Metres between neighbouring crew members along the spawn arc. A player is 1.55 m across.
const SPAWN_SPACING: float = 2.6

## Metres above the analytic ground a player is dropped from, so the solver settles them onto the
## real collision surface rather than trusting the profile to agree with the mesh to the millimetre.
const SPAWN_DROP_HEIGHT: float = 0.35

## Island the crew is sailing towards. Reaching it ends the run.
@export var mainland: Island

## Island the crew starts on.
@export var home: Island

## The landmark the crossing is steered by. Optional; without it the mainland's centre is used.
@export var lighthouse: Node3D

@onready var _director: RunDirector = $RunDirector

var _arrival_elapsed: float = 0.0


func _ready() -> void:
	super()
	_director.phase_changed.connect(_on_phase_changed)
	_director.run_reset.connect(_on_run_reset)
	# Tied up from the first frame, so the raft is waiting at the jetty rather than drifting off
	# while the crew is still walking down to it. Only the authority simulates the raft, so this
	# is a no-op anywhere else and the replicated value takes over.
	if raft != null:
		raft.moor_here()
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
		# The whole transform, heading included: the raft starts pointed at the mainland, and a
		# reset that zeroed its rotation would hand the next crew a raft facing north.
		raft.transform = _raft_start
		raft.linear_velocity = Vector3.ZERO
		raft.angular_velocity = Vector3.ZERO
		raft.moor_here()

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
		# One slot per body. Asking _spawn_position for each would hand every one of them the SAME
		# slot, because it counts the players that exist, and that count does not change during a
		# reset: three crew would be dropped inside one another.
		body.position = _spawn_slot(slot)
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
	return _spawn_slot(_players.get_child_count())


## Returns the [param index]th place ashore, on the side of the home island facing the raft.
##
## Slots fan out alternately either side of the bearing to the raft, so a crew of any size stands
## together looking down the jetty, and the first player is on the line straight to it.
func _spawn_slot(index: int) -> Vector3:
	if home == null:
		return super._spawn_position(0)
	var ring := home.plateau_radius * SPAWN_RING_FRACTION
	var step := SPAWN_SPACING / maxf(ring, 0.001)
	var side := 1.0 if index % 2 == 1 else -1.0
	var bearing := _departure_bearing() + side * float(ceili(float(index) * 0.5)) * step
	var spot := Vector2(
		home.global_position.x + cos(bearing) * ring,
		home.global_position.z + sin(bearing) * ring,
	)
	return Vector3(spot.x, home.height_at_world(spot) + SPAWN_DROP_HEIGHT, spot.y)


## Returns the bearing from the home island's centre toward where the raft starts, in radians.
func _departure_bearing() -> float:
	if home == null or raft == null:
		return PI
	var toward := _raft_start.origin - home.global_position
	return atan2(toward.z, toward.x)


## Returns the point the crew is steering for: the lighthouse, or the mainland without one.
func destination() -> Vector3:
	if is_instance_valid(lighthouse):
		return lighthouse.global_position
	if mainland != null:
		return mainland.global_position
	return Vector3.ZERO


## Builds a player, and turns this peer's own camera toward the lighthouse once its body exists.
func _spawn_player(data: Dictionary) -> Node:
	var body := super(data)
	if int(data.get("peer_id", 1)) == NetworkSession.local_peer_id():
		body.ready.connect(_face_destination, CONNECT_ONE_SHOT)
	return body


## Points the local camera across the water at the destination.
func _face_destination() -> void:
	if _camera != null:
		_camera.look_toward(destination())


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
	_refresh_status()
	# Every peer turns its own camera: the view is local, and a crew reset to the jetty should be
	# looking at the crossing ahead rather than at wherever the last one ended.
	_face_destination()


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


## Where the raft began, heading included, so a reset can put it back exactly.
@onready var _raft_start: Transform3D = raft.transform if raft != null else Transform3D.IDENTITY


func _refresh_status() -> void:
	super()
	if _status == null or _director == null:
		return
	# Appended rather than replacing the roster text, so the objective is added to what the
	# base class already renders instead of competing with it for the same label.
	_status.text = "%s\n\n%s" % [_status.text, _director.objective()]
