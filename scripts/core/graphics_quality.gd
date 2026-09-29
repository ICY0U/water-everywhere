class_name GraphicsQuality
extends RefCounted

## The graphics presets, and the half of each that lives on nodes in a scene.
##
## [code]Settings[/code] applies what belongs to the whole application — anti-aliasing, render
## scale, the shadow atlas. This applies the rest to one scene's own nodes, and is called by that
## scene whenever the preset changes and whenever the weather does, because a weather preset
## writes the environment's volumetric fog flag itself and would otherwise switch fog back on
## underneath a Low setting.
##
## Nothing here is replicated: two players on different presets see the same sea, drawn at
## different cost. The foam simulation's resolution changes only how finely foam is drawn, not
## where waves are, so buoyancy and every peer's water stay identical.

## Settings for each [code]Settings.Quality[/code], cheapest first.
##
## [b]Volumetric fog is the big lever.[/b] It carries the god rays and the depth haze, and on an
## integrated GPU it costs more than the ocean itself; Low drops it and keeps the ordinary
## distance fog, so the horizon still dissolves. Foam resolution is the second: the simulation is
## two full-screen passes over a square texture every frame.
const PRESETS: Array[Dictionary] = [
	{
		"msaa": Viewport.MSAA_DISABLED, "scale": 0.8, "shadow_atlas": 2048,
		"soft_shadows": RenderingServer.SHADOW_QUALITY_SOFT_VERY_LOW,
		"shadow_distance": 140.0, "volumetric_fog": false, "foam_resolution": 256,
	},
	{
		"msaa": Viewport.MSAA_2X, "scale": 1.0, "shadow_atlas": 4096,
		"soft_shadows": RenderingServer.SHADOW_QUALITY_SOFT_LOW,
		"shadow_distance": 200.0, "volumetric_fog": true, "foam_resolution": 384,
	},
	{
		"msaa": Viewport.MSAA_4X, "scale": 1.0, "shadow_atlas": 4096,
		"soft_shadows": RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM,
		"shadow_distance": 260.0, "volumetric_fog": true, "foam_resolution": 512,
	},
]


## Applies preset [param level] to the nodes of one scene. Any argument may be null.
static func apply_to_scene(
	level: int, environment: Environment, sun: DirectionalLight3D, foam: FoamField
) -> void:
	var preset: Dictionary = PRESETS[clampi(level, 0, PRESETS.size() - 1)]
	if environment != null and not preset["volumetric_fog"]:
		# Only ever switched OFF here. Whether fog is on at all is the weather's decision; the
		# preset can veto it but must not force fog into a preset authored without any.
		environment.volumetric_fog_enabled = false
	if sun != null:
		sun.directional_shadow_max_distance = preset["shadow_distance"]
	if foam != null and foam.resolution != int(preset["foam_resolution"]):
		foam.resolution = preset["foam_resolution"]
