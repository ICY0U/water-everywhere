class_name Atmosphere
extends Node3D

## Owns the scene's air: depth fog at the horizon, volumetric fog near the camera, and the
## banded god-ray volume that rides along with it.
##
## Three separate systems have to agree for the air to read as one atmosphere, and this
## node is where that agreement lives:
##
## [b]Depth fog[/b] handles the horizon. Volumetric fog has a finite range — a few hundred
## metres at usable quality — while the ocean extends past 2 km, so the far water would
## otherwise end at a hard line where the fog stops. Analytic depth fog covers everything
## beyond the volumetric range and costs essentially nothing.
##
## [b]Volumetric fog[/b] handles the shafts. In Godot, god rays are not a post-process:
## shadow-casting lights write their shadows into the froxel grid, so thin fog plus a very
## bright sun [i]is[/i] the effect. That is why this node adjusts the sun's
## [member Light3D.light_volumetric_fog_energy] rather than driving any screen-space pass.
##
## [b]The FogVolume[/b] carries [code]cel_godrays.gdshader[/code], which quantises density
## into slabs so the shafts have flat edges instead of a smooth gradient.
##
## The volume follows the camera, because a froxel grid only covers the view frustum;
## a world-anchored volume would simply leave the grid. It is snapped to a grid step for
## the same reason [Ocean] snaps its rings — a continuously sliding volume resamples the
## noise field every frame and the fog boils.
##
## Fog belongs to weather, so [WeatherPreset] drives this node through
## [method apply_weather]. Setting fog anywhere else reintroduces exactly the split this
## project avoids elsewhere: a scene lit by one day and hazed by another.

## Shader parameter names on the god-ray material.
const PARAM_DENSITY: StringName = &"density"
const PARAM_ALBEDO: StringName = &"albedo"
const PARAM_FLOOR_HEIGHT: StringName = &"floor_height"
const PARAM_FALLOFF_HEIGHT: StringName = &"falloff_height"
const PARAM_FOG_TIME: StringName = &"fog_time"

## Shader parameter names on the cloud shadow caster.
const PARAM_COVERAGE: StringName = &"coverage"
const PARAM_CLOUD_SCALE: StringName = &"scale"
const PARAM_CLOUD_TIME: StringName = &"cloud_time"
const PARAM_SHADOW_AMOUNT: StringName = &"shadow_amount"
const PARAM_WIND_DIRECTION: StringName = &"wind_direction"
const PARAM_WIND_SPEED: StringName = &"wind_speed"

@export_group("Targets")

## Environment carrying the fog settings. Without it only the FogVolume responds.
@export var world_environment: WorldEnvironment

## Sun whose shadows carve the shafts. Its volumetric fog energy is driven from here.
@export var sun: DirectionalLight3D

## Node the fog volume follows. Falls back to the viewport camera when unset.
@export var follow_target: Node3D

## Ocean providing the shared, network-corrected presentation clock.
@export var ocean_clock: Ocean

@export_group("Volume")

## Horizontal half-size of the god-ray volume, in metres.
##
## This wants to be a little larger than [member Environment.volumetric_fog_length], so the
## volume always covers the whole froxel grid. Larger than that is wasted: froxels outside
## the grid are never shaded.
@export_range(10.0, 2000.0, 1.0) var volume_extent: float = 320.0:
	set(value):
		volume_extent = value
		_update_volume_size()

## Vertical size of the volume, in metres. Shafts are only visible inside it.
@export_range(10.0, 1000.0, 1.0) var volume_height: float = 220.0:
	set(value):
		volume_height = value
		_update_volume_size()

## Grid step the volume snaps to as it follows the camera.
##
## Snapping is what stops the fog boiling. A volume that slides continuously feeds a
## slightly different world position to the noise field every frame, and the patches crawl.
@export_range(1.0, 100.0, 1.0) var follow_snap: float = 16.0

## Material for the fog volume. Expects [code]cel_godrays.gdshader[/code].
@export var godray_material: Material:
	set(value):
		godray_material = value
		if _volume != null:
			_volume.material = godray_material

@export_group("Cloud Shadows")

## Material for the cloud shadow slab. Expects [code]cloud_shadow_caster.gdshader[/code].
##
## Without this there are no god rays at all. Shafts are the sun's shadow in the froxel
## grid, and over open ocean nothing else casts one — the sky's clouds are a background
## pass, and wave crests are far too short. See the shader for the measurements.
@export var cloud_shadow_material: Material:
	set(value):
		cloud_shadow_material = value
		if _caster != null:
			_caster.material_override = cloud_shadow_material

## Height above the camera at which the cloud slab sits, in metres.
##
## This is the shaft length: the light travels from here down to the water, so a low slab
## gives short stubby beams and a high one gives long raking ones.
##
## It must stay well inside the sun's [member
## DirectionalLight3D.directional_shadow_max_distance], and that is a tighter constraint than
## it sounds: at 160 m the cascade was too coarse to resolve the slab at all and NO cloud
## shadow appeared, which looks exactly like "the caster is broken". Measured — a 45 m slab
## under a 120 m cascade casts cleanly.
@export_range(20.0, 2000.0, 1.0) var cloud_shadow_height: float = 45.0

## Edge length of the cloud slab, in metres. Wants to cover the shadow cascade.
@export_range(50.0, 4000.0, 10.0) var cloud_shadow_size: float = 500.0

@export_group("Clock")

## Whether to drive the god-ray shader's clock from this node.
##
## The project runs one clock so the CPU wave field, the ocean shader and the fog cannot
## drift apart. Leave this on unless something else is pushing [code]fog_time[/code].
@export var drive_fog_time: bool = true

var _volume: FogVolume
var _caster: MeshInstance3D
var _time: float = 0.0


func _ready() -> void:
	_volume = FogVolume.new()
	_volume.name = &"GodRayVolume"
	_volume.shape = RenderingServer.FOG_VOLUME_SHAPE_BOX
	_volume.material = godray_material
	_update_volume_size()
	add_child(_volume)

	_build_cloud_shadow_caster()


func _process(delta: float) -> void:
	_time = ocean_clock.elapsed_time if ocean_clock != null else _time + delta
	_follow_camera()
	if drive_fog_time:
		_push_fog_time()


## Writes every atmospheric value in [param preset] to the scene.
##
## Called by [WeatherController] as part of one atomic weather change, so the air, the sky
## and the water always describe the same day.
func apply_weather(preset: WeatherPreset, environment: Environment = null) -> void:
	if preset == null:
		return

	var env := environment if environment != null else _resolve_environment()
	if env != null:
		_apply_depth_fog(preset, env)
		_apply_volumetric_fog(preset, env)

	_apply_sun_shafts(preset)
	_apply_godray_material(preset)
	_apply_cloud_shadows(preset)


func _apply_depth_fog(preset: WeatherPreset, env: Environment) -> void:
	env.fog_enabled = preset.fog_enabled
	env.fog_light_color = preset.fog_color
	env.fog_density = preset.fog_density
	env.fog_sky_affect = preset.fog_sky_affect
	# Aerial perspective: the fog picks up the sun's colour when looking toward it, which
	# is what makes a hazy horizon read as lit rather than as flat grey wash.
	env.fog_sun_scatter = preset.fog_sun_scatter
	env.fog_height = preset.fog_height
	env.fog_height_density = preset.fog_height_density


func _apply_volumetric_fog(preset: WeatherPreset, env: Environment) -> void:
	env.volumetric_fog_enabled = preset.volumetric_fog_enabled
	env.volumetric_fog_density = preset.volumetric_fog_density
	env.volumetric_fog_albedo = preset.volumetric_fog_albedo
	env.volumetric_fog_emission = preset.volumetric_fog_emission
	env.volumetric_fog_emission_energy = preset.volumetric_fog_emission_energy
	# Forward scattering is what separates "god rays" from "haze": near 1.0 the fog
	# brightens sharply toward the sun, which is the visual signature of a shaft. It is
	# free, so it is the first dial to reach for.
	env.volumetric_fog_anisotropy = preset.volumetric_fog_anisotropy
	env.volumetric_fog_length = preset.volumetric_fog_length
	env.volumetric_fog_ambient_inject = preset.volumetric_fog_ambient_inject
	env.volumetric_fog_sky_affect = preset.volumetric_fog_sky_affect


func _apply_sun_shafts(preset: WeatherPreset) -> void:
	if sun == null:
		return
	# Shafts are the sun's shadow in the froxel grid, so their strength is a property of
	# the LIGHT, not of the fog. Zero excludes the light from the volumetric pass entirely,
	# which is also a real performance saving.
	sun.light_volumetric_fog_energy = preset.sun_shaft_energy


func _apply_godray_material(preset: WeatherPreset) -> void:
	var material := godray_material as ShaderMaterial
	if material == null:
		return
	material.set_shader_parameter(PARAM_DENSITY, preset.godray_density)
	material.set_shader_parameter(PARAM_ALBEDO, preset.godray_color)
	material.set_shader_parameter(PARAM_FALLOFF_HEIGHT, preset.godray_falloff_height)


func _follow_camera() -> void:
	var target := _resolve_follow_target()
	if target == null:
		return

	var origin := target.global_position
	# Snapped so the noise field is sampled at stable world positions. Height is snapped
	# too: the volume is tall enough that a step is invisible, and an unsnapped Y makes the
	# height falloff crawl as the camera rises.
	global_position = Vector3(
		snappedf(origin.x, follow_snap),
		snappedf(origin.y, follow_snap),
		snappedf(origin.z, follow_snap),
	)


func _apply_cloud_shadows(preset: WeatherPreset) -> void:
	var material := cloud_shadow_material as ShaderMaterial
	if material == null:
		return
	# Matched to the sky's own cloud field, so shadows land under the clouds that are drawn
	# rather than beside them.
	material.set_shader_parameter(PARAM_COVERAGE, preset.cloud_coverage)
	material.set_shader_parameter(PARAM_CLOUD_SCALE, preset.cloud_shadow_scale)
	material.set_shader_parameter(PARAM_SHADOW_AMOUNT, preset.cloud_shadow_amount)
	var heading := deg_to_rad(preset.wind_angle)
	material.set_shader_parameter(PARAM_WIND_DIRECTION, Vector2(cos(heading), sin(heading)))
	material.set_shader_parameter(PARAM_WIND_SPEED, preset.wind_speed)


func _build_cloud_shadow_caster() -> void:
	_caster = MeshInstance3D.new()
	_caster.name = &"CloudShadowCaster"
	var quad := QuadMesh.new()
	quad.size = Vector2(cloud_shadow_size, cloud_shadow_size)
	# QuadMesh faces +Z, so lay it flat to face down at the water.
	quad.orientation = PlaneMesh.FACE_Y
	_caster.mesh = quad
	_caster.material_override = cloud_shadow_material
	# The whole point: cast into the shadow map, never appear in the camera's view.
	_caster.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	_caster.position = Vector3(0.0, cloud_shadow_height, 0.0)
	add_child(_caster)


func _push_fog_time() -> void:
	var material := godray_material as ShaderMaterial
	if material != null:
		material.set_shader_parameter(PARAM_FOG_TIME, _time)

	var caster_material := cloud_shadow_material as ShaderMaterial
	if caster_material != null:
		caster_material.set_shader_parameter(PARAM_CLOUD_TIME, _time)


func _update_volume_size() -> void:
	if _volume == null:
		return
	_volume.size = Vector3(volume_extent * 2.0, volume_height, volume_extent * 2.0)


func _resolve_environment() -> Environment:
	if world_environment == null:
		return null
	return world_environment.environment


func _resolve_follow_target() -> Node3D:
	if follow_target != null:
		return follow_target
	return get_viewport().get_camera_3d()
