extends SceneTree

## Sails the voyage end to end, the way a player would, and fails if the crossing cannot be made.
##
## Every other voyage check moves bodies by hand: [code]tools/verify_voyage.gd[/code] proves the
## arrival RULE by dropping a player on the mainland, and says so. Nothing had ever proved the
## crossing could be SAILED, and when it was tried it could not — the raft sat grounded in the
## shallows facing north, six shoves moved it 1.5 m, a lone paddler boarded at the far edge and
## turned it back into the beach, and even in open water it made 0.3 m/s, ten minutes for the
## crossing. This suite is the guard against any of that coming back.
##
## [b]A bot, not a script of positions.[/b] It only ever does what a player can: it sets the
## same [PlayerInput] fields a keyboard sets — a movement direction, a board count, a stroke count
## — and the server-side code under test does everything else. It walks down the jetty, climbs
## aboard, paddles, steers by standing left or right of the centreline exactly as a human must,
## walks off the beached raft and up the beach. If it arrives, a player can.
##
## [b]What it does not prove.[/b] That the crossing is fun, or the right length; it asserts a
## generous time budget, not a feel. It is one skilled, patient crew member in each weather; it
## says nothing about a first-time player finding the controls, which is what the HUD is for.
##
## Run with (the fixed frame rate lets it run faster than real time):
## [codeblock lang=text]
## godot --path . --headless --fixed-fps 60 --script tools/verify_crossing.gd
## [/codeblock]
## Pass [code]-- --weather=N[/code] to sail one preset only. Exits non-zero on any failure.

const SCENE := "res://scenes/voyage.tscn"

## Simulated seconds allowed for the whole voyage, from spawn to arrival, per weather.
##
## Generous on purpose. The target for a solo crossing is two to three minutes; this is the line
## past which the voyage is broken rather than slow, and it scales for the rougher seas, where the
## crew spends time in the water.
const BUDGET_SECONDS: Array[float] = [300.0, 330.0, 420.0]

## Preset names, for the report. Indices match the voyage scene's weather presets.
const WEATHER_NAMES: Array[String] = ["sunny", "overcast", "stormy"]

## Metres from a deck target at which the bot stops walking toward it.
const DECK_TOLERANCE: float = 0.35

## Heading error, in degrees, inside which the bot paddles from the centre and goes straight.
const STRAIGHT_DEGREES: float = 4.0

## How far off the centreline the bot stands per degree of heading error, in metres.
const STEER_GAIN: float = 0.09

## Furthest the bot steps off the centreline, in metres: the deck's spawn-slot edge.
const STEER_LIMIT: float = 2.7

## Raft speed below which, near the mainland, the bot treats the raft as beached.
const BEACHED_SPEED: float = 0.25

## Seconds the raft must stay that slow before the bot gives up on it and wades ashore.
const BEACHED_SECONDS: float = 2.5

## Distance from the mainland's centre inside which a slow raft counts as beached rather than
## merely slowed by a wave.
const BEACH_RADIUS: float = 112.0

enum Step { TO_JETTY, DOWN_JETTY, BOARD, PADDLE, ASHORE, ARRIVED }

var _failures: int = 0
var _game: Node3D
var _body: NetworkPlayer
var _input: PlayerInput
var _raft: Raft
var _director: RunDirector
var _jetty: Node3D
var _step: Step = Step.TO_JETTY
var _clock: float = 0.0
var _stroke_clock: float = 0.0
var _slow_clock: float = 0.0
var _milestones: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var only := -1
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--weather="):
			only = int(argument.trim_prefix("--weather="))
	for weather in WEATHER_NAMES.size():
		if only >= 0 and weather != only:
			continue
		await _sail(weather)
	print("verify_crossing: %d failures" % _failures)
	quit(1 if _failures else 0)


## Builds a fresh voyage in [param weather] and sails it, recording each milestone.
func _sail(weather: int) -> void:
	_step = Step.TO_JETTY
	_clock = 0.0
	_stroke_clock = 0.0
	_slow_clock = 0.0
	_milestones = {}

	_game = load(SCENE).instantiate()
	root.add_child(_game)
	current_scene = _game
	await physics_frame
	_game.weather.apply_index(weather)
	_director = _game.director()
	_raft = _game.raft
	_jetty = _game.get_node_or_null("HomeJetty")
	_game.begin_voyage()
	_game._spawn_for_peer(1)
	_body = _game.get_node("Players/1") as NetworkPlayer
	_input = _body.input_node()
	# The bot writes intent directly, as the synchroniser would deliver it from a client. Left
	# processing, the node would clear that intent every frame for want of a captured mouse.
	_input.set_process(false)
	var label := WEATHER_NAMES[weather]

	_expect(_jetty != null, "%s: the voyage has a jetty to leave from" % label)
	_expect(_raft.moored, "%s: the raft starts moored" % label)

	var budget := BUDGET_SECONDS[weather]
	while _step != Step.ARRIVED and _clock < budget:
		_tick(1.0 / Engine.physics_ticks_per_second)
		await physics_frame
		_clock += 1.0 / Engine.physics_ticks_per_second

	_input.move_direction = Vector2.ZERO
	for milestone: String in ["aboard", "cast off", "beached", "arrived"]:
		var at: Variant = _milestones.get(milestone)
		print("  %-8s %-9s %s" % [label, milestone, "%.1f s" % at if at != null else "never"])

	_expect(_milestones.has("aboard"), "%s: the crew reaches the raft and climbs aboard" % label)
	_expect(_milestones.has("cast off"), "%s: the first stroke casts off the mooring" % label)
	_expect(
		_director.phase == RunDirector.Phase.ARRIVAL,
		"%s: the crossing is sailed to the mainland within %.0f s (%s)" % [
			label, budget,
			"%.1f s" % _milestones["arrived"] if _milestones.has("arrived") else "not arrived",
		]
	)
	if _milestones.has("cast off") and _milestones.has("beached"):
		var sailing: float = _milestones["beached"] - _milestones["cast off"]
		print("  %-8s paddling took %.1f s" % [label, sailing])

	_game.queue_free()
	await process_frame
	await process_frame


## One frame of the bot's decision-making.
func _tick(delta: float) -> void:
	if _director.phase == RunDirector.Phase.ARRIVAL:
		_mark("arrived")
		_step = Step.ARRIVED
		return
	match _step:
		Step.TO_JETTY:
			# The landward end of the jetty, then its seaward end: the jetty is narrow and the
			# beach beside it slopes into the sea.
			if _walk_to(_jetty.global_position + _jetty_direction() * 2.0, 1.0):
				_step = Step.DOWN_JETTY
		Step.DOWN_JETTY:
			var end: Vector3 = _jetty.call("end_position")
			if _walk_to(end - _jetty_direction() * 0.8, 0.8) or _board_reach() < NetworkPlayer.BOARD_RANGE - 1.0:
				_step = Step.BOARD
		Step.BOARD:
			_input.move_direction = Vector2.ZERO
			if _is_aboard():
				_mark("aboard")
				_step = Step.PADDLE
			elif int(_clock * 60.0) % 30 == 0:
				_input.board_requests += 1
			elif _board_reach() > NetworkPlayer.BOARD_RANGE - 0.5:
				_walk_to(_raft.global_position, 0.0)
		Step.PADDLE:
			_paddle(delta)
		Step.ASHORE:
			_walk_to(_game.destination(), 0.0, true)


## Keeps the raft pointed at the lighthouse and paddling, and notices when it has beached.
func _paddle(delta: float) -> void:
	if not _is_aboard():
		# Washed off. Swim back and climb on again; a player would.
		if _board_reach() < NetworkPlayer.BOARD_RANGE - 1.0:
			_input.move_direction = Vector2.ZERO
			if int(_clock * 60.0) % 30 == 0:
				_input.board_requests += 1
		else:
			_walk_to(_raft.global_position, 0.0, true)
		return

	if not _raft.moored:
		_mark("cast off")

	var to_target: Vector3 = _game.destination() - _raft.global_position
	var forward := -_raft.global_basis.z
	forward.y = 0.0
	to_target.y = 0.0
	var error := rad_to_deg(forward.signed_angle_to(to_target, Vector3.UP))
	# A positive error means the lighthouse is to port. A stroke from the starboard side turns the
	# bow to port, so the bot stands to starboard: the same rule the HUD teaches a player.
	var lateral := 0.0
	if absf(error) > STRAIGHT_DEGREES:
		lateral = clampf(error * STEER_GAIN, -STEER_LIMIT, STEER_LIMIT)
	var spot := _raft.to_global(Vector3(lateral, Raft.DECK_HEIGHT, 0.0))
	var offset := Vector2(spot.x - _body.global_position.x, spot.z - _body.global_position.z)
	if offset.length() > DECK_TOLERANCE:
		_input.move_direction = offset.normalized() * clampf(offset.length(), 0.3, 1.0)
	else:
		_input.move_direction = Vector2.ZERO

	# Holding the paddle key: one stroke per stroke length, as PlayerInput asks while held.
	_stroke_clock -= delta
	if _stroke_clock <= 0.0:
		_input.paddle_strokes += 1
		_stroke_clock = Raft.STROKE_DURATION

	var mainland: Node3D = _game.mainland
	var centre := Vector2(mainland.global_position.x, mainland.global_position.z)
	var here := Vector2(_raft.global_position.x, _raft.global_position.z)
	var speed := Vector2(_raft.linear_velocity.x, _raft.linear_velocity.z).length()
	if here.distance_to(centre) < BEACH_RADIUS and speed < BEACHED_SPEED:
		_slow_clock += delta
	else:
		_slow_clock = 0.0
	if _slow_clock > BEACHED_SECONDS:
		_mark("beached")
		_step = Step.ASHORE


## Walks (or swims) toward [param target]; returns true once within [param tolerance] metres.
func _walk_to(target: Vector3, tolerance: float, sprint: bool = false) -> bool:
	var offset := Vector2(target.x - _body.global_position.x, target.z - _body.global_position.z)
	_input.wants_sprint = sprint
	if offset.length() <= tolerance:
		_input.move_direction = Vector2.ZERO
		return true
	_input.move_direction = offset.normalized()
	return false


## Horizontal distance from the player to the raft's centre: what boarding measures.
func _board_reach() -> float:
	var offset := _raft.global_position - _body.global_position
	return Vector2(offset.x, offset.z).length()


func _is_aboard() -> bool:
	return _body.standing_on() == _raft


## The jetty's seaward direction, flattened.
func _jetty_direction() -> Vector3:
	var along := -_jetty.global_basis.z
	along.y = 0.0
	return along.normalized()


func _mark(milestone: String) -> void:
	if not _milestones.has(milestone):
		_milestones[milestone] = _clock


func _expect(condition: bool, message: String) -> void:
	print("%s %s" % ["PASS " if condition else "FAIL ", message])
	if not condition:
		_failures += 1
