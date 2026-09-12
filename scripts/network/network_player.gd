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

## Multiplier on thrust while sprinting.
const SPRINT_MULTIPLIER: float = 2.4

## Vertical thrust per unit mass, for rising and diving.
const VERTICAL_THRUST_PER_MASS: float = 9.0

## How far from the raft's centre a player can be and still climb aboard, in metres.
##
## The hull is 9 by 9.6 m, so this reaches a couple of metres past the gunwale: far enough to
## get back on after a wave washes you off, not far enough to cross open water.
const BOARD_RANGE: float = 9.0

## Lowest dot product between a surface normal and up that still counts as standing on it.
##
## Shared by deck movement and boarding so that both agree on what "aboard" means.
const SUPPORT_NORMAL_MINIMUM: float = 0.65

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

@onready var _input: PlayerInput = $PlayerInput
@onready var _name_tag: Label3D = $NameTag
@onready var _mesh: MeshInstance3D = $Mesh

## Value of [member PlayerInput.board_requests] the server has already acted on.
var _boards_served: int = 0


func _ready() -> void:
	super()
	# Remote bodies are presentation proxies; Jolt must not integrate gravity between updates.
	freeze = not is_multiplayer_authority()
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
	_apply_boarding()
	_apply_thrust()


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
	if _apply_deck_movement():
		return
	if submersion() <= 0.0:
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
	var hit := _deck_support()
	if hit.is_empty():
		return false
	var normal: Vector3 = hit.normal
	var support := hit.collider as RigidBody3D
	var support_velocity := Vector3.ZERO
	if support != null:
		var lever: Vector3 = hit.position - support.global_transform * support.center_of_mass
		support_velocity = support.linear_velocity + support.angular_velocity.cross(lever)
	var speed := 4.0 * (SPRINT_MULTIPLIER if _input.wants_sprint else 1.0)
	var desired := _input.world_direction().slide(normal) * speed
	var relative := (linear_velocity - support_velocity).slide(normal)
	var force := ((desired - relative) * 6.0).limit_length(20.0) * mass
	apply_central_force(force)
	# A supported player balances on the deck; in water the existing free roll still applies.
	var support_spin := support.angular_velocity if support != null else Vector3.ZERO
	var balance := (
		global_basis.y.cross(normal) * 35.0 - (angular_velocity - support_spin) * 10.0
	) * mass
	apply_torque(balance)
	if support != null:
		support.apply_force(-force, hit.position - support.global_position)
		support.apply_torque(-balance)
	return true


## Returns what the player is standing on, or an empty dictionary when it is standing on nothing.
##
## A surface too steep to stand on counts as nothing, so a player pressed against the side of a
## hull is not treated as being on top of it.
func _deck_support() -> Dictionary:
	# The player's cube can arrive tilted from swimming; its lowest corner is then farther
	# below the centre than the upright half-height.
	var half_height := absf(global_basis.x.y) + absf(global_basis.y.y) + absf(global_basis.z.y)
	var query := PhysicsRayQueryParameters3D.create(
		global_position, global_position + Vector3.DOWN * (half_height + 0.25), 1, [get_rid()]
	)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return {}
	var normal: Vector3 = hit.normal
	if normal.dot(Vector3.UP) < SUPPORT_NORMAL_MINIMUM:
		return {}
	return hit


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
