extends SceneTree

## Measures what a floating player's body actually does, before changing anything about it.
##
## Reports the stance, the animation clip and — the number this exists for — how far the body's
## own up axis has tipped away from world up while it floats. A player who reads as "face down"
## on screen is a body lying flat in the water, not a clip that failed to play, and those two
## causes need different fixes.
##
## Run with:
## [codeblock lang=text]
## godot --path . --headless --script tools/swim_pose_probe.gd
## [/codeblock]

const SCENE_PATH: String = "res://scenes/island_multiplayer.tscn"
const PEER_ID: int = 1

## Metres from the island's centre, past its shelf, so nothing is under the player but sea.
const OPEN_WATER: float = 120.0

## Simulated seconds the body is left to settle before anything is believed.
const SETTLE_SECONDS: float = 25.0

## Simulated seconds sampled after settling. Several wave periods, not one frame.
const SAMPLE_SECONDS: float = 12.0

const TIMEOUT_SECONDS: float = 180.0


## Weather preset applied before the measurement, by file stem in [code]resources/weather/[/code].
##
## The servo has to hold in the sea the game actually has, not only the calm one: the stormy
## preset drives the wave field at 19 m/s of wind against sunny's 8.5.
var _weather: String = "sunny"


func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--weather="):
			_weather = argument.trim_prefix("--weather=")
	_run.call_deferred()


func _run() -> void:
	create_timer(TIMEOUT_SECONDS).timeout.connect(func() -> void: quit(2))

	var packed := load(SCENE_PATH) as PackedScene
	var game := packed.instantiate() as Node3D
	root.add_child(game)
	current_scene = game
	await physics_frame

	if not game._spawn_for_peer(PEER_ID):
		print("FAILED: no player spawned")
		quit(1)
		return
	await physics_frame

	var players := game.get_node("Players") as Node3D
	var player := players.get_child(0) as NetworkPlayer
	var ocean := game.get_node("Ocean") as Ocean
	var animation := player.find_child("AnimationPlayer", true, false) as AnimationPlayer

	var weather := game.get_node_or_null("Weather") as WeatherController
	var preset := load("res://resources/weather/%s.tres" % _weather) as WeatherPreset
	if weather != null and preset != null:
		weather.presets = [preset]
		weather.apply_index(0)
		await physics_frame

	player.global_position = Vector3(OPEN_WATER, 2.0, 0.0)
	player.linear_velocity = Vector3.ZERO
	player.angular_velocity = Vector3.ZERO
	await physics_frame

	await _wait(SETTLE_SECONDS)

	var steps := int(SAMPLE_SECONDS / _step())
	var tilt_min := INF
	var tilt_max := -INF
	var tilt_sum := 0.0
	var submersion_min := INF
	var submersion_max := -INF
	var clips: Dictionary = {}
	var stances: Dictionary = {}
	var head_above := 0.0
	for i in steps:
		await physics_frame
		var tilt := rad_to_deg(player.global_basis.y.angle_to(Vector3.UP))
		tilt_min = minf(tilt_min, tilt)
		tilt_max = maxf(tilt_max, tilt)
		tilt_sum += tilt
		var wet := player.submersion()
		submersion_min = minf(submersion_min, wet)
		submersion_max = maxf(submersion_max, wet)
		var clip: String = animation.current_animation if animation != null else "no player"
		clips[clip] = int(clips.get(clip, 0)) + 1
		var stance := _stance_name(player.stance)
		stances[stance] = int(stances.get(stance, 0)) + 1
		var water := ocean.get_water_height(
			Vector2(player.global_position.x, player.global_position.z)
		)
		# The head is 4.125 m up the body's own axis: where it ends up says whether the character
		# is standing in the water or lying across it.
		var head := player.global_transform * Vector3(0.0, 4.125, 0.0)
		head_above += head.y - water

	print("--- floating player, %.0f s settle, %.0f s sample ---" % [
		SETTLE_SECONDS, SAMPLE_SECONDS
	])
	print("stance:      %s" % _tally(stances, steps))
	print("clip:        %s" % _tally(clips, steps))
	print("tilt:        min %.1f deg, mean %.1f deg, max %.1f deg (0 = upright)" % [
		tilt_min, tilt_sum / steps, tilt_max
	])
	print("submersion:  %.3f - %.3f" % [submersion_min, submersion_max])
	print("head above water: %.2f m mean" % (head_above / steps))
	quit(0)


func _step() -> float:
	return 1.0 / float(Engine.physics_ticks_per_second)


func _wait(seconds: float) -> void:
	for i in int(seconds / _step()):
		await physics_frame


func _tally(counts: Dictionary, total: int) -> String:
	var parts: PackedStringArray = []
	for key: Variant in counts:
		parts.append("%s %d%%" % [key, roundi(100.0 * float(counts[key]) / float(total))])
	return ", ".join(parts)


func _stance_name(stance: int) -> String:
	match stance:
		NetworkPlayer.Stance.GROUNDED:
			return "GROUNDED"
		NetworkPlayer.Stance.FLOATING:
			return "FLOATING"
		_:
			return "AIRBORNE"
