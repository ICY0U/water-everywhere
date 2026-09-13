extends SceneTree

## Gate checks for the A04 voyage scene: phase, objective, late-join baseline and reset.
##
## Driven through the game's own server-side methods rather than by hosting a session. The
## autoload's NAME is not a resolvable identifier under [code]--script[/code], so any script
## extending [MultiplayerGame] — which [VoyageGame] does — fails to compile if the session path
## is exercised here; [code]tools/verify_island_spawn.gd[/code] documents the same trap. The
## phase and reset logic under test is server code that a real host runs verbatim, so driving it
## directly tests the same thing. Real ENet behaviour is covered by verify_multiplayer.gd.
##
## Run with:
## [codeblock lang=text]
## godot --path . --headless --script tools/verify_voyage.gd
## [/codeblock]
## Exits non-zero if any check fails.

const SCENE := "res://scenes/voyage.tscn"

## Simulated seconds allowed for a spawned body to settle onto the island.
const SETTLE_SECONDS: float = 3.0

## Resets the gate requires to leave the world in a known state.
const RESET_COUNT: int = 3

var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	create_timer(120.0).timeout.connect(func() -> void:
		_expect(false, "the voyage suite finished before its timeout")
		_finish())

	var game: Node3D = load(SCENE).instantiate()
	root.add_child(game)
	current_scene = game
	await physics_frame

	var director: RunDirector = game.director()
	var players := game.get_node("Players") as Node3D
	_expect(director != null, "the scene has a run director")
	_expect(game.mainland != null, "the scene has a mainland to reach")
	_expect(game.home != null, "the scene has a home island to leave")
	_expect(game.raft != null, "the scene has a raft")

	# --- Phase and objective -------------------------------------------------------------
	_expect(director.phase == RunDirector.Phase.LOBBY, "a fresh scene starts in LOBBY")
	_expect(director.revision == 0, "a fresh run starts at revision 0")
	_expect(not director.objective().is_empty(), "every phase names an objective")

	game.begin_voyage()
	_expect(director.phase == RunDirector.Phase.VOYAGE, "begin_voyage enters VOYAGE")
	_expect(director.revision == 1, "entering a phase advances the revision (%d)" % director.revision)
	var voyage_objective := director.objective()
	_expect(
		voyage_objective.contains("mainland"),
		"the voyage objective names the destination ('%s')" % voyage_objective
	)
	# The objective is the only instruction a new player gets, so every landmark it names has to
	# exist in the scene. This check exists because it did not: the first version of the line
	# sent players to a "lighthouse" that was never built, and 36 other checks passed anyway.
	# Assert against the world rather than against the string, or this just restates the bug.
	for landmark: String in ["lighthouse", "beacon", "tower", "harbour", "harbor"]:
		if not voyage_objective.to_lower().contains(landmark):
			continue
		_expect(
			not game.mainland.find_children("*%s*" % landmark, "", true, false).is_empty(),
			"the objective's '%s' exists in the scene" % landmark
		)
	_expect(
		game.mainland is MountainIsland and (game.mainland as MountainIsland).summit_height() > 20.0,
		"the mainland carries the relief the objective points at (%.1f m)" % (
			(game.mainland as MountainIsland).summit_height() if game.mainland is MountainIsland
			else 0.0)
	)

	# A repeated request must not invent a second transition. The plan requires one result from
	# a duplicate trigger, and the revision is what a joiner uses to order phases.
	game.begin_voyage()
	_expect(director.revision == 1, "re-entering the same phase does not bump the revision")

	# --- Spawning ------------------------------------------------------------------------
	_expect(game._spawn_for_peer(1), "the host is given a body")
	_expect(game._spawn_for_peer(2), "a second peer is given a body")
	_expect(players.get_child_count() == 2, "two peers produce exactly two bodies")

	await _wait_physics(SETTLE_SECONDS)

	var host_body := players.get_node_or_null("1") as NetworkPlayer
	var guest_body := players.get_node_or_null("2") as NetworkPlayer
	if host_body == null or guest_body == null:
		_expect(false, "both peers have a named body")
		_finish()
		return

	var home_centre := Vector2(game.home.global_position.x, game.home.global_position.z)
	var host_here := Vector2(host_body.global_position.x, host_body.global_position.z)
	_expect(
		host_here.distance_to(home_centre) < game.home.plateau_radius,
		"the crew starts ashore on the home island (r=%.1f < %.1f)" % [
			host_here.distance_to(home_centre), game.home.plateau_radius]
	)
	_expect(
		host_body.global_position.distance_to(guest_body.global_position) > 1.5,
		"the second player spawns clear of the first (%.2f m)" % (
			host_body.global_position.distance_to(guest_body.global_position))
	)
	# Starting ashore is the point of the voyage: the crew must have to board and cross.
	var mainland_centre := Vector2(game.mainland.global_position.x, game.mainland.global_position.z)
	_expect(
		host_here.distance_to(mainland_centre) > game.mainland.plateau_radius * 2.0,
		"the crew starts well away from the mainland (%.0f m)" % host_here.distance_to(mainland_centre)
	)
	_expect(
		director.phase == RunDirector.Phase.VOYAGE,
		"spawning ashore does not by itself end the run"
	)

	# --- Late-join baseline --------------------------------------------------------------
	# A joiner cannot be caught up by phase messages it was not connected for, so the whole run
	# state has to be available as one snapshot.
	var baseline := director.snapshot()
	_expect(
		baseline.get("phase") == RunDirector.Phase.VOYAGE
		and baseline.get("revision") == director.revision
		and baseline.get("epoch") == director.epoch,
		"the join baseline carries phase, revision and epoch"
	)

	# --- Arrival --------------------------------------------------------------------------
	# Moved rather than sailed: this asserts the arrival RULE, not the handling. Crossing under
	# real propulsion is B01 onward and has its own gates.
	guest_body.position = game.mainland.global_position + Vector3(0, 20, 0)
	await _wait_physics(1.0)
	_expect(director.phase == RunDirector.Phase.ARRIVAL, "reaching the mainland ends the run")
	var arrival_revision := director.revision
	await _wait_physics(0.6)
	_expect(
		director.revision == arrival_revision,
		"staying ashore does not re-trigger arrival (%d)" % director.revision
	)

	# --- Reset ----------------------------------------------------------------------------
	var epoch_before := director.epoch
	for pass_index in RESET_COUNT:
		game.reset_run()
		await _wait_physics(SETTLE_SECONDS)
		_expect(
			players.get_child_count() == 2,
			"reset %d leaves one body per player (%d)" % [pass_index + 1, players.get_child_count()]
		)
		_expect(
			_count_rafts(game) == 1,
			"reset %d leaves exactly one raft (%d)" % [pass_index + 1, _count_rafts(game)]
		)
		_expect(
			director.phase == RunDirector.Phase.VOYAGE,
			"reset %d starts a new crossing" % (pass_index + 1)
		)
		var back := Vector2(host_body.global_position.x, host_body.global_position.z)
		_expect(
			back.distance_to(home_centre) < game.home.plateau_radius,
			"reset %d returns the crew to the home island (r=%.1f)" % [
				pass_index + 1, back.distance_to(home_centre)]
		)

	_expect(
		director.epoch == epoch_before + RESET_COUNT,
		"each reset starts a new epoch (%d after %d resets)" % [director.epoch, RESET_COUNT]
	)
	# An epoch is only worth carrying if a stale command is actually refused by it.
	var stale_epoch := director.epoch - 1
	var revision_before := director.revision
	director._receive_phase(RunDirector.Phase.ARRIVAL, revision_before + 5, stale_epoch)
	_expect(
		director.phase == RunDirector.Phase.VOYAGE and director.revision == revision_before,
		"a command from a previous run is ignored"
	)
	# And a replayed message from THIS run must not walk the phase backwards either.
	director._receive_phase(RunDirector.Phase.LOBBY, revision_before - 1, director.epoch)
	_expect(
		director.phase == RunDirector.Phase.VOYAGE,
		"a stale revision cannot rewind the phase"
	)

	_finish()


## Returns how many rafts the scene holds, so a reset that duplicated one is caught.
func _count_rafts(game: Node) -> int:
	var found := 0
	for child in game.get_children():
		if child is Raft:
			found += 1
	return found


func _expect(condition: bool, message: String) -> void:
	print("%s %s" % ["PASS " if condition else "FAIL ", message])
	if not condition:
		_failures += 1


func _wait_physics(seconds: float) -> void:
	for _step: int in ceili(seconds * Engine.physics_ticks_per_second):
		await physics_frame


func _finish() -> void:
	print("verify_voyage: %d failures" % _failures)
	quit(1 if _failures else 0)
