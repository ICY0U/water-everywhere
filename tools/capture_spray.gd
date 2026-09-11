extends SceneTree

## Renders the spray and rain to PNG files so they can be inspected without a display.
##
## Runs as a [code]--script[/code] that instantiates the demo scene itself, rather than as
## an autoload. An autoload has to be registered in project settings, and other sessions
## working in this project would pick it up for their own runs while it was there.
##
## [codeblock lang=text]
## godot --path . --script tools/capture_spray.gd --rendering-driver d3d12 --resolution 1600x900
## [/codeblock]
## Images land in [code]user://shots/spray/[/code].
##
## Like [code]capture_water.gd[/code], the whole capture is a single coroutine: a capture
## started from [method Node._process] would start again on every frame it was suspended.

## Directory the images are written to.
const OUTPUT_DIRECTORY: String = "user://shots/spray"

## Frames to wait before the first capture, for shaders to compile and the sea to get going.
const WARMUP_FRAMES: int = 240

## Frames to wait after a weather change.
##
## Long: spray and rain take seconds to fill in, and longer still to clear. Drops already
## falling when the rain stops keep falling, so a shot taken too soon after switching to a
## dry weather is still full of the last one's rain.
const WEATHER_SETTLE_FRAMES: int = 420

## Frames to wait between framings under the same weather.
const SETTLE_FRAMES: int = 30

## How much larger droplets are drawn under `--spray-debug`.
const DEBUG_SIZE_SCALE: float = 3.0

## Colour droplets are drawn in under `--spray-debug`. Nothing else in the scene is magenta.
const DEBUG_COLOR: Color = Color(1.0, 0.0, 0.8)

## Index of each weather in the demo scene's preset list.
const SUNNY: int = 0
const OVERCAST: int = 1
const STORMY: int = 2

## Framings to capture, in order.
const SHOTS: Array[Dictionary] = [
	{
		"name": "01_storm_sea_level",
		"weather": STORMY,
		"position": Vector3(0.0, 3.5, 30.0),
		"target": Vector3(0.0, 1.0, -20.0),
	},
	{
		"name": "02_storm_overview",
		"weather": STORMY,
		"position": Vector3(0.0, 22.0, 50.0),
		"target": Vector3(0.0, 0.0, -10.0),
	},
	{
		"name": "03_storm_rain_on_water",
		"weather": STORMY,
		"position": Vector3(0.0, 3.0, 8.0),
		"target": Vector3(0.0, 0.0, -4.0),
	},
	{
		"name": "04_overcast_sea_level",
		"weather": OVERCAST,
		"position": Vector3(0.0, 3.5, 30.0),
		"target": Vector3(0.0, 1.0, -20.0),
	},
	{
		"name": "05_sunny_sea_level",
		"weather": SUNNY,
		"position": Vector3(0.0, 3.5, 30.0),
		"target": Vector3(0.0, 1.0, -20.0),
	},
]

var _camera: Camera3D
var _weather: WeatherController


func _initialize() -> void:
	var scene: PackedScene = load("res://scenes/ocean_demo.tscn")
	var demo := scene.instantiate()

	var options := OS.get_cmdline_user_args()
	# Before the scene enters the tree: OceanSpray reads its exports once, on ready.
	if options.has("--spray-debug"):
		_exaggerate_spray(demo)
	root.add_child(demo)

	_camera = demo.get_node("Camera") as Camera3D
	_weather = demo.get_node("Weather") as WeatherController
	if _camera == null or _weather == null:
		printerr("capture_spray: the demo scene has no Camera or Weather node")
		quit(1)
		return

	# `-- --no-particles` removes the spray and rain, so a problem in a shot can be pinned on
	# them or cleared of them by rendering the same framings again without them.
	if options.has("--no-particles"):
		_remove(demo, ["OceanSpray", "RainShower"])
	# `-- --no-rain` leaves the spray but takes the weather off it, for judging one at a time.
	if options.has("--no-rain"):
		_remove(demo, ["RainShower"])
	# `-- --no-cube` removes the floating test body, and with it every object contact, wake
	# and dent, so the open sea can be judged on its own.
	if options.has("--no-cube"):
		_remove(demo, ["TestCube"])

	_capture_all()


## Walks the shot list, holding each framing steady long enough to be worth photographing.
func _capture_all() -> void:
	# Nodes added from _initialize() are readied on the first frame, not by add_child(). The
	# WeatherController applies its starting preset in _ready, so a weather change made
	# before then is silently overwritten.
	await process_frame

	var current_weather := -1
	var first := true
	for shot in SHOTS:
		var frames := SETTLE_FRAMES
		if shot["weather"] != current_weather:
			current_weather = shot["weather"]
			_weather.apply_index(current_weather)
			frames = WEATHER_SETTLE_FRAMES
		if first:
			frames = WARMUP_FRAMES
			first = false

		for _frame in frames:
			_apply_framing(shot)
			await RenderingServer.frame_post_draw
		_report_effects(shot)
		_save(shot)

	quit(0)


func _apply_framing(shot: Dictionary) -> void:
	# Re-asserted every frame. FreeCamera rewrites its own basis in _process and captures the
	# mouse on ready, and switching its processing off once does not stick.
	_camera.set_process(false)
	_camera.set_process_unhandled_input(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	var position: Vector3 = shot["position"]
	var target: Vector3 = shot["target"]
	_camera.global_transform = Transform3D(
		Basis.looking_at(target - position, Vector3.UP), position
	)


## Prints what the effects were actually set to for this shot.
##
## A picture shows how much spray there is but not how much was asked for, and the two
## disagreeing is exactly the bug worth catching: the values below are read back from the
## live shader materials, not from the exports that were meant to reach them.
func _report_effects(shot: Dictionary) -> void:
	var preset := _weather.current_preset()
	var line := "%s: weather=%s" % [shot["name"], preset.display_name if preset else "none"]

	var spray := root.find_child("OceanSpray", true, false) as OceanSpray
	if spray != null:
		var spray_material := spray.get_node("Spray").process_material as ShaderMaterial
		line += "  spray_amount=%.3f spindrift=%.3f breaking_threshold=%.3f" % [
			spray_material.get_shader_parameter(&"spray_amount"),
			spray_material.get_shader_parameter(&"spindrift_amount"),
			spray_material.get_shader_parameter(&"breaking_threshold"),
		]

	var rain := root.find_child("RainShower", true, false) as RainShower
	if rain != null:
		var rain_emitter := rain.get_node("Rain") as GPUParticles3D
		line += "  rain_amount=%.3f emitting=%s" % [
			(rain_emitter.process_material as ShaderMaterial).get_shader_parameter(&"rain_amount"),
			rain_emitter.emitting,
		]
	print(line)


## Makes spray impossible to miss: far larger droplets, in a colour nothing else in the scene
## can produce.
##
## This answers "is any spray being emitted at all?" separately from "can I see it?" — a
## question a subtle white effect on a grey sea cannot answer for itself.
func _exaggerate_spray(demo: Node) -> void:
	var spray := demo.get_node_or_null("OceanSpray") as OceanSpray
	if spray == null:
		return
	spray.droplet_size_min *= DEBUG_SIZE_SCALE
	spray.droplet_size_max *= DEBUG_SIZE_SCALE
	spray.spray_color = DEBUG_COLOR
	spray.edge_noise = 0.0
	print("capture_spray: spray exaggerated for this run")


## Frees the named children of [param demo] before the first frame is drawn.
func _remove(demo: Node, node_names: Array[String]) -> void:
	for node_name in node_names:
		var node := demo.get_node_or_null(node_name)
		if node != null:
			node.free()
	print("capture_spray: removed %s for this run" % ", ".join(node_names))


func _save(shot: Dictionary) -> void:
	# Each option writes to its own folder, so a run with and without something can be
	# compared side by side.
	var directory := OUTPUT_DIRECTORY
	for option in ["--no-particles", "--no-rain", "--no-cube", "--spray-debug"]:
		if OS.get_cmdline_user_args().has(option):
			directory += "_" + option.trim_prefix("--").replace("-", "_")
	DirAccess.make_dir_recursive_absolute(directory)
	var path := "%s/%s.png" % [directory, shot["name"]]
	var image := root.get_texture().get_image()
	var error := image.save_png(path)
	if error != OK:
		printerr("capture_spray: failed to save %s (error %d)" % [path, error])
	else:
		print("wrote ", ProjectSettings.globalize_path(path))
