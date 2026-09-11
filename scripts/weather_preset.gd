class_name WeatherPreset
extends Resource

## A complete weather look: sky, sun, ambient light and the ocean's response to them.
##
## Weather is authored as discrete presets rather than blended from a single dial, so each
## mood can be tuned to its best without being a point on a compromise curve between the
## others.
##
## A preset owns every value that has to move together. Changing the sky without changing
## the sun and the water's tint is what produces a scene that looks lit by two different
## days at once, so [method apply] writes all of them from one place.
##
## Applying a preset is a discrete change, not a transition. To cross-fade between two
## looks, apply the target and animate the pieces that matter — there is deliberately no
## interpolation built in here.

@export_group("Identity")

## Human-readable name, shown in the HUD.
@export var display_name: String = "Untitled"

@export_group("Sky")

## Colour at the skyline.
@export var horizon_color: Color = Color(0.71, 0.87, 0.95)

## Colour overhead.
@export var zenith_color: Color = Color(0.19, 0.51, 0.84)

## Colour of the banded halo immediately around the sun.
@export var sun_glow_color: Color = Color(1.0, 0.93, 0.75)

## Colour of the dome below the horizon, behind the sea.
##
## This sits directly behind the far water, where the sea has already fogged out to
## [member fog_color]. Authoring the two independently puts a hard step at the skyline —
## the sea fading to one colour and the sky beneath it painted another — so this is blended
## toward the fog by [member below_horizon_fog_blend] rather than used raw.
@export var below_horizon_color: Color = Color(0.45, 0.62, 0.72)

## How far the below-horizon sky is pulled toward [member fog_color].
##
## 1.0 makes the skyline seamless, which is what distance haze actually does. Lower it only
## if a deliberately visible horizon line is wanted.
@export_range(0.0, 1.0, 0.01) var below_horizon_fog_blend: float = 0.85

## Hard steps between horizon and zenith. Fewer bands reads as more graphic.
@export_range(0, 12, 1) var sky_bands: int = 5

## Compresses the gradient toward the horizon as it rises.
@export_range(0.2, 8.0, 0.1) var horizon_falloff: float = 2.2

@export_group("Sun")

@export var sun_color: Color = Color(1.0, 0.97, 0.86)

## Angular radius of the solid sun disc, in radians.
@export_range(0.0, 0.5, 0.001) var sun_size: float = 0.045

@export_range(0.0, 2.0, 0.01) var sun_glow_size: float = 0.45

@export_range(1, 8, 1) var sun_glow_bands: int = 3

@export_range(0.0, 20.0, 0.1) var sun_intensity: float = 6.0

@export_group("Clouds")

@export var cloud_lit_color: Color = Color(1.0, 0.99, 0.96)

@export var cloud_mid_color: Color = Color(0.86, 0.89, 0.95)

@export var cloud_shadow_color: Color = Color(0.64, 0.69, 0.81)

## Fraction of the sky covered. 0 is clear, 1 is solid overcast.
@export_range(0.0, 1.0, 0.01) var cloud_coverage: float = 0.42

## Edge hardness. Near zero gives the crisp border of a painted cloud.
@export_range(0.001, 0.4, 0.001) var cloud_edge: float = 0.03

@export_range(0.2, 12.0, 0.1) var cloud_scale: float = 2.6

@export_range(0.0, 0.2, 0.001) var cloud_speed: float = 0.012

## Compass direction the whole weather mass travels toward, in degrees.
##
## Shared by waves, visible clouds, cloud shadows, spray and rain. Keeping one heading is
## what makes the sky read as the cause of the sea state instead of an unrelated backdrop.
@export_range(0.0, 360.0, 1.0) var wind_angle: float = 45.0

@export_range(1, 6, 1) var cloud_octaves: int = 4

## Strength of the lit rim on the sunward side of each cloud.
@export_range(0.0, 1.0, 0.01) var cloud_light_wrap: float = 0.55

@export_group("Storm")

## Darkens cloud bases in proportion to their thickness.
@export_range(0.0, 1.0, 0.01) var cloud_base_darkening: float = 0.0

## Strength of a second, faster cloud layer that adds churn to a storm front.
@export_range(0.0, 1.0, 0.01) var storm_layer_strength: float = 0.0

@export_group("Lighting")

@export var light_color: Color = Color(1.0, 0.965, 0.898)

@export_range(0.0, 5.0, 0.01) var light_energy: float = 1.05

## Sun elevation above the horizon, in degrees.
@export_range(-10.0, 90.0, 0.5) var sun_elevation: float = 45.0

## Sun compass bearing, in degrees.
@export_range(0.0, 360.0, 1.0) var sun_azimuth: float = 150.0

@export var ambient_color: Color = Color(0.42, 0.58, 0.78)

@export_range(0.0, 3.0, 0.01) var ambient_energy: float = 0.35

@export_group("Ocean Response")

## Colour the water reflects at grazing angles. Should track the sky, or the sea reads as
## belonging to a different scene from the one above it.
@export var ocean_sky_tint: Color = Color(0.62, 0.84, 0.93)

@export var ocean_shallow_color: Color = Color(0.35, 0.83, 0.85)

@export var ocean_mid_color: Color = Color(0.11, 0.52, 0.75)

@export var ocean_deep_color: Color = Color(0.05, 0.22, 0.45)

@export var ocean_specular_color: Color = Color(1.0, 0.99, 0.93)

@export_range(0.0, 4.0, 0.01) var ocean_specular_strength: float = 1.3

@export_range(0.0, 1.0, 0.01) var ocean_fresnel_strength: float = 0.18

@export_group("Atmosphere")

## Analytic depth fog. Covers the horizon, beyond volumetric fog's finite range.
@export var fog_enabled: bool = true

## Fog colour. Should sit between the horizon sky and the far water, or the skyline reads
## as a seam between two separately-drawn scenes.
@export var fog_color: Color = Color(0.68, 0.82, 0.91)

## Depth fog thickness. Small values read as distance haze; large values close the horizon
## in entirely.
@export_range(0.0, 0.1, 0.0001) var fog_density: float = 0.0016

## How far the fog tints the sky as well as the geometry. Keep low: the sky is already a
## banded gradient, and fogging it flattens the bands the sky shader works to produce.
@export_range(0.0, 1.0, 0.01) var fog_sky_affect: float = 0.25

## Aerial perspective — how strongly the haze picks up the sun's colour when looking
## toward it. This is what makes distance read as lit air rather than grey wash.
@export_range(0.0, 1.0, 0.01) var fog_sun_scatter: float = 0.35

## Height at which depth fog sits, in metres.
@export var fog_height: float = 0.0

## How fast depth fog thins with altitude. Negative values thin going up.
@export_range(-16.0, 16.0, 0.01) var fog_height_density: float = 0.06

@export_group("God Rays")

## Volumetric fog. Off is a real performance saving on weathers that do not need shafts.
@export var volumetric_fog_enabled: bool = true

## Global volumetric density.
##
## For clean shafts this wants to be [i]very[/i] low — the documented god-ray recipe is a
## near-zero density with a very bright sun, so the air reads as rays rather than as fog.
## Raise it for genuine murk, at the cost of the water's colour bands.
@export_range(0.0, 1.0, 0.0001) var volumetric_fog_density: float = 0.008

@export var volumetric_fog_albedo: Color = Color(0.78, 0.87, 0.96)

@export var volumetric_fog_emission: Color = Color(0.0, 0.0, 0.0)

@export_range(0.0, 8.0, 0.01) var volumetric_fog_emission_energy: float = 0.0

## Scattering asymmetry. Near 1.0 scatters forward, so the fog flares toward the sun —
## the visual signature of a god ray, and free.
@export_range(-0.9, 0.9, 0.01) var volumetric_fog_anisotropy: float = 0.75

## Range over which volumetric fog is computed, in metres.
##
## The highest-leverage quality dial: the same number of depth slices is stretched over
## whatever range is asked for, so a short length is sharper at [i]identical[/i] cost.
## Depth fog covers everything past this.
@export_range(10.0, 1024.0, 1.0) var volumetric_fog_length: float = 180.0

@export_range(0.0, 4.0, 0.01) var volumetric_fog_ambient_inject: float = 0.4

@export_range(0.0, 1.0, 0.01) var volumetric_fog_sky_affect: float = 0.4

## The sun's volumetric fog energy — how brightly it lights the fog it shines through.
##
## This is the shaft dial. Shafts are the sun's shadow written into the froxel grid, so
## their strength belongs to the light, not the fog. Godot 4.6 made fog blending brighter,
## so values from older tutorials are far too high; these are tuned for 4.7.
@export_range(0.0, 5000.0, 0.5) var sun_shaft_energy: float = 12.0

## Density of the banded god-ray volume that rides with the camera.
@export_range(0.0, 1.0, 0.001) var godray_density: float = 0.035

## Scattering colour of the shafts. Should track the sky.
@export var godray_color: Color = Color(0.72, 0.85, 0.95)

## Height over which the shaft volume's density falls to nothing, in metres.
@export_range(1.0, 400.0, 1.0) var godray_falloff_height: float = 45.0

## How much of the cloud field casts shadows, and so how strong the shafts are.
##
## This is what actually creates god rays: over open ocean nothing else occludes the sun, so
## an invisible slab casts the clouds into the shadow map. 0 disables it — correct for
## overcast, where a solid lid diffuses the light rather than breaking it into beams.
@export_range(0.0, 1.0, 0.01) var cloud_shadow_amount: float = 0.85

## World size of the cloud shadow cells, in metres.
##
## Larger means broader, further-apart shafts. Wants to be in proportion to
## [member cloud_scale] so the shadows read as belonging to the clouds overhead.
@export_range(20.0, 2000.0, 10.0) var cloud_shadow_scale: float = 260.0

@export_group("Sea State")

## Wind speed driving the sea, in m/s.
##
## Wave height is [i]derived[/i] from this rather than set directly: a fully developed sea
## follows from its wind, so raising the wind is what makes a storm rough. See [WaveField].
@export_range(0.0, 30.0, 0.1) var wind_speed: float = 10.0

## Wave steepness. Higher gives the sharper crests of a rougher sea.
@export_range(0.0, 1.0, 0.01) var wave_steepness: float = 0.72

## Surface compression at which crests break into foam. Lower means more whitecaps.
##
## Named to match the shader uniform it drives: the ocean sources foam from horizontal
## compression of the wave field, which is where real waves break.
@export_range(0.0, 1.0, 0.01) var whitecap_threshold: float = 0.62

## Fraction of the foam residue that survives one second.
##
## How long the streak left behind a breaking crest lingers before it dissolves. A cold,
## rough sea holds foam for many seconds; a calm warm one loses it almost at once. This is
## the parameter that decides whether foam reads as something the water remembers or as a
## texture painted on the crest.
@export_range(0.0, 0.999, 0.001) var foam_persistence: float = 0.55

@export_group("Precipitation")

## How hard it is raining, from 0 (dry) to 1 (a downpour).
##
## Read by [RainShower] when the weather changes, rather than written by [method apply]: the
## rain owns its own particles, and only needs to know how many to let fall. It is authored
## here instead of being derived from the sea state the way spray is, because a squall can
## come with any sea.
@export_range(0.0, 1.0, 0.01) var rain_intensity: float = 0.0


## Writes every value in this preset to the scene.
##
## All four targets are optional so a preset can drive a partial scene — a sky-only preview,
## or an ocean with no environment.
func apply(
	sky_material: ShaderMaterial,
	environment: Environment,
	sun: DirectionalLight3D,
	ocean_material: ShaderMaterial,
	wave_field: WaveField = null,
	atmosphere: Atmosphere = null,
	foam_field: FoamField = null,
) -> void:
	_apply_sky(sky_material)
	_apply_environment(environment)
	_apply_sun(sun)
	_apply_ocean(ocean_material)
	_apply_sea_state(wave_field)
	_apply_foam(foam_field)
	# Fog last, because it reads the environment the steps above just wrote.
	if atmosphere != null:
		atmosphere.apply_weather(self, environment)


func _apply_sky(sky_material: ShaderMaterial) -> void:
	if sky_material == null:
		return
	sky_material.set_shader_parameter(&"horizon_color", horizon_color)
	sky_material.set_shader_parameter(&"zenith_color", zenith_color)
	sky_material.set_shader_parameter(&"sun_glow_color", sun_glow_color)
	# Matched to the fog the sea fades into, so the skyline is a continuation of the haze
	# rather than a seam between two separately authored colours.
	var horizon_base := below_horizon_color
	if fog_enabled:
		horizon_base = below_horizon_color.lerp(fog_color, below_horizon_fog_blend)
	sky_material.set_shader_parameter(&"below_horizon_color", horizon_base)
	sky_material.set_shader_parameter(&"sky_bands", sky_bands)
	sky_material.set_shader_parameter(&"horizon_falloff", horizon_falloff)

	sky_material.set_shader_parameter(&"sun_color", sun_color)
	sky_material.set_shader_parameter(&"sun_size", sun_size)
	sky_material.set_shader_parameter(&"sun_glow_size", sun_glow_size)
	sky_material.set_shader_parameter(&"sun_glow_bands", sun_glow_bands)
	sky_material.set_shader_parameter(&"sun_intensity", sun_intensity)

	sky_material.set_shader_parameter(&"cloud_lit_color", cloud_lit_color)
	sky_material.set_shader_parameter(&"cloud_mid_color", cloud_mid_color)
	sky_material.set_shader_parameter(&"cloud_shadow_color", cloud_shadow_color)
	sky_material.set_shader_parameter(&"cloud_coverage", cloud_coverage)
	sky_material.set_shader_parameter(&"cloud_edge", cloud_edge)
	sky_material.set_shader_parameter(&"cloud_scale", cloud_scale)
	sky_material.set_shader_parameter(&"cloud_speed", cloud_speed)
	sky_material.set_shader_parameter(&"cloud_wind_angle", wind_angle)
	sky_material.set_shader_parameter(&"cloud_octaves", cloud_octaves)
	sky_material.set_shader_parameter(&"cloud_light_wrap", cloud_light_wrap)

	sky_material.set_shader_parameter(&"cloud_base_darkening", cloud_base_darkening)
	sky_material.set_shader_parameter(&"storm_layer_strength", storm_layer_strength)


func _apply_environment(environment: Environment) -> void:
	if environment == null:
		return
	environment.ambient_light_color = ambient_color
	environment.ambient_light_energy = ambient_energy


func _apply_sun(sun: DirectionalLight3D) -> void:
	if sun == null:
		return
	sun.light_color = light_color
	sun.light_energy = light_energy
	# Point the light down from the given elevation and bearing. The sky shader reads
	# LIGHT0_DIRECTION, so the sun disc and the cloud lighting follow from this alone.
	sun.rotation = Vector3(
		deg_to_rad(-sun_elevation), deg_to_rad(sun_azimuth), 0.0
	)


func _apply_ocean(ocean_material: ShaderMaterial) -> void:
	if ocean_material == null:
		return
	ocean_material.set_shader_parameter(&"color_sky_tint", ocean_sky_tint)
	ocean_material.set_shader_parameter(&"color_shallow", ocean_shallow_color)
	ocean_material.set_shader_parameter(&"color_mid", ocean_mid_color)
	ocean_material.set_shader_parameter(&"color_deep", ocean_deep_color)
	ocean_material.set_shader_parameter(&"specular_color", ocean_specular_color)
	ocean_material.set_shader_parameter(&"specular_strength", ocean_specular_strength)
	ocean_material.set_shader_parameter(&"fresnel_strength", ocean_fresnel_strength)
	ocean_material.set_shader_parameter(&"whitecap_threshold", whitecap_threshold)
	ocean_material.set_shader_parameter(&"sun_direction", sun_direction())


## Returns the unit vector pointing from the scene toward the sun.
##
## The ocean shader needs the direction light arrives FROM for its hard specular, while
## [DirectionalLight3D] points along -Z once rotated. Deriving both from the same elevation
## and azimuth here keeps the water's glint on the same sun the sky draws.
func sun_direction() -> Vector3:
	var elevation := deg_to_rad(sun_elevation)
	var azimuth := deg_to_rad(sun_azimuth)
	# Derived from the same rotation _apply_sun() gives the light, so the two cannot drift.
	# A DirectionalLight3D shines along its local -Z, so the direction TOWARD the sun is the
	# negation of that: rotating (0,0,-1) by (pitch=-elevation, yaw=azimuth) and flipping.
	return Vector3(
		sin(azimuth) * cos(elevation),
		sin(elevation),
		cos(azimuth) * cos(elevation),
	).normalized()


func _apply_sea_state(wave_field: WaveField) -> void:
	if wave_field == null:
		return
	# Setting these emits Resource.changed, which the Ocean forwards to the shader, so the
	# CPU and GPU wave spectra stay in agreement.
	wave_field.wind_speed = wind_speed
	wave_field.wind_angle = wind_angle
	wave_field.steepness = wave_steepness


## Writes the foam behaviour to the running simulation.
##
## The ocean material already carries [member whitecap_threshold] for the analytic foam it
## draws beyond the simulated area; this keeps the simulation's own breaking criterion on
## the same value, so foam does not change character at the edge of the map.
func _apply_foam(foam_field: FoamField) -> void:
	if foam_field == null:
		return
	foam_field.set_simulation_parameter(&"whitecap_threshold", whitecap_threshold)
	foam_field.set_simulation_parameter(&"residue_decay", foam_persistence)
