class_name PropMaterials
extends RefCounted

## Shared materials for the props built in code: the jetty, the lighthouse and their fittings.
##
## Every solid surface uses [code]cel.gdshader[/code], the same shader and banding as the islands
## and the raft, so a prop reads as part of the painted world rather than as a grey placeholder.
## Materials are cached by colour: a lighthouse has a few dozen parts in five colours, and a
## material per part would be a few dozen identical shader instances for the renderer to sort.

const CEL_SHADER: Shader = preload("res://shaders/cel.gdshader")

static var _cel_cache: Dictionary = {}
static var _glow_cache: Dictionary = {}


## Returns the opaque cel material for [param color].
##
## Opaque on purpose: see the long note in [code]cel.gdshader[/code] on why anything that sits
## in or near the water must never write ALPHA.
static func cel(color: Color, bands: int = 3) -> ShaderMaterial:
	var key := "%s/%d" % [color.to_html(), bands]
	if not _cel_cache.has(key):
		var material := ShaderMaterial.new()
		material.shader = CEL_SHADER
		material.set_shader_parameter(&"albedo_color", Vector3(color.r, color.g, color.b))
		material.set_shader_parameter(&"light_bands", bands)
		material.set_shader_parameter(&"specular_strength", 0.15)
		material.set_shader_parameter(&"rim_strength", 0.35)
		_cel_cache[key] = material
	return _cel_cache[key]


## Returns a self-lit material for lamps and windows, which must read as a light source in any
## weather rather than being shaded by the sun.
static func glow(color: Color, energy: float = 2.0) -> StandardMaterial3D:
	var key := "%s/%.2f" % [color.to_html(), energy]
	if not _glow_cache.has(key):
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = color
		material.emission_enabled = true
		material.emission = color
		material.emission_energy_multiplier = energy
		_glow_cache[key] = material
	return _glow_cache[key]


## Appends a box of [param size] centred at [param centre] to [param tool].
static func add_box(
	tool: SurfaceTool, size: Vector3, centre: Vector3, basis: Basis = Basis.IDENTITY
) -> void:
	var box := BoxMesh.new()
	box.size = size
	tool.append_from(box, 0, Transform3D(basis, centre))


## Appends a vertical cylinder (or cone, or frustum) to [param tool], its base at [param base].
static func add_cylinder(
	tool: SurfaceTool, bottom_radius: float, top_radius: float, height: float, base: Vector3,
	segments: int = 12,
) -> void:
	var cylinder := CylinderMesh.new()
	cylinder.bottom_radius = bottom_radius
	cylinder.top_radius = top_radius
	cylinder.height = height
	cylinder.radial_segments = segments
	cylinder.rings = 1
	tool.append_from(cylinder, 0, Transform3D(Basis.IDENTITY, base + Vector3.UP * height * 0.5))


## Returns a started [SurfaceTool] ready for [method add_box] and [method add_cylinder].
static func begin() -> SurfaceTool:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	return tool


## Commits [param tool] into a [MeshInstance3D] child of [param parent] wearing [param material].
static func commit(
	tool: SurfaceTool, parent: Node3D, node_name: String, material: Material,
	shadows: bool = true,
) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = tool.commit()
	instance.material_override = material
	instance.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	parent.add_child(instance)
	return instance
