class_name PaddleRig
extends Node3D

## A paddle in the character's hands while they paddle: shown, swung, and held.
##
## [b]Presentation only[/b], like the rest of [CharacterVisual]. Nothing here moves the raft; the
## server's [method Raft.request_stroke] does that. This reads what every peer already has — that
## the body stands on a raft, and that its owner's stroke count is rising — and draws a stroke on
## the side of the deck the player is standing on, which is also the side the stroke turns the
## raft from. Seeing which side a crewmate is paddling on is how a crew steers together.
##
## The paddle is long, because the deck is high: the character stands 1.8 m above the waterline,
## and at the model's 2.5x scale a paddle has to reach from chest height to below the surface.
## Both hands are pulled onto the shaft by a [TwoBoneIK3D] per arm, blended in and out, so the
## walk and idle clips are untouched whenever the paddle is stowed.

## Length of the paddle, blade tip to grip, in metres.
const LENGTH: float = 5.0

## Fraction of a stroke spent pulling; the rest is the recovery, blade out of the water.
const PULL_FRACTION: float = 0.62

## Where the upper hand holds the shaft, in the paddler's frame: height above the feet, distance
## toward the paddle side, and distance forward. The model's arms are about 0.8 m long from a
## shoulder 1.9 m up, so both grips sit within that reach, in front of the chest.
const UPPER_HAND: Vector3 = Vector3(0.05, 2.35, 0.35)

## Where the lower hand holds the shaft, in the same frame. The line through the two hands is
## the shaft, so these two points also decide where the blade meets the water.
const LOWER_HAND: Vector3 = Vector3(0.62, 1.35, 0.25)

## How far each hand travels fore and aft through the pull, in metres. The lower hand travels
## further than the upper, so the paddle pivots and the blade sweeps.
const UPPER_SWEEP: float = 0.18
const LOWER_SWEEP: float = 0.5

## How far the hands lift during the recovery, in metres, taking the blade out of the water.
const RECOVERY_LIFT: float = 0.35

## Length of the grip above the upper hand, in metres.
const GRIP_OVERHANG: float = 0.35

## Seconds after the owner's last stroke request that the paddle is still being worked.
const LINGER: float = Raft.STROKE_DURATION * 1.3

## Rate the paddle blends in and out, per second.
const BLEND_RATE: float = 4.0

## The player whose paddle this is, and their input and skeleton. Set by [CharacterVisual].
var body: NetworkPlayer
var input: PlayerInput
var skeleton: Skeleton3D

## The raft the paddle is being worked from this frame, or null.
var raft: Raft

## How far the paddle is blended in, 0 to 1.
var blend: float = 0.0

var _model: Node3D
var _ik: SkeletonModifier3D
var _targets: Array[Node3D] = []
var _poles: Array[Node3D] = []
var _phase: float = 0.0
var _last_count: int = -1
var _recent: float = 0.0
var _side: float = 1.0


func _ready() -> void:
	top_level = true
	_model = _build_paddle()
	add_child(_model)
	_model.hide()


func _process(delta: float) -> void:
	if body == null:
		return
	raft = _raft_underfoot()
	var working := raft != null and _is_working(delta)
	blend = move_toward(blend, 1.0 if working else 0.0, delta * BLEND_RATE)
	_model.visible = blend > 0.0
	if blend <= 0.0:
		if _ik != null:
			_ik.influence = 0.0
			_ik.active = false
		return
	if raft == null:
		return
	if working:
		var previous := _phase
		_phase = fmod(_phase + delta / Raft.STROKE_DURATION, 1.0)
		# In the middle band a paddler switches sides each stroke, as a canoeist does to hold a
		# straight line; off it, they paddle the side they stand on.
		var lateral := raft.to_local(body.global_position).x
		if absf(lateral) > Raft.STRAIGHT_BAND:
			_side = signf(lateral)
		elif _phase < previous:
			_side = -_side
	_pose()


## The bow of the raft being paddled, flattened, for the character to face; zero when idle.
func facing() -> Vector3:
	if blend <= 0.0 or raft == null:
		return Vector3.ZERO
	var bow := -raft.global_basis.z
	bow.y = 0.0
	return bow.normalized()


## Whether this player is paddling: their stroke count rose recently, or, where that count never
## reaches this peer, they are the only one aboard a raft that is being paddled.
func _is_working(delta: float) -> bool:
	_recent = maxf(_recent - delta, 0.0)
	if input != null:
		if _last_count >= 0 and input.paddle_strokes > _last_count:
			_recent = LINGER
		_last_count = input.paddle_strokes
	if _recent > 0.0:
		return true
	if not raft.thrusting:
		return false
	var players := body.get_parent()
	if players == null:
		return false
	var aboard := 0
	for child in players.get_children():
		if raft.carries(child as NetworkPlayer):
			aboard += 1
	return aboard == 1


func _raft_underfoot() -> Raft:
	for node: Node in body.get_tree().get_nodes_in_group(&"water_subjects"):
		var candidate := node as Raft
		if candidate != null and candidate.carries(body):
			return candidate
	return null


## Places the hands for the current phase of the stroke, and the paddle through them.
##
## Worked in the paddler's own frame — facing the bow, with "out" toward the paddle side — and the
## shaft is simply the line through the two hands, extended down to the blade. So the blade meets
## the water wherever that line does, and the hands are always exactly on the shaft.
func _pose() -> void:
	var forward := facing()
	var up := Vector3.UP
	var out := forward.cross(up).normalized() * _side
	var along := 0.0
	var lift := 0.0
	if _phase < PULL_FRACTION:
		# The pull: from the catch, well forward, back past the hip.
		var t := _phase / PULL_FRACTION
		along = lerpf(1.0, -1.0, t * t * (3.0 - 2.0 * t))
	else:
		# The recovery: out of the water and swung forward again.
		var t := (_phase - PULL_FRACTION) / (1.0 - PULL_FRACTION)
		along = lerpf(-1.0, 1.0, t)
		lift = sin(t * PI) * RECOVERY_LIFT
	var feet := body.global_position
	var upper := feet + out * UPPER_HAND.x + up * (UPPER_HAND.y + lift) \
		+ forward * (UPPER_HAND.z + along * UPPER_SWEEP)
	var lower := feet + out * LOWER_HAND.x + up * (LOWER_HAND.y + lift) \
		+ forward * (LOWER_HAND.z + along * LOWER_SWEEP)

	var shaft := (upper - lower).normalized()
	var tip := upper + shaft * GRIP_OVERHANG - shaft * LENGTH
	# The blade's face looks fore and aft, square to the stroke.
	var face := (forward - shaft * forward.dot(shaft)).normalized()
	_model.global_transform = Transform3D(Basis(shaft.cross(face), shaft, face), tip)

	_ensure_ik()
	if _ik == null:
		return
	_ik.active = true
	_ik.influence = blend
	# The hand on the paddle's side holds low; the other holds the top.
	var right_low := _side > 0.0
	_targets[0].global_position = lower if right_low else upper
	_targets[1].global_position = upper if right_low else lower
	# Elbows out and back, so each arm bends the way an arm on a paddle does.
	var right := forward.cross(up).normalized()
	_poles[0].global_position = feet + right * 1.5 + up * 1.2 - forward * 0.8
	_poles[1].global_position = feet - right * 1.5 + up * 1.2 - forward * 0.8


func _ensure_ik() -> void:
	if _ik != null or skeleton == null:
		return
	if skeleton.find_bone("DEF-hand.R") < 0 or skeleton.find_bone("DEF-hand.L") < 0:
		return
	var ik := TwoBoneIK3D.new()
	ik.name = "PaddleArms"
	skeleton.add_child(ik)
	ik.setting_count = 2
	for index in 2:
		var suffix := "R" if index == 0 else "L"
		var target := Node3D.new()
		target.name = "PaddleHand%s" % suffix
		target.top_level = true
		add_child(target)
		_targets.append(target)
		# Without a pole the solver has no plane to bend the elbow in: the arms rest nearly
		# straight, and a straight two-bone chain is degenerate. Measured: the hand did not move.
		var pole := Node3D.new()
		pole.name = "PaddleElbow%s" % suffix
		pole.top_level = true
		add_child(pole)
		_poles.append(pole)
		ik.set_root_bone_name(index, "DEF-upper_arm.%s" % suffix)
		ik.set_middle_bone_name(index, "DEF-forearm.%s" % suffix)
		ik.set_end_bone_name(index, "DEF-hand.%s" % suffix)
		ik.set_target_node(index, ik.get_path_to(target))
		ik.set_pole_node(index, ik.get_path_to(pole))
	ik.influence = 0.0
	_ik = ik


## A single-bladed paddle along +Y from its blade tip: blade, shaft and T-grip.
func _build_paddle() -> Node3D:
	var holder := Node3D.new()
	holder.name = "Paddle"
	var wood := PropMaterials.begin()
	PropMaterials.add_cylinder(wood, 0.11, 0.1, LENGTH - 1.2, Vector3.UP * 1.15, 10)
	PropMaterials.add_box(wood, Vector3(0.7, 0.16, 0.16), Vector3.UP * (LENGTH - 0.02))
	PropMaterials.commit(wood, holder, "Shaft", PropMaterials.cel(Color(0.62, 0.45, 0.29)))
	var blade := PropMaterials.begin()
	PropMaterials.add_box(blade, Vector3(0.72, 1.35, 0.09), Vector3.UP * 0.67)
	PropMaterials.add_cylinder(blade, 0.3, 0.12, 0.3, Vector3.UP * 1.3, 10)
	PropMaterials.commit(blade, holder, "Blade", PropMaterials.cel(Color(0.85, 0.36, 0.25)))
	return holder
