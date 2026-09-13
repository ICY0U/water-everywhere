class_name NetworkPlayer
extends BuoyantBody

## A player: a cube that floats on the ocean, driven by whoever owns it.
##
## Extends [BuoyantBody], so a player is subject to the same water as anything else — it bobs
## on the swell, rolls into a wave face, drifts downwind and carves a Kelvin wake when it moves.
## Thrust is added on top of that rather than replacing it, which is why steering feels like
## driving a boat instead of sliding a marker across a plane.
##
## [b]Authority.[/b] The server owns this node and runs its physics; the client owns only the
## [PlayerInput] child and publishes intent. See [PlayerInput] for why the two are split.
## Non-authority peers receive the resulting transform through a [MultiplayerSynchronizer] and
## do not simulate the body themselves — a client that ran its own buoyancy here would fight
## the incoming transform on every wave.

## How hard a player can push themselves through the water, in newtons per kilogram of hull.
##
## Expressed per unit mass so a heavier player is not automatically slower: the thrust scales
## with the body it has to move.
const THRUST_PER_MASS: float = 14.0

## Ground travel speed in metres per second. Animation matches support-relative motion.
const WALK_SPEED: float = 3.4

## Sprint multiplier, shared with swimming thrust.
const SPRINT_MULTIPLIER: float = 2.4

## Separate acceleration, braking and corner grip keep sprint responsive without instant speed changes.
const GROUND_ACCELERATION: float = 18.0
const GROUND_BRAKING: float = 30.0
const GROUND_TURN_ACCELERATION: float = 28.0
const GROUND_RESPONSE: float = 12.0
const SUPPORT_REACH: float = 0.18

## Vertical thrust per unit mass, for rising and diving.
const VERTICAL_THRUST_PER_MASS: float = 9.0

## How far from the raft's centre a player can be and still climb aboard, in metres.
##
## The hull is 9 by 9.6 m, so this reaches a couple of metres past the gunwale: far enough to
## get back on after a wave washes you off, not far enough to cross open water.
const BOARD_RANGE: float = 9.0

## How far above the body's origin the support probe starts, in metres.
##
## The probe casts DOWN from the body origin, so it only works if that origin is above the
## surface being stood on. It is not: the player's collision shape sits a little above the
## origin, so when the feet rest on the ground the origin is under it, and a downward ray from
## there has already passed through the surface. Measured at 0.084 m of offset plus 0.020 m of
## ordinary contact penetration.
##
## This must therefore exceed that penetration, and stay below knee height so a step up is not
## mistaken for the ground. With the collider's bottom on the origin the origin sits exactly at
## the contact surface, so the probe only has to clear how far the solver lets a resting body
## settle: about 0.02 m measured, against Jolt's 0.04 m default margin, which an impact can
## briefly exceed. 0.1 m covers that with room to spare and is still ankle height on this
## character.
const SUPPORT_PROBE_LIFT: float = 0.1

## Lowest dot product between a surface normal and up that still counts as standing on it.
##
## Shared by deck movement and boarding so that both agree on what "aboard" means.
const SUPPORT_NORMAL_MINIMUM: float = 0.65

## What the player is currently doing with the world beneath it.
##
## These three cases already existed, scattered through [method _apply_thrust] as early returns.
## Naming them is what lets the physics and the presentation agree: the stance is decided once a
## frame, on the server, and both the forces and the animation read that same answer. A state
## that only drove the animation could quietly disagree with the body — a character playing a
## swim while being pushed as though it were walking.
enum Stance {
	## Standing on something solid enough to walk on: ground, or a raft's deck.
	GROUNDED,
	## In the water, under its own buoyancy.
	FLOATING,
	## Neither — falling, or thrown clear by a wave.
	AIRBORNE,
}

## Submersion at which a player that was not floating starts.
##
## See [member stance] for why this is not the same number as the one it stops at.
const FLOAT_ENTER_SUBMERSION: float = 0.3

## Submersion at which a player that was floating stops.
const FLOAT_EXIT_SUBMERSION: float = 0.08

## Seconds a player must stay clear of the water before they stop floating.
##
## A submersion threshold alone cannot decide this, at any pair of values. A player floating at
## rest in the default sea sweeps between 0.045 and 0.951 submerged as the waves pass — measured
## over twelve seconds — so the troughs reach values indistinguishable from being out of the
## water altogether, and any exit threshold low enough to sit under them is also low enough to be
## meaningless. What separates a passing trough from actually climbing out is how LONG it lasts:
## the longest unbroken dip below the exit threshold measured 0.35 s. This is set well clear of
## that, so a wave cannot end the state but leaving the water promptly does.
##
## It delays only the exit to AIRBORNE. Climbing onto a raft is detected as support and takes
## effect on the same frame, because support is tested before the water is.
const FLOAT_EXIT_GRACE: float = 1.0

## Peer id that controls this player.
##
## Setting it hands input authority to that peer while the body itself stays with the server.
## Exported so [MultiplayerSpawner] carries it in the spawn state, which is what makes the
## assignment survive a client joining midway through.
@export var owner_peer_id: int = 1:
	set(value):
		owner_peer_id = value
		_apply_input_authority()

## Name shown above the cube.
@export var player_name: String = "":
	set(value):
		player_name = value
		_apply_name_tag()

## Colour of this player's cube, so the two windows are told apart at a glance.
@export var player_color: Color = Color(0.886, 0.353, 0.263):
	set(value):
		player_color = value
		_apply_color()

## Whether the upright servo keeps a supported player standing.
##
## Off, nothing rights the body: it topples under its own walking force, which is the raw
## behaviour a balance servo exists to hide. Worth seeing when tuning how a walk feels.
@export var balance_enabled: bool = true

## Diagnostic switch for the old off-centre thrust. Keep off for normal locomotion:
## pushing below the centre of mass creates a large pitch/roll torque on every sharp turn.
@export var foot_force_enabled: bool = false

## Whether a player can walk on a supporting surface at all.
##
## Off, deck movement never engages and a player on land cannot move: thrust only applies in
## water. The bluntest switch, for isolating the walk from everything else.
@export var deck_movement_enabled: bool = true

@onready var _input: PlayerInput = $PlayerInput
@onready var _name_tag: Label3D = $NameTag
# Both are optional: a player is either the placeholder cube ("Mesh") or the skinned character
# ("Visual"), never both, and the scene decides which. Looked up rather than asserted so either
# scene can be spawned without this script caring which one it got.
@onready var _mesh: MeshInstance3D = get_node_or_null("Mesh") as MeshInstance3D
@onready var _visual: CharacterVisual = get_node_or_null("Visual") as CharacterVisual

## Value of [member PlayerInput.board_requests] the server has already acted on.
var _boards_served: int = 0

## Unbroken seconds a floating player has spent clear of the water: see
## [constant FLOAT_EXIT_GRACE].
var _dry_seconds: float = 0.0

## What the player is doing with the world beneath it: see [enum Stance].
##
## [b]Decided by the server and replicated[/b], rather than worked out by each peer. It has to
## be, because the number it is derived from does not exist anywhere else:
## [method BuoyantBody.submersion] is only ever assigned inside
## [method BuoyantBody._physics_process], which this class skips entirely for non-authority
## peers, so on every peer but the server a remote player's submersion reads 0.0 forever. Asking
## a client to decide from that gives a swimmer who walks on everyone else's screen.
##
## [b]It has hysteresis[/b]: a player starts floating at [constant FLOAT_ENTER_SUBMERSION] and
## stops at the lower [constant FLOAT_EXIT_SUBMERSION]. A single threshold sits inside the range
## that passing wave crests sweep a floating body through, so the stance would change several
## times a second and the animation would strobe between swimming and standing. The gap is what
## makes the state describe what the player is doing rather than which part of a wave is
## currently going past.
var stance: Stance = Stance.AIRBORNE

## Authoritative motion across the supporting surface, streamed for remote animation.
var ground_velocity: Vector3 = Vector3.ZERO
var _support_hit: Dictionary = {}


func _ready() -> void:
	super()
	# Remote bodies are presentation proxies; Jolt must not integrate gravity between updates.
	freeze = not is_multiplayer_authority()
	# The visual derives its clip and facing from this body's replicated motion, so it needs the
	# body itself rather than any input: a remote player has no input here to read.
	if _visual != null:
		_visual.body = self
		_visual.input = _input
	_apply_input_authority()
	_apply_name_tag()
	_apply_color()


func _physics_process(delta: float) -> void:
	# Only the server simulates. A client applying buoyancy locally would immediately disagree
	# with the transform arriving from the server, and the body would judder between the two
	# answers on every wave — the classic symptom of two peers both thinking they are right.
	if not is_multiplayer_authority():
		_report_remote_visual_contact()
		return

	super(delta)
	# Before the forces, so the stance the thrust acts on is this frame's rather than last
	# frame's, and after super(), which is what refreshes the submersion it reads.
	_support_hit = _deck_support()
	_update_stance(delta)
	_apply_boarding()
	_apply_thrust()


## Decides what the player is doing with the world beneath it, for this frame.
##
## Support wins over water: a player standing on a raft's deck with a crest washing over them is
## still standing, which is both what it looks like and what the forces should do.
func _update_stance(delta: float) -> void:
	if not _support_hit.is_empty():
		stance = Stance.GROUNDED
		_dry_seconds = 0.0
		return

	ground_velocity = Vector3.ZERO
	var wet := submersion()
	if stance != Stance.FLOATING:
		_dry_seconds = 0.0
		stance = Stance.FLOATING if wet >= FLOAT_ENTER_SUBMERSION else Stance.AIRBORNE
		return

	# Already floating, so leaving takes both a low submersion AND time at it — see
	# [constant FLOAT_EXIT_GRACE]. The timer resets on any frame the player is back in the water,
	# so only an unbroken stretch out of it counts.
	_dry_seconds = 0.0 if wet > FLOAT_EXIT_SUBMERSION else _dry_seconds + delta
	if _dry_seconds > FLOAT_EXIT_GRACE:
		stance = Stance.AIRBORNE


## Reconstructs the continuous water contact from replicated transform and velocity.
##
## Remote peers must not run buoyancy, but wakes and foam are presentation derived from the
## authoritative body state. Reporting this cheap approximation gives every peer the same
## visible interaction without allowing a client to apply a single physics force.
func _report_remote_visual_contact() -> void:
	if ocean == null:
		return
	if _hull == null or not _hull.is_valid():
		return
	var water_height := ocean.get_water_height(Vector2(global_position.x, global_position.z))
	var half_height := maxf(_hull.bounds.size.y * 0.5, 0.001)
	var bottom := global_position.y - half_height
	var visual_submersion := clampf((water_height - bottom) / (half_height * 2.0), 0.0, 1.0)
	if visual_submersion <= 0.0:
		return
	var waterline := Vector3(global_position.x, water_height, global_position.z)
	var flow := ocean.get_water_velocity(Vector2(global_position.x, global_position.z))
	var radius := _hull.waterline_radius * contact_radius_scale
	ocean.report_contact(
		self, waterline, radius, linear_velocity, linear_velocity - flow, visual_submersion
	)


## Returns the input node, for a camera that wants to follow where the player is looking.
func input_node() -> PlayerInput:
	return _input


## Pushes the body along whatever its owner is asking for.
##
## Applied as a force rather than by setting velocity, so the water still has its say: a player
## driving into a steep wave face climbs it slowly, and one running downwind is carried along.
## Setting velocity directly would override buoyancy and make the sea decorative.
func _apply_thrust() -> void:
	if _input == null:
		return
	# Both branches read the stance decided this frame rather than re-deriving their own answer,
	# so the forces and the animation can never disagree about what the player is doing.
	if stance == Stance.GROUNDED and _apply_deck_movement():
		return
	if stance != Stance.FLOATING:
		return

	var direction := _input.world_direction()
	var thrust := direction * THRUST_PER_MASS * mass
	if _input.wants_sprint:
		thrust *= SPRINT_MULTIPLIER

	var lift := 0.0
	if _input.wants_up:
		lift += VERTICAL_THRUST_PER_MASS
	if _input.wants_down:
		lift -= VERTICAL_THRUST_PER_MASS
	thrust.y += lift * mass

	if thrust.length_squared() > 0.0:
		# Applied centrally: a player pushing themselves along should not also be torqued by
		# their own engine. The waves supply all the rolling this needs.
		apply_central_force(thrust)


## Ground movement is relative to the supporting body, so a drifting raft carries an idle
## player. The opposite force pushes back on the raft rather than creating free momentum.
func _apply_deck_movement() -> bool:
	if not deck_movement_enabled:
		return false
	var hit := _support_hit
	if hit.is_empty():
		return false
	var normal: Vector3 = hit.normal
	var support := hit.collider as RigidBody3D
	var support_velocity := Vector3.ZERO
	if support != null:
		var support_state := PhysicsServer3D.body_get_direct_state(support.get_rid())
		var centre := support.global_position
		if support_state != null:
			centre = support_state.center_of_mass + support.global_position
		var lever: Vector3 = hit.position - centre
		support_velocity = support.linear_velocity + support.angular_velocity.cross(lever)
	var direction := _input.world_direction()
	var speed := WALK_SPEED * (SPRINT_MULTIPLIER if _input.wants_sprint else 1.0)
	# Normalise after projection: slopes should not silently shorten an analog input.
	var desired := direction.slide(normal).normalized() * direction.length() * speed
	ground_velocity = (linear_velocity - support_velocity).slide(normal)
	var acceleration := GROUND_ACCELERATION
	if direction.is_zero_approx() or ground_velocity.length() > desired.length() + 0.1:
		acceleration = GROUND_BRAKING
	elif ground_velocity.normalized().dot(desired.normalized()) < 0.5:
		acceleration = GROUND_TURN_ACCELERATION
	var correction := (desired - ground_velocity) * GROUND_RESPONSE
	# Counter downhill gravity as part of the traction force, including at rest.
	var gravity_along_ground := (Vector3.DOWN * _gravity).slide(normal)
	var force := (correction.limit_length(acceleration) - gravity_along_ground) * mass
	# Central traction avoids the foot-level lever that caused 45-degree sprint tipping.
	if foot_force_enabled:
		apply_force(force, hit.position - global_position)
	else:
		apply_central_force(force)
	# A supported player balances on the deck; in water the existing free roll still applies.
	#
	# Scaled by rotational inertia rather than by mass. Torque turns a body against its inertia,
	# and inertia grows with mass AND with the square of size, so a coefficient tuned per-unit-
	# mass silently weakens as a body gets bigger: at 2.5x scale the inertia is 6.25x larger
	# relative to the same torque, and a walking player tips over instead of staying upright.
	# Multiplying by the real inertia makes the response the same at any size.
	var inertia := _upright_inertia()
	var balance := (
		global_basis.y.cross(Vector3.UP) * 90.0 - angular_velocity * 18.0
	) * inertia
	if balance_enabled:
		apply_torque(balance)
	if support != null:
		support.apply_force(-force, hit.position - support.global_position)
		if balance_enabled:
			support.apply_torque(-balance)
	return true


## Returns the body's rotational inertia about a horizontal axis, in kg*m^2.
##
## Taken from the hull's own bounds rather than from Jolt, whose inertia tensor is not exposed
## to script, and approximated as a solid box — close enough for a servo whose job is to keep a
## body upright rather than to model its exact dynamics.
func _upright_inertia() -> float:
	if _hull == null or not _hull.is_valid():
		return mass
	var size := _hull.bounds.size
	return mass * (size.y * size.y + size.z * size.z) / 12.0


## Returns what the player is standing on, or an empty dictionary when it is standing on nothing.
##
## A surface too steep to stand on counts as nothing, so a player pressed against the side of a
## hull is not treated as being on top of it.
func _deck_support() -> Dictionary:
	if _hull == null or not _hull.is_valid():
		return {}
	# Probe the actual bottom footprint, not a hard-coded metre below the body origin.
	# Corners keep contact on slopes and deck edges where the centre ray misses the floor.
	var bounds := _hull.bounds
	var centre := bounds.get_center()
	var half := bounds.size * 0.5
	var best: Dictionary = {}
	for offset in [Vector2.ZERO, Vector2(-1, -1), Vector2(-1, 1),
		Vector2(1, -1), Vector2(1, 1)]:
		var foot := global_transform * Vector3(centre.x + offset.x * half.x * 0.95,
			bounds.position.y, centre.z + offset.y * half.z * 0.95)
		var start := foot + Vector3.UP * SUPPORT_PROBE_LIFT
		var query := PhysicsRayQueryParameters3D.create(start,
			foot + Vector3.DOWN * SUPPORT_REACH, 1, [get_rid()])
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty() or hit.normal.dot(Vector3.UP) < SUPPORT_NORMAL_MINIMUM:
			continue
		if best.is_empty() or hit.position.y > best.position.y:
			best = hit
	return best


## Climbs onto the raft when this player's owner asks to, and the request is allowed.
##
## Server-side by construction. The client only publishes a count through
## [member PlayerInput.board_requests], exactly as it publishes its movement keys, and every
## condition is tested here — a client asking from across the ocean, or while already standing on
## the deck, moves nothing. Each increment is consumed whether or not it boarded, so a refused
## request does not sit waiting to fire the moment the player happens to drift into range.
func _apply_boarding() -> void:
	if _input == null or _input.board_requests <= _boards_served:
		return
	_boards_served = _input.board_requests

	var raft := _nearest_raft()
	if raft == null:
		return
	# Horizontal distance only: someone treading water sits below the deck and someone thrown off
	# a crest may be well above it, and both should be able to get back on.
	var offset := raft.global_position - global_position
	if Vector2(offset.x, offset.z).length() > BOARD_RANGE:
		return
	if _deck_support().get("collider") == raft:
		return
	var players := get_parent() as Node3D
	if players == null:
		return

	# The slot the spawner would choose, so boarding lands clear of the other players and on the
	# deck as it is tilted at this moment. Arrive upright, keeping only the facing, and travelling
	# with the hull, so the raft moving underneath does not throw the player straight back off.
	var yaw := global_rotation.y
	global_transform = Transform3D(
		Basis.from_euler(Vector3(0.0, yaw, 0.0)), raft.spawn_position(players)
	)
	linear_velocity = raft.linear_velocity
	angular_velocity = Vector3.ZERO


## Returns the nearest [Raft], or null when the scene has none.
##
## Found through the [code]water_subjects[/code] group rather than an exported reference: players
## are spawned from [code]player.tscn[/code] by [MultiplayerSpawner], so there is no scene in
## which a raft could be wired into this node.
func _nearest_raft() -> Raft:
	var nearest: Raft = null
	var nearest_distance := INF
	for node: Node in get_tree().get_nodes_in_group(&"water_subjects"):
		var raft := node as Raft
		if raft == null:
			continue
		var distance := global_position.distance_squared_to(raft.global_position)
		if distance < nearest_distance:
			nearest = raft
			nearest_distance = distance
	return nearest


## Gives the owning client authority over the input node, and nothing else.
func _apply_input_authority() -> void:
	# Resolve before @onready so input replication enters the tree with its owner.
	var input := get_node_or_null("PlayerInput") as PlayerInput
	if input == null:
		return
	input.set_multiplayer_authority(owner_peer_id)


func _apply_name_tag() -> void:
	if _name_tag == null:
		return
	_name_tag.text = player_name


func _apply_color() -> void:
	if _visual != null:
		# The character tints only its raincoat; see [method CharacterVisual.tint].
		_visual.tint(player_color)
		return
	if _mesh == null:
		return
	var material := _mesh.get_active_material(0) as ShaderMaterial
	if material == null:
		return
	# Duplicated per player, or every cube in the scene shares one material and they all take
	# the colour of whichever was set last.
	if _mesh.material_override == null or not _mesh.material_override.resource_local_to_scene:
		var unique := material.duplicate() as ShaderMaterial
		unique.resource_local_to_scene = true
		_mesh.material_override = unique
	var target := _mesh.material_override as ShaderMaterial
	if target != null:
		target.set_shader_parameter(&"albedo_color", player_color)
