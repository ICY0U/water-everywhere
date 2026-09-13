class_name Raft
extends BuoyantBody

## Imported barrel raft with a simple closed displacement/collision envelope.

## Why a stroke was or was not applied.
##
## A bare [code]false[/code] cannot tell "nobody was aboard" from "that paddler is still
## recovering", and the B01 gate has to prove specifically that an off-raft stroke is refused —
## a check that passed on a cooldown refusal would be passing for the wrong reason.
enum StrokeResult {
	## Force and yaw were applied to the raft.
	ACCEPTED,
	## The paddler is not standing on THIS raft.
	NOT_ABOARD,
	## The blade is not in the water, so there is nothing to push against.
	NOT_IN_WATER,
	## That paddler's previous stroke has not finished.
	COOLING_DOWN,
	## Called on a peer that does not own this raft's physics.
	NOT_AUTHORITY,
}

## Seconds one stroke lasts, from catch to release.
##
## Shared with the client so the held-key repeat cadence and the server's cooldown are the same
## number rather than two copies that drift apart. It is also what bounds "missing input stops
## thrust": once no fresh stroke arrives, thrust ends within this long.
const STROKE_DURATION: float = 0.9

const DECK_HEIGHT: float = 1.804
const SPAWN_OFFSETS: Array[Vector2] = [
	Vector2.ZERO, Vector2(-2.7, 0), Vector2(2.7, 0),
	Vector2(0, -2.7), Vector2(-2.7, -2.7), Vector2(2.7, -2.7),
	Vector2(-2.7, 2.7), Vector2(2.7, 2.7), Vector2(0, 2.7),
]

## Force one stroke delivers, in newtons, at the blade.
##
## [b]A stroke is meant to be a nudge, and this value is deliberate — do not "fix" it.[/b] One
## stroke turns the loaded raft about 0.031 degrees, which is mechanically correct and humanly
## imperceptible. That is the design: wind and waves are the forces that move this vessel, and
## paddling only trims it at the margin.
##
## Measured on the voyage raft (108,864 kg, wind zeroed, settled between trials), yaw over ten
## strokes from one side:
## [codeblock lang=text]
##   1,200 N   -0.39 deg    <- this value; below the raft's own residual drift
##   6,000 N   -1.89 deg
##  20,000 N   -6.54 deg    barely felt
##  60,000 N  -15.61 deg    usable, and physically absurd: six tonnes from one paddler
## [/codeblock]
## Symmetry is exact once the raft is settled (-9.101 against +9.095 at matched force), so a
## reading that says otherwise is an unsettled rig rather than a torque bug.
@export_range(0.0, 20000.0, 10.0) var stroke_force: float = 1200.0

## How far out from the centreline a stroke bites, in metres.
##
## The lever arm is what turns a stroke on one side into yaw. Taken from the paddler's own
## position rather than assumed, so kneeling at the bow turns differently from amidships.
@export_range(0.0, 8.0, 0.05) var stroke_lever: float = 2.4

## Rises by one each time a stroke is accepted. Replicated, never reset.
##
## A serial rather than a flag because a stroke is momentary: a bool set true for one frame can
## fall between two synchroniser samples and never be seen, and a bool sampled twice looks
## identical whether it never changed or changed forty times. A number that only rises tells a
## remote peer exactly how many strokes happened, which is what animation and splash need.
var stroke_serial: int = 0

## Whether a stroke is currently under way. Replicated, for remote animation and HUD.
var thrusting: bool = false

## Seconds of the current stroke still to run, per paddler.
##
## Keyed by paddler rather than held once on the raft: two people paddling should not share one
## cooldown, or the second would be refused because the first just went.
var _stroke_remaining: Dictionary = {}

## Lever arm each in-progress stroke is pulling at, per paddler. See [method request_stroke].
var _stroke_arm: Dictionary = {}


func _physics_process(delta: float) -> void:
	# Authority can change after _ready when a player chooses Join from the offline menu.
	freeze = not is_multiplayer_authority()
	if freeze:
		return
	super(delta)
	_advance_strokes(delta)


## Applies one paddle stroke from [param paddler], and says whether it was allowed.
##
## Server-side by construction: the client publishes a rising count and every condition is
## tested here, exactly as boarding is. A client cannot submit a force, a side or a speed —
## only the fact that it asked.
##
## [param side] is a hint and is deliberately IGNORED for the direction of yaw. The real side
## comes from where the paddler is standing in this raft's own space, so somebody on the left
## edge cannot paddle as though they were on the right.
func request_stroke(paddler: NetworkPlayer, _side: float = 0.0) -> StrokeResult:
	if not is_multiplayer_authority():
		return StrokeResult.NOT_AUTHORITY
	if paddler == null:
		return StrokeResult.NOT_ABOARD
	# Standing on THIS raft, by the same support the stance was decided from this frame. Asking
	# the player rather than re-casting keeps one answer to "aboard" in the codebase: a fresh
	# raycast here could disagree with the stance already chosen earlier in the same frame.
	if paddler.standing_on() != self:
		return StrokeResult.NOT_ABOARD
	# A blade in the air pushes nothing. The hull has to be in the water for a stroke to bite.
	if submersion() <= 0.0:
		return StrokeResult.NOT_IN_WATER
	if _stroke_remaining.get(paddler.get_instance_id(), 0.0) > 0.0:
		return StrokeResult.COOLING_DOWN

	# The arm is locked in at the catch rather than re-read each frame. A stroke is one committed
	# pull: if the paddler shuffles or is thrown across the deck mid-stroke, the force that
	# stroke already began does not swing round to follow them.
	var local := to_local(paddler.global_position)
	_stroke_remaining[paddler.get_instance_id()] = STROKE_DURATION
	# Left of the centreline pushes the bow right, and the reverse; that is what steering IS.
	_stroke_arm[paddler.get_instance_id()] = signf(local.x) * stroke_lever

	stroke_serial += 1
	thrusting = true
	return StrokeResult.ACCEPTED


## Runs the stroke clocks down and drops [member thrusting] when the last one ends.
##
## This is what makes "missing input stops thrust" true without the client having to say stop:
## nothing here keeps a stroke alive, so a peer that falls silent stops paddling within
## [constant STROKE_DURATION] whether it meant to or not.
func _advance_strokes(delta: float) -> void:
	if _stroke_remaining.is_empty():
		return
	# Thrust is along the raft's own forward, not the paddler's facing: a crew pulls the vessel
	# where it points, and a player turning their head does not slew the boat.
	var forward := -global_basis.z.normalized()
	var beam := global_basis.x.normalized()
	var still_going := false
	for id: int in _stroke_remaining.keys():
		var left: float = _stroke_remaining[id] - delta
		if left <= 0.0:
			_stroke_remaining.erase(id)
			_stroke_arm.erase(id)
			continue
		_stroke_remaining[id] = left
		still_going = true
		# Applied EVERY physics step for the length of the stroke, not once at the catch.
		# apply_force() is a per-step force in Godot — it is cleared at the end of the step —
		# so a single call at accept time would deliver stroke_force for one 1/60 s tick and
		# then nothing, while thrusting stayed true for the remaining 0.9 s claiming otherwise.
		# That made a stroke about 54x weaker than stroke_force reads, and it is what the
		# earlier yaw measurements were unknowingly measuring.
		apply_force(forward * stroke_force, beam * float(_stroke_arm.get(id, 0.0)))
	thrusting = still_going


func spawn_position(players: Node3D) -> Vector3:
	# Choose the clearest deck slot in the raft's CURRENT transform, including late joins.
	var best := Vector3.ZERO
	var best_clearance := -1.0
	for offset in SPAWN_OFFSETS:
		var candidate := to_global(Vector3(offset.x, DECK_HEIGHT, offset.y))
		# Players spawn upright; account for their box extent along the tilted deck normal.
		var up := global_basis.y.normalized()
		var half_extent := absf(up.x) + absf(up.y) + absf(up.z)
		candidate += up * (half_extent + 0.15)
		var clearance := INF
		for player: Node3D in players.get_children():
			clearance = minf(clearance, candidate.distance_squared_to(player.global_position))
		if clearance > best_clearance:
			best = candidate
			best_clearance = clearance
	return best
