extends SceneTree

## Headless assertions on the player's stance: that entering the water puts a player into
## [constant NetworkPlayer.Stance.FLOATING], and that it stays there.
##
## [b]The stance exists because submersion cannot cross the wire.[/b]
## [method BuoyantBody.submersion] is only assigned inside
## [method BuoyantBody._physics_process], and [NetworkPlayer] returns before calling it for any
## body it does not have authority over. So a remote player's submersion reads 0.0 on every peer
## but the server, and anything deciding from it — the animation picked a standing clip — was
## deciding from a number that was never filled in. The stance is decided once, by the server,
## and replicated. This suite therefore checks BOTH that the state is right and that it is
## carried, because a correct state nobody receives fixes nothing.
##
## [b]Most of this suite is about flicker, not about the transition.[/b] Getting a player to
## report FLOATING once it is in the water is the easy half; a single threshold does that. The
## hard half is that a floating body's submersion is not a constant — it is swept up and down by
## every wave that passes — so a bare threshold placed anywhere near the resting value changes
## the answer several times a second, and the animation strobes between swimming and standing
## while the player does nothing at all. The window checks below count transitions rather than
## sampling a state, because a state sampled twice can look perfectly stable while changing
## forty times in between.
##
## Drives the spawner directly rather than hosting a session, so it binds no port and can run
## alongside anything.
##
## Run with:
## [codeblock lang=text]
## godot --path . --headless --script tools/verify_player_state.gd
## [/codeblock]
## Exits non-zero if any check fails, so it is usable from CI.

## Scene under test: it has dry ground and open water in one place, which is the transition.
const SCENE_PATH: String = "res://scenes/island_multiplayer.tscn"

## Real seconds allowed before the run is abandoned.
const TIMEOUT_SECONDS: float = 120.0

## Peer the test player is spawned for.
const PEER_ID: int = 1

## Simulated seconds for a player to settle after being placed.
const SETTLE_SECONDS: float = 6.0

## Simulated seconds each stance is then watched for.
##
## Several wave periods. A window shorter than one period can miss the trough that a badly placed
## threshold would flicker on, which is the whole failure being guarded against.
const WATCH_SECONDS: float = 12.0

## Where the player is dropped to test open water, in metres from the island's centre.
##
## Beyond the island's 50 m shelf, so nothing is under the player but sea.
const OPEN_WATER: float = 120.0

## Height the player is lifted to for the airborne check, in metres.
const SKY_HEIGHT: float = 60.0

var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	create_timer(TIMEOUT_SECONDS).timeout.connect(func() -> void: quit(2))

	var packed := load(SCENE_PATH) as PackedScene
	if packed == null:
		_check("scene loads", false, SCENE_PATH)
		_finish()
		return

	var game := packed.instantiate() as Node3D
	root.add_child(game)
	current_scene = game
	await physics_frame

	if not game._spawn_for_peer(PEER_ID):
		_check("a player spawns", false)
		_finish()
		return
	await physics_frame

	var players := game.get_node("Players") as Node3D
	var player := players.get_child(0) as NetworkPlayer
	var ocean := game.get_node("Ocean") as Ocean
	if player == null or ocean == null:
		_check("the scene has a player and an ocean", false)
		_finish()
		return

	_check_thresholds()
	_check_replicated()

	# --- on dry ground ---
	await _wait_physics(SETTLE_SECONDS)
	var ashore := await _watch(player)
	_check(
		"a player on the island is GROUNDED",
		player.stance == NetworkPlayer.Stance.GROUNDED,
		_name_of(player.stance)
	)
	_check(
		"and stays there without flickering",
		int(ashore["changes"]) == 0,
		"%d stance changes in %.0f s" % [ashore["changes"], WATCH_SECONDS]
	)

	# --- entering the water ---
	player.global_position = Vector3(OPEN_WATER, 2.0, 0.0)
	player.linear_velocity = Vector3.ZERO
	player.angular_velocity = Vector3.ZERO
	await physics_frame
	var entered := await _wait_for_stance(player, NetworkPlayer.Stance.FLOATING)
	_check(
		"entering the water puts the player into FLOATING",
		entered >= 0.0,
		"after %.2f s" % entered if entered >= 0.0 else _name_of(player.stance)
	)

	# --- floating ---
	await _wait_physics(SETTLE_SECONDS)
	var afloat := await _watch(player)
	_check(
		"a player in open water is FLOATING",
		player.stance == NetworkPlayer.Stance.FLOATING,
		_name_of(player.stance)
	)
	# The one that matters. A threshold placed near the resting submersion passes every check
	# above and fails this one.
	_check(
		"and stays there as the waves pass",
		int(afloat["changes"]) == 0,
		"%d stance changes in %.0f s" % [afloat["changes"], WATCH_SECONDS]
	)
	# The measurement the grace period is sized against, reported whether or not it passes. A
	# floating player really does leave the water — the troughs reach submersions no threshold can
	# tell apart from being in the air — so what has to hold is that the grace outlasts them.
	var dip := float(afloat["longest_dry_seconds"])
	_check(
		"the grace period outlasts the longest trough",
		NetworkPlayer.FLOAT_EXIT_GRACE > dip,
		"longest dip %.2f s against a %.2f s grace; submersion %.3f-%.3f" % [
			dip, NetworkPlayer.FLOAT_EXIT_GRACE,
			afloat["submersion_min"], afloat["submersion_max"],
		]
	)

	# --- out of the water ---
	#
	# Both halves of the grace are checked, because each alone can pass while the mechanism is
	# broken: a grace that never holds makes the first check fail, and one that never releases
	# leaves a player swimming through the air and makes the second fail.
	player.global_position = Vector3(OPEN_WATER, SKY_HEIGHT, 0.0)
	player.linear_velocity = Vector3.ZERO
	await _wait_physics(NetworkPlayer.FLOAT_EXIT_GRACE * 0.5)
	_check(
		"a player just lifted clear is still FLOATING",
		player.stance == NetworkPlayer.Stance.FLOATING,
		"%s after %.2f s of a %.2f s grace" % [
			_name_of(player.stance),
			NetworkPlayer.FLOAT_EXIT_GRACE * 0.5,
			NetworkPlayer.FLOAT_EXIT_GRACE,
		]
	)
	await _wait_physics(NetworkPlayer.FLOAT_EXIT_GRACE)
	_check(
		"a player kept clear of the water becomes AIRBORNE",
		player.stance == NetworkPlayer.Stance.AIRBORNE,
		_name_of(player.stance)
	)

	_finish()


## Checks the thresholds form a band rather than a single line.
func _check_thresholds() -> void:
	_check(
		"the float thresholds are hysteretic",
		NetworkPlayer.FLOAT_EXIT_SUBMERSION < NetworkPlayer.FLOAT_ENTER_SUBMERSION,
		"enter %.3f, exit %.3f" % [
			NetworkPlayer.FLOAT_ENTER_SUBMERSION, NetworkPlayer.FLOAT_EXIT_SUBMERSION
		]
	)


## Checks the stance is actually carried to other peers.
##
## Asserted against the replication config rather than by hosting a session: the config is what
## decides whether the property crosses the wire at all, and it is built by a static function for
## exactly this reason. A stance that is correct on the server and never sent is the bug this
## whole feature exists to fix, so it is checked directly rather than inferred.
func _check_replicated() -> void:
	var config := PlayerReplication.build_config()
	var found := config.has_property(NodePath(".:stance"))
	_check("the stance is replicated", found, config.get_properties())
	if not found:
		return
	var mode := config.property_get_replication_mode(NodePath(".:stance"))
	_check(
		"it is sent on change, reliably",
		mode == SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE,
		mode
	)
	_check(
		"and carried in the spawn, so a late joiner sees it",
		config.property_get_spawn(NodePath(".:stance"))
	)


## Watches a player for [constant WATCH_SECONDS] and returns what its stance did.
##
## Counts transitions rather than comparing the ends, because a stance that changed forty times
## and landed back where it started looks identical to one that never moved.
func _watch(player: NetworkPlayer) -> Dictionary:
	var steps := ceili(WATCH_SECONDS * Engine.physics_ticks_per_second)
	var started: int = player.stance
	var previous: int = started
	var changes := 0
	var least := INF
	var greatest := -INF
	var dry_run := 0
	var longest_dry := 0

	for _step: int in steps:
		await physics_frame
		if player.stance != previous:
			changes += 1
			previous = player.stance
		var wet := player.submersion()
		least = minf(least, wet)
		greatest = maxf(greatest, wet)
		# The longest unbroken stretch spent below the exit threshold: what a grace period has to
		# outlast to stop a passing trough being mistaken for climbing out.
		if wet <= NetworkPlayer.FLOAT_EXIT_SUBMERSION:
			dry_run += 1
			longest_dry = maxi(longest_dry, dry_run)
		else:
			dry_run = 0

	return {
		"changes": changes,
		"submersion_min": least,
		"submersion_max": greatest,
		"longest_dry_seconds": float(longest_dry) / float(Engine.physics_ticks_per_second),
	}


## Returns the simulated seconds a player took to reach [param wanted], or -1 if it never did.
func _wait_for_stance(player: NetworkPlayer, wanted: int) -> float:
	var steps := ceili(SETTLE_SECONDS * Engine.physics_ticks_per_second)
	for step: int in steps:
		await physics_frame
		if player.stance == wanted:
			return float(step) / float(Engine.physics_ticks_per_second)
	return -1.0


## Returns a stance's name, so a failure says FLOATING rather than 1.
func _name_of(stance: int) -> String:
	return NetworkPlayer.Stance.keys()[stance]


## Prints the tally and exits, non-zero if any check failed.
func _finish() -> void:
	print("verify_player_state: %d failures" % _failures)
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
