class_name VoyageGame
extends MultiplayerGame

## The crossing: leave the home island, cross open water, reach the lighthouse on the mainland.
##
## Built on the A04 skeleton — an authoritative run phase, an objective every peer reads from it,
## and a reset to a known state — and now the game's main scene. On top of [MultiplayerGame] it
## adds:
##
## * [b]the front end[/b], a [GameUI] whose title screen is this very scene: the raft waits at
##   its jetty behind the menu, and choosing to sail starts a session here with no second load;
## * [b]solo, host and join[/b] entry points for that menu, solo running the whole authoritative
##   game on an [OfflineMultiplayerPeer] with no socket open;
## * [b]arrival facts[/b] — time, strokes, who landed first — recorded by the authority and sent
##   with the ARRIVAL transition, so every peer's summary is the same one;
## * [b]the soundscape[/b], a [VoyageSoundscape] that hears strokes, splashes and footsteps from
##   the replicated state already on every peer.
##
## Launched with [code]--server[/code] or [code]--client[/code] it skips the title and behaves
## exactly as it did before, which is what the two-window development test relies on.

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

## Controls named in the key legend, in the order they are learned.
const LEGEND: Array = [
	[&"board", "Board"],
	[&"paddle", "Paddle"],
	[&"push", "Push"],
	[&"toggle_view", "View"],
	[&"pause", "Menu"],
]

## Island the crew is sailing towards. Reaching it ends the run.
@export var mainland: Island

## Island the crew starts on.
@export var home: Island

## The landmark the crossing is steered by. Optional; without it the mainland's centre is used.
@export var lighthouse: Node3D

@onready var _director: RunDirector = $RunDirector

## Where the raft began, heading included, so a reset can put it back exactly.
@onready var _raft_start: Transform3D = raft.transform if raft != null else Transform3D.IDENTITY

var _arrival_elapsed: float = 0.0
var _ui: GameUI
var _soundscape: VoyageSoundscape

## The raft's stroke serial when this crossing began, so the summary counts this run's strokes.
var _strokes_at_start: int = 0

## Whether the raft was moored last frame, to catch the moment it casts off on every peer.
var _was_moored: bool = true


func _ready() -> void:
	super()
	_director.phase_changed.connect(_on_phase_changed)
	_director.run_reset.connect(_on_run_reset)
	# Tied up from the first frame, so the raft is waiting at the jetty rather than drifting off
	# while the crew is still walking down to it. Only the authority simulates the raft, so this
	# is a no-op anywhere else and the replicated value takes over.
	if raft != null:
		raft.moor_here()

	_soundscape = VoyageSoundscape.new()
	_soundscape.name = "Soundscape"
	_soundscape.game = self
	add_child(_soundscape)

	_ui = GameUI.new()
	_ui.name = "GameUI"
	_ui.game = self
	_ui.camera = _camera
	add_child(_ui)
	_style_legend()
	if weather != null:
		# Re-applied after every weather change, because a preset writes the environment's
		# volumetric fog flag itself and would otherwise turn fog back on under a Low setting.
		weather.weather_changed.connect(func(_preset: WeatherPreset, _index: int) -> void:
			apply_graphics_quality())
	apply_graphics_quality()
	# The objective belongs on screen from the first frame, not from the first phase change.
	_refresh_status()


func _process(delta: float) -> void:
	super(delta)
	_watch_mooring()
	if _director.phase != RunDirector.Phase.VOYAGE:
		return
	if not _is_run_authority():
		return
	_arrival_elapsed += delta
	if _arrival_elapsed < ARRIVAL_INTERVAL:
		return
	_arrival_elapsed = 0.0
	var first := _first_ashore()
	if first != null:
		_director.advance_to(RunDirector.Phase.ARRIVAL, _arrival_facts(first))


## Returns the run director, so tests and UI can read the authoritative phase.
func director() -> RunDirector:
	return _director


## Returns the front end, or null before it exists.
func ui() -> GameUI:
	return _ui


## Starts the crossing. Server only; safe to call when already under way.
func begin_voyage() -> void:
	if _director.phase != RunDirector.Phase.VOYAGE and raft != null:
		_strokes_at_start = raft.stroke_serial
	_director.advance_to(RunDirector.Phase.VOYAGE)


## Sets sail alone, in the sea state at [param sea_state].
func start_solo(player_name: String, sea_state: int) -> Error:
	_restore_world()
	if weather != null:
		weather.apply_index(sea_state)
	return NetworkSession.start_solo(player_name)


## Hosts a crewed voyage on [param port], in the sea state at [param sea_state].
func host_session(player_name: String, port: int, sea_state: int) -> Error:
	_restore_world()
	if weather != null:
		weather.apply_index(sea_state)
	var error := NetworkSession.host(port, player_name)
	_report_start(error)
	return error


## Joins a voyage hosted at [param address]. The host decides the weather.
func join_session(address: String, port: int, player_name: String) -> Error:
	_restore_world()
	var error := NetworkSession.join(address, port, player_name)
	_report_start(error)
	return error


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
	_return_raft()

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


## Redraws the key legend, for a change of input device.
func refresh_legend() -> void:
	_refresh_status()


## Applies the graphics preset to this scene's own nodes. See [GraphicsQuality].
func apply_graphics_quality() -> void:
	var settings := get_node_or_null(^"/root/Settings")
	var level: int = settings.call(&"quality") if settings != null else 2
	var environment := (
		$WorldEnvironment.environment as Environment if has_node(^"WorldEnvironment") else null
	)
	GraphicsQuality.apply_to_scene(
		level, environment, get_node_or_null(^"SunLight") as DirectionalLight3D,
		ocean.foam_field if ocean != null else null,
	)


func _unhandled_input(event: InputEvent) -> void:
	super(event)
	var key := event as InputEventKey
	if key == null or not key.is_pressed() or key.echo:
		return
	# R sails again, but only once the crossing is over: a stray R halfway across would throw
	# away a voyage, and the pause menu is where a deliberate restart lives.
	if (
		key.keycode == KEY_R and _is_run_authority()
		and _director.phase == RunDirector.Phase.ARRIVAL
	):
		if _ui != null:
			_ui.sail_again()
		else:
			reset_run()


## P opens the voyage menu, which pauses a solo game, rather than freezing the world silently.
func _toggle_pause() -> void:
	if _ui != null:
		_ui.open_pause()
	else:
		super()


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


## Puts the world back as the title screen shows it once a session is over, however it ended.
func _on_session_ended(reason: String) -> void:
	super(reason)
	_restore_world()


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


## Returns the first player found ashore on the mainland, or null when nobody is.
func _first_ashore() -> NetworkPlayer:
	if mainland == null:
		return null
	var limit := mainland.plateau_radius + ARRIVAL_MARGIN
	var centre := Vector2(mainland.global_position.x, mainland.global_position.z)
	for child in _players.get_children():
		var body := child as NetworkPlayer
		if body == null:
			continue
		var here := Vector2(body.global_position.x, body.global_position.z)
		if here.distance_to(centre) < limit:
			return body
	return null


## What the summary reports, measured here on the authority at the moment of arrival.
func _arrival_facts(first: NetworkPlayer) -> Dictionary:
	var crew: Array[String] = []
	for child in _players.get_children():
		var body := child as NetworkPlayer
		if body != null:
			crew.append(body.player_name)
	return {
		"seconds": _director.voyage_seconds,
		"strokes": raft.stroke_serial - _strokes_at_start if raft != null else 0,
		"first": first.player_name,
		"crew": crew,
		"weather": weather.current_index() if weather != null else 0,
	}


## Sends the raft back to its berth and the run back to the lobby, with nobody aboard.
##
## For the title screen: after a session ends, and before a new one starts, so every voyage begins
## from the same place however the last one finished. Runs on whichever peer is now offline, which
## makes it the authority over its own copy of the world.
func _restore_world() -> void:
	if not _is_run_authority():
		return
	_return_raft()
	if _director.phase != RunDirector.Phase.LOBBY:
		_director.reset_run()


func _return_raft() -> void:
	if raft == null:
		return
	# The whole transform, heading included: the raft starts pointed at the mainland, and a reset
	# that zeroed its rotation would hand the next crew a raft facing north.
	raft.transform = _raft_start
	raft.linear_velocity = Vector3.ZERO
	raft.angular_velocity = Vector3.ZERO
	raft.moor_here()
	_was_moored = true


## Marks the moment the raft casts off, on every peer, from the replicated mooring flag.
func _watch_mooring() -> void:
	if raft == null:
		return
	if _was_moored and not raft.moored and _director.phase == RunDirector.Phase.VOYAGE:
		if _ui != null and NetworkSession.is_active():
			_ui.hud.toast("Cast off!", UiStyle.ACCENT)
			Audio.play_sting(&"castoff")
	_was_moored = raft.moored


## Replaces the development roster with a one-line key legend for the voyage.
##
## The roster moved into the HUD's crew panel and the objective into its own card, so this label
## keeps one job: naming the keys, read from the input map rather than typed, so a rebinding
## cannot leave it naming a key that does nothing.
func _refresh_status() -> void:
	if _status == null:
		return
	var parts := PackedStringArray()
	for control: Array in LEGEND:
		var key: String = _ui.key_name(control[0]) if _ui != null else _key_name(control[0])
		if not key.is_empty():
			parts.append("%s  %s" % [key, control[1]])
	var legend := "      ".join(parts)
	if not _status_notice.is_empty():
		legend = "%s\n%s" % [_status_notice, legend]
	_status.text = legend


## Moves the legend to the bottom-left corner and gives it the interface's type.
func _style_legend() -> void:
	if _status == null:
		return
	_status.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_status.offset_left = 22
	_status.offset_right = 900
	_status.offset_top = -46
	_status.offset_bottom = -16
	_status.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_status.add_theme_font_override(&"font", UiStyle.body_font(800))
	_status.add_theme_font_size_override(&"font_size", 17)
	_status.add_theme_color_override(&"font_color", Color(UiStyle.TEXT, 0.9))
	_status.add_theme_color_override(&"font_outline_color", UiStyle.OUTLINE)
	_status.add_theme_constant_override(&"outline_size", 4)
