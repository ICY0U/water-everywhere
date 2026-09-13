extends SceneTree

## Renders the Kotarou player from several angles and mid-animation, so the import can be
## inspected without a display. Numbers alone cannot show a model imported inside-out, lit
## flat, or animating into a knot; this is the visual half of verify_player_model.gd.
##
## Images land in the directory given by --output, defaulting to user://player_shots/.

const CLIPS: Array[StringName] = [&"Idle", &"Walk", &"Swim_Idle"]

## Fractions through each clip to photograph.
const PHASES: Array[float] = [0.0, 0.25, 0.5, 0.75]

## Yaw angles the character is turned to, in degrees, for the still portraits.
const ANGLES: Array[float] = [0.0, 45.0, 90.0, 180.0]

var _output: String = "user://player_shots"


func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--output="):
			_output = argument.trim_prefix("--output=")
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(_output)

	var world := Node3D.new()
	get_root().add_child(world)

	var model: Node3D = load("res://assets/characters/kotarou_player.glb").instantiate()
	world.add_child(model)

	# Three-point-ish lighting: a key with shadows plus a fill, so form reads in a still.
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-40.0, 35.0, 0.0)
	key.light_energy = 1.6
	key.shadow_enabled = true
	world.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-15.0, -130.0, 0.0)
	fill.light_energy = 0.45
	world.add_child(fill)

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.16, 0.2, 0.26)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.5, 0.58, 0.7)
	environment.ambient_light_energy = 0.55
	var camera := Camera3D.new()
	camera.environment = environment
	camera.current = true
	# Frame the whole 1.65 m figure from slightly above its waist.
	camera.position = Vector3(0.0, 1.0, 3.1)
	camera.rotation_degrees = Vector3(-6.0, 0.0, 0.0)
	world.add_child(camera)

	var animation := model.find_child("AnimationPlayer", true, false) as AnimationPlayer

	# Let shaders and shadows compile before the first capture.
	for i in 45:
		await process_frame

	for angle in ANGLES:
		model.rotation_degrees = Vector3(0.0, angle, 0.0)
		animation.play(&"Idle")
		animation.seek(0.0, true)
		await _settle()
		_save("portrait_%03d" % int(angle))

	model.rotation_degrees = Vector3(0.0, 30.0, 0.0)
	for clip in CLIPS:
		var length := animation.get_animation(clip).length
		for phase in PHASES:
			animation.play(clip)
			animation.seek(length * phase, true)
			await _settle()
			_save("%s_%0.2f" % [clip, phase])

	print("wrote images to ", ProjectSettings.globalize_path(_output))
	quit(0)


## Waits for the posed frame to be drawn before it is read back.
func _settle() -> void:
	await process_frame
	await process_frame


func _save(name: String) -> void:
	var image := get_root().get_texture().get_image()
	var path := "%s/%s.png" % [_output, name]
	if image.save_png(path) != OK:
		print("FAILED to write ", path)
