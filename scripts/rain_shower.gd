class_name RainShower
extends OceanParticles

## Rain falling on the sea, for the weathers that bring it.
##
## Unlike spray, rain does not follow from the sea state: a squall can arrive over any sea,
## so how hard it rains is authored per weather as [member WeatherPreset.rain_intensity].
## Everything else about it is physical. Drops fall at a raindrop's terminal velocity, lean
## with the same wind the waves are built from, land on the actual swell, and leave a ring
## where they hit. See [code]rain_particles.gdshader[/code].

## Viewer height above the sea that a drop from the ceiling is guaranteed time to fall
## through, in metres.
##
## Sets the emitter's cycle, and it is deliberately modest. Each particle slot restarts once
## per cycle, so a cycle far longer than a drop's actual fall leaves most slots empty most of
## the time: at 40 m only a fifth of them were ever in the air, and the rain looked thin
## however high [member amount] went. Seen from higher up than this the topmost drops are
## recycled before they land, which is invisible from inside the column.
const COVERED_VIEW_HEIGHT: float = 12.0

const RAIN_PROCESS_SHADER: Shader = preload("res://shaders/rain_particles.gdshader")
const DROPLET_SHADER: Shader = preload("res://shaders/spray_droplet.gdshader")

## How hard it rains, from 0 (dry) to 1. Replaced by the weather preset whenever
## [member OceanParticles.weather] applies one.
@export_range(0.0, 1.0, 0.01) var rain_intensity: float = 0.0:
	set(value):
		rain_intensity = value
		_apply_intensity()

@export_group("Emission")

## Drops falling at full intensity.
@export_range(100, 100000, 100) var amount: int = 60000

## Radius of the rained-on patch of sea around the viewer, in metres.
@export_range(5.0, 200.0, 1.0) var rain_radius: float = 45.0

## How far above the viewer drops can appear, in metres.
@export_range(1.0, 200.0, 1.0) var rain_ceiling: float = 22.0

@export_group("Fall")

## Slowest drop, in m/s.
@export_range(0.5, 20.0, 0.1) var fall_speed_min: float = 7.0

## Fastest drop, in m/s.
@export_range(0.5, 20.0, 0.1) var fall_speed_max: float = 9.0

## How much of the wind the drops carry. 1 is physical; lower is more upright rain.
@export_range(0.0, 1.0, 0.01) var wind_fraction: float = 0.6

## Drawn width of a drop, in metres.
@export_range(0.001, 0.2, 0.001) var drop_size: float = 0.022

@export_group("Look")

@export var rain_color: Color = Color(0.72, 0.79, 0.86)

## Seconds of fall a streak spans.
##
## Kept short. A long streak reads as a scratch across the frame rather than as a falling
## drop, and at close range a drop's streak covers a lot of screen.
@export_range(0.0, 0.5, 0.005) var streak_time: float = 0.045

## Narrowest a drop may become on screen, in pixels.
@export_range(0.0, 8.0, 0.1) var min_pixel_width: float = 1.6

## Distance within which drops are not drawn at all, in metres.
##
## A drop falling past the lens is drawn as a streak across the whole frame. Removing the
## nearest ones costs nothing visually — there is always another drop behind it.
@export_range(0.0, 10.0, 0.1) var near_fade: float = 1.4

@export_group("Landing")

## Most ripple rings alive at once.
@export_range(0, 20000, 100) var ripple_amount: int = 3000

## Rings are only left within this distance of the viewer, in metres.
@export_range(0.0, 200.0, 1.0) var ripple_max_distance: float = 24.0

## Smallest ring, in metres.
@export_range(0.01, 4.0, 0.01) var ripple_radius_min: float = 0.12

## Largest ring, in metres.
@export_range(0.01, 4.0, 0.01) var ripple_radius_max: float = 0.28

## Seconds a ring lasts.
@export_range(0.1, 4.0, 0.05) var ripple_lifetime: float = 0.55

var _emitter: GPUParticles3D
var _process_material: ShaderMaterial


func _build_emitters() -> void:
	var draw_material := ShaderMaterial.new()
	draw_material.shader = DROPLET_SHADER
	draw_material.set_shader_parameter(&"albedo", rain_color)
	draw_material.set_shader_parameter(&"streak_time", streak_time)
	draw_material.set_shader_parameter(&"min_pixel_width", min_pixel_width)
	draw_material.set_shader_parameter(&"near_fade", near_fade)
	# Rain streaks are clean and never dissolve; lumps and erosion are for spray.
	draw_material.set_shader_parameter(&"edge_noise", 0.0)
	draw_material.set_shader_parameter(&"erosion_start", 1.0)
	draw_material.set_shader_parameter(&"tail_taper", 0.3)

	var cycle := (rain_ceiling + COVERED_VIEW_HEIGHT) / maxf(fall_speed_min, 0.1)
	_emitter = _create_emitter(
		"Rain", amount, cycle, RAIN_PROCESS_SHADER, QuadMesh.new(), draw_material, rain_radius * 2.0
	)
	_process_material = _emitter.process_material as ShaderMaterial
	_create_ripples(_emitter, ripple_amount, ripple_lifetime)

	_process_material.set_shader_parameter(&"rain_radius", rain_radius)
	_process_material.set_shader_parameter(&"rain_ceiling", rain_ceiling)
	_process_material.set_shader_parameter(&"fall_speed", Vector2(fall_speed_min, fall_speed_max))
	_process_material.set_shader_parameter(&"wind_fraction", wind_fraction)
	_process_material.set_shader_parameter(&"drop_size", drop_size)
	_process_material.set_shader_parameter(&"ripple_max_distance", ripple_max_distance)
	_process_material.set_shader_parameter(
		&"ripple_radius", Vector2(ripple_radius_min, ripple_radius_max)
	)
	_process_material.set_shader_parameter(&"ripple_lifetime", ripple_lifetime)
	_apply_intensity()


func _weather_changed(preset: WeatherPreset) -> void:
	rain_intensity = preset.rain_intensity


## Writes [member rain_intensity] to the emitter, switching it off entirely when dry.
##
## Stopping emission rather than emitting at zero intensity lets the system go idle once the
## last drops land, so a dry weather costs nothing on the GPU.
func _apply_intensity() -> void:
	if _emitter == null:
		return
	_process_material.set_shader_parameter(&"rain_amount", rain_intensity)
	_emitter.emitting = rain_intensity > 0.0
