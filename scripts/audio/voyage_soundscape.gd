class_name VoyageSoundscape
extends Node

## What the voyage sounds like: the sea and the weather, the shore and the lighthouse, and the
## crew's own splashes, strokes and footsteps.
##
## Every sound is derived from state this peer already has, so the soundscape needs nothing on
## the wire and can never disagree with the picture:
##
## * a stroke is heard when the raft's replicated [member Raft.stroke_serial] rises — the same
##   serial that exists so remote peers can see paddling at all;
## * a shove when [member Raft.push_serial] rises;
## * a landing on the deck when a body's replicated stance puts it on the raft;
## * footsteps and swimming from each body's replicated stance and motion;
## * splashes from the impacts the ocean already raises on every peer for the spray particles.
##
## The positional one-shots and the ambient beds live in the [code]Audio[/code] autoload; this
## node decides when they play for this scene.

## Seconds between lighthouse bells, give or take a little.
const BELL_INTERVAL: Vector2 = Vector2(11.0, 16.0)

## Seconds between gull calls near an island.
const GULL_INTERVAL: Vector2 = Vector2(5.0, 13.0)

## How close to an island's centre, beyond its beach, the listener must be to hear its gulls.
const GULL_RANGE: float = 90.0

## Metres walked per footstep, at the character's 2.5x scale.
const STRIDE: float = 1.55

## Metres swum per stroke sound.
const SWIM_STRIDE: float = 2.2

## Least time between splash sounds, so a burst of impacts is one splash, not a stutter.
const SPLASH_GAP: float = 0.12

## Impact energy, in joules, from which a splash is heard as a big one.
const BIG_SPLASH_ENERGY: float = 6000.0

## Impact energy, in joules, below which no splash is played: a paddle blade's own splash is
## about 100 J and already has the stroke sound.
const QUIET_SPLASH_ENERGY: float = 400.0

## Raft roll-and-pitch rate, in radians per second, above which its timbers are heard working.
const CREAK_RATE: float = 0.12

var game: VoyageGame

var _rng := RandomNumberGenerator.new()
var _bell: AudioStreamPlayer3D
var _bell_clock: float = 6.0
var _gull_clock: float = 3.0
var _creak_clock: float = 2.0
var _splash_clock: float = 0.0
var _stroke_serial: int = -1
var _push_serial: int = -1
var _walkers: Dictionary = {}


func _ready() -> void:
	_rng.randomize()
	if game.weather != null:
		game.weather.weather_changed.connect(_on_weather_changed)
		var preset := game.weather.current_preset()
		if preset != null:
			_on_weather_changed(preset, game.weather.current_index())
	else:
		Audio.set_ambience(1.0, 0.3, 0.0)
	if game.ocean != null:
		game.ocean.water_impacted.connect(_on_water_impacted)
	_build_shores()
	_bell = AudioStreamPlayer3D.new()
	_bell.name = "LighthouseBell"
	_bell.stream = Audio.EFFECTS[&"bell"][0]
	_bell.bus = &"SFX"
	_bell.unit_size = 45.0
	_bell.max_distance = 420.0
	_bell.volume_db = -4.0
	add_child(_bell)


func _process(delta: float) -> void:
	_update_listener()
	_update_raft(delta)
	_update_walkers(delta)
	_update_bell(delta)
	_update_gulls(delta)
	_splash_clock = maxf(_splash_clock - delta, 0.0)


func _on_weather_changed(preset: WeatherPreset, _index: int) -> void:
	# Wind is heard from a fresh breeze upward; rain exactly as hard as it falls.
	var wind := clampf((preset.wind_speed - 4.0) / 15.0, 0.12, 1.0)
	Audio.set_ambience(1.0, wind, preset.rain_intensity)


## Surf where each island meets the sea: a few looping emitters round its waterline.
func _build_shores() -> void:
	var stream: AudioStream = preload("res://assets/audio/ambience/shore_loop.ogg")
	for island_node: Node in get_tree().get_nodes_in_group(&"playable_islands"):
		var island := island_node as Island
		if island == null:
			continue
		var count := 4 if island.plateau_radius < 40.0 else 7
		for index in count:
			var bearing := TAU * (float(index) + 0.5) / float(count)
			var radius := island.waterline_radius(bearing)
			var surf := AudioStreamPlayer3D.new()
			surf.name = "Surf_%s_%d" % [island.name, index]
			surf.stream = stream
			surf.bus = &"Ambience"
			surf.unit_size = 14.0
			surf.max_distance = 110.0
			surf.volume_db = -9.0
			surf.position = island.global_position + Vector3(
				cos(bearing) * radius, 0.5, sin(bearing) * radius
			)
			add_child(surf)
			# Silent where nothing can hear it; see the Audio autoload's headless rule.
			if DisplayServer.get_name() != "headless":
				surf.play(_rng.randf() * stream.get_length())


## Muffles the sea when the camera's eye is under it.
func _update_listener() -> void:
	var viewport := get_viewport()
	var camera := viewport.get_camera_3d() if viewport != null else null
	if camera == null or game.ocean == null:
		return
	var eye := camera.global_position
	Audio.set_underwater(eye.y < game.ocean.get_water_height(Vector2(eye.x, eye.z)) - 0.1)


func _update_raft(delta: float) -> void:
	var raft := game.raft
	if raft == null:
		return
	if _stroke_serial < 0:
		_stroke_serial = raft.stroke_serial
		_push_serial = raft.push_serial
	if raft.stroke_serial > _stroke_serial:
		_stroke_serial = raft.stroke_serial
		# Heard over the side the stroke is taken from would be nicer still; the hull's centre is
		# honest about where the water is being pushed.
		Audio.play_at(&"paddle", raft.global_position + Vector3.UP * 0.5, -3.0)
	elif raft.stroke_serial < _stroke_serial:
		_stroke_serial = raft.stroke_serial
	if raft.push_serial > _push_serial:
		_push_serial = raft.push_serial
		Audio.play_at(&"push", raft.global_position, 0.0, 0.9)
	elif raft.push_serial < _push_serial:
		_push_serial = raft.push_serial

	# The raft's timbers work as it rolls; the harder the sea, the more often they are heard.
	_creak_clock -= delta
	if _creak_clock <= 0.0:
		var working := Vector2(raft.angular_velocity.x, raft.angular_velocity.z).length()
		if working > CREAK_RATE:
			Audio.play_at(&"creak", raft.global_position + Vector3.UP, -10.0 + minf(working * 6.0, 6.0), 1.0, 0.15)
		_creak_clock = _rng.randf_range(1.8, 4.5)


## Footsteps, swimming and landing on the deck, for every player this peer can see.
func _update_walkers(delta: float) -> void:
	var players := game.get_node_or_null("Players")
	if players == null:
		return
	var seen := {}
	for child in players.get_children():
		var body := child as NetworkPlayer
		if body == null:
			continue
		var id := body.get_instance_id()
		seen[id] = true
		var state: Dictionary = _walkers.get(id, {"travel": 0.0, "aboard": false, "stance": -1})
		var aboard := game.raft != null and game.raft.carries(body)
		if aboard and not state["aboard"] and state["stance"] != -1:
			Audio.play_at(&"thud", body.global_position, -2.0)
		if (
			body.stance == NetworkPlayer.Stance.FLOATING
			and int(state["stance"]) == NetworkPlayer.Stance.AIRBORNE
		):
			Audio.play_at(&"splash_small", body.global_position, -2.0)
		state["aboard"] = aboard
		state["stance"] = body.stance

		var local := body.input_node() != null and body.input_node().is_multiplayer_authority()
		var trim := -6.0 if local else -11.0
		match body.stance:
			NetworkPlayer.Stance.GROUNDED:
				var speed := Vector2(body.ground_velocity.x, body.ground_velocity.z).length()
				if speed < 0.6:
					speed = 0.0
				state["travel"] = float(state["travel"]) + speed * delta
				if float(state["travel"]) >= STRIDE:
					state["travel"] = 0.0
					var surface := &"step_wood" if aboard or _on_jetty(body) else &"step_sand"
					Audio.play_at(surface, body.global_position, trim, 1.0, 0.1)
			NetworkPlayer.Stance.FLOATING:
				var swim := Vector2(body.linear_velocity.x, body.linear_velocity.z).length()
				state["travel"] = float(state["travel"]) + (swim if swim > 0.8 else 0.0) * delta
				if float(state["travel"]) >= SWIM_STRIDE:
					state["travel"] = 0.0
					Audio.play_at(&"swim", body.global_position, trim + 2.0, 1.0, 0.1)
		_walkers[id] = state
	for id: int in _walkers.keys():
		if not seen.has(id):
			_walkers.erase(id)


func _on_jetty(body: Node3D) -> bool:
	var jetty := game.get_node_or_null("HomeJetty") as Jetty
	if jetty == null:
		return false
	var local := jetty.to_local(body.global_position)
	return absf(local.x) < jetty.width * 0.5 + 0.4 and local.z < 0.5 and local.z > -jetty.length


func _update_bell(delta: float) -> void:
	_bell_clock -= delta
	if _bell_clock > 0.0:
		return
	_bell_clock = _rng.randf_range(BELL_INTERVAL.x, BELL_INTERVAL.y)
	var lighthouse := game.lighthouse as Lighthouse
	if lighthouse == null:
		return
	_bell.global_position = lighthouse.lamp_position()
	_bell.pitch_scale = _rng.randf_range(0.98, 1.02)
	if DisplayServer.get_name() != "headless":
		_bell.play()


func _update_gulls(delta: float) -> void:
	_gull_clock -= delta
	if _gull_clock > 0.0:
		return
	_gull_clock = _rng.randf_range(GULL_INTERVAL.x, GULL_INTERVAL.y)
	var viewport := get_viewport()
	var camera := viewport.get_camera_3d() if viewport != null else null
	if camera == null:
		return
	for island_node: Node in get_tree().get_nodes_in_group(&"playable_islands"):
		var island := island_node as Island
		if island == null:
			continue
		var reach := island.beach_radius + GULL_RANGE
		var offset := camera.global_position - island.global_position
		if Vector2(offset.x, offset.z).length() > reach:
			continue
		var angle := _rng.randf() * TAU
		var spot := island.global_position + Vector3(
			cos(angle) * island.plateau_radius, _rng.randf_range(14.0, 30.0),
			sin(angle) * island.plateau_radius,
		)
		Audio.play_at(&"gull", spot, -8.0, _rng.randf_range(0.92, 1.1), 0.0)
		return


func _on_water_impacted(impact: WaterImpact) -> void:
	if impact == null or impact.kind == Ocean.ImpactKind.EXIT or _splash_clock > 0.0:
		return
	if impact.energy < QUIET_SPLASH_ENERGY:
		return
	_splash_clock = SPLASH_GAP
	var big := impact.energy >= BIG_SPLASH_ENERGY
	var level := clampf(-14.0 + 4.0 * log(maxf(impact.energy, 1.0)) / log(10.0), -14.0, 0.0)
	Audio.play_at(&"splash_big" if big else &"splash_small", impact.position, level)
