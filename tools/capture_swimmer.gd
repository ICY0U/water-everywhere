extends SceneTree

## Photographs a player floating in open water, from the height a nearby crewmate would see them.
##
## The numbers in [method NetworkPlayer._apply_swim_balance] say the body is upright; only a
## picture says whether the character reads as treading water rather than as a corpse or a
## marionette. Both failures measure the same tilt from above.
##
## Run with (no [code]--headless[/code]: this one has to render):
## [codeblock lang=text]
## godot --path . --script tools/capture_swimmer.gd -- --output=docs/swim_pose --weather=stormy
## [/codeblock]

const SCENE_PATH: String = "res://scenes/island_multiplayer.tscn"

## Metres from the island's centre, past its shelf, so nothing is under the player but sea.
const OPEN_WATER: float = 120.0

## Simulated seconds the body settles before the shutter opens.
const SETTLE_SECONDS: float = 20.0

var _output: String = "user://swim_shots"
var _weather: String = "sunny"


func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--output="):
			_output = argument.trim_prefix("--output=")
		elif argument.begins_with("--weather="):
			_weather = argument.trim_prefix("--weather=")
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(_output)

	var game := (load(SCENE_PATH) as PackedScene).instantiate() as Node3D
	root.add_child(game)
	current_scene = game
	await physics_frame
	game._spawn_for_peer(1)
	await physics_frame

	var player := game.get_node("Players").get_child(0) as NetworkPlayer
	var weather := game.get_node_or_null("Weather") as WeatherController
	var preset := load("res://resources/weather/%s.tres" % _weather) as WeatherPreset
	if weather != null and preset != null:
		weather.presets = [preset]
		weather.apply_index(0)

	player.global_position = Vector3(OPEN_WATER, 2.0, 0.0)
	player.linear_velocity = Vector3.ZERO
	player.angular_velocity = Vector3.ZERO

	var camera := Camera3D.new()
	camera.current = true
	game.add_child(camera)

	# Settled with the camera already placed, so the water and its foam have run for as long as
	# the body has: a shot taken the frame a camera appears is of a sea that has not started yet.
	for i in int(SETTLE_SECONDS * Engine.physics_ticks_per_second):
		await physics_frame
		_aim(camera, player, Vector3(7.0, 2.4, 7.0))

	# Chest height, not the origin at the feet: aiming at the origin of a 4.1 m body points the
	# camera at the water in front of it.
	var shots := {
		"swimmer_near": Vector3(5.0, 1.6, 5.0),
		"swimmer_eye": Vector3(8.0, 0.9, 2.0),
		"swimmer_above": Vector3(6.0, 6.5, 6.0),
	}
	for shot_name: String in shots:
		_aim(camera, player, shots[shot_name] as Vector3)
		await process_frame
		await process_frame
		var path := "%s/%s_%s.png" % [_output, shot_name, _weather]
		get_root().get_texture().get_image().save_png(path)
		print("wrote ", ProjectSettings.globalize_path(path))

	var tilt := rad_to_deg(player.global_basis.y.angle_to(Vector3.UP))
	print("tilt at the shutter: %.1f deg, submersion %.3f" % [tilt, player.submersion()])
	quit(0)


## Places [param camera] at [param offset] from the swimmer and points it at their chest.
func _aim(camera: Camera3D, player: NetworkPlayer, offset: Vector3) -> void:
	var chest := player.global_position + Vector3.UP * 2.2
	camera.global_position = player.global_position + offset
	camera.look_at(chest)
