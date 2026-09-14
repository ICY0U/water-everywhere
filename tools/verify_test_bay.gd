extends SceneTree

## Guards the B01 paddle test bay: calm sea, crew aboard on spawn, stroke legible against noise.
##
## The bay is an INSTRUMENT. Its whole job is to make a deliberately tiny stroke visible, and
## every property that does that job is one somebody can undo without noticing — a copied
## weather preset, a scene edit, a "tidy-up" of the wave field. This suite exists because each
## of those actually happened while the bay was being built.
##
## Deliberately port-free: the scene is instantiated and driven directly rather than hosting a
## session, the way [code]tools/verify_voyage.gd[/code] does. The bay has no run director and no
## RPC, so a session would add nothing but a fixed port to collide on.
##
## Run with:
## [codeblock lang=text]
## godot --path . --headless --script tools/verify_test_bay.gd
## [/codeblock]
## Exits non-zero if any check fails.

const SCENE := "res://scenes/test_bay.tscn"

## Simulated seconds to let the raft and its crew settle before anything is measured.
const SETTLE_SECONDS: float = 15.0

## Seconds of do-nothing control window, and of paddling, that get compared.
const WINDOW_SECONDS: float = 6.0

## Strokes taken during the paddling window.
const STROKE_COUNT: int = 8

## Least signal-to-noise the bay must deliver to be worth calling a test bay.
##
## Measured at roughly 20x when built. Set well below that: this is meant to catch the bay
## becoming USELESS, not to pin a number that drifts with the sea state.
const MINIMUM_SIGNAL_RATIO: float = 4.0

var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	create_timer(180.0).timeout.connect(func() -> void:
		_expect(false, "the test bay suite finished before its timeout")
		_finish())

	var game: Node3D = load(SCENE).instantiate()
	root.add_child(game)
	current_scene = game
	await physics_frame

	var raft := game.raft as Raft
	_expect(raft != null, "the bay has a raft")
	_expect(game.get_node_or_null("Markers") != null, "the bay has bearing markers")
	_expect(
		game.get_node("Markers").get_child_count() >= 3,
		"at least three markers, so a turn reads against something (%d)"
			% game.get_node("Markers").get_child_count()
	)

	# --- The sea, AS IT ENDS UP AT RUNTIME ------------------------------------------------
	# Read from the live WaveField rather than from the .tres, because the bug this guards
	# against was exactly a scene value that was true on disk and false once running: a
	# WeatherController applies its preset on ready and overwrites wave_field.wind_speed, so a
	# check reading the resource would have passed while the bay was blowing a gale.
	var field: WaveField = game.ocean.wave_field
	_expect(field != null, "the ocean has a wave field")
	_expect(
		field.peak_wavelength() > 10.0,
		"the swell is sea-scale, not ripples (%.2f m)" % field.peak_wavelength()
	)
	_expect(
		field.total_amplitude() < 0.5,
		"the sea is flattened enough to read a stroke (amplitude %.3f)" % field.total_amplitude()
	)

	# Volumetric fog over open water renders the whole sea as a flat white sheet: there is no
	# geometry to occlude the in-scattering. Measured in this scene at mean luma 0.763 with zero
	# water pixels against 0.447 and 44,334 with it off. This check is here because that defect
	# is invisible to every headless assertion and comes back the moment somebody copies a
	# weather preset from a scene that has land in it.
	#
	# [b]The WEATHER PRESET is what this actually guards, not the scene.[/b] Verified by breaking
	# it both ways: re-enabling volumetric fog in test_bay.tscn leaves this check GREEN, because
	# [code]atmosphere.gd[/code] writes the preset's value over the scene's Environment on ready
	# ([code]env.volumetric_fog_enabled = preset.volumetric_fog_enabled[/code]). Re-enabling it in
	# calm_test_bay.tres turns this red and exits 1. So the scene's own fog settings are dead
	# weight here, exactly like its wave field — edit the preset, and re-test by editing the
	# preset, or you will "prove" a guard that never looked at what you changed.
	var environment: Environment = (game.get_node("WorldEnvironment") as WorldEnvironment).environment
	_expect(
		not environment.volumetric_fog_enabled,
		"volumetric fog is off, or the sea renders white"
	)

	# --- The crew ---------------------------------------------------------------------------
	_expect(game._spawn_for_peer(1), "a player is given a body")
	await _wait_physics(SETTLE_SECONDS)
	var paddler := game.get_node_or_null("Players/1") as NetworkPlayer
	if paddler == null:
		_expect(false, "the spawned body exists")
		_finish()
		return
	# The bay starts the crew ABOARD: this fixture is for judging the paddle, not the walk out.
	_expect(
		paddler.standing_on() == raft,
		"the crew starts on the raft, with no swim or board first"
	)

	# --- Signal against noise ---------------------------------------------------------------
	# Both windows are measured in the SAME run, one after the other, rather than compared with
	# a number written here. A hard-coded baseline goes stale the moment the sea changes, and
	# would then be asserting about a bay that no longer exists.
	paddler.global_position = raft.to_global(Vector3(-2.5, Raft.DECK_HEIGHT + 1.2, 0.0))
	paddler.linear_velocity = Vector3.ZERO
	await _wait_physics(3.0)

	var noise := await _yaw_range(raft, WINDOW_SECONDS)

	var before: float = raft.rotation.y
	var served := 0
	for _stroke: int in STROKE_COUNT:
		if raft.request_stroke(paddler, 0.0) == Raft.StrokeResult.ACCEPTED:
			served += 1
		await _wait_physics(Raft.STROKE_DURATION + 0.05)
	var signal_strength: float = absf(rad_to_deg(angle_difference(before, raft.rotation.y)))

	# A signal check that never confirmed a stroke happened would pass on a dead paddle.
	_expect(served == STROKE_COUNT, "every stroke was accepted (%d of %d)" % [served, STROKE_COUNT])
	var ratio: float = signal_strength / maxf(noise, 0.001)
	_expect(
		ratio >= MINIMUM_SIGNAL_RATIO,
		"paddling reads against the sea's own motion (%.2f deg vs %.3f deg noise, %.0fx)" % [
			signal_strength, noise, ratio]
	)

	# The markers are the bearing reference, so the raft must not wander into one during a test.
	_expect(
		Vector2(raft.global_position.x, raft.global_position.z).length() < 20.0,
		"the raft stays in the middle of the bay (%.2f m from centre)"
			% Vector2(raft.global_position.x, raft.global_position.z).length()
	)

	_finish()


## Returns the range a raft's heading wanders over [param seconds], in degrees.
func _yaw_range(raft: Raft, seconds: float) -> float:
	var origin: float = raft.rotation.y
	var lowest := 0.0
	var highest := 0.0
	for _step: int in ceili(seconds * Engine.physics_ticks_per_second):
		await physics_frame
		var offset: float = rad_to_deg(angle_difference(origin, raft.rotation.y))
		lowest = minf(lowest, offset)
		highest = maxf(highest, offset)
	return highest - lowest


func _expect(condition: bool, message: String) -> void:
	print("%s %s" % ["PASS " if condition else "FAIL ", message])
	if not condition:
		_failures += 1


func _wait_physics(seconds: float) -> void:
	for _step: int in ceili(seconds * Engine.physics_ticks_per_second):
		await physics_frame


func _finish() -> void:
	print("verify_test_bay: %d failures" % _failures)
	quit(1 if _failures else 0)
