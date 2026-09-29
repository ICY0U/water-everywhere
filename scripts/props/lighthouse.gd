class_name Lighthouse
extends StaticBody3D

## The mainland's lighthouse: the landmark the whole crossing is steered by.
##
## The plan asks for "a distinctive lighthouse, harbor silhouette ... and obvious landing", and
## the voyage's objective used to point at mountains because nothing else was there. A mountain
## says "land"; a lighthouse says "this land, and this side of it". Banded red and white so it
## reads against the green-grey mainland at 250 m, tall enough that its lamp clears the home
## island's dunes, and lit, with a beam that sweeps harder as the weather closes in — which is
## exactly when a crew needs to find it.
##
## Built in code, like [Jetty] and [Island], from a handful of dimensions, and settled onto the
## ground under it when it enters the tree: its parent island answers
## [method Island.height_at_world], so moving the lighthouse in the editor needs no hand-tuned
## height and the plinth never floats or sinks.
##
## [b]Presentation only, apart from its collider.[/b] The beam turns on the ocean's replicated
## clock, so every peer sees it pointing the same way without a byte on the wire.

## Height of the banded tower above its plinth, in metres.
@export_range(8.0, 60.0, 0.5) var tower_height: float = 24.0

## Radius of the tower at its foot and at its top, in metres.
@export_range(1.0, 8.0, 0.1) var base_radius: float = 3.6
@export_range(0.5, 6.0, 0.1) var top_radius: float = 2.3

## Number of alternating colour bands up the tower.
@export_range(1, 12, 1) var bands: int = 5

## Seconds for the beam to sweep once round.
@export_range(2.0, 60.0, 0.5) var sweep_period: float = 9.0

## Ocean whose clock turns the beam, so every peer's beam points the same way.
@export var ocean: Ocean

## Weather whose light level sets how strongly the beam shows. Optional.
@export var weather: WeatherController

@export_group("Colours")
@export var band_color: Color = Color(0.824, 0.231, 0.212)
@export var wall_color: Color = Color(0.957, 0.937, 0.894)
@export var trim_color: Color = Color(0.231, 0.255, 0.302)
@export var stone_color: Color = Color(0.580, 0.573, 0.553)
@export var lamp_color: Color = Color(1.0, 0.878, 0.541)
@export var roof_color: Color = Color(0.588, 0.231, 0.184)

## Height of the stone plinth the tower stands on, in metres.
const PLINTH_HEIGHT: float = 1.6

## How far the plinth is sunk into the ground, so a slope under it never shows a gap.
const PLINTH_SINK: float = 0.9

## Height of the glazed lantern room, in metres.
const LANTERN_HEIGHT: float = 3.0

## Beam opacity in the brightest and the dullest weather.
##
## A shaft of light is barely visible at noon and unmissable in a squall. Tied to the sun's
## energy rather than to a preset's name, so a new preset gets a sensible beam for free.
const BEAM_ALPHA_BRIGHT: float = 0.05
const BEAM_ALPHA_DULL: float = 0.34

## Sun energies that count as the brightest and the dullest weather for the beam.
const SUN_ENERGY_BRIGHT: float = 1.15
const SUN_ENERGY_DULL: float = 0.45

var _beam_pivot: Node3D
var _beam_material: StandardMaterial3D
var _lamp_light: OmniLight3D

## Time the beam turns on when no ocean clock is assigned.
var _own_clock: float = 0.0


func _ready() -> void:
	_settle_on_ground()
	_build_plinth()
	_build_tower()
	_build_lantern()
	_build_beam()
	_build_cottage()
	_build_colliders()
	if weather != null:
		weather.weather_changed.connect(_on_weather_changed)
		var preset := weather.current_preset()
		if preset != null:
			_on_weather_changed(preset, weather.current_index())
	else:
		_set_beam_strength(0.5)


func _process(delta: float) -> void:
	if _beam_pivot == null:
		return
	var clock := ocean.elapsed_time if ocean != null else _fallback_clock(delta)
	_beam_pivot.rotation.y = fmod(clock, sweep_period) / sweep_period * TAU


## Returns the world position of the lamp, for anything that wants to point at the light.
func lamp_position() -> Vector3:
	return to_global(Vector3(0.0, PLINTH_HEIGHT - PLINTH_SINK + tower_height + 1.6, 0.0))


func _fallback_clock(delta: float) -> float:
	_own_clock += delta
	return _own_clock


## Drops the lighthouse onto its parent island's ground, at the lowest point of its footprint.
func _settle_on_ground() -> void:
	var island := get_parent() as Island
	if island == null:
		return
	var lowest := INF
	for index in 8:
		var angle := float(index) / 8.0 * TAU
		var probe := global_position + Vector3(cos(angle), 0.0, sin(angle)) * (base_radius + 1.2)
		lowest = minf(lowest, island.height_at_world(Vector2(probe.x, probe.z)))
	lowest = minf(lowest, island.height_at_world(Vector2(global_position.x, global_position.z)))
	global_position.y = lowest


func _build_plinth() -> void:
	var tool := PropMaterials.begin()
	PropMaterials.add_cylinder(
		tool, base_radius + 1.6, base_radius + 1.2, PLINTH_HEIGHT, Vector3.DOWN * PLINTH_SINK, 8
	)
	# A step up to the door, facing +X: the lighthouse is placed with +X toward the sea.
	PropMaterials.add_box(tool, Vector3(1.4, 0.35, 2.4), Vector3(base_radius + 2.3, 0.175, 0.0))
	PropMaterials.commit(tool, self, "Plinth", PropMaterials.cel(stone_color))


func _build_tower() -> void:
	var floor_y := PLINTH_HEIGHT - PLINTH_SINK
	var band_height := tower_height / float(bands)
	var walls := PropMaterials.begin()
	var stripes := PropMaterials.begin()
	for index in bands:
		var lower := lerpf(base_radius, top_radius, float(index) / float(bands))
		var upper := lerpf(base_radius, top_radius, float(index + 1) / float(bands))
		var tool := stripes if index % 2 == 1 else walls
		PropMaterials.add_cylinder(
			tool, lower, upper, band_height, Vector3.UP * (floor_y + band_height * index), 20
		)
	PropMaterials.commit(walls, self, "TowerWhite", PropMaterials.cel(wall_color))
	PropMaterials.commit(stripes, self, "TowerRed", PropMaterials.cel(band_color))

	var trim := PropMaterials.begin()
	# The door, and a pair of small windows up the seaward face.
	PropMaterials.add_box(trim, Vector3(0.5, 2.6, 1.5),
		Vector3(base_radius - 0.15, floor_y + 1.3, 0.0))
	for height in [0.38, 0.66]:
		var radius := lerpf(base_radius, top_radius, height) - 0.1
		PropMaterials.add_box(trim, Vector3(0.4, 1.2, 0.8),
			Vector3(radius, floor_y + tower_height * height, 0.0))
	# The gallery: a platform ringing the top of the tower, with a rail.
	var gallery_y := floor_y + tower_height
	PropMaterials.add_cylinder(trim, top_radius + 0.9, top_radius + 1.1, 0.45, Vector3.UP * gallery_y, 20)
	for index in 16:
		var angle := float(index) / 16.0 * TAU
		var post := Vector3(cos(angle), 0.0, sin(angle)) * (top_radius + 0.95)
		PropMaterials.add_box(trim, Vector3(0.12, 1.1, 0.12), post + Vector3.UP * (gallery_y + 1.0))
	var rail := TorusMesh.new()
	rail.inner_radius = top_radius + 0.88
	rail.outer_radius = top_radius + 1.04
	rail.rings = 24
	rail.ring_segments = 6
	trim.append_from(rail, 0, Transform3D(Basis.IDENTITY, Vector3.UP * (gallery_y + 1.5)))
	PropMaterials.commit(trim, self, "Trim", PropMaterials.cel(trim_color))


func _build_lantern() -> void:
	var base_y := PLINTH_HEIGHT - PLINTH_SINK + tower_height + 0.45
	var glass := PropMaterials.begin()
	PropMaterials.add_cylinder(glass, top_radius - 0.35, top_radius - 0.35, LANTERN_HEIGHT,
		Vector3.UP * base_y, 16)
	PropMaterials.commit(glass, self, "Lamp", PropMaterials.glow(lamp_color, 2.6), false)

	var frame := PropMaterials.begin()
	for index in 8:
		var angle := float(index) / 8.0 * TAU
		var bar := Vector3(cos(angle), 0.0, sin(angle)) * (top_radius - 0.3)
		PropMaterials.add_box(frame, Vector3(0.14, LANTERN_HEIGHT, 0.14),
			bar + Vector3.UP * (base_y + LANTERN_HEIGHT * 0.5))
	PropMaterials.add_cylinder(frame, top_radius - 0.2, top_radius - 0.2, 0.25,
		Vector3.UP * (base_y + LANTERN_HEIGHT), 16)
	PropMaterials.commit(frame, self, "LanternFrame", PropMaterials.cel(trim_color))

	var roof := PropMaterials.begin()
	PropMaterials.add_cylinder(roof, top_radius + 0.25, 0.12, 2.3,
		Vector3.UP * (base_y + LANTERN_HEIGHT + 0.25), 16)
	var finial := SphereMesh.new()
	finial.radius = 0.32
	finial.height = 0.64
	roof.append_from(finial, 0, Transform3D(Basis.IDENTITY,
		Vector3.UP * (base_y + LANTERN_HEIGHT + 2.7)))
	PropMaterials.commit(roof, self, "Roof", PropMaterials.cel(roof_color))

	_lamp_light = OmniLight3D.new()
	_lamp_light.name = "LampLight"
	_lamp_light.light_color = lamp_color
	_lamp_light.omni_range = 26.0
	_lamp_light.light_energy = 1.6
	_lamp_light.shadow_enabled = false
	_lamp_light.position = Vector3.UP * (base_y + LANTERN_HEIGHT * 0.5)
	add_child(_lamp_light)


## Two opposed cones of light on a pivot that the clock turns.
##
## Additive and unshaded, so a beam only ever brightens what is behind it; transparent is safe
## here in a way it is not for the props in the water, because nothing is meant to be hidden
## behind a shaft of light.
func _build_beam() -> void:
	_beam_pivot = Node3D.new()
	_beam_pivot.name = "Beam"
	_beam_pivot.position = Vector3.UP * (
		PLINTH_HEIGHT - PLINTH_SINK + tower_height + 0.45 + LANTERN_HEIGHT * 0.5
	)
	add_child(_beam_pivot)

	_beam_material = StandardMaterial3D.new()
	_beam_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_beam_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_beam_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_beam_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_beam_material.no_depth_test = false
	_beam_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	_beam_material.albedo_color = Color(lamp_color, BEAM_ALPHA_BRIGHT)

	var cone := CylinderMesh.new()
	cone.top_radius = 0.5
	cone.bottom_radius = 6.5
	cone.height = 90.0
	cone.radial_segments = 16
	cone.rings = 1
	cone.cap_top = false
	cone.cap_bottom = false
	for side in [-1.0, 1.0]:
		var beam := MeshInstance3D.new()
		beam.name = "Cone%s" % ("East" if side > 0.0 else "West")
		beam.mesh = cone
		beam.material_override = _beam_material
		beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Lay the cone on its side with its narrow top at the lamp and its wide mouth out along
		# +/-X. Rotating Y about +Z by an angle a gives (-sin a, cos a, 0), so the top points back
		# at the lamp, along -side*X, when sin a = side.
		beam.transform = Transform3D(
			Basis(Vector3.BACK, side * PI * 0.5), Vector3(side * cone.height * 0.5, 0.0, 0.0)
		)
		_beam_pivot.add_child(beam)


func _build_cottage() -> void:
	# The keeper's cottage sits landward of the tower, behind it as seen from the sea.
	var origin := Vector3(-3.5, -0.4, -9.0)
	var walls := PropMaterials.begin()
	PropMaterials.add_box(walls, Vector3(7.5, 4.2, 6.0), origin + Vector3.UP * 2.1)
	PropMaterials.add_box(walls, Vector3(1.2, 2.6, 1.2), origin + Vector3(2.4, 5.8, 1.2))
	PropMaterials.commit(walls, self, "Cottage", PropMaterials.cel(wall_color))

	var roof := PrismMesh.new()
	roof.size = Vector3(8.4, 2.6, 6.8)
	var roof_tool := PropMaterials.begin()
	roof_tool.append_from(roof, 0, Transform3D(Basis.IDENTITY, origin + Vector3.UP * 5.5))
	PropMaterials.commit(roof_tool, self, "CottageRoof", PropMaterials.cel(roof_color))

	var trim := PropMaterials.begin()
	PropMaterials.add_box(trim, Vector3(1.3, 2.4, 0.2), origin + Vector3(0.0, 1.2, 3.02))
	for x in [-2.4, 2.4]:
		PropMaterials.add_box(trim, Vector3(1.1, 1.0, 0.2), origin + Vector3(x, 2.4, 3.02))
	PropMaterials.commit(trim, self, "CottageTrim", PropMaterials.cel(trim_color))

	var windows := PropMaterials.begin()
	for x in [-2.4, 2.4]:
		PropMaterials.add_box(windows, Vector3(0.8, 0.7, 0.12), origin + Vector3(x, 2.4, 3.1))
	PropMaterials.commit(windows, self, "CottageWindows", PropMaterials.glow(lamp_color, 1.2), false)


func _build_colliders() -> void:
	var tower := CollisionShape3D.new()
	tower.name = "TowerCollision"
	var tower_shape := CylinderShape3D.new()
	# As wide as the plinth, not the tower: a narrower collider lets a player walk their feet
	# into the stonework.
	tower_shape.radius = base_radius + 1.5
	tower_shape.height = tower_height + PLINTH_HEIGHT + LANTERN_HEIGHT + 3.0
	tower.shape = tower_shape
	tower.position = Vector3.UP * (tower_shape.height * 0.5 - PLINTH_SINK)
	add_child(tower)

	var cottage := CollisionShape3D.new()
	cottage.name = "CottageCollision"
	var cottage_shape := BoxShape3D.new()
	cottage_shape.size = Vector3(7.5, 6.8, 6.0)
	cottage.shape = cottage_shape
	cottage.position = Vector3(-3.5, 3.0, -9.0)
	add_child(cottage)


func _on_weather_changed(preset: WeatherPreset, _index: int) -> void:
	if preset == null:
		return
	var dullness := inverse_lerp(SUN_ENERGY_BRIGHT, SUN_ENERGY_DULL, preset.light_energy)
	_set_beam_strength(clampf(dullness, 0.0, 1.0))


func _set_beam_strength(strength: float) -> void:
	if _beam_material != null:
		_beam_material.albedo_color.a = lerpf(BEAM_ALPHA_BRIGHT, BEAM_ALPHA_DULL, strength)
	if _lamp_light != null:
		_lamp_light.light_energy = lerpf(1.2, 4.0, strength)
