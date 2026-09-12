extends SceneTree

## Headless assertions on the raft in the shipping scene: that it floats with players aboard,
## that deck input moves a player along it, and that a late joiner spawns onto it.
##
## Unlike the other suites this one instances [code]multiplayer_demo.tscn[/code] whole and hosts
## a real session, so it exercises the production spawner and the imported raft model rather
## than a stand-in.
##
## Settling is measured in physics frames, not seconds. When a frame runs long the engine caps
## how many physics steps it catches up on, so a wall-clock wait can end before the simulation
## has run for as long as it claims — and a settling check then fails for want of time.
##
## Run with a display and it also saves [code]docs/raft_in_game.png[/code], an overview of the
## raft and both players.
##
## Run with:
## [codeblock lang=text]
## godot --path . --headless --script tools/verify_raft.gd
## [/codeblock]
## Exits non-zero if any check fails, so it is usable from CI.

## Port for the hosted session, clear of the game's default and of the other suites' ports.
const TEST_PORT: int = 27103

## Real seconds allowed before the run is abandoned.
const TIMEOUT_SECONDS: float = 45.0

## Simulated seconds for the raft and the host to settle after spawning.
const SETTLE_SECONDS: float = 10.0

## Simulated seconds the host is driven along the deck.
##
## Two seconds, where this check used to run for six tenths. The deck servo targets 4 m/s and
## gets to about 3.2, but it approaches as a first-order lag that the hull underneath keeps
## re-disturbing, so a six-tenths window measured the acceleration ramp — and therefore the
## raft's motion — more than the player's walking. Over two seconds the displacement is
## unambiguous: about 3 m, against a third of a metre of sideways drift.
const MOVE_SECONDS: float = 2.0

## Least distance a player must walk along the deck in [constant MOVE_SECONDS], in metres.
##
## Measured at 2.6 to 3.3 m from several starting poses, so this leaves generous margin while
## still being far beyond anything the hull's own motion could contribute.
const WALK_MINIMUM: float = 1.5

## Largest sideways drift accepted while walking, as a fraction of the distance walked forward.
##
## A player told to walk along X should end up along X. Before the raft was made to float
## properly it threw the player nearly as far sideways as forwards — 0.558 m against 0.569 m,
## which this ratio would fail — where a hull sitting in the water gives better than ten to one.
const OFF_AXIS_FRACTION: float = 0.5

## Lowest a settled player's origin may sit relative to the deck, in metres.
##
## The player's collider is a 4.49 m box centred at local y = 2.23, so the origin is at its
## FEET: standing upright it rests 0.011 m above the deck, not the ~1 m a centred origin would
## imply. The window this check used to apply, 0.8 to 1.7 m, described a body the scene has
## never contained.
const DECK_REST_MINIMUM: float = -0.05

## Highest a settled player's origin may sit above the deck, in metres.
##
## Allows for the body leaning: a wave jolting the hull tips it, and because the origin is at the
## feet, pivoting about a bottom edge lifts the origin. Measured at 0.208 m during such a jolt,
## recovering to 0.011 m within a couple of seconds.
const DECK_REST_MAXIMUM: float = 0.6

## Simulated seconds the raft is left to drift, so the late joiner spawns onto a moved raft.
const DRIFT_SECONDS: float = 2.0

## Simulated seconds for the late joiner to settle.
const GUEST_SETTLE_SECONDS: float = 8.0

## Peer id given to the late joiner.
const GUEST_PEER_ID: int = 2

## Metres east of the raft's centre a player is dropped to test boarding.
##
## Outside the deck the other checks allow for, and inside
## [constant NetworkPlayer.BOARD_RANGE], so boarding should be permitted from here.
const BOARD_OFFSET: float = 7.0

## Metres east of the raft's centre that must be too far to board from.
const UNREACHABLE_OFFSET: float = 40.0

## Simulated seconds given to the water after a player is dropped into it.
const SWIM_SECONDS: float = 1.0

## Simulated seconds given to a boarding request to be served and settle.
const BOARD_SECONDS: float = 0.5

var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	# Real time, not simulated: the watchdog exists to catch a run that has stopped advancing.
	create_timer(TIMEOUT_SECONDS).timeout.connect(func() -> void: quit(2))
	var game := load("res://scenes/multiplayer_demo.tscn").instantiate() as Node3D
	root.add_child(game)
	current_scene = game
	var session := root.get_node("NetworkSession")
	var host_error: Error = session.host(TEST_PORT, "Raft test")
	if host_error != OK:
		# Nothing below can run without a session, so stop now rather than crash on a missing
		# player and sit out the watchdog. The usual cause is another run holding the port.
		var reason := "%s; is another run using the port?" % error_string(host_error)
		_check("session hosts on port %d" % TEST_PORT, false, reason)
		_finish()
		return
	await physics_frame

	var raft := game.get("raft") as Raft
	var players := game.get_node("Players") as Node3D
	var player := players.get_child(0) as NetworkPlayer
	_check("spawn above deck", raft.to_local(player.position).y > Raft.DECK_HEIGHT + 1.0)
	var model := raft.get_node("Model") as MeshInstance3D
	_check("imported model has materials", model.mesh.get_surface_count() >= 5)

	await _wait_physics(SETTLE_SECONDS)
	var local := raft.to_local(player.global_position)
	var submersion := raft.submersion()
	_check("raft floats with player aboard", submersion > 0.01 and submersion < 0.8, submersion)
	var on_deck := absf(local.x) < 4.0 and absf(local.z) < 4.0
	var at_deck_height := (
		local.y > Raft.DECK_HEIGHT + DECK_REST_MINIMUM
		and local.y < Raft.DECK_HEIGHT + DECK_REST_MAXIMUM
	)
	_check("player settles on deck", on_deck and at_deck_height, local)
	_check("raft stays upright", raft.global_basis.y.dot(Vector3.UP) > 0.8)

	# Move via the same input consumed by server physics, with live input sampling disabled.
	var input := player.input_node()
	input.set_process(false)
	input.set_physics_process(false)
	input.move_direction = Vector2(1, 0)
	var before := raft.to_local(player.position)
	await _wait_physics(MOVE_SECONDS)
	input.move_direction = Vector2.ZERO
	var after := raft.to_local(player.position)
	var walk := after - before
	var walked_far_enough := walk.x > WALK_MINIMUM
	var walked_straight := absf(walk.z) < walk.x * OFF_AXIS_FRACTION
	_check("WASD moves along deck", walked_far_enough and walked_straight, walk)

	await _wait_physics(DRIFT_SECONDS)
	# Spawn a second real player through the production spawner after the raft has drifted.
	game._spawn_for_peer(GUEST_PEER_ID)
	await physics_frame
	var guest := players.get_node(str(GUEST_PEER_ID)) as NetworkPlayer
	var guest_local := raft.to_local(guest.global_position)
	_check("late spawn tracks raft", guest_local.y > Raft.DECK_HEIGHT + 0.9)
	var spacing := guest.global_position.distance_to(player.global_position)
	_check("late spawn avoids host", spacing > 2.5)

	await _wait_physics(GUEST_SETTLE_SECONDS)
	guest_local = raft.to_local(guest.global_position)
	var guest_on_deck := absf(guest_local.x) < 4.5 and absf(guest_local.z) < 4.8
	var guest_at_deck_height := (
		guest_local.y > Raft.DECK_HEIGHT + DECK_REST_MINIMUM
		and guest_local.y < Raft.DECK_HEIGHT + DECK_REST_MAXIMUM
	)
	_check("second player supported", guest_on_deck and guest_at_deck_height, guest_local)
	submersion = raft.submersion()
	var still_upright := raft.global_basis.y.dot(Vector3.UP) > 0.75
	_check("loaded raft remains afloat", submersion < 0.85 and still_upright, submersion)

	# Boarding: put the host in the water beside the raft, then ask to climb back on. The request
	# is made the way a client makes it — by raising the count the server watches — rather than by
	# calling the boarding code, so the replicated property is part of what is tested.
	player.global_position = raft.global_position + Vector3(BOARD_OFFSET, 0.0, 0.0)
	player.linear_velocity = Vector3.ZERO
	player.angular_velocity = Vector3.ZERO
	await _wait_physics(SWIM_SECONDS)
	var overboard := raft.to_local(player.global_position)
	_check("starts off the deck", overboard.y < Raft.DECK_HEIGHT, overboard)

	input.board_requests += 1
	await _wait_physics(BOARD_SECONDS)
	var boarded := raft.to_local(player.global_position)
	var boarded_on_deck := absf(boarded.x) < 4.5 and absf(boarded.z) < 4.8
	# Same height window the settle checks use, rather than a bare "above DECK_HEIGHT". A player
	# whose origin is at its feet rests with that origin essentially level with the deck, so an
	# exact comparison passes only for a body whose collider is taller than the character it
	# draws — which was true of the placeholder cube and is not true of the real one.
	var boarded_at_deck_height := (
		boarded.y > Raft.DECK_HEIGHT + DECK_REST_MINIMUM
		and boarded.y < Raft.DECK_HEIGHT + DECK_REST_MAXIMUM
	)
	_check("F boards the raft", boarded_on_deck and boarded_at_deck_height, boarded)

	# One press, one boarding: with no new request the player stays put instead of being
	# re-seated every physics frame.
	var settled := raft.to_local(player.global_position)
	await _wait_physics(BOARD_SECONDS)
	var drift := raft.to_local(player.global_position).distance_to(settled)
	_check("boarding does not repeat itself", drift < 2.0, drift)

	# Out of range the same request must do nothing at all.
	player.global_position = raft.global_position + Vector3(UNREACHABLE_OFFSET, 0.0, 0.0)
	player.linear_velocity = Vector3.ZERO
	await _wait_physics(SWIM_SECONDS)
	input.board_requests += 1
	await _wait_physics(BOARD_SECONDS)
	var stranded := raft.to_local(player.global_position)
	var stayed_away := Vector2(stranded.x, stranded.z).length() > 20.0
	_check("F cannot board from out of range", stayed_away, stranded)

	if DisplayServer.get_name() != "headless":
		# A fixed overview shows the full asset and the two supported players.
		var player_camera := game.get_node("PlayerCamera")
		player_camera.set_process(false)
		player_camera.set_physics_process(false)
		var camera := Camera3D.new()
		game.add_child(camera)
		camera.global_position = raft.global_position + Vector3(13, 11, 17)
		camera.look_at(raft.global_position + Vector3.UP)
		camera.current = true
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://docs/raft_in_game.png")

	session.leave()
	_finish()


## Prints the tally and exits, non-zero if any check failed.
func _finish() -> void:
	print("verify_raft: %d failures" % _failures)
	quit(1 if _failures else 0)


## Prints one result line, counting it if it failed.
func _check(label: String, condition: bool, detail: Variant = "") -> void:
	print("%s %s %s" % ["PASS" if condition else "FAIL", label, str(detail)])
	if not condition:
		_failures += 1


## Returns once the physics simulation has advanced by [param seconds].
func _wait_physics(seconds: float) -> void:
	var steps := ceili(seconds * Engine.physics_ticks_per_second)
	for _step: int in steps:
		await physics_frame
