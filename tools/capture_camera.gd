extends Node

## Photographs both camera modes, so the view can be judged rather than assumed.
##
## The assertions can prove the arm collapsed and the cull mask changed. They cannot show
## whether first person actually looks like standing on the boat, whether the horizon sits
## level as the hull rolls, or whether the local name tag is genuinely absent while the hull
## remains visible. Those are the questions a picture answers.
##
## Runs single-player: a session is hosted so a body spawns, but no client is needed, because
## what is being photographed is one viewer's own camera.
##
## Register it temporarily rather than committing it to [code]project.godot[/code]:
## [codeblock lang=text]
## [autoload]
## CameraShotter="*res://tools/capture_camera.gd"
## [/codeblock]
## Images land in [code]res://docs/camera_validation/[/code], beside the project so a
## validation run leaves reviewable evidence rather than hiding it in Godot's user-data folder.

## Directory the images are written to.
const OUTPUT_DIRECTORY: String = "res://docs/camera_validation"

## Private port for the capture's one-player session, kept away from the playable demo and
## the loopback verification port so the tool can run while either is already open.
const CAPTURE_PORT: int = 27101

## Frames to wait before the first capture.
##
## Long enough for the player to settle onto the water and for foam to build; a shot taken as
## the cube is still falling shows a splash rather than a floating body.
const WARMUP_FRAMES: int = 360

## Frames to hold each framing before photographing it.
const SETTLE_FRAMES: int = 90

## Pitch angles photographed in each mode, in degrees, to show the horizon and the water.
const PITCHES: Array[float] = [0.0, -25.0]

var _camera: PlayerCamera


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUTPUT_DIRECTORY)
	await get_tree().process_frame
	if not NetworkSession.is_active():
		var error := NetworkSession.host(CAPTURE_PORT, "Camera validation")
		if error != OK:
			printerr("capture_camera: could not start local session (error %d)" % error)
			get_tree().quit(1)
			return
	await _capture_all()


func _capture_all() -> void:
	_camera = get_tree().root.find_child("PlayerCamera", true, false) as PlayerCamera
	if _camera == null:
		printerr("capture_camera: no PlayerCamera in the scene")
		get_tree().quit(1)
		return

	for _frame in WARMUP_FRAMES:
		await RenderingServer.frame_post_draw

	for mode in [PlayerCamera.ViewMode.THIRD_PERSON, PlayerCamera.ViewMode.FIRST_PERSON]:
		_camera.set_view_mode(mode)
		var label := "third" if mode == PlayerCamera.ViewMode.THIRD_PERSON else "first"

		for pitch in PITCHES:
			# Written straight onto the camera rather than sent as fake mouse motion, so the
			# framing is exact and repeatable between runs.
			_camera._pitch = deg_to_rad(pitch)
			for _frame in SETTLE_FRAMES:
				await RenderingServer.frame_post_draw
			_save("%s_pitch%+03d" % [label, int(pitch)])

	get_tree().quit(0)


func _save(shot_name: String) -> void:
	var path := "%s/cam_%s.png" % [OUTPUT_DIRECTORY, shot_name]
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(path)
	if error != OK:
		printerr("capture_camera: failed to save %s (error %d)" % [path, error])
		return

	# Printed with the shot so a picture that looks wrong can be matched against what the rig
	# believed at the time, rather than guessed at afterwards.
	var arm := _camera.get_node_or_null("SpringArm") as SpringArm3D
	var camera := _camera.get_node_or_null("SpringArm/Camera") as Camera3D
	var body := _camera.target()
	print("%s: arm=%.2f (hit %.2f) fov=%.0f local_tag_drawn=%s body_at=%s" % [
		shot_name,
		arm.spring_length if arm != null else -1.0,
		arm.get_hit_length() if arm != null else -1.0,
		camera.fov if camera != null else -1.0,
		camera.get_cull_mask_value(PlayerCamera.LOCAL_BODY_LAYER) if camera != null else false,
		str(body.global_position.snappedf(0.1)) if is_instance_valid(body) else "<none>",
	])
