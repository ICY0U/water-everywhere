extends Node

## Photographs the voyage — the scene F5 launches — at each beat a first-time player meets.
##
## Every other capture tool frames a test scene. None framed the one a player is actually handed,
## so nothing showed what a demo audience sees on launch: which way the camera faces, whether the
## destination is on screen, what the HUD says at each phase. A suite can assert the objective
## string; only a picture shows whether the mountains it names are anywhere in view.
##
## The keys are pressed rather than the methods called. H, F and Space go through
## [method Input.parse_input_event] into the same [InputMap] and [method Node._unhandled_input]
## paths a keyboard feeds, so a binding that stopped reaching its handler would show up here as a
## shot of nothing happening. Only two things are placed by hand, both to save simulated minutes
## of walking and sailing that would photograph nothing new: the player is set down beside the
## raft before boarding, and on the mainland to trigger arrival.
##
## Register it temporarily rather than committing it to [code]project.godot[/code] — ideally in
## a scratch copy of the project, because an autoload registered through [code]override.cfg[/code]
## is inherited by every suite run from that folder (see [code]tools/run_suites.gd[/code]):
## [codeblock lang=text]
## [autoload]
## VoyageShotter="*res://tools/capture_voyage.gd"
## [/codeblock]
## Then launch the game normally, on a port no suite uses:
## [codeblock lang=text]
## godot --path . -- --port=27391
## [/codeblock]
## Images land in [code]user://shots/voyage/[/code]; each is printed with the phase, the camera
## and the HUD text the game held at that moment, so a picture can be checked against the state.
## Pass [code]--no-fog[/code] as well to switch the atmosphere off, as
## [code]tools/capture_water.gd[/code] does. A software renderer such as lavapipe draws the
## volumetric god rays as a solid pale wall across the west — exactly where the destination is —
## so framing and layout are judged without it there, and the look on real hardware.

## Directory the images are written to.
const OUTPUT_DIRECTORY: String = "user://shots/voyage"

## Physics ticks to wait before the first shot, so shaders compile and foam builds.
##
## Counted in physics ticks rather than rendered frames throughout, because a software renderer
## can draw a frame per second while the physics runs its full 60 Hz: a wait in frames would be
## a different length of simulated time on every machine.
const WARMUP_TICKS: int = 240

## Physics ticks for a freshly spawned body to land and settle on the island.
const SETTLE_TICKS: int = 300

## Physics ticks for the camera to swing round after it is turned, and the foam to catch up.
const TURN_TICKS: int = 60

## Physics ticks the paddle key is held for: three strokes at [constant Raft.STROKE_DURATION].
const PADDLE_TICKS: int = 162

## Seconds of wall clock allowed for the whole sequence before it gives up.
##
## Generous because a software renderer is slow, but finite: a sequence that stalls — a spawn
## that never happens, a phase that never arrives — must end in an error rather than a hang.
const TIMEOUT_SECONDS: float = 1800.0

var _shot: int = 0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUTPUT_DIRECTORY)
	get_tree().create_timer(TIMEOUT_SECONDS, true, false, true).timeout.connect(func() -> void:
		printerr("capture_voyage: timed out after %.0f s" % TIMEOUT_SECONDS)
		get_tree().quit(1))
	_capture_all.call_deferred()


func _capture_all() -> void:
	await _ticks(WARMUP_TICKS)
	var game := get_tree().current_scene as VoyageGame
	if game == null:
		printerr("capture_voyage: the running scene is not the voyage")
		get_tree().quit(1)
		return
	var camera := game.get_node("PlayerCamera") as PlayerCamera
	if OS.get_cmdline_user_args().has("--no-fog"):
		_disable_fog(game)
		await _ticks(TURN_TICKS)

	# What F5 shows before anything is pressed: the title screen.
	await _save(game, "title")

	# Play, pressed as a player would press it. The button's own signal, so a Play that stopped
	# reaching the game would show up here as a title screen that never went away.
	(game.menu().find_child("Play", true, false) as Button).pressed.emit()
	var body := await _wait_for_local_body(game)
	if body == null:
		printerr("capture_voyage: pressing H produced no player body")
		get_tree().quit(1)
		return
	await _ticks(SETTLE_TICKS)
	# Untouched: the game turns the view itself, so this is exactly the first frame of play.
	await _save(game, "hosted")

	# Beside the raft, then F.
	var raft := game.raft
	var shore_side := (body.global_position - raft.global_position)
	shore_side.y = 0.0
	var beside := raft.global_position + shore_side.normalized() * 6.5
	beside.y = maxf(body.global_position.y, raft.global_position.y + 2.5)
	body.global_position = beside
	body.linear_velocity = Vector3.ZERO
	print("  set down beside the raft at %s" % str(body.global_position.snappedf(0.1)))
	await _ticks(30)
	await _click()
	await _tap(KEY_F)
	await _ticks(SETTLE_TICKS)
	camera.face(game.mainland.global_position - body.global_position)
	await _ticks(TURN_TICKS)
	await _save(game, "aboard")

	# Space held for three strokes.
	await _click()
	_press(KEY_SPACE, true)
	await _ticks(PADDLE_TICKS)
	_press(KEY_SPACE, false)
	await _save(game, "paddling")

	# Escape opens the menu, and pauses a solo game; Escape again resumes.
	await _tap(KEY_ESCAPE)
	await get_tree().process_frame
	await _save(game, "pause_menu")
	await _tap(KEY_ESCAPE)

	# Set ashore on the mainland, which is what ends the run.
	var mainland := game.mainland
	var landing := Vector2(mainland.global_position.x + mainland.plateau_radius * 0.5,
		mainland.global_position.z)
	body.global_position = Vector3(landing.x, mainland.height_at_world(landing) + 1.0, landing.y)
	body.linear_velocity = Vector3.ZERO
	await _ticks(SETTLE_TICKS)
	await _save(game, "arrival")
	# The end screen, then Sail again from it, which should put the crew back ashore at home.
	(game.menu().find_child("Again", true, false) as Button).pressed.emit()
	await _ticks(SETTLE_TICKS)
	await _save(game, "sailed_again")

	get_tree().quit(0)


## Switches off distance and volumetric fog for this run only.
func _disable_fog(game: VoyageGame) -> void:
	var world := game.get_node("WorldEnvironment") as WorldEnvironment
	world.environment.fog_enabled = false
	world.environment.volumetric_fog_enabled = false
	print("capture_voyage: fog disabled for this run")


## Waits [param count] physics ticks.
func _ticks(count: int) -> void:
	for _tick in count:
		await get_tree().physics_frame


## Waits for the local player's body to exist, or returns null after a few simulated seconds.
func _wait_for_local_body(game: VoyageGame) -> NetworkPlayer:
	for _tick in 600:
		await get_tree().physics_frame
		var players := game.get_node("Players")
		var body := players.get_node_or_null(str(multiplayer.get_unique_id())) as NetworkPlayer
		if body != null:
			return body
	return null


## Left-clicks the game window, which is how a player takes control back after releasing it.
##
## Movement, boarding and paddling are read only while the mouse is captured, and a virtual
## display need not grant the grab on launch or keep it, so every key sequence that needs control
## is preceded by the same click a player would make.
func _click() -> void:
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = get_viewport().get_visible_rect().size * 0.5
		Input.parse_input_event(event)
		await get_tree().process_frame


## Presses and releases [param key] across two frames, as a keyboard would.
func _tap(key: Key) -> void:
	_press(key, true)
	await get_tree().process_frame
	await get_tree().process_frame
	_press(key, false)


## Sends one key event through the same path a keyboard does.
##
## Both codes are set because the project's bindings are physical and the game's own hotkeys
## (H, R, the weather keys) match on the logical keycode.
func _press(key: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.pressed = pressed
	Input.parse_input_event(event)


func _save(game: VoyageGame, label: String) -> void:
	# The headless renderer never draws, so it never announces a finished frame either.
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
	_shot += 1
	var path := "%s/%02d_%s.png" % [OUTPUT_DIRECTORY, _shot, label]
	# A headless run has no image to save, but its state lines are still worth printing: they are
	# how the sequence itself is checked quickly, before minutes are spent rendering it.
	if DisplayServer.get_name() == "headless":
		path = "(headless, no image)"
	else:
		var error := get_viewport().get_texture().get_image().save_png(path)
		if error != OK:
			printerr("capture_voyage: failed to save %s (%s)" % [path, error_string(error)])
			return

	var camera := game.get_node("PlayerCamera") as PlayerCamera
	var status := game.get_node("HUD/Status") as Label
	print("%02d_%s: %s" % [_shot, label, ProjectSettings.globalize_path(path)])
	var body := game.get_node("Players").get_node_or_null(
		str(multiplayer.get_unique_id())) as NetworkPlayer
	print("  phase %s  camera %s yaw %.0f deg  %.0f fps" % [
		RunDirector.Phase.keys()[game.director().phase],
		str(camera.global_position.snappedf(0.1)),
		rad_to_deg(float(camera.get("_yaw"))),
		Engine.get_frames_per_second(),
	])
	if body != null:
		print("  body %s  stance %s  on %s  controls %s" % [
			str(body.global_position.snappedf(0.1)),
			NetworkPlayer.Stance.keys()[body.stance],
			body.standing_on().name if body.standing_on() != null else "nothing",
			"live" if body.input_node().controls_enabled else "OFF",
		])
	# The bow is the raft's -Z, the axis every stroke drives it along. Printed as a compass
	# bearing so it can be read against the objective's "west" at a glance: 0 is north (-Z),
	# 270 is west (-X).
	var raft := game.raft
	var bow := -raft.global_basis.z
	print("  raft %s  bow bearing %.0f deg  speed %.2f m/s  strokes %d" % [
		str(raft.global_position.snappedf(0.1)),
		fposmod(rad_to_deg(atan2(bow.x, -bow.z)), 360.0),
		Vector2(raft.linear_velocity.x, raft.linear_velocity.z).length(),
		raft.stroke_serial,
	])
	for line in status.text.split("\n"):
		print("  | %s" % line)
	var hint := game.get_node("HUD/Hint") as Label
	print("  hint: %s   menu: %s   paused: %s" % [
		hint.text if not hint.text.is_empty() else "(none)",
		"open" if game.menu().is_blocking() else "closed", get_tree().paused])
	# Handed back on a physics tick. The shot was taken on a rendering signal, and bodies moved
	# from there did not move: the first rendered run set the player down beside the raft straight
	# after a shot, and it was still standing at its spawn when F was pressed 57 m away.
	await get_tree().physics_frame
