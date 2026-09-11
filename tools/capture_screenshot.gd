extends Node

## Renders the demo scene to PNG files so the result can be inspected without a display.
##
## Registered as an autoload so it runs inside the real rendered scene: it waits for shaders
## and the sky to compile, steps through a list of framings, and writes one image each.
##
## Register it temporarily rather than committing it to [code]project.godot[/code]:
## [codeblock lang=text]
## [autoload]
## Shotter="*res://tools/capture_screenshot.gd"
## [/codeblock]
## Images land in [code]user://shots/[/code].

## Directory the images are written to.
const OUTPUT_DIRECTORY: String = "user://shots"

## Frames to wait before capturing, so shaders and the sky have compiled.
##
## Capturing earlier yields a frame that is missing the very thing being checked. This also
## lets the wave clock advance away from zero: at t=0 every wave in the spectrum is in phase
## at the origin, which is an unrepresentative moment to photograph.
const WARMUP_FRAMES: int = 90

## Camera framings to capture, in order. Rotations are Euler angles in degrees.
const SHOTS: Array[Dictionary] = [
	{
		"name": "01_sea_level",
		"position": Vector3(0.0, 3.5, 0.0),
		"rotation": Vector3(-2.0, 0.0, 0.0),
	},
	{
		"name": "02_low_angle",
		"position": Vector3(0.0, 5.0, 0.0),
		"rotation": Vector3(-8.0, 25.0, 0.0),
	},
	{
		"name": "03_overview",
		"position": Vector3(0.0, 28.0, 40.0),
		"rotation": Vector3(-22.0, 0.0, 0.0),
	},
	{
		"name": "04_high_wide",
		"position": Vector3(0.0, 70.0, 90.0),
		"rotation": Vector3(-30.0, 15.0, 0.0),
	},
]

var _shot_index: int = 0
var _frames_on_current_shot: int = 0
var _camera: Camera3D


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUTPUT_DIRECTORY)

	_camera = get_tree().root.get_camera_3d()
	if _camera == null:
		printerr("capture_screenshot: no active Camera3D in the scene")
		get_tree().quit(1)
		return

	# Stop the free camera driving itself while scripted framings are in effect.
	_camera.set_process(false)
	_camera.set_process_unhandled_input(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	_apply_current_framing()


func _process(_delta: float) -> void:
	# Re-assert every frame: other scripts also write to the camera transform, so setting it
	# once leaves the framing dependent on script execution order.
	_apply_current_framing()

	_frames_on_current_shot += 1
	if _frames_on_current_shot < WARMUP_FRAMES:
		return

	await RenderingServer.frame_post_draw
	_save_current_shot()
	_advance_to_next_shot()


func _apply_current_framing() -> void:
	var shot: Dictionary = SHOTS[_shot_index]
	_camera.global_position = shot["position"]
	var degrees: Vector3 = shot["rotation"]
	_camera.global_rotation = Vector3(
		deg_to_rad(degrees.x), deg_to_rad(degrees.y), deg_to_rad(degrees.z)
	)


func _save_current_shot() -> void:
	var shot: Dictionary = SHOTS[_shot_index]
	var path := "%s/%s.png" % [OUTPUT_DIRECTORY, shot["name"]]
	var image := get_viewport().get_texture().get_image()

	var error := image.save_png(path)
	if error != OK:
		printerr("capture_screenshot: failed to save %s (error %d)" % [path, error])
	else:
		print("wrote ", ProjectSettings.globalize_path(path))


func _advance_to_next_shot() -> void:
	_shot_index += 1
	if _shot_index >= SHOTS.size():
		# Stop processing before quitting: _process runs again before the tree tears down,
		# and would index past the end of SHOTS.
		set_process(false)
		get_tree().quit(0)
		return

	_frames_on_current_shot = 0
	_apply_current_framing()
