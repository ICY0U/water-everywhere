extends Node

## Renders the Kelvin wake behind a body driven through the water.
##
## The demo scene's cube floats on the spot, so nothing in it ever produces a wake. A wake is
## the whole point of the water-reaction rework and it is invisible in a still scene, so this
## tool supplies the one thing missing: a body actually going somewhere.
##
## A powered body is towed across the sea at a constant speed while the camera tracks it from
## astern and from above. The overhead framing is the one that matters — the 19.47 degree
## Kelvin angle is a plan-view property, and from sea level a wake reads as little more than
## a bright streak.
##
## Register it temporarily rather than committing it to [code]project.godot[/code]:
## [codeblock lang=text]
## [autoload]
## WakeShotter="*res://tools/capture_wake.gd"
## [/codeblock]
## Images land in [code]user://shots/[/code].

## Directory the images are written to.
const OUTPUT_DIRECTORY: String = "user://shots"

## Frames to wait before the first capture.
##
## Long enough for the foam simulation to accumulate a wake behind the body: foam builds over
## seconds, and photographed too early the sea is bare no matter how fast the body is moving.
const WARMUP_FRAMES: int = 300

## Frames to wait between subsequent captures.
const SETTLE_FRAMES: int = 30

## Speed the test body is driven at, in metres per second.
##
## Comfortably above the ocean material's [code]wake_full_speed[/code], so the wake is at full
## strength rather than fading up.
const TOW_SPEED: float = 8.0

## Heading the body is driven along, in degrees around Y.
const TOW_HEADING: float = 0.0

var _body: BuoyantBody
var _camera: Camera3D
var _ocean: Ocean


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUTPUT_DIRECTORY)

	# An autoload is readied BEFORE the main scene exists, so nothing can be looked up or
	# parented here — the camera and ocean are not in the tree yet, and a body added now
	# races the scene being built. Waiting one idle frame is what makes the scene real.
	await get_tree().process_frame

	_camera = get_tree().root.get_camera_3d()
	_ocean = get_tree().root.find_child("Ocean", true, false) as Ocean
	if _camera == null or _ocean == null:
		printerr("capture_wake: needs a Camera3D and an Ocean in the scene")
		get_tree().quit(1)
		return

	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_spawn_body()
	# One more frame so the body is inside the tree before anything reads its transform.
	await get_tree().physics_frame
	await _capture_all()


## Adds a hull that will be driven through the water, clear of the demo's own cube.
func _spawn_body() -> void:
	_body = BuoyantBody.new()
	_body.name = "WakeBoat"
	_body.ocean = _ocean
	_body.body_density = 420.0
	_body.position = Vector3(-60.0, 1.0, 0.0)
	# A hull longer than it is wide, so the wake has an obvious direction of travel.
	_body.add_to_group(&"water_subjects")

	var collider := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.5, 2.0, 7.0)
	collider.shape = box
	_body.add_child(collider)

	get_tree().root.add_child(_body)


func _physics_process(_delta: float) -> void:
	if _body == null or not _body.is_inside_tree():
		return
	# Driven by holding its velocity rather than by applying thrust: the point is to
	# photograph a wake at a known speed, not to model a propeller. Only the horizontal
	# components are overridden, so the hull is still free to heave and roll with the sea.
	var heading := Vector3(
		sin(deg_to_rad(TOW_HEADING)), 0.0, cos(deg_to_rad(TOW_HEADING))
	).normalized()
	var velocity := _body.linear_velocity
	var wanted := heading * TOW_SPEED
	_body.linear_velocity = Vector3(wanted.x, velocity.y, wanted.z)


func _capture_all() -> void:
	for _frame in WARMUP_FRAMES:
		_frame_camera_overhead()
		await RenderingServer.frame_post_draw
	_save("01_wake_overhead")

	for _frame in SETTLE_FRAMES:
		_frame_camera_astern()
		await RenderingServer.frame_post_draw
	_save("02_wake_astern")

	for _frame in SETTLE_FRAMES:
		_frame_camera_high()
		await RenderingServer.frame_post_draw
	_save("03_wake_high")

	get_tree().quit(0)


## Plan view: the framing that shows the Kelvin angle for what it is.
func _frame_camera_overhead() -> void:
	_place_camera(_body.global_position + Vector3(0.0, 46.0, 30.0), _body.global_position)


## Low and behind, where the transverse waves inside the V read most clearly.
func _frame_camera_astern() -> void:
	_place_camera(_body.global_position + Vector3(0.0, 5.0, -26.0), _body.global_position)


## High and off to one side, showing the wake against the open sea.
func _frame_camera_high() -> void:
	_place_camera(
		_body.global_position + Vector3(34.0, 22.0, -18.0), _body.global_position
	)


func _place_camera(position: Vector3, target: Vector3) -> void:
	if not _body.is_inside_tree():
		return
	# Re-asserted every frame: FreeCamera rewrites its own basis in _process, so silencing it
	# once on ready is quietly undone when it re-enters the tree.
	_camera.set_process(false)
	_camera.set_process_unhandled_input(false)
	_camera.global_transform = Transform3D(
		Basis.looking_at(target - position, Vector3.UP), position
	)


func _save(shot_name: String) -> void:
	var path := "%s/%s.png" % [OUTPUT_DIRECTORY, shot_name]
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(path)
	if error != OK:
		printerr("capture_wake: failed to save %s (error %d)" % [path, error])
		return
	print("%s: body at %s wrote %s" % [
		shot_name,
		_body.global_position.snappedf(0.01),
		ProjectSettings.globalize_path(path),
	])
