class_name CharacterVisual
extends Node3D

## Drives the player character's skinned model: animation choice, facing and cel materials.
##
## [b]Presentation only.[/b] Nothing here applies a force, moves the body or reads local input.
## The clip and the facing are chosen from state that every peer already has — the body's
## replicated velocity and its submersion — so a remote player animates identically to the
## local one without a single extra byte on the wire. That is deliberate: animation state is
## the classic thing to over-replicate, and here it is pure derivation.
##
## [b]Why facing is separate from the body.[/b] The body is a buoyant [RigidBody3D]; it rolls
## into wave faces and is spun by the water, which is right for physics and wrong for a
## character's head. The model is therefore yawed on its own within the body, so the character
## keeps facing where it is travelling while the hull beneath it does whatever the sea says.

## Speed above which the character is treated as walking rather than idling, in metres/second.
##
## Above the noise floor of a body bobbing in place: a player sitting on a wave drifts at a few
## centimetres per second, and that must not read as walking on the spot.
const WALK_SPEED_THRESHOLD: float = 0.35

## Seconds the animation player takes to cross-fade between clips.
const ANIMATION_BLEND: float = 0.25

## How quickly the model yaws toward its direction of travel, in radians per second.
const TURN_RATE: float = 9.0

## Ground speed the walk clip was authored to travel at, in metres per second.
##
## Measured from the model rather than guessed: the left foot swings 0.213 m through one cycle
## and the feet part by at most 0.379 m, which over the clip's 1.333 s is a stride that carries
## the character about 0.7 m/s once the 2.5x model scale is applied.
##
## This matters because a walk cycle is only convincing while the foot on the ground is still
## relative to the ground. Play it at a fixed rate under a body moving faster and the feet
## skate — the character appears to be pushed along rather than walking. See
## [member CharacterVisual.stride_matching_enabled].
const CLIP_GROUND_SPEED: float = 0.71

## Widest the walk clip may be sped up or slowed down to match the body, as a multiplier.
##
## Stride matching is only honest within a range: below this the legs crawl, above it they
## blur. Outside the range some sliding is unavoidable and the cap keeps the animation
## readable rather than correct.
##
## The upper bound is set by the walk this character actually does: at [constant
## NetworkPlayer.WALK_SPEED] the clip needs about 4.8x to keep its feet planted, and sprinting
## needs more still. Letting it reach that is what stops the feet skating; beyond roughly 6x
## the legs stop reading as legs, so the cap sits there and a sprint slides a little.
const SPEED_SCALE_LIMITS: Vector2 = Vector2(0.6, 6.0)

## Clip names as they arrive from the glTF import.
##
## The importer strips the [code]_Loop[/code] suffix and turns it into the clip's loop mode, so
## [code]Idle_Loop[/code] in Blender is [code]Idle[/code] here. Naming them as constants means a
## renamed clip fails loudly at [method _ready] instead of silently never playing.
const CLIP_IDLE: StringName = &"Idle"
const CLIP_WALK: StringName = &"Walk"
const CLIP_SWIM: StringName = &"Swim_Idle"

## Whether to play animation clips at all.
##
## Off leaves the model in its imported rest pose, which is the baseline to compare a walk
## against: any motion still visible is the physics body moving, not the animation.
@export var animation_enabled: bool = true:
	set(value):
		animation_enabled = value
		if not value and _animation != null:
			_animation.stop()
			_current_clip = &""

## Whether the model yaws to face where it is travelling.
##
## Off leaves the model pointing along the body's own forward axis, so a walk shows the raw
## direction the physics is pushing rather than the direction this script has decided to face.
@export var turning_enabled: bool = true:
	set(value):
		turning_enabled = value
		if not value:
			rotation.y = 0.0
			_yaw = 0.0

## Whether the walk clip's playback rate follows the body's ground speed.
##
## Off, the clip plays at its authored rate whatever the body is doing, and the feet slide
## whenever the two disagree. On, the rate is scaled so a planted foot stays put — the single
## biggest contributor to a walk reading as walking rather than gliding.
@export var stride_matching_enabled: bool = true:
	set(value):
		stride_matching_enabled = value
		if not value and _animation != null:
			_animation.speed_scale = 1.0

## Body whose motion selects the animation. Assigned by the owning player scene.
var body: BuoyantBody

## Intent of the player driving [member body], when this peer has it.
##
## Preferred over velocity wherever it exists, because velocity is a poor proxy for "is this
## character walking": standing on a drifting raft, the deck servo holds a residual speed that
## never falls to zero, and the swell adds its own. Reading intent means releasing the keys
## stops the walk immediately, which is what a player expects. Remote peers have no intent to
## read and fall back to velocity — see [method _is_walking].
var input: PlayerInput

var _animation: AnimationPlayer
var _skeleton: Skeleton3D
var _current_clip: StringName = &""
var _yaw: float = 0.0


func _ready() -> void:
	_animation = find_child("AnimationPlayer", true, false) as AnimationPlayer
	_skeleton = find_child("Skeleton3D", true, false) as Skeleton3D
	if _animation == null:
		push_error("CharacterVisual: imported model has no AnimationPlayer.")
		return
	for clip in [CLIP_IDLE, CLIP_WALK, CLIP_SWIM]:
		if not _animation.has_animation(clip):
			push_error("CharacterVisual: model is missing the '%s' clip." % clip)
	_yaw = rotation.y


func _process(delta: float) -> void:
	if _animation == null or body == null:
		return
	if animation_enabled:
		var clip := _choose_clip()
		_play(clip)
		_match_stride(clip)
	if turning_enabled:
		_face_travel(delta)


## Picks the clip that matches what the body is currently doing.
##
## Swimming is decided by the body's replicated [member NetworkPlayer.stance] rather than by its
## submersion, for two reasons found by measurement rather than argument. Submersion is computed
## only where a body simulates, so on every peer but the server a remote player's reads 0.0 and
## would swim on nobody's screen but their own. And a floating player's submersion sweeps almost
## the whole range as waves pass — 0.045 to 0.952 while settled — so no threshold on it can tell
## a trough from climbing out, and any value strobes the clip. The stance answers both: it is
## replicated, and it leaves the water only after the body has been shallow continuously.
func _choose_clip() -> StringName:
	var player := body as NetworkPlayer
	if player != null and player.stance == NetworkPlayer.Stance.FLOATING:
		return CLIP_SWIM
	return CLIP_WALK if _is_walking() else CLIP_IDLE


## Whether the character should be playing its walk.
##
## Intent decides it wherever this peer has it, so letting go of the keys stops the walk even
## though the body is still coasting, still being carried by the raft under it, and still being
## nudged by the swell. Only a remote player — whose input node belongs to another peer and is
## therefore empty here — falls back to reading the replicated velocity.
func _is_walking() -> bool:
	if input != null and input.is_multiplayer_authority():
		return input.move_direction.length() > 0.0
	var velocity := _motion_velocity()
	# Horizontal only: a body heaving up and down on a swell is not walking.
	return Vector2(velocity.x, velocity.z).length() >= WALK_SPEED_THRESHOLD


## Cross-fades to [param clip], doing nothing when it is already the one playing.
func _play(clip: StringName) -> void:
	if clip == _current_clip:
		return
	if not _animation.has_animation(clip):
		return
	_current_clip = clip
	_animation.play(clip, ANIMATION_BLEND)


## Yaws the model toward its direction of travel, independently of how the hull is rolling.
##
## The yaw is taken from the body's own horizontal velocity rather than from input, so it works
## for remote players — who have no input to read — and so a player being carried sideways by a
## current faces the way they are actually going.
func _face_travel(delta: float) -> void:
	var flat := Vector2.ZERO
	if input != null and input.is_multiplayer_authority():
		# Face where this player is steering, so a character walking across a drifting raft
		# faces its own direction of travel rather than the raft's.
		var intent := input.world_direction()
		flat = Vector2(intent.x, intent.z)
	else:
		var velocity := _motion_velocity()
		flat = Vector2(velocity.x, velocity.z)
		if flat.length() < WALK_SPEED_THRESHOLD:
			return
	if flat.length() < 0.001:
		return
	# The model is authored facing +Z, not Godot's conventional -Z, so the yaw is measured from
	# that axis: rotating +Z by y gives (sin y, cos y), hence atan2(x, z) and not atan2(-x, -z).
	var target := atan2(flat.x, flat.y)
	_yaw = rotate_toward(_yaw, target, TURN_RATE * delta)
	# Only the yaw is overridden; the parent body supplies roll and pitch from the waves.
	rotation.y = _yaw - get_parent_node_3d().global_rotation.y


## Scales walk playback so the feet keep pace with the ground the body is crossing.
##
## Only the walk is scaled: idling and treading water have no ground contact to match, and
## speeding those up would read as agitation rather than as travel.
func _match_stride(clip: StringName) -> void:
	if not stride_matching_enabled:
		return
	if clip != CLIP_WALK:
		_animation.speed_scale = 1.0
		return
	var velocity := _motion_velocity()
	var ground_speed := Vector2(velocity.x, velocity.z).length()
	_animation.speed_scale = clampf(
		ground_speed / CLIP_GROUND_SPEED, SPEED_SCALE_LIMITS.x, SPEED_SCALE_LIMITS.y
	)


## Ground motion is streamed relative to the support. A remote player carried by a raft
## must idle just like its owner, rather than walking at the raft's world-space speed.
func _motion_velocity() -> Vector3:
	var player := body as NetworkPlayer
	if player != null and player.stance == NetworkPlayer.Stance.GROUNDED:
		return player.ground_velocity
	return body.linear_velocity


## Applies [param color] to the character's raincoat so players are told apart at a glance.
##
## Only the coat is tinted. Recolouring every surface would turn the character into a
## silhouette and throw away the skin, hair and face the model actually ships with.
func tint(color: Color) -> void:
	if _skeleton == null:
		return
	for child in _skeleton.get_children():
		var mesh_instance := child as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		for surface in mesh_instance.mesh.get_surface_count():
			var material := mesh_instance.mesh.surface_get_material(surface)
			if material == null or not material.resource_name.begins_with("Rain"):
				continue
			# Overridden per instance, or every player in the scene shares the imported
			# material resource and they all take the colour of whichever was set last.
			var unique := material.duplicate() as StandardMaterial3D
			unique.albedo_color = color
			mesh_instance.set_surface_override_material(surface, unique)
