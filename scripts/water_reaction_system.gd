class_name WaterReactionSystem
extends Node3D

## Energy-driven presentation for entries, exits and hull slams.
##
## Physics produces [WaterImpact] records; this node turns them into pooled spray crowns and
## expanding foam rings. It never applies forces, so it is safe to run on every peer from the
## same authority-authored event. Burst size follows transferred momentum while droplet count
## and speed follow energy, keeping a broad hull distinct from a fast small object.

const DROPLET_SHADER: Shader = preload("res://shaders/spray_droplet.gdshader")
const RING_SHADER: Shader = preload("res://shaders/impact_foam_ring.gdshader")

@export var ocean: Ocean

@export_group("Pool")
@export_range(4, 64, 1) var pool_size: int = 24
@export_range(16, 512, 1) var particles_per_burst: int = 144

@export_group("Response")
@export_range(0.1, 4.0, 0.05) var minimum_lifetime: float = 0.65
@export_range(0.1, 5.0, 0.05) var maximum_lifetime: float = 1.8
@export_range(0.1, 20.0, 0.1) var maximum_launch_speed: float = 12.0
@export_range(0.1, 20.0, 0.1) var maximum_ring_radius: float = 9.0
@export var foam_color: Color = Color(0.97, 0.99, 1.0)
@export var edge_color: Color = Color(0.67, 0.82, 0.90)

var _slots: Array[Dictionary] = []
var _cursor: int = 0


func _ready() -> void:
	if ocean == null:
		push_warning("%s: no ocean assigned; impact reactions are disabled." % name)
		return
	ocean.water_impacted.connect(_on_water_impacted)
	_build_pool()


func _process(delta: float) -> void:
	if ocean == null:
		return
	for slot in _slots:
		if not slot.active:
			continue
		slot.elapsed += delta
		var age: float = slot.elapsed / maxf(slot.lifetime, 0.001)
		if age >= 1.0:
			slot.active = false
			slot.ring.visible = false
			continue
		var origin: Vector2 = slot.origin
		var point := ocean.get_surface_point(origin)
		var normal := ocean.get_water_normal(origin)
		var ring: MeshInstance3D = slot.ring
		ring.global_position = point + normal * 0.06
		ring.global_basis = _basis_from_up(normal).scaled(Vector3.ONE * slot.radius)
		(slot.ring_material as ShaderMaterial).set_shader_parameter(&"age", age)


func _exit_tree() -> void:
	if ocean != null and ocean.water_impacted.is_connected(_on_water_impacted):
		ocean.water_impacted.disconnect(_on_water_impacted)


func _build_pool() -> void:
	for index in pool_size:
		var particles := CPUParticles3D.new()
		particles.name = "ImpactSpray%d" % index
		particles.amount = particles_per_burst
		particles.one_shot = true
		particles.use_fixed_seed = true
		particles.explosiveness = 1.0
		particles.emitting = false
		particles.local_coords = false
		particles.visibility_aabb = AABB(Vector3(-16.0, -8.0, -16.0), Vector3(32.0, 28.0, 32.0))
		particles.mesh = QuadMesh.new()
		var drop_material := ShaderMaterial.new()
		drop_material.shader = DROPLET_SHADER
		drop_material.set_shader_parameter(&"albedo", foam_color)
		drop_material.set_shader_parameter(&"streak_time", 0.035)
		drop_material.set_shader_parameter(&"edge_noise", 0.72)
		drop_material.set_shader_parameter(&"erosion_start", 0.5)
		particles.material_override = drop_material
		add_child(particles)

		var ring := MeshInstance3D.new()
		ring.name = "ImpactRing%d" % index
		var plane := PlaneMesh.new()
		plane.size = Vector2(2.0, 2.0)
		ring.mesh = plane
		ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var ring_material := ShaderMaterial.new()
		ring_material.shader = RING_SHADER
		ring_material.set_shader_parameter(&"foam_color", foam_color)
		ring_material.set_shader_parameter(&"edge_color", edge_color)
		ring.material_override = ring_material
		ring.visible = false
		add_child(ring)

		_slots.append({
			"active": false,
			"elapsed": 0.0,
			"lifetime": 1.0,
			"origin": Vector2.ZERO,
			"radius": 1.0,
			"particles": particles,
			"ring": ring,
			"ring_material": ring_material,
		})


func _on_water_impacted(impact: WaterImpact) -> void:
	if _slots.is_empty() or impact.impact_speed < 0.05:
		return
	var slot := _slots[_cursor]
	_cursor = (_cursor + 1) % _slots.size()

	# Log compression preserves the difference between a hand splash and a hull slam without
	# allowing a large body to consume the whole screen or particle budget.
	var energy_level := clampf(log(1.0 + maxf(impact.energy, 0.0)) / log(1.0 + 250000.0), 0.0, 1.0)
	var impulse_level := clampf(log(1.0 + maxf(impact.impulse, 0.0)) / log(1.0 + 120000.0), 0.0, 1.0)
	var life := lerpf(minimum_lifetime, maximum_lifetime, energy_level)
	var radius := minf(
		maximum_ring_radius,
		maxf(impact.waterline_radius, pow(maxf(impact.volume, 0.001), 1.0 / 3.0))
			* lerpf(1.25, 2.8, impulse_level)
	)

	slot.active = true
	slot.elapsed = 0.0
	slot.lifetime = life
	slot.origin = Vector2(impact.position.x, impact.position.z)
	slot.radius = radius
	var ring: MeshInstance3D = slot.ring
	ring.visible = true
	var ring_material: ShaderMaterial = slot.ring_material
	ring_material.set_shader_parameter(&"age", 0.0)
	ring_material.set_shader_parameter(&"seed", float(posmod(impact.seed, 10000)) / 10000.0)
	ring_material.set_shader_parameter(&"violence", energy_level)

	var particles: CPUParticles3D = slot.particles
	particles.global_position = impact.position + impact.normal * 0.08
	var horizontal := Vector3(impact.relative_velocity.x, 0.0, impact.relative_velocity.z)
	var launch_direction := impact.normal
	if horizontal.length_squared() > 0.001:
		launch_direction = (impact.normal + horizontal.normalized() * 0.38).normalized()
	if impact.kind == Ocean.ImpactKind.EXIT:
		launch_direction = (impact.normal * 0.85 + launch_direction * 0.15).normalized()
	particles.global_basis = _basis_from_up(launch_direction)
	particles.lifetime = life
	particles.direction = Vector3.UP
	particles.spread = lerpf(62.0, 34.0, energy_level)
	particles.gravity = Vector3(0.0, -9.81, 0.0)
	particles.initial_velocity_min = minf(maximum_launch_speed, 0.8 + impact.impact_speed * 0.38)
	particles.initial_velocity_max = minf(maximum_launch_speed, 2.0 + impact.impact_speed * 0.9)
	particles.scale_amount_min = lerpf(0.06, 0.12, energy_level)
	particles.scale_amount_max = lerpf(0.22, 0.7, energy_level)
	particles.randomness = float(posmod(impact.seed, 997)) / 997.0
	particles.seed = posmod(impact.seed, 2147483647)
	particles.emitting = true
	particles.restart()


func _basis_from_up(up: Vector3) -> Basis:
	var unit_up := up.normalized()
	var helper := Vector3.FORWARD if absf(unit_up.dot(Vector3.FORWARD)) < 0.98 else Vector3.RIGHT
	var right := helper.cross(unit_up).normalized()
	var forward := right.cross(unit_up).normalized()
	return Basis(right, unit_up, forward)
