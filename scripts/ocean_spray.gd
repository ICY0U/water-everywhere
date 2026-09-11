class_name OceanSpray
extends OceanParticles

## Spray thrown off breaking crests, and the spindrift a gale tears from them.
##
## How much spray there is is not a dial. Like the waves themselves it follows from the wind,
## here through the Beaufort scale's own descriptions of the sea: force 5 (from 8 m/s)
## brings a "chance of some spray" and force 6 "probably some spray", so spray ramps in
## across that range; force 7 (from 13.9 m/s) is where "spindrift begins to be seen", and by
## the top of force 8 (20.7 m/s) "edges of crests break into spindrift". So the sunny
## preset's 8.5 m/s breeze throws the odd burst and the stormy gale streams spindrift
## downwind, without either being tuned for it.
##
## Where spray comes from is the same physics as the foam: water leaves a crest where that
## crest is breaking, which is where horizontal compression of the wave field collapses.
## See [code]spray_particles.gdshader[/code].
##
## @tutorial(Beaufort scale): https://en.wikipedia.org/wiki/Beaufort_scale

## Wind speed at which spray first appears, in m/s: the bottom of Beaufort force 5.
const SPRAY_ONSET_WIND: float = 8.0

## Wind speed at which spray is fully developed, in m/s: the top of Beaufort force 6.
const SPRAY_FULL_WIND: float = 13.8

## Wind speed at which spindrift first appears, in m/s: the bottom of Beaufort force 7.
const SPINDRIFT_ONSET_WIND: float = 13.9

## Wind speed at which crests break into spindrift throughout, in m/s: the top of force 8.
const SPINDRIFT_FULL_WIND: float = 20.7

## Whitecap threshold assumed until a weather preset supplies one.
##
## Matches the demo scene's ocean material, so spray without a [member weather] still leaves
## the crests that foam.
const DEFAULT_WHITECAP_THRESHOLD: float = 0.84

const SPRAY_PROCESS_SHADER: Shader = preload("res://shaders/spray_particles.gdshader")
const DROPLET_SHADER: Shader = preload("res://shaders/spray_droplet.gdshader")

@export_group("Emission")

## Particle slots. Most restarts find no breaking crest and emit nothing, so this is a budget
## rather than a count of visible droplets.
##
## Cheap to raise: a slot that finds no crest dies in [code]start()[/code] and costs nothing
## more until its next restart.
@export_range(100, 100000, 100) var amount: int = 20000

## Multiplier on the wind-derived amount of spray. 1 is as the Beaufort scale describes.
@export_range(0.0, 1.0, 0.01) var amount_scale: float = 1.0

## Radius around the viewer in which crests throw spray, in metres.
@export_range(5.0, 400.0, 1.0) var spawn_radius: float = 90.0

## Points of sea each restart examines for a breaking crest.
@export_range(1, 16, 1) var candidate_count: int = 8

## How much harder than a whitecap a crest must break to throw spray, in compression.
##
## Foam forms across a whole whitecap; spray only leaves the heart of it.
@export_range(0.0, 0.5, 0.01) var threshold_offset: float = 0.08

## Compression below the threshold over which breaking reaches full strength.
@export_range(0.01, 1.0, 0.01) var breaking_range: float = 0.25

@export_group("Flight")

## Slowest spray leaves a crest along its normal, in m/s.
##
## Fast enough to clear the crest it came from: spray only reads as spray once it is above
## the foam, silhouetted against the sky.
@export_range(0.0, 20.0, 0.1) var launch_speed_min: float = 2.5

## Fastest spray leaves a crest along its normal, in m/s.
@export_range(0.0, 20.0, 0.1) var launch_speed_max: float = 7.0

## Wind at spray height as a fraction of the ten-metre wind speed.
@export_range(0.0, 1.0, 0.01) var wind_fraction: float = 0.7

## Drag rate toward the wind for the smallest droplet, in reciprocal seconds.
@export_range(0.0, 20.0, 0.1) var air_drag: float = 3.0

## Smallest drawn droplet, in metres.
@export_range(0.005, 2.0, 0.005) var droplet_size_min: float = 0.1

## Largest drawn droplet, in metres.
##
## Spray off a gale-force crest is not a mist of individual drops but torn sheets of water,
## so the largest are drawn nearly a metre across.
@export_range(0.005, 2.0, 0.005) var droplet_size_max: float = 0.85

## Shortest life of a droplet that never lands, in seconds.
@export_range(0.1, 10.0, 0.1) var lifetime_min: float = 0.9

## Longest life of a droplet that never lands, in seconds.
@export_range(0.1, 10.0, 0.1) var lifetime_max: float = 2.2

@export_group("Look")

@export var spray_color: Color = Color(0.96, 0.98, 1.0)

## Seconds of travel a streak spans. 0 draws round blobs.
@export_range(0.0, 0.5, 0.005) var streak_time: float = 0.04

## How far each droplet's silhouette is broken into lumps.
##
## High: spray off a breaking crest is torn water, and a clean outline reads as a solid
## object rather than as something coming apart in the air.
@export_range(0.0, 1.5, 0.01) var edge_noise: float = 0.85

## Fraction of its life after which a droplet dissolves into holes.
@export_range(0.0, 1.0, 0.01) var erosion_start: float = 0.45

## Distance within which droplets are not drawn at all, in metres.
##
## A metre-wide sheet of spray passing the camera would otherwise fill the frame.
@export_range(0.0, 10.0, 0.1) var near_fade: float = 1.0

@export_group("Landing")

## Most ripple rings alive at once.
@export_range(0, 20000, 100) var ripple_amount: int = 2000

## Rings are only left within this distance of the viewer, in metres.
@export_range(0.0, 200.0, 1.0) var ripple_max_distance: float = 45.0

## Ring radius as a multiple of the droplet's size.
@export_range(0.5, 10.0, 0.1) var ripple_scale: float = 1.8

## Seconds a ring lasts.
@export_range(0.1, 4.0, 0.05) var ripple_lifetime: float = 0.8

var _whitecap_threshold: float = DEFAULT_WHITECAP_THRESHOLD
var _emitter: GPUParticles3D
var _process_material: ShaderMaterial
var _draw_material: ShaderMaterial


## Returns how much spray a sea raised by [param wind_speed] throws, from 0 to 1.
static func spray_amount_for_wind(wind_speed: float) -> float:
	return smoothstep(SPRAY_ONSET_WIND, SPRAY_FULL_WIND, wind_speed)


## Returns the fraction of spray that is spindrift at [param wind_speed], from 0 to 1.
static func spindrift_amount_for_wind(wind_speed: float) -> float:
	return smoothstep(SPINDRIFT_ONSET_WIND, SPINDRIFT_FULL_WIND, wind_speed)


func _build_emitters() -> void:
	_draw_material = ShaderMaterial.new()
	_draw_material.shader = DROPLET_SHADER

	# Spray drifts downwind of where it was launched, so the bounds reach past the search
	# radius by the distance a droplet can travel in its life.
	var reach := spawn_radius + lifetime_max * 20.0
	_emitter = _create_emitter(
		"Spray", amount, lifetime_max, SPRAY_PROCESS_SHADER, QuadMesh.new(), _draw_material, reach
	)
	_process_material = _emitter.process_material as ShaderMaterial
	_create_ripples(_emitter, ripple_amount, ripple_lifetime)
	_push_parameters()


func _sea_state_changed(field: WaveField) -> void:
	_process_material.set_shader_parameter(
		&"spray_amount", spray_amount_for_wind(field.wind_speed) * amount_scale
	)
	_process_material.set_shader_parameter(
		&"spindrift_amount", spindrift_amount_for_wind(field.wind_speed)
	)


func _weather_changed(preset: WeatherPreset) -> void:
	# Spray leaves the crests the preset says are foaming, so the two stay in agreement as
	# the weather changes how readily the sea breaks.
	_whitecap_threshold = preset.whitecap_threshold
	_push_breaking_threshold()


## Writes every exported value to the materials. Called once the emitters exist.
func _push_parameters() -> void:
	_process_material.set_shader_parameter(&"spawn_radius", spawn_radius)
	_process_material.set_shader_parameter(&"candidate_count", candidate_count)
	_process_material.set_shader_parameter(&"breaking_range", breaking_range)
	_process_material.set_shader_parameter(
		&"launch_speed", Vector2(launch_speed_min, launch_speed_max)
	)
	_process_material.set_shader_parameter(&"wind_fraction", wind_fraction)
	_process_material.set_shader_parameter(&"air_drag", air_drag)
	_process_material.set_shader_parameter(
		&"droplet_size", Vector2(droplet_size_min, droplet_size_max)
	)
	_process_material.set_shader_parameter(
		&"lifetime_range", Vector2(lifetime_min, lifetime_max)
	)
	_process_material.set_shader_parameter(&"ripple_max_distance", ripple_max_distance)
	_process_material.set_shader_parameter(&"ripple_scale", ripple_scale)
	_process_material.set_shader_parameter(&"ripple_lifetime", ripple_lifetime)
	_push_breaking_threshold()

	_draw_material.set_shader_parameter(&"albedo", spray_color)
	_draw_material.set_shader_parameter(&"streak_time", streak_time)
	_draw_material.set_shader_parameter(&"edge_noise", edge_noise)
	_draw_material.set_shader_parameter(&"erosion_start", erosion_start)
	_draw_material.set_shader_parameter(&"near_fade", near_fade)


func _push_breaking_threshold() -> void:
	_process_material.set_shader_parameter(
		&"breaking_threshold", _whitecap_threshold - threshold_offset
	)
