extends SceneTree

## B01 gate checks for the paddle, over a real loopback connection.
##
## B01's gate is that host and client both see a stroke start and stop, that a stroke requested
## from off the raft is refused, and that missing input stops thrust. Every one of those is a
## claim about what crosses the network or what the server decides, so they are asserted against
## a genuine ENet server and client rather than by calling [method Raft.request_stroke] directly.
##
## [b]Fixture.[/b] Server and client are two branches of this one [SceneTree], each with its own
## [MultiplayerAPI], ocean, raft and player spawner, as [code]tools/verify_multiplayer.gd[/code]
## does. The branches share ONE physics world, and a frozen [RigidBody3D] still collides —
## [code]freeze_mode[/code] defaults to static — so the client's proxies are taken out of it. Only
## the proxies: the server's player has to stand on the server's raft. Zeroing both rafts, as the
## raft check in [code]verify_multiplayer.gd[/code] can afford to, would drop the paddler through
## the deck, and every stroke would be refused for a reason that has nothing to do with paddling.
##
## [b]Not the voyage scene.[/b] A script extending [MultiplayerGame] cannot host a session under
## [code]--script[/code] ([code]tools/verify_voyage.gd[/code] documents why), and the paddle is
## wired into [NetworkPlayer], which every game scene shares, so a bare raft tests the same code.
##
## [b]What this does not prove.[/b] Whether paddling feels right, or moves the raft enough to
## matter. The raft's mass is under review, so the movement and turning checks compare strokes
## against the raft's own drift and a noise floor, never against a speed or a rate of turn. They
## show that a stroke pushes the hull, and turns it the right way for the side it is taken from;
## how much is a tuning decision the gate leaves to a human.
##
## Run with:
## [codeblock lang=text]
## godot --path . --headless --script tools/verify_b01_paddle.gd
## [/codeblock]
## Exits non-zero if any check fails, so it is usable from CI.

## Port for the loopback session: clear of the game's default and of every other suite's port.
const TEST_PORT: int = 27123

## Real seconds allowed before the run is abandoned.
const TIMEOUT_SECONDS: float = 150.0

## Real seconds allowed for the client to finish connecting.
const CONNECT_SECONDS: float = 5.0

## Simulated seconds for the raft to float before anyone is put on it.
const RAFT_SETTLE_SECONDS: float = 4.0

## Simulated seconds allowed for a player to come to rest on the deck or in the water.
const STANCE_SECONDS: float = 8.0

## Simulated seconds allowed for a value to cross the loopback connection.
##
## Loopback delivers in a frame or two. This is generous so a slow frame is not read as a lost
## packet.
const REPLICATION_SECONDS: float = 0.3

## Simulated seconds within which thrust must end once no new stroke arrives.
##
## A stroke can still be pending when input stops, because [NetworkPlayer] holds one through a
## cooldown rather than dropping it. That stroke waits at most one [constant Raft.STROKE_DURATION]
## to be served, thrusts for one more, and the result has to cross the wire.
const STOP_BOUND: float = Raft.STROKE_DURATION * 2.0 + REPLICATION_SECONDS

## Metres east of the raft's centre a player is put in the water for the off-raft checks.
##
## The hull is 9 by 9.6 m, so this is open water a few metres past the gunwale.
const SWIM_OFFSET: float = 12.0

## Metres either side of the raft's centreline a paddler stands for the turning check.
##
## The deck spawn slots in [constant Raft.SPAWN_OFFSETS] use 2.7, so a player is known to fit.
const EDGE_OFFSET: float = 2.7

## Simulated seconds for the raft to stop rocking after a player is put down on its deck.
##
## Putting the paddler down at an edge yaws the raft by itself: measured at 0.00025 rad in the
## window straight after, larger than a whole stroke's turn at the stock stroke force. Both the
## control and the paddled window start only once that has died away.
const EDGE_SETTLE_SECONDS: float = 3.0

## How many times the raft's own drift a paddled change must exceed to count as the stroke's.
const DRIFT_RATIO: float = 3.0

## Least horizontal travel, in metres, accepted as a stroke's rather than numerical noise.
##
## Not a feel target. A calm sea can leave drift at exactly zero, and any multiple of zero is
## zero, so this floor is what stops a solver's rounding from satisfying the movement check.
const TRAVEL_FLOOR: float = 0.001

## Least change of heading, in radians, accepted as a stroke's rather than numerical noise.
##
## Not a feel target either, for the same reason as [constant TRAVEL_FLOOR].
const YAW_FLOOR: float = 0.001

## Checks this suite reports.
##
## Compared in both directions in [method _finish]: a check that threw partway is then a failure
## rather than a silence, and adding a check without updating this number cannot cancel out a
## real failure, which is how [code]verify_multiplayer.gd[/code] once exited 0 while red.
const EXPECTED_CHECKS: int = 21

var _failures: int = 0
var _reported: int = 0
var _finished: bool = false

var _client_api: MultiplayerAPI
var _server_root: Node
var _client_root: Node
var _server_raft: Raft
var _client_raft: Raft
var _server_body: NetworkPlayer
var _client_body: NetworkPlayer
var _server_input: PlayerInput
var _client_input: PlayerInput
var _camera: PlayerCamera


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	# Real time, not simulated: the watchdog exists to catch a run that has stopped advancing.
	create_timer(TIMEOUT_SECONDS).timeout.connect(_on_timed_out)

	if not await _connect():
		_finish()
		return
	if not await _build_world():
		_finish()
		return

	await _check_stroke_starts_and_stops()
	await _check_stalled_input_stops_thrust()
	_check_clear_intent_keeps_count()
	await _check_burst_is_one_stroke()
	await _check_off_raft_refused()
	await _check_client_cannot_stroke()
	await _check_raft_moves()
	await _check_turning()
	_finish()


## Hosts and joins over loopback. Returns false, having reported why, if either side fails.
func _connect() -> bool:
	_server_root = Node.new()
	_server_root.name = "ServerRoot"
	root.add_child(_server_root)
	_client_root = Node.new()
	_client_root.name = "ClientRoot"
	root.add_child(_client_root)

	var server_peer := ENetMultiplayerPeer.new()
	var host_error := server_peer.create_server(TEST_PORT, 4)
	if host_error != OK:
		# Worded so tools/run_suites.gd reports BUSY: every suite hosts on a fixed port, and the
		# usual cause is another run holding this one rather than anything this suite tests.
		_check("session hosts on port %d" % TEST_PORT, false,
			"%s; is another run using the port?" % error_string(host_error))
		return false
	var server_api := MultiplayerAPI.create_default_interface()
	server_api.multiplayer_peer = server_peer
	set_multiplayer(server_api, _server_root.get_path())

	var client_peer := ENetMultiplayerPeer.new()
	var join_error := client_peer.create_client("127.0.0.1", TEST_PORT)
	if join_error != OK:
		_check("client joins over loopback", false,
			"could not connect: %s" % error_string(join_error))
		return false
	_client_api = MultiplayerAPI.create_default_interface()
	_client_api.multiplayer_peer = client_peer
	set_multiplayer(_client_api, _client_root.get_path())

	var deadline := Time.get_ticks_msec() + roundi(CONNECT_SECONDS * 1000.0)
	while (
		client_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED
		and Time.get_ticks_msec() < deadline
	):
		await process_frame
	var connected := client_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED
	_check("client joins over loopback", connected, "peer id %d" % _client_api.get_unique_id())
	return connected


## Gives both branches a calm ocean, a raft and a player spawner, then spawns the client's player
## onto the settled raft. Returns false, having reported why, if the player never gets aboard.
func _build_world() -> bool:
	var raft_scene := load("res://scenes/raft.tscn") as PackedScene
	var player_scene := load("res://scenes/player.tscn") as PackedScene
	for branch: Node in [_server_root, _client_root]:
		var is_proxy := branch == _client_root
		var ocean := Ocean.new()
		ocean.name = "Ocean"
		# Calm water. Every check here is about what the network carries and what the server
		# decides, and a swell rocking the deck would make "aboard" a question of timing.
		ocean.wave_field = WaveField.new()
		ocean.wave_field.wind_speed = 0.0
		branch.add_child(ocean)

		var raft := raft_scene.instantiate() as Raft
		raft.name = "Raft"
		raft.ocean = ocean
		if is_proxy:
			_remove_from_physics(raft)
		branch.add_child(raft)

		var players := Node3D.new()
		players.name = "Players"
		branch.add_child(players)

		var spawner := MultiplayerSpawner.new()
		spawner.name = "Spawner"
		spawner.spawn_path = NodePath("../Players")
		spawner.spawn_function = func(data: Variant) -> Node:
			var spawn: Dictionary = data
			var body := player_scene.instantiate() as NetworkPlayer
			body.name = str(spawn["peer"])
			body.owner_peer_id = spawn["peer"]
			body.position = spawn["at"]
			body.ocean = ocean
			if is_proxy:
				_remove_from_physics(body)
			return body
		branch.add_child(spawner)

	_server_raft = _server_root.get_node("Raft") as Raft
	_client_raft = _client_root.get_node("Raft") as Raft
	await _wait_physics(RAFT_SETTLE_SECONDS)

	# Onto the raft as it floats now, through the raft's own slot choice, so the paddler lands
	# where a real game would put them.
	var peer_id := _client_api.get_unique_id()
	var deck := _server_raft.spawn_position(_server_root.get_node("Players") as Node3D)
	(_server_root.get_node("Spawner") as MultiplayerSpawner).spawn({"peer": peer_id, "at": deck})
	var path := "Players/%d" % peer_id
	await _wait_until(func() -> bool: return _client_root.has_node(path), STANCE_SECONDS)
	_server_body = _server_root.get_node_or_null(path) as NetworkPlayer
	_client_body = _client_root.get_node_or_null(path) as NetworkPlayer
	if _server_body == null or _client_body == null:
		_check("the paddler settles on the raft deck", false, "the body never reached the client")
		return false

	_server_input = _server_body.input_node()
	_client_input = _client_body.input_node()
	# PlayerInput publishes nothing without a camera to turn keys into world directions. It only
	# has to exist; it is never added to the tree.
	_camera = PlayerCamera.new()
	_client_input.movement_camera = _camera
	_client_input.controls_enabled = true

	var aboard := await _wait_until(_is_aboard, STANCE_SECONDS)
	_check("the paddler settles on the raft deck", aboard, "stance %s, deck-local %s" % [
		NetworkPlayer.Stance.keys()[_server_body.stance],
		_server_raft.to_local(_server_body.global_position),
	])
	return aboard


## A held paddle key strokes on the press and again every stroke. Host and client both see the
## raft start thrusting, and both see it stop once the key is released.
func _check_stroke_starts_and_stops() -> void:
	var count_before := _client_input.paddle_strokes
	var serial_before := _server_raft.stroke_serial
	var client_serial_before := _client_raft.stroke_serial

	Input.action_press(&"paddle")
	await _wait_physics(REPLICATION_SECONDS)
	_check("pressing paddle raises the stroke count",
		_client_input.paddle_strokes == count_before + 1,
		"%d -> %d" % [count_before, _client_input.paddle_strokes])
	_check("the host starts a stroke",
		_server_raft.thrusting and _server_raft.stroke_serial > serial_before,
		"thrusting=%s, serial %d -> %d" % [
			_server_raft.thrusting, serial_before, _server_raft.stroke_serial,
		])
	await _wait_physics(REPLICATION_SECONDS)
	_check("the client sees the stroke start",
		_client_raft.thrusting and _client_raft.stroke_serial > client_serial_before,
		"thrusting=%s, serial %d -> %d" % [
			_client_raft.thrusting, client_serial_before, _client_raft.stroke_serial,
		])

	# Held for two and a half strokes in all: the press, then a repeat at one and at two stroke
	# durations, with half a stroke of margin either side of the last so timing jitter between the
	# client's frame clock and the physics clock cannot add or lose one.
	await _wait_physics(Raft.STROKE_DURATION * 2.5 - REPLICATION_SECONDS * 2.0)
	var requested := _client_input.paddle_strokes - count_before
	Input.action_release(&"paddle")
	_check("holding paddle repeats a stroke every stroke duration", requested == 3,
		"%d strokes requested in %.2f s" % [requested, Raft.STROKE_DURATION * 2.5])

	await _wait_physics(STOP_BOUND)
	_check("each stroke requested is served exactly once",
		_server_raft.stroke_serial - serial_before == requested,
		"%d requested, %d served" % [requested, _server_raft.stroke_serial - serial_before])
	_check("releasing paddle requests no more strokes",
		_client_input.paddle_strokes - count_before == requested,
		"%d after release" % (_client_input.paddle_strokes - count_before))
	_check("the host sees the stroke stop", not _server_raft.thrusting,
		"thrusting=%s %.2f s after release" % [_server_raft.thrusting, STOP_BOUND])
	await _wait_physics(REPLICATION_SECONDS)
	_check("the client sees the stroke stop",
		not _client_raft.thrusting and _client_raft.stroke_serial == _server_raft.stroke_serial,
		"thrusting=%s, serial client %d / host %d" % [
			_client_raft.thrusting, _client_raft.stroke_serial, _server_raft.stroke_serial,
		])


## Missing input stops thrust: the key stays down, but the owner stops publishing strokes.
##
## Stopping the client's input node is how "missing" is simulated. From the server's side it is
## indistinguishable from the owner's packets no longer arriving: the last replicated count just
## stops rising. It is the case a held flag cannot handle — a [code]wants_paddle[/code] left true
## on the server by a client that went quiet would thrust indefinitely — and it is why strokes
## cross the network as a count.
func _check_stalled_input_stops_thrust() -> void:
	Input.action_press(&"paddle")
	await _wait_physics(Raft.STROKE_DURATION * 1.5)
	var thrusting_before := _server_raft.thrusting
	_client_input.set_process(false)
	await _wait_physics(REPLICATION_SECONDS)
	var serial_at_stall := _server_raft.stroke_serial
	await _wait_physics(STOP_BOUND)
	_check("missing input stops thrust with the key still held",
		thrusting_before and not _server_raft.thrusting,
		"thrusting %s -> %s within %.2f s" % [thrusting_before, _server_raft.thrusting, STOP_BOUND])
	_check("a stalled owner leaves at most one stroke to serve",
		_server_raft.stroke_serial - serial_at_stall <= 1,
		"%d served after the stall" % (_server_raft.stroke_serial - serial_at_stall))
	Input.action_release(&"paddle")
	_client_input.set_process(true)
	await process_frame


## Clearing intent — a mouse release, a focus loss — must leave the running count alone.
##
## Zeroing it would read as a decrease on the server, which would then ignore every stroke until
## the client climbed back to the count it had already served: paddling that works, then silently
## stops after one alt-tab. [member PlayerInput.board_requests] has the same rule for the same
## reason.
func _check_clear_intent_keeps_count() -> void:
	var before := _client_input.paddle_strokes
	_client_input.clear_intent()
	_check("clearing intent never rewinds the stroke count",
		_client_input.paddle_strokes == before,
		"%d -> %d" % [before, _client_input.paddle_strokes])


## A burst of requests arriving together is served as one stroke, not five.
##
## The server keeps at most one stroke pending, so a backlog — increments queued through a hitch,
## or a client inflating its count — cannot keep the raft thrusting after the owner stops asking.
func _check_burst_is_one_stroke() -> void:
	await _wait_physics(Raft.STROKE_DURATION)
	var serial_before := _server_raft.stroke_serial
	_client_input.paddle_strokes += 5
	await _wait_physics(STOP_BOUND + Raft.STROKE_DURATION)
	var served := _server_raft.stroke_serial - serial_before
	_check("a burst of five requests is served as one stroke",
		_server_input.paddle_strokes == _client_input.paddle_strokes and served == 1,
		"%d served; count client %d / host %d" % [
			served, _client_input.paddle_strokes, _server_input.paddle_strokes,
		])


## A stroke asked for from the water is refused, and stays refused once the player is back aboard.
func _check_off_raft_refused() -> void:
	var raft_at := _server_raft.global_position
	_place_server_body(Vector3(raft_at.x + SWIM_OFFSET, 0.0, raft_at.z))
	var floating := await _wait_until(
		func() -> bool: return _server_body.stance == NetworkPlayer.Stance.FLOATING,
		STANCE_SECONDS
	)
	await _wait_physics(Raft.STROKE_DURATION)

	var serial_before := _server_raft.stroke_serial
	_client_input.paddle_strokes += 1
	await _wait_physics(REPLICATION_SECONDS)
	# Asserted separately so a refusal cannot be mistaken for a request that never arrived.
	_check("a swimmer's stroke request reaches the host",
		floating and _server_input.paddle_strokes == _client_input.paddle_strokes,
		"stance %s, count client %d / host %d" % [
			NetworkPlayer.Stance.keys()[_server_body.stance],
			_client_input.paddle_strokes, _server_input.paddle_strokes,
		])
	await _wait_physics(Raft.STROKE_DURATION)
	_check("the host refuses a stroke from the water",
		_server_raft.stroke_serial == serial_before and not _server_raft.thrusting,
		"serial %d -> %d, thrusting=%s" % [
			serial_before, _server_raft.stroke_serial, _server_raft.thrusting,
		])

	# Asked directly as well, so the refusal is seen to be NOT_ABOARD rather than inferred from
	# nothing happening. The cooldown expired long ago, so this cannot be COOLING_DOWN in disguise.
	var result := _server_raft.request_stroke(_server_body, 0.0)
	_check("the raft refuses an off-raft stroke as NOT_ABOARD",
		result == Raft.StrokeResult.NOT_ABOARD, Raft.StrokeResult.keys()[result])

	# A refused request is spent, as a refused board request is. It must not sit waiting to fire
	# the moment the player climbs back on.
	_place_server_body(_server_raft.spawn_position(_server_root.get_node("Players") as Node3D))
	var aboard := await _wait_until(_is_aboard, STANCE_SECONDS)
	await _wait_physics(Raft.STROKE_DURATION)
	_check("a refused stroke does not fire on reboarding",
		aboard and _server_raft.stroke_serial == serial_before,
		"aboard=%s, serial %d -> %d" % [aboard, serial_before, _server_raft.stroke_serial])


## Only the server decides strokes. A client asking its own copy of the raft changes nothing.
func _check_client_cannot_stroke() -> void:
	await _wait_physics(Raft.STROKE_DURATION)
	var serial_before := _server_raft.stroke_serial
	var result := _client_raft.request_stroke(_client_body, 0.0)
	await _wait_physics(REPLICATION_SECONDS)
	_check("a client cannot start a stroke itself",
		result == Raft.StrokeResult.NOT_AUTHORITY
		and _client_raft.stroke_serial == serial_before
		and _server_raft.stroke_serial == serial_before,
		"%s; serial client %d / host %d (was %d)" % [
			Raft.StrokeResult.keys()[result], _client_raft.stroke_serial,
			_server_raft.stroke_serial, serial_before,
		])


## Paddling moves the raft further than it drifts on its own over the same time.
##
## Relative, not a speed: see "What this does not prove" at the top of this file.
func _check_raft_moves() -> void:
	var window := Raft.STROKE_DURATION * 3.0
	var still := await _raft_motion(window, false)
	var paddled := await _raft_motion(window, true)
	var drift_travel: float = still["travel"]
	var paddled_travel: float = paddled["travel"]
	var strokes: int = paddled["strokes"]
	# Strokes served is part of the claim: without it this passes when nothing was accepted and
	# the raft happened to be nudged by something else.
	_check("paddling moves the raft more than drift does",
		strokes > 0 and paddled_travel > drift_travel * DRIFT_RATIO
		and paddled_travel > TRAVEL_FLOOR,
		"paddled %.4f m in %d strokes, drift %.4f m, over %.1f s" % [
			paddled_travel, strokes, drift_travel, window,
		])


## Strokes from opposite edges of the deck turn the raft opposite ways.
##
## The side is the server's to decide from where the paddler stands, so the client sends none.
## This moves the paddler rather than claiming a side, the only way a real player can change it.
##
## Each edge carries its own control window, because putting a player down on the deck rocks the
## raft — see [constant EDGE_SETTLE_SECONDS] — and a turn counts as the stroke's only if it beats
## what the same paddler standing in the same place produces by doing nothing.
func _check_turning() -> void:
	var left := await _edge_turn(-1.0)
	var right := await _edge_turn(1.0)
	var left_yaw: float = left["paddled"]
	var right_yaw: float = right["paddled"]
	_check("strokes from opposite edges turn the raft opposite ways",
		_turn_is_the_stroke(left) and _turn_is_the_stroke(right)
		and signf(left_yaw) == -signf(right_yaw),
		"left %s; right %s" % [_turn_detail(left), _turn_detail(right)])


## Measures one edge of the deck: the paddler stands there doing nothing, then paddles from the
## same place. Returns whether they were aboard, strokes served, the drift and the paddled turn.
func _edge_turn(side: float) -> Dictionary:
	_place_server_body(
		_server_raft.to_global(Vector3(side * EDGE_OFFSET, Raft.DECK_HEIGHT + 0.3, 0.0))
	)
	var aboard := await _wait_until(_is_aboard, STANCE_SECONDS)
	await _wait_physics(EDGE_SETTLE_SECONDS)
	var window := Raft.STROKE_DURATION * 3.0
	var still := await _raft_motion(window, false)
	var paddled := await _raft_motion(window, true)
	return {
		"aboard": aboard and _is_aboard(),
		"strokes": paddled["strokes"],
		"drift": absf(still["yaw"]),
		"paddled": paddled["yaw"],
	}


## True when an edge's turn was the stroke's doing: the paddler stayed aboard, strokes were
## served, and the turn beat both that edge's own drift and the noise floor.
func _turn_is_the_stroke(edge: Dictionary) -> bool:
	var strokes: int = edge["strokes"]
	var paddled: float = edge["paddled"]
	var drift: float = edge["drift"]
	return edge["aboard"] and strokes > 0 and absf(paddled) > maxf(drift * DRIFT_RATIO, YAW_FLOOR)


## Renders one edge's measurement for the result line.
func _turn_detail(edge: Dictionary) -> String:
	return "%+.5f rad in %d strokes (drift %.5f, aboard=%s)" % [
		edge["paddled"], edge["strokes"], edge["drift"], edge["aboard"],
	]


## Returns how far the raft travels horizontally and how far it turns in [param seconds] from
## rest, with or without the paddle held, and how many strokes were served while it did.
func _raft_motion(seconds: float, paddle: bool) -> Dictionary:
	await _wait_until(func() -> bool: return not _server_raft.thrusting, STOP_BOUND)
	_server_raft.linear_velocity = Vector3.ZERO
	_server_raft.angular_velocity = Vector3.ZERO
	var from := _server_raft.global_transform
	var serial_before := _server_raft.stroke_serial
	if paddle:
		Input.action_press(&"paddle")
	await _wait_physics(seconds)
	if paddle:
		Input.action_release(&"paddle")
	var travel := _server_raft.global_position - from.origin
	return {
		"travel": Vector2(travel.x, travel.z).length(),
		"yaw": wrapf(_server_raft.global_rotation.y - from.basis.get_euler().y, -PI, PI),
		"strokes": _server_raft.stroke_serial - serial_before,
	}


## True when the server's player is standing on the server's raft specifically, not merely on
## something.
func _is_aboard() -> bool:
	return (
		_server_body.stance == NetworkPlayer.Stance.GROUNDED
		and _server_body.standing_on() == _server_raft
	)


## Moves the server's player, upright and moving with the raft. Server-side, as a reset is.
func _place_server_body(at: Vector3) -> void:
	_server_body.global_transform = Transform3D(Basis.IDENTITY, at)
	_server_body.linear_velocity = _server_raft.linear_velocity
	_server_body.angular_velocity = Vector3.ZERO


## Takes a client-side proxy out of the shared physics world. See the fixture note at the top.
func _remove_from_physics(body: CollisionObject3D) -> void:
	body.collision_layer = 0
	body.collision_mask = 0


func _check(label: String, passed: bool, detail: Variant = "") -> void:
	_reported += 1
	print("%s  %s  %s" % ["PASS" if passed else "FAIL", label, detail])
	if not passed:
		_failures += 1


## Waits [param seconds] of simulated time, counted in physics frames.
##
## Frames rather than a timer: when a frame runs long the engine caps how many physics steps it
## catches up on, so a wall-clock wait can end before the simulation has run that long.
func _wait_physics(seconds: float) -> void:
	for _step: int in ceili(seconds * Engine.physics_ticks_per_second):
		await physics_frame


## Waits until [param condition] holds, for at most [param seconds] of simulated time, and
## returns whether it did.
func _wait_until(condition: Callable, seconds: float) -> bool:
	for _step: int in ceili(seconds * Engine.physics_ticks_per_second):
		if condition.call():
			return true
		await physics_frame
	return condition.call()


func _on_timed_out() -> void:
	if _finished:
		return
	_finished = true
	print("FAIL  the suite finishes within %.0f s  %d of %d checks reported" % [
		TIMEOUT_SECONDS, _reported, EXPECTED_CHECKS,
	])
	print("verify_b01_paddle: timed out")
	quit(1)


func _finish() -> void:
	if _finished:
		return
	_finished = true
	Input.action_release(&"paddle")
	if _camera != null:
		_camera.free()
	if _reported != EXPECTED_CHECKS:
		print("FAIL  every check reports  %d of %d; one did not run to completion" % [
			_reported, EXPECTED_CHECKS,
		])
		_failures += absi(EXPECTED_CHECKS - _reported)
	print("verify_b01_paddle: %d failures" % _failures)
	quit(1 if _failures > 0 else 0)
