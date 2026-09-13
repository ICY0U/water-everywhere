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
		raft.position = _raft_start
		raft.rotation = Vector3.ZERO
		raft.linear_velocity = Vector3.ZERO
		raft.angular_velocity = Vector3.ZERO

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
		body.position = _spawn_position(body.owner_peer_id)
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
	var ring := home.plateau_radius * 0.45
	var bearing := float(_players.get_child_count()) * (2.6 / maxf(ring, 0.001))
	var spot := Vector2(
		home.global_position.x + cos(bearing) * ring,
		home.global_position.z + sin(bearing) * ring,
	)
	return Vector3(spot.x, home.height_at_world(spot) + 0.35, spot.y)


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


## Where the raft began, so a reset can put it back.
@onready var _raft_start: Vector3 = raft.position if raft != null else Vector3.ZERO


func _refresh_status() -> void:
	super()
	if _status == null or _director == null:
		return
	# Appended rather than replacing the roster text, so the objective is added to what the
	# base class already renders instead of competing with it for the same label.
	_status.text = "%s\n\n%s" % [_status.text, _director.objective()]
