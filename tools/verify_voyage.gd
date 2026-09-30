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

## Degrees the raft's bow may point away from the mainland and still count as aimed at it.
##
## Loose enough for the swell to yaw a moored raft a little while it settles; tight enough that
## the unrotated raft this guards against, 90 degrees off, fails by a wide margin.
const BOW_TOLERANCE: float = 15.0

## Degrees the opening view may look away from the mainland and still have it on screen.
##
## Half the third-person camera's 70 degree field of view, less a margin, so the destination is
## not merely in frame but toward its middle.
const VIEW_TOLERANCE: float = 25.0

## Metres a reset raft may lie from its mooring once it has settled for [constant SETTLE_SECONDS].
##
## The swell moves a floating hull a little in that time, so this is not zero; a reset that left
## the raft where it was sits 65 m away.
const RESET_MOORING_TOLERANCE: float = 3.0

## Metres apart a reset must place two of the crew, before physics has touched them.
##
## Spawn slots are 2.6 m apart along the ring. A body is 1.55 m across, which is how far the
## solver pushes two bodies placed on the same spot — so the threshold sits between the two.
const RESET_SPACING: float = 2.0

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
	# Switched on for this test only — the raft ships without contact reporting — because it is
	# the one direct way to ask whether the island is holding the raft up. Connected before the
	# first physics step, so a raft placed inside the terrain is caught on the frame it starts.
	var aground_on_home := [false]
	game.raft.contact_monitor = true
	game.raft.max_contacts_reported = 8
	game.raft.body_entered.connect(func(other: Node) -> void:
		if other == game.home:
			aground_on_home[0] = true)
	await physics_frame

	var director: RunDirector = game.director()
	var players := game.get_node("Players") as Node3D
	_expect(director != null, "the scene has a run director")
	_expect(game.mainland != null, "the scene has a mainland to reach")
	_expect(game.home != null, "the scene has a home island to leave")
	_expect(game.raft != null, "the scene has a raft")

	# --- Where the crew is pointed ------------------------------------------------------
	# The objective says "west", and every stroke drives the raft along its own bow, so a bow
	# pointing anywhere else makes a player's first job turning it round — at about 1.3 degrees
	# a stroke. It was: the raft was placed unrotated, bow north, 90 degrees off the course.
	var mooring: Transform3D = game.raft.global_transform
	_expect(
		_bow_error(game.raft, game.mainland) < BOW_TOLERANCE,
		"the raft's bow points at the mainland (%.0f deg off)" % _bow_error(game.raft, game.mainland)
	)
	# The first frame is the first chance to show where home is, and the A04 gate asks whether a
	# player finds it within 30 seconds. The view opened facing north, over the dune, with the
	# raft and the mountains both off screen to the left.
	var camera := game.get_node("PlayerCamera") as PlayerCamera
	_expect(
		_view_error(camera, game.mainland.global_position) < VIEW_TOLERANCE,
		"the view opens facing the mainland (%.0f deg off)" % (
			_view_error(camera, game.mainland.global_position))
	)

	# --- Front end ----------------------------------------------------------------------
	# A public build opens on a title screen, not on a developer's key list over an empty world.
	# Untyped on purpose: naming GameMenu here compiles it before the autoload it uses exists,
	# the --script trap tools/verify_session_identity.gd documents.
	var menu: Control = game.menu()
	_expect(
		menu != null and menu.is_blocking() and menu.get_node("WaterTitle").visible,
		"the game opens on its title screen"
	)
	_expect(
		not (game.get_node("HUD/Status") as Label).visible,
		"the title screen is not drawn over by the HUD"
	)
	_expect(
		menu.find_child("Play", true, false) is Button,
		"the title screen offers Play"
	)

	# --- Sound, graphics and credits ---------------------------------------------------
	# The settings file is the player's own, and this suite changes settings, so it is put back
	# exactly as it was — or removed again if there was none.
	var settings_path := "user://settings.cfg"
	var saved_settings: Variant = (
		FileAccess.get_file_as_string(settings_path) if FileAccess.file_exists(settings_path)
		else null)
	var audio: Node = game.get_node_or_null("AudioDirector")
	_expect(audio != null, "the voyage has sound")
	var sea_bed := audio.get_node("OceanLoop") as AudioStreamPlayer
	_expect(
		sea_bed.playing and (sea_bed.stream as AudioStreamWAV).loop_mode
			== AudioStreamWAV.LOOP_FORWARD,
		"the sea bed is playing and loops"
	)
	# A stroke is heard from the replicated serial, which is all a client ever receives.
	await process_frame
	game.raft.stroke_serial += 1
	await process_frame
	var splashing := false
	for child in audio.get_children():
		if child is AudioStreamPlayer3D and (child as AudioStreamPlayer3D).playing:
			splashing = true
	_expect(splashing, "a paddle stroke is heard as a splash")
	# Low graphics drops volumetric fog, and a weather change must not quietly bring it back.
	menu._set_setting("graphics", 2)
	game.weather.apply_index(2)
	var environment := (game.get_node("WorldEnvironment") as WorldEnvironment).environment
	_expect(
		not environment.volumetric_fog_enabled and root.scaling_3d_scale < 1.0,
		"Low graphics stays low through a weather change (fog %s, scale %.2f)" % [
			environment.volumetric_fog_enabled, root.scaling_3d_scale]
	)
	menu._set_setting("graphics", 0)
	game.weather.apply_index(0)
	_expect(
		environment.volumetric_fog_enabled == game.weather.current_preset().volumetric_fog_enabled,
		"High graphics gives the weather its own fog back"
	)
	if saved_settings == null:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(settings_path))
	else:
		var restore := FileAccess.open(settings_path, FileAccess.WRITE)
		restore.store_string(saved_settings)
		restore.close()
	# Godot's MIT licence requires its notice in every copy, and a game is a copy.
	var credits := menu.find_child("Licenses", true, false) as Label
	_expect(
		credits != null and credits.text.contains("Godot Engine contributors")
			and credits.text.contains("Jolt"),
		"the credits carry Godot's licence and its third-party notices"
	)

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

	# The HUD is the only place a player is told which key paddles, and a hint typed in as a
	# literal goes stale the moment the binding moves. Asserted against the InputMap for the same
	# reason the objective above is asserted against the world rather than against another string.
	var status := game.get_node("HUD/Status") as Label
	var push_key := _bound_key(&"push")
	_expect(
		not push_key.is_empty()
		and status.text.contains(push_key)
		and status.text.to_lower().contains("push"),
		"the HUD names the key that pushes the raft off ('%s')" % push_key
	)
	var paddle_key := _bound_key(&"paddle")
	_expect(
		not paddle_key.is_empty()
		and status.text.contains(paddle_key)
		and status.text.to_lower().contains("paddle"),
		"the HUD names the key that paddles ('%s')" % paddle_key
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

	# Followed as the game follows the local player's own body. Under --script nobody is the local
	# player, so without this the camera follows no one and a reset's view is never tested from a
	# body at all.
	camera.follow(host_body)
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
	# The crew starts on the side of the island the raft is moored off, so the walk to it is
	# down the nearest beach rather than over the top and round.
	var moored_at := Vector2(mooring.origin.x, mooring.origin.z)
	_expect(
		host_here.distance_to(moored_at) < home_centre.distance_to(moored_at),
		"the crew starts on the raft's side of the island (%.0f m to it)" % (
			host_here.distance_to(moored_at))
	)
	# Afloat rather than aground. It was placed with its hull bottom 1.8 m down where the seabed
	# is 1.1 to 2.0 m down, so it started inside the terrain, was pushed up onto the slope, and
	# one paddler holding Space for ten simulated minutes moved it 5.3 m.
	_expect(
		not aground_on_home[0],
		"the raft rides afloat off the home island, never touching it"
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
	var arrival_panel := menu.get_node("ArrivalPanel") as Control
	_expect(
		arrival_panel.visible and (arrival_panel.find_child("Time", true, false) as Label).text
			.begins_with("Crossing time"),
		"reaching the mainland shows the end screen with the crossing time"
	)
	var arrival_revision := director.revision
	await _wait_physics(0.6)
	_expect(
		director.revision == arrival_revision,
		"staying ashore does not re-trigger arrival (%d)" % director.revision
	)

	# --- Reset ----------------------------------------------------------------------------
	var epoch_before := director.epoch
	for pass_index in RESET_COUNT:
		# Sailed off and turned round, as a crew mid-crossing would leave it, so that a reset which
		# forgot the raft — or put it back facing the wrong way — has something to be caught doing.
		game.raft.global_transform = Transform3D(
			Basis(Vector3.UP, 1.0 + pass_index), mooring.origin + Vector3(-60.0, 0.0, 25.0))
		game.raft.linear_velocity = Vector3.ZERO
		game.raft.angular_velocity = Vector3.ZERO
		# Ashore beside the mainland and looking back the way they came, as a crew that has just
		# landed would be. South of its centre on purpose: a reset that turned the view from where
		# the body stood — which it did, briefly, since the reset is announced before anyone is
		# moved home — would face north from there, not west.
		host_body.global_position = game.mainland.global_position + Vector3(0.0, 30.0, 40.0)
		camera.face(Vector3.RIGHT)
		game.reset_run()
		if pass_index == 0:
			_expect(not menu.is_blocking(), "sailing again takes the crew off the end screen")
		# Measured where the reset PUT them, before a physics step. Every body used to be sent to
		# the same spot — the spawn slot was the number of bodies, and during a reset every body
		# already exists, so each was given the same answer — and the solver then shoved the pair
		# apart to 1.53 m, which is just past the width of a body and passed a check made later.
		var placed_apart := host_body.global_position.distance_to(guest_body.global_position)
		_expect(
			placed_apart > RESET_SPACING,
			"reset %d puts each of the crew on their own spot (%.2f m apart)" % [
				pass_index + 1, placed_apart]
		)
		var course: Vector3 = game.mainland.global_position - game.home.global_position
		_expect(
			_look_error(camera, course) < VIEW_TOLERANCE,
			"reset %d turns the view back to the mainland (%.0f deg off)" % [
				pass_index + 1, _look_error(camera, course)]
		)
		await _wait_physics(SETTLE_SECONDS)
		var raft_home := Vector2(game.raft.global_position.x, game.raft.global_position.z)
		_expect(
			raft_home.distance_to(moored_at) < RESET_MOORING_TOLERANCE,
			"reset %d returns the raft to its mooring (%.1f m away)" % [
				pass_index + 1, raft_home.distance_to(moored_at)]
		)
		_expect(
			_bow_error(game.raft, game.mainland) < BOW_TOLERANCE,
			"reset %d points the raft at the mainland again (%.0f deg off)" % [
				pass_index + 1, _bow_error(game.raft, game.mainland)]
		)
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


## Returns how far, in degrees, the raft's bow points from the mainland, seen from above.
##
## The bow is the raft's -Z because that is the axis every stroke drives it along
## ([method Raft._advance_strokes]); where the model's barrels happen to face does not matter.
func _bow_error(raft: Node3D, mainland: Node3D) -> float:
	var bow := -raft.global_basis.z
	var course := mainland.global_position - raft.global_position
	return absf(rad_to_deg(Vector2(bow.x, bow.z).angle_to(Vector2(course.x, course.z))))


## Returns how far, in degrees, [param camera] is looking from [param target], seen from above.
func _view_error(camera: Node3D, target: Vector3) -> float:
	return _look_error(camera, target - camera.global_position)


## Returns how far, in degrees, [param camera] is looking from [param direction], seen from above.
func _look_error(camera: Node3D, direction: Vector3) -> float:
	var look := -camera.global_basis.z
	return absf(rad_to_deg(Vector2(look.x, look.z).angle_to(Vector2(direction.x, direction.z))))


## Returns how many rafts the scene holds, so a reset that duplicated one is caught.
func _count_rafts(game: Node) -> int:
	var found := 0
	for child in game.get_children():
		if child is Raft:
			found += 1
	return found


## Returns the name of the first key bound to [param action], or "" when none is.
##
## Deliberately its own copy rather than a call into [method MultiplayerGame._key_name]: a test
## that reads the key through the same function the HUD does would still pass if that function
## returned the wrong name for every action.
func _bound_key(action: StringName) -> String:
	if not InputMap.has_action(action):
		return ""
	for event: InputEvent in InputMap.action_get_events(action):
		var key := event as InputEventKey
		if key == null:
			continue
		var code := key.physical_keycode if key.physical_keycode != KEY_NONE else key.keycode
		if code != KEY_NONE:
			return OS.get_keycode_string(code)
	return ""


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
