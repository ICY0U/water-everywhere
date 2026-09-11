class_name BuoyantBody
extends RigidBody3D

## A rigid body that floats on the ocean with real marine hydrodynamics.
##
## The forces here are the Morison formulation used for offshore structures: buoyancy from
## the genuinely submerged volume, added mass, quadratic drag against the water's own motion,
## and depth-attenuated wave forcing. Each exists because leaving it out produces a specific,
## recognisable wrongness.
##
## [b]Buoyancy is integrated, not approximated.[/b] The hull is clipped against the water
## plane every physics frame and the submerged polyhedron is integrated exactly — see
## [HullGeometry]. That gives both the displaced volume and the centre it acts at, so a body
## gets a righting moment from its real shape: a barge is stiff, a log rolls, a sphere has no
## preferred attitude at all. Sampling a grid of probes and ramping each by depth cannot do
## this, because it describes a box no matter what the collider actually is.
##
## [b]Added mass is why water feels heavy.[/b] A body accelerating in water must accelerate
## the water around it too, and for a submerged sphere that added mass is half the displaced
## fluid mass again. Without the term a hull is far too eager in heave — it springs up and
## down like a cork on a spring, and no amount of drag tuning fixes it, because drag opposes
## velocity while this opposes acceleration. It is the single biggest contributor to water
## feeling weighty rather than bouncy.
##
## [b]Drag is quadratic.[/b] Real hydrodynamic drag goes as the square of speed, which is
## what gives a falling body a terminal velocity and stops an entry from driving straight
## through the surface. A purely linear damper has no such limit.
##
## [b]Wave forcing decays with depth.[/b] Dynamic pressure under a deep-water wave falls off
## as [code]e^(-k*z)[/code], reaching about 5% of its surface value half a wavelength down.
## Applying the surface's full orbital velocity to a deeply submerged body would have a
## submarine shoved about as hard as a raft.
##
## Bodies report themselves to the ocean each frame, which is what dents the surface, churns
## foam and raises the impact events that spray effects listen for.
##
## @tutorial(Archimedes' principle): https://en.wikipedia.org/wiki/Archimedes%27_principle
## @tutorial(Morison equation): https://en.wikipedia.org/wiki/Morison_equation

## Density of sea water, in kilograms per cubic metre.
const WATER_DENSITY: float = 1025.0

## Added-mass coefficient in heave, as a fraction of the displaced fluid mass.
##
## Potential flow gives exactly 0.5 for a sphere, and it is the standard first estimate for
## a compact hull. Vertical motion is resisted far more than horizontal, because a body
## heaving has to push a column of water out of its way.
const HEAVE_ADDED_MASS: float = 0.5

## Added-mass coefficient in surge and sway, as a fraction of the displaced fluid mass.
##
## Lower than heave: a hull moving horizontally sheds water around its sides rather than
## lifting it.
const HORIZONTAL_ADDED_MASS: float = 0.25

## Closing speed above which a contact is reported as a slam, in metres per second.
##
## See [signal Ocean.water_impacted]. A slam is a genuine re-entry, so the body must also
## have been moving slowly recently — sustained fast travel through water is not a slam.
const SLAM_SPEED_THRESHOLD: float = 3.0

## Speed below which a body counts as calm for the purpose of arming a slam.
const SLAM_ARM_SPEED: float = 1.0

## Seconds a body stays armed for a slam after being calm.
const SLAM_ARM_WINDOW: float = 0.25

## Ceiling on the added-mass force, in multiples of the body's own weight in water.
##
## Added mass is proportional to acceleration, which makes it a stiff feedback path: one
## outsized step — a frame hitch, or the discontinuity at the moment of entry — would
## otherwise inject an impulse with no physical counterpart and launch the body.
const MAX_ADDED_MASS_GRAVITIES: float = 4.0

## Acceleration below which the added-mass term is ignored, in metres per second squared.
##
## A body at rest is never exactly at rest: the solver leaves a little velocity jitter every
## step, and differentiating that produces a small acceleration whose sign does not average
## out. Added mass then acts as a steady force on a body that is not accelerating at all,
## which shifts where it floats — a settled hull sat 67 mm off its Archimedean draught until
## this deadband was added. Real added mass has no such effect: at rest there is nothing
## being entrained.
const ADDED_MASS_DEADBAND: float = 0.05

## Ocean this body floats on. Without one it behaves as an ordinary rigid body.
@export var ocean: Ocean

@export_group("Hull")

## Density of the body, in kilograms per cubic metre; zero keeps [member RigidBody3D.mass].
##
## This decides how deep the body floats: it settles where the water it displaces weighs what
## it does, so a body at half the density of water sits half submerged. Sea water is about
## 1025, seasoned oak about 750, closed-cell foam about 100.
@export_range(0.0, 4000.0, 1.0) var body_density: float = 380.0

## Largest number of triangles the clipped hull is allowed to carry.
##
## The collision shape's debug mesh can run to thousands of triangles for a sphere or
## capsule, which is far more than the forces are worth. Lowering this is the main
## performance dial; raising it sharpens the draught of an intricate hull.
@export_range(12, 512, 4) var hull_detail: int = 128

@export_group("Hydrodynamics")

## Quadratic drag coefficient, dimensionless.
##
## Roughly 0.8–1.2 for a bluff body such as a box, 0.1–0.3 for a faired hull. This multiplies
## the standard [code]0.5 * rho * Cd * A * v^2[/code], with the reference area taken from the
## hull's real silhouette facing the flow.
@export_range(0.0, 3.0, 0.01) var drag_coefficient: float = 0.9

## Linear damping rate applied alongside quadratic drag, in reciprocal seconds.
##
## Quadratic drag vanishes at low speed, which leaves a body drifting forever on a calm sea.
## A small linear term is what actually brings it to rest, and it is also what keeps the
## solver stable when the body is nearly still.
@export_range(0.0, 10.0, 0.05) var linear_damping_rate: float = 0.6

## Resistance to rotation, as a rate in reciprocal seconds.
##
## The shape-dependent righting moment already opposes roll and pitch. This adds the yaw
## damping that a symmetric hull cannot produce for itself.
@export_range(0.0, 20.0, 0.1) var angular_drag: float = 2.4

## How much of the water's own motion the body is carried by, from 0 to 1.
##
## 1.0 is physical. Lower it to keep a body roughly on station in a heavy sea.
@export_range(0.0, 1.0, 0.01) var flow_influence: float = 1.0

## Whether wave forcing is attenuated with depth, as real dynamic pressure is.
##
## Physically correct and normally wanted. Switching it off makes deep bodies feel the full
## surface orbital motion, which is useful only for exaggerated or shallow-water looks.
@export var depth_attenuation: bool = true

@export_group("Water Contact")

## Whether to report this body to the ocean so it dents the surface and makes foam.
@export var reports_contact: bool = true

## Multiplier on the radius reported to the ocean, over the hull's own footprint.
##
## Above 1 spreads the wake and its foam wider than the hull itself, which is roughly what a
## real disturbed waterline looks like.
@export_range(0.5, 4.0, 0.05) var contact_radius_scale: float = 1.25

var _hull: HullGeometry
var _gravity: float = 9.8
var _submersion: float = 0.0
var _submerged_volume: float = 0.0
var _was_touching_water: bool = false
var _calm_timer: float = 0.0
## Body velocity from the previous physics step, for the added-mass acceleration term.
var _previous_velocity: Vector3 = Vector3.ZERO


func _ready() -> void:
	_hull = HullGeometry.from_body(self, hull_detail)
	if not _hull.is_valid():
		push_warning("%s: no usable collision hull; the body will not float." % name)
	elif body_density > 0.0:
		mass = maxf(body_density * _hull.volume, 0.001)

	_gravity = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8) * gravity_scale
	if ocean == null:
		push_warning("%s: no ocean assigned; the body will not float." % name)


func _physics_process(delta: float) -> void:
	if ocean == null or _hull == null or not _hull.is_valid():
		return

	var surface := _local_water_plane()
	var clipped := _hull.clip_below_plane(surface[0], surface[1])
	_submerged_volume = clipped["volume"]
	_submersion = clampf(_submerged_volume / _hull.volume, 0.0, 1.0)

	var touching := _submerged_volume > 0.0
	_track_impacts(touching, surface, delta)
	_was_touching_water = touching

	if not touching:
		# Out of the water the added-mass history is meaningless, and carrying it across a
		# flight would apply a stale acceleration on re-entry.
		_previous_velocity = linear_velocity
		return

	var centroid_local: Vector3 = clipped["centroid"]
	var centroid_world := global_transform * centroid_local
	# apply_force takes an offset from the body ORIGIN in global axes, and torques it about
	# the centre of mass — verified against Jolt rather than assumed.
	var lever := centroid_world - global_position

	_apply_buoyancy(lever)
	_apply_hydrodynamics(centroid_world, lever, delta)
	_apply_rotational_drag()
	_previous_velocity = linear_velocity

	if reports_contact:
		_report_contact(centroid_world)


## Returns the hull's volume, in cubic metres.
func hull_volume() -> float:
	return _hull.volume if _hull != null else 0.0


## Returns how much of the hull was under water on the last physics frame, from 0 to 1.
func submersion() -> float:
	return _submersion


## Returns the volume of water the hull is displacing, in cubic metres.
func displaced_volume() -> float:
	return _submerged_volume


## Returns the hull, for tools that need to inspect the geometry buoyancy is solved against.
func hull() -> HullGeometry:
	return _hull


## Returns the water plane under the body, in the hull's own space, as
## [code][point, normal][/code].
##
## The ocean surface is not flat, but over the footprint of one hull a plane through the
## surface point, tilted to the surface normal, is a close fit — and it is what makes the
## clip a single plane cut rather than a general curved-surface intersection. Sampling the
## normal as well as the height is what lets a body sit ALONG a wave face instead of level
## with the horizon.
func _local_water_plane() -> Array:
	var here := Vector2(global_position.x, global_position.z)
	var height := ocean.get_water_height(here)
	var normal := ocean.get_water_normal(here)

	var to_local := global_transform.affine_inverse()
	var point_local := to_local * Vector3(global_position.x, height, global_position.z)
	var normal_local := (to_local.basis * normal).normalized()
	return [point_local, normal_local]


## Applies Archimedes' upthrust at the centre of the displaced volume.
##
## Acting at the centroid rather than at the body's centre is the whole source of the
## righting moment: when a hull heels, the submerged shape becomes lopsided, its centroid
## shifts to the low side, and the resulting couple rights the body.
func _apply_buoyancy(lever: Vector3) -> void:
	var displaced_mass := WATER_DENSITY * _submerged_volume
	apply_force(Vector3.UP * displaced_mass * _gravity, lever)


## Applies added mass, quadratic drag and wave forcing at the centre of buoyancy.
func _apply_hydrodynamics(centroid_world: Vector3, lever: Vector3, delta: float) -> void:
	var here := Vector2(centroid_world.x, centroid_world.z)
	var flow := ocean.get_water_velocity(here) * flow_influence * _wave_attenuation(centroid_world)
	var point_velocity := linear_velocity + angular_velocity.cross(lever)
	var relative := point_velocity - flow

	var displaced_mass := WATER_DENSITY * _submerged_volume

	# --- quadratic drag: 0.5 * rho * Cd * A * v^2, opposing relative motion ---
	var speed := relative.length()
	if speed > 0.0001:
		var direction := relative / speed
		var area := _hull.projected_area(direction) * _submersion
		var drag := -direction * 0.5 * WATER_DENSITY * drag_coefficient * area * speed * speed
		# A drag impulse larger than the momentum it opposes would reverse the body, so the
		# force is capped at whatever exactly arrests it this step. This is what keeps the
		# stiff spring of buoyancy-plus-drag stable for small dense bodies instead of
		# diverging.
		var maximum := (mass + displaced_mass * HEAVE_ADDED_MASS) * speed / maxf(delta, 0.0001)
		if drag.length() > maximum:
			drag = drag.normalized() * maximum
		apply_force(drag, lever)

	# --- linear damping: what actually brings a body to rest on a calm sea ---
	apply_force(-relative * linear_damping_rate * displaced_mass, lever)

	# --- added mass: resistance to ACCELERATION, not to velocity ---
	#
	# A body accelerating through water has to accelerate the water around it as well, and
	# that entrained mass is a fixed fraction of the water it displaces — half of it in heave
	# for a sphere, by potential flow. This is what makes water feel HEAVY: drag opposes
	# velocity and vanishes at the top of a bob, while this opposes acceleration and is
	# strongest exactly there.
	#
	# Three details keep it stable, each of which caused a real failure when missing:
	#
	# * It is measured from the body's own velocity, not from the velocity at the buoyancy
	#   centroid. The centroid jumps as the clip changes — for a shallow raft it can move most
	#   of the hull height in one step — and differentiating a jumping sample produces an
	#   acceleration that is an artefact of the geometry rather than of any real motion. That
	#   threw a raft over a kilometre into the air.
	# * It is applied CENTRALLY. Entrained water resists the body as a whole; applying it at
	#   the centroid's lever arm would add a torque that potential flow does not predict.
	# * It is capped. A term proportional to acceleration is a stiff feedback path, and a
	#   single large step — a frame hitch, or the moment of entry — would otherwise inject an
	#   impulse far beyond anything physical.
	var body_acceleration := (linear_velocity - _previous_velocity) / maxf(delta, 0.0001)
	if body_acceleration.length() > ADDED_MASS_DEADBAND:
		var entrained := Vector3(
			body_acceleration.x * displaced_mass * HORIZONTAL_ADDED_MASS,
			body_acceleration.y * displaced_mass * HEAVE_ADDED_MASS,
			body_acceleration.z * displaced_mass * HORIZONTAL_ADDED_MASS,
		)
		# The entrained mass can never resist harder than the body's own weight scale; beyond
		# that it is numerical, not physical.
		var entrained_limit := (mass + displaced_mass) * _gravity * MAX_ADDED_MASS_GRAVITIES
		if entrained.length() > entrained_limit:
			entrained = entrained.normalized() * entrained_limit
		apply_central_force(-entrained)


## Damps rotation, scaled by how much of the hull is actually in the water.
func _apply_rotational_drag() -> void:
	var extents := _hull.bounds.size
	# Torque needs a moment of inertia to act on, or angular_drag would not be a rate. A solid
	# box about its centre is close enough for water that is only being damped.
	var rotational_inertia := mass * extents.length_squared() / 12.0
	apply_torque(-angular_velocity * angular_drag * rotational_inertia * _submersion)


## Returns how strongly wave motion reaches [param point], from 0 to 1.
##
## Dynamic pressure under a deep-water wave decays as [code]e^(-k*z)[/code] with depth, so a
## body well below the surface is barely driven by the waves above it. The dominant octave
## sets the decay rate, since it carries most of the energy.
func _wave_attenuation(point: Vector3) -> float:
	if not depth_attenuation or ocean.wave_field == null:
		return 1.0

	var surface_height := ocean.get_water_height(Vector2(point.x, point.z))
	var depth := maxf(surface_height - point.y, 0.0)
	var wavelength := maxf(ocean.wave_field.peak_wavelength(), 0.0001)
	return exp(-TAU / wavelength * depth)


## Raises entry, exit and slam events, and keeps the slam arming window.
func _track_impacts(touching: bool, surface: Array, delta: float) -> void:
	var here := Vector2(global_position.x, global_position.z)
	var normal := ocean.get_water_normal(here)
	var flow := ocean.get_water_velocity(here)
	var relative := linear_velocity - flow
	var closing := -relative.dot(normal)

	# A slam is only a slam if the body was recently calm; otherwise a hull under way would
	# slam continuously.
	if relative.length() < SLAM_ARM_SPEED:
		_calm_timer = SLAM_ARM_WINDOW
	else:
		_calm_timer = maxf(_calm_timer - delta, 0.0)

	if touching == _was_touching_water:
		if touching and closing > SLAM_SPEED_THRESHOLD and _calm_timer > 0.0:
			_calm_timer = 0.0
			_emit_impact(Ocean.ImpactKind.SLAM, normal, closing, relative)
		return

	if touching:
		_emit_impact(Ocean.ImpactKind.ENTRY, normal, maxf(closing, 0.0), relative)
	else:
		_emit_impact(Ocean.ImpactKind.EXIT, normal, maxf(-closing, 0.0), relative)


func _emit_impact(
	kind: Ocean.ImpactKind, normal: Vector3, speed: float, relative: Vector3
) -> void:
	var here := Vector2(global_position.x, global_position.z)
	var impact := WaterImpact.new()
	impact.position = Vector3(global_position.x, ocean.get_water_height(here), global_position.z)
	impact.normal = normal
	impact.impact_speed = speed
	impact.relative_velocity = relative
	impact.waterline_radius = _hull.waterline_radius * contact_radius_scale
	# What the event actually disturbs: the volume swept through the surface for an entry or
	# exit, and the volume already immersed for a slam.
	impact.volume = maxf(_submerged_volume, _hull.volume * 0.05)
	# The accelerated water mass is the displaced volume, not the body's dry mass. This keeps
	# a hollow hull visually heavy without making a dense pebble produce a ship-sized splash.
	var disturbed_mass := WATER_DENSITY * impact.volume
	impact.impulse = disturbed_mass * speed
	impact.energy = 0.5 * disturbed_mass * speed * speed
	impact.kind = kind
	impact.source = self
	ocean.report_impact(impact)


func _report_contact(centroid_world: Vector3) -> void:
	var here := Vector2(global_position.x, global_position.z)
	var waterline := Vector3(global_position.x, ocean.get_water_height(here), global_position.z)
	var flow := ocean.get_water_velocity(here)
	ocean.report_contact(
		self,
		waterline,
		_hull.waterline_radius * contact_radius_scale,
		linear_velocity,
		linear_velocity - flow,
		_submersion,
	)
