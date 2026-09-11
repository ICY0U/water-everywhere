extends Node

## Renders the demo scene to PNG files so the water can be inspected without a display.
##
## Registered as an autoload so it runs inside the real rendered scene: it waits for shaders
## and the foam simulation to warm up, steps through a list of framings, and writes one
## image each. Framings are given as a position and a target rather than as Euler angles,
## because every shot here exists to look at something specific — the cube, a wave face, the
## horizon — and an angle would have to be re-derived by hand whenever that thing moves.
##
## The whole capture is one coroutine rather than a state machine in [method Node._process].
## That is not a style preference: [method Node._process] keeps being called while a
## coroutine of it is suspended on [signal RenderingServer.frame_post_draw], every one of
## those calls starts a capture of its own, and they all resume together on the next
## emission — so the shot list is burnt through in two frames and each image is saved under a
## framing that a later coroutine has already replaced. Nothing in the log says so; the only
## symptom is screenshots that do not show what they claim to.
##
## Register it temporarily rather than committing it to [code]project.godot[/code]:
## [codeblock lang=text]
## [autoload]
## WaterShotter="*res://tools/capture_water.gd"
## [/codeblock]
## Images land in [code]user://shots/[/code]. Pass [code]-- --no-fog[/code] on the command
## line to switch the atmosphere off: fog is what the water is seen THROUGH, so judging a
## change to the surface itself is much easier without it.

## Directory the images are written to.
const OUTPUT_DIRECTORY: String = "user://shots"

## Frames to wait before the first capture.
##
## Long enough for shaders to compile, for the wave clock to advance away from t = 0, and —
## the reason this is not the 30 frames a static scene needs — for the foam simulation to
## accumulate. Foam builds up over seconds; photographed at frame 30 the sea is bare.
const WARMUP_FRAMES: int = 240

## Frames to wait between subsequent captures, once warmed up.
const SETTLE_FRAMES: int = 20

## Camera framings to capture, in order.
const SHOTS: Array[Dictionary] = [
	{
		"name": "01_sea_level",
		"position": Vector3(0.0, 2.4, 26.0),
		"target": Vector3(6.0, 1.0, -30.0),
	},
	{
		"name": "02_test_cube",
		"position": Vector3(22.0, 9.0, 16.0),
		"target": Vector3(9.0, 0.5, 2.0),
	},
	{
		"name": "03_cube_waterline",
		"position": Vector3(17.0, 2.2, 13.0),
		"target": Vector3(9.0, 1.0, 2.0),
	},
	{
		"name": "04_overview",
		"position": Vector3(0.0, 26.0, 46.0),
		"target": Vector3(0.0, 0.0, -20.0),
	},
	{
		"name": "05_whitecaps",
		"position": Vector3(0.0, 62.0, 70.0),
		"target": Vector3(0.0, 0.0, -40.0),
	},
]

var _camera: Camera3D


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUTPUT_DIRECTORY)

	_camera = get_tree().root.get_camera_3d()
	if _camera == null:
		# Also true when this autoload is left registered during a --script run, which has no
		# scene at all.
		printerr("capture_water: no active Camera3D in the scene")
		get_tree().quit(1)
		return

	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	if OS.get_cmdline_user_args().has("--no-fog"):
		_disable_fog()

	await _capture_all()


## Walks the shot list, holding each framing steady long enough to be worth photographing.
func _capture_all() -> void:
	var first := true
	for shot in SHOTS:
		var frames := WARMUP_FRAMES if first else SETTLE_FRAMES
		first = false
		for _frame in frames:
			# Re-asserted every frame: other scripts also write to the camera transform, so
			# setting it once leaves the framing dependent on script execution order.
			_apply_framing(shot)
			await RenderingServer.frame_post_draw
		_report_framing(shot)
		_save(shot)

	get_tree().quit(0)


## Switches the atmosphere off so a shot shows the water rather than the air in front of it.
func _disable_fog() -> void:
	var world := get_tree().root.find_child("WorldEnvironment", true, false) as WorldEnvironment
	if world == null or world.environment == null:
		return
	world.environment.fog_enabled = false
	world.environment.volumetric_fog_enabled = false
	print("capture_water: fog disabled for this run")


func _apply_framing(shot: Dictionary) -> void:
	# Silencing the free camera is re-asserted here, not done once on ready. A node that
	# implements _process has processing switched on again when it enters the tree, so a
	# set_process(false) issued from an autoload — which is readied before the main scene —
	# is quietly undone. FreeCamera._apply_look() then rewrites the basis from its own
	# stored yaw and pitch every frame while leaving the position alone, which presents as
	# screenshots taken from the right place pointing in the wrong direction.
	_camera.set_process(false)
	_camera.set_process_unhandled_input(false)

	# Position and orientation are written as one transform rather than as a move followed
	# by look_at(), so a half-applied framing can never be what gets drawn.
	var position: Vector3 = shot["position"]
	var target: Vector3 = shot["target"]
	_camera.global_transform = Transform3D(
		Basis.looking_at(target - position, Vector3.UP), position
	)


## Prints where the camera ended up and where the floating bodies land on screen.
##
## A body missing from a shot has either sunk, drifted out of frame, been hidden behind a
## wave, or failed to draw at all, and the picture alone cannot say which. Printing the
## camera alongside the projection separates "the framing is wrong" from "the subject is
## wrong", which is otherwise a guessing game.
func _report_framing(shot: Dictionary) -> void:
	print("%s: camera=%s target=%s forward=%s" % [
		shot["name"],
		_camera.global_position.snappedf(0.01),
		shot["target"],
		(-_camera.global_basis.z).snappedf(0.01),
	])
	for node in get_tree().get_nodes_in_group(&"water_subjects"):
		var body := node as Node3D
		if body == null:
			continue
		print("    %s: world=%s screen=%s behind=%s" % [
			body.name,
			body.global_position.snappedf(0.01),
			_camera.unproject_position(body.global_position).snappedf(0.1),
			_camera.is_position_behind(body.global_position),
		])


func _save(shot: Dictionary) -> void:
	var path := "%s/%s.png" % [OUTPUT_DIRECTORY, shot["name"]]
	var image := get_viewport().get_texture().get_image()

	var error := image.save_png(path)
	if error != OK:
		printerr("capture_water: failed to save %s (error %d)" % [path, error])
	else:
		print("    wrote ", ProjectSettings.globalize_path(path))
