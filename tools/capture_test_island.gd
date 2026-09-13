extends SceneTree

## Photographs the test island, so the two rafts can be judged rather than only measured.
##
## [code]verify_test_island.gd[/code] can prove the land raft rests at 5.196 m and the water
## raft floats at 0.41 submerged. It cannot show whether the raft looks like it is SITTING on
## the ground rather than hovering a hand's breadth above it, whether the waterline crosses the
## floating hull where a waterline should, or whether the shore reads as a beach rather than as
## a box pushed through a sheet. Those are the questions a picture answers, and each framing
## below exists to answer one of them.
##
## Runs as a [code]--script[/code] that instantiates the scene itself, rather than as an
## autoload. An autoload has to be registered in project settings, and other sessions working in
## this project would pick it up for their own runs while it was there.
##
## Run with:
## [codeblock lang=text]
## godot --path . --script tools/capture_test_island.gd --resolution 1600x900
## [/codeblock]
## Images land in [code]res://docs/test_island/[/code], beside the project, so a validation run
## leaves reviewable evidence rather than hiding it in Godot's user-data folder.

## Scene photographed.
const SCENE_PATH: String = "res://scenes/test_island.tscn"

## Directory the images are written to.
const OUTPUT_DIRECTORY: String = "res://docs/test_island"

## Simulated seconds for both rafts to settle before anything is photographed.
##
## The same settling [code]verify_test_island.gd[/code] waits for, and for the same reason. The
## floating raft is seeded out of equilibrium and rings down for the better part of twenty
## seconds — at twelve it is still being thrown a metre and a half clear of the water. A shot
## taken before then photographs a raft in mid-flight and a land raft in mid-fall, which is a
## picture of neither thing this scene exists to show.
const SETTLE_SECONDS: float = 25.0

## Frames held after settling, for shaders and the sky to compile.
##
## Capturing earlier yields a frame missing the very thing being checked — an unshaded sea, or a
## sky still resolving — and the wave clock is also away from zero by then, where at t = 0 every
## octave is in phase at the origin and the sea looks unrepresentatively flat.
const WARMUP_FRAMES: int = 150

## Frames held after moving the camera, so the new framing is fully drawn before it is saved.
const FRAMING_FRAMES: int = 12

## Camera framings, in order. Each is a position, a point to look at, and why it is here.
const SHOTS: Array[Dictionary] = [
	{
		"name": "01_overview",
		"position": Vector3(46, 62, 150),
		"target": Vector3(14, 0, 0),
		"note": "the island whole: plateau, beach and both rafts in one frame",
	},
	{
		"name": "02_raft_on_land",
		"position": Vector3(-10, 11, 30),
		"target": Vector3(0, 5, 4),
		"note": "the land raft close: is it resting on the deck, or hovering over it",
	},
	{
		"name": "03_shoreline",
		"position": Vector3(56, 7, 34),
		"target": Vector3(28, 0, 4),
		"note": "the beach meeting the sea, where the shore surf should break",
	},
	{
		"name": "04_raft_on_water",
		"position": Vector3(70, 1, 14),
		"target": Vector3(60, 0, 0),
		"note": "the floating raft at eye level: where the waterline crosses the hull",
	},
]

## Real seconds allowed before the run is abandoned.
const TIMEOUT_SECONDS: float = 300.0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	# Real time, not simulated: the watchdog catches a run that has stopped advancing, which for
	# a rendering tool usually means a shader that never finished compiling.
	create_timer(TIMEOUT_SECONDS).timeout.connect(func() -> void: quit(2))

	if DisplayServer.get_name() == "headless":
		printerr("capture_test_island: needs a display; run without --headless")
		quit(1)
		return

	var error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIRECTORY))
	if error != OK and error != ERR_ALREADY_EXISTS:
		printerr("capture_test_island: cannot create %s (error %d)" % [OUTPUT_DIRECTORY, error])
		quit(1)
		return

	var packed := load(SCENE_PATH) as PackedScene
	if packed == null:
		printerr("capture_test_island: cannot load %s" % SCENE_PATH)
		quit(1)
		return

	var scene := packed.instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene
	await physics_frame

	# Stop the free camera driving itself while scripted framings are in effect, and take the
	# view with a camera of this tool's own rather than moving the scene's.
	var free_camera := scene.get_node_or_null("Camera")
	if free_camera != null:
		free_camera.set_process(false)
		free_camera.set_process_unhandled_input(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	var camera := Camera3D.new()
	scene.add_child(camera)
	camera.fov = 70.0
	camera.current = true

	# Every wait below is on frame_post_draw, and none of them on process_frame. Kept as a habit,
	# not offered as a rule: waiting on one signal throughout costs nothing.
	#
	# Do NOT read this as "mixing the two hangs". An earlier version of this loop waited out its
	# framing on process_frame, then awaited frame_post_draw, and wrote one image before stopping
	# dead until the watchdog fired — but that was seen ONCE, another tool in this project mixes
	# the two happily, and a peer's capture failed and then refused to fail again across a series
	# of isolation runs that killed four separate explanations. Several Godot instances share this
	# project's .godot/ directory all day, and transient one-offs are a known feature of working
	# here. So if a capture hangs or comes out dark, RE-RUN IT before investigating, and suspect
	# another instance rather than this loop.
	for _frame: int in _frames_for(SETTLE_SECONDS):
		await RenderingServer.frame_post_draw
	for _frame: int in WARMUP_FRAMES:
		await RenderingServer.frame_post_draw

	# The whole capture is one coroutine. Started from _process it would start again on every
	# frame it was suspended on, and the shots would interleave.
	for shot: Dictionary in SHOTS:
		for _frame: int in FRAMING_FRAMES:
			# Re-asserted every frame: other scripts also write to camera transforms, so setting
			# a framing once leaves it at the mercy of script execution order.
			camera.global_position = shot["position"]
			camera.look_at(shot["target"])
			await RenderingServer.frame_post_draw
		_save(shot)

	quit(0)


## Writes one framing to disk, naming what it is evidence of.
func _save(shot: Dictionary) -> void:
	var path := "%s/%s.png" % [OUTPUT_DIRECTORY, shot["name"]]
	var image := root.get_texture().get_image()
	var error := image.save_png(path)
	if error != OK:
		printerr("capture_test_island: failed to save %s (error %d)" % [path, error])
		return
	print("wrote %s — %s" % [ProjectSettings.globalize_path(path), shot["note"]])


## Returns how many drawn frames cover [param seconds] of simulation.
##
## Counted in frames rather than waited out on a clock: when a frame runs long the engine caps
## how many physics steps it catches up on, so a timed wait can end before the simulation has
## run for as long as it claims.
func _frames_for(seconds: float) -> int:
	return ceili(seconds * Engine.physics_ticks_per_second)
