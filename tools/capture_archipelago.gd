extends SceneTree

## Photographs the archipelago, because a backdrop is an art question before it is a geometry one.
##
## [code]verify_archipelago.gd[/code] can prove a mountain is 194 m tall, stands clear of the sea
## and keeps its relief off the beach. It cannot say whether the islands read as distance rather
## than as large things nearby, whether the haze separates them from the home island, or whether
## a cel-shaded mountain holds its silhouette against a bright sky. Each framing below asks one
## of those.
##
## Runs as a [code]--script[/code] that instantiates the scene itself rather than as an autoload:
## an autoload has to be registered in project settings, and every other session working in this
## project would then load it during their own runs.
##
## Run with:
## [codeblock lang=text]
## godot --path . --script tools/capture_archipelago.gd --resolution 1600x900
## [/codeblock]
## Images land in [code]res://docs/archipelago/[/code].

## Scene photographed.
const SCENE_PATH: String = "res://scenes/archipelago.tscn"

## Directory the images are written to.
const OUTPUT_DIRECTORY: String = "res://docs/archipelago"

## Simulated seconds before anything is photographed.
##
## The islands are static and need none of this; it is the sea that does. At t = 0 every octave
## of the spectrum is in phase at the origin, which is the one moment the water looks nothing
## like itself.
const SETTLE_SECONDS: float = 2.0

## Frames held after settling, for shaders and the sky to compile.
const WARMUP_FRAMES: int = 45

## Frames held after moving the camera, so the framing is fully drawn before it is saved.
const FRAMING_FRAMES: int = 12

## Real seconds allowed before the run is abandoned.
const TIMEOUT_SECONDS: float = 300.0

## Camera framings, in order. Each is a position, a point to look at, and what it is evidence of.
const SHOTS: Array[Dictionary] = [
	{"name": "01_world", "position": Vector3(760, 620, 900),
		"target": Vector3(130, 5, -250), "note": "starter, exploration island, scattered islands and horizon"},
	{"name": "02_starter", "position": Vector3(160, 95, 180),
		"target": Vector3(-5, 4, -10), "note": "starter clearing, low hills and beach"},
	{"name": "03_exploration", "position": Vector3(865, 285, -80),
		"target": Vector3(430, 42, -590), "note": "coastal plain, foothills, ridge and mountain route"},
	{"name": "04_player_view", "position": Vector3(24, 12, 30),
		"target": Vector3(430, 75, -550), "note": "the exploration island seen from the starter clearing"},
	{"name": "05_ridge", "position": Vector3(458, 92, -581),
		"target": Vector3(480, 118, -698), "note": "walkable mountain saddle and simple rock texture"},
	{"name": "06_background", "position": Vector3(-85, 17, -35),
		"target": Vector3(-500, 60, -1650), "note": "faceted horizon mountains"},
]


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	create_timer(TIMEOUT_SECONDS).timeout.connect(func() -> void: quit(2))

	if DisplayServer.get_name() == "headless":
		printerr("capture_archipelago: needs a display; run without --headless")
		quit(1)
		return

	var error := DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(OUTPUT_DIRECTORY)
	)
	if error != OK and error != ERR_ALREADY_EXISTS:
		printerr("capture_archipelago: cannot create %s (error %d)" % [OUTPUT_DIRECTORY, error])
		quit(1)
		return

	var packed := load(SCENE_PATH) as PackedScene
	if packed == null:
		printerr("capture_archipelago: cannot load %s" % SCENE_PATH)
		quit(1)
		return

	var scene := packed.instantiate() as Node3D
	root.add_child(scene)
	scene.get_node("HUD").hide()
	current_scene = scene
	await physics_frame

	var free_camera := scene.get_node_or_null("PlayerCamera")
	if free_camera != null:
		free_camera.set_process(false)
		free_camera.set_process_unhandled_input(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	var camera := Camera3D.new()
	scene.add_child(camera)
	camera.fov = 70.0
	# The furthest island sits 918 m out and the sea is drawn kilometres past it, so the default
	# near/far pair matters here in a way it does not in a scene that fits inside 100 m.
	camera.far = 4000.0
	camera.current = true

	# Waits are on frame_post_draw throughout — see capture_test_island.gd for why that is a
	# habit here rather than a rule, and why a dark or hung capture is re-run before it is
	# investigated.
	for _frame: int in _frames_for(SETTLE_SECONDS):
		await RenderingServer.frame_post_draw
	for _frame: int in WARMUP_FRAMES:
		await RenderingServer.frame_post_draw

	for shot: Dictionary in SHOTS:
		for _frame: int in FRAMING_FRAMES:
			camera.global_position = shot["position"]
			camera.look_at(shot["target"])
			scene.get_node("Ocean").set("follow_target", camera)
			scene.get_node("Atmosphere").set("follow_target", camera)
			await RenderingServer.frame_post_draw
		_save(shot)

	quit(0)


## Writes one framing to disk, naming what it is evidence of.
func _save(shot: Dictionary) -> void:
	var path := "%s/%s.png" % [OUTPUT_DIRECTORY, shot["name"]]
	var image := root.get_texture().get_image()
	var error := image.save_png(path)
	if error != OK:
		printerr("capture_archipelago: failed to save %s (error %d)" % [path, error])
		return
	print("wrote %s — %s" % [ProjectSettings.globalize_path(path), shot["note"]])


## Returns how many drawn frames cover [param seconds] of simulation.
func _frames_for(seconds: float) -> int:
	return ceili(seconds * Engine.physics_ticks_per_second)
