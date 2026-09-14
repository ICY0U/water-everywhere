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

## Seconds one shove lasts, from brace to release.
##
## Shorter than [constant STROKE_DURATION] because a shove is one committed effort rather than a
## repeating rhythm: long enough that the force is not a single-tick spike, short enough that a
## press reads as a press. It also bounds how long a disconnecting pusher can keep shoving.
const PUSH_DURATION: float = 0.55

## Seconds before the same pusher may shove again.
##
## [b]Longer than [constant PUSH_DURATION], deliberately.[/b] When the two were the same number
## the cooldown expired exactly as the shove ended, so a player tapping G every 0.55 s applied
## 90 kN continuously — which is the thing [member PlayerInput.push_requests] refuses to allow by
## holding, arrived at by tapping instead. The gap is the rest between efforts, and it is what
## makes a shove one committed heave rather than a throttle.
const PUSH_COOLDOWN: float = 1.2

## How far from the raft's centre a pusher can stand and still reach the hull, in metres.
##
## The hull is 9 by 9.6 m, so its corner is about 6.6 m from centre; this reaches roughly an arm
## past that. Deliberately shorter than [constant NetworkPlayer.BOARD_RANGE], which is 9.0: you
## can scramble aboard from further away than you can brace against a hull and shove it.
const PUSH_RANGE: float = 7.5

## Why a shove was or was not applied.
##
## Separate from [enum StrokeResult] rather than shared, because the two refuse for opposite
## reasons: a stroke needs the paddler ABOARD, a shove needs them off it and standing on
## something solid. One enum covering both would have members that are unreachable for half its
## callers, and a test asserting the wrong one would still read as passing.
enum PushResult {
	## The shove was applied to the raft.
	ACCEPTED,
	## The pusher is standing on this raft, so their shove has nothing to push against.
	##
	## Pushing a hull you are standing on cancels: the force you put into it comes back through
	## your own feet. This is the whole reason a shove is a different action from a stroke.
	ABOARD,
	## The pusher is not standing on anything solid — swimming, or in the air.
	NO_FOOTING,
	## The pusher is too far from the hull to reach it.
	OUT_OF_REACH,
	## The pusher is directly under the hull's centre in plan view, so there is no direction to
	## shove in.
	##
	## Its own member rather than folded into [constant OUT_OF_REACH], which would be a refusal
	## passing for the wrong reason — the exact failure this enum is split up to prevent. A test
	## asserting OUT_OF_REACH here would be asserting a lie.
	TOO_CLOSE,
	## That pusher's previous shove has not finished.
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
## [b]Set from play, against a raft whose mass was corrected first.[/b]
##
## The first playtest ran at 1,200 N against a 108,864 kg raft and the verdict was that it "is
## not moving at all" — at that mass a believable stroke reads to a player as a broken control.
## The reflex is to raise this number, and that road ends at 120,000 N: twelve tonnes from one
## paddler, a heavy raft pretending to be a light one.
##
## The actual fault was the raft's mass, and the lever is [member BuoyantBody.body_density], NOT
## the hull's size. [code]mass = body_density * hull.volume[/code], and density is the half of
## that product that touches no geometry: equilibrium submersion is about density/1025 whatever
## the shape, so lowering it makes the hull ride higher without moving the deck relative to the
## waterline. Thinning the hull moves both, which breaks freeboard and boarding.
##
## [code]raft.tscn[/code] now carries density 300 rather than 420 — waterlogged timber and
## barrels rather than seasoned oak — for 77,760 kg.
##
## Measured in the test bay, two crew aboard, ten strokes from one side, at 30,000 N:
## [codeblock lang=text]
##  density 420  108,864 kg    7.5 deg   1.65 m   the original; played, felt like nothing
##  density 300   77,760 kg   13.2 deg   2.33 m   <- shipped
##  density 250   64,800 kg   ~20  deg            fails verify_test_island's trough check
##  density 200   51,840 kg   25.3 deg   3.20 m   fails trough AND draught
## [/codeblock]
## Symmetry is exact once the raft is settled (-9.101 against +9.095 at matched force), so a
## reading that says otherwise is an unsettled rig rather than a torque bug.
##
## [b]300 is the lightest density that keeps every existing suite green, and that is why it is
## here.[/b] Below it [code]verify_test_island[/code] goes red on constants documented against a
## 420 kg/m³ hull — a trough floor, a draught tolerance and a floating minimum. Those constants
## are arguably stale rather than right, but a lighter raft is not worth editing three thresholds
## in someone else's suite to accommodate. If this raft ever needs to be lighter, derive those
## bands from the density instead of widening them.
@export_range(0.0, 200000.0, 10.0) var stroke_force: float = 30000.0

## How far out from the centreline a stroke bites, in metres.
##
## The lever arm is what turns a stroke on one side into yaw. Taken from the paddler's own
## position rather than assumed, so kneeling at the bow turns differently from amidships.
@export_range(0.0, 8.0, 0.05) var stroke_lever: float = 2.4

## Force one shove delivers, in newtons, at the hull's centre of mass.
##
## [b]Set from play, and NOT from measurement — unlike [member stroke_force], which was.[/b] That
## is a deliberate admission rather than an oversight, because the obvious way to measure this
## does not work and the next person should not spend an evening rediscovering that.
##
## A raft grounded in the shallows is still floating, so the swell moves it more than a shove
## does. Averaged over four wave phases, from an identical re-settled start, displacement two and
## a half seconds after the shove came out as:
## [codeblock lang=text]
##       0 N   0.271 m   <- no shove at all, the control
##   20000 N   0.134 m
##   40000 N   0.112 m
##   60000 N   0.318 m
##   90000 N   0.233 m   <- shipped
##  140000 N   0.333 m
## [/codeblock]
## The control out-moves half the shoves, so every row of that table is the sea rather than the
## push. A number chosen from it would be indistinguishable from a number chosen at random.
##
## Two things would have to change to measure it honestly: settle and sample over this project's
## established windows for settled physics — 25 s and 12 s, not the 12 s and 2.5 s used above —
## and measure the hull's contact with the bed ENDING rather than a distance, because "did it
## come off the bottom" is a state change and distance at this scale is swamped by wave orbital
## motion. Neither is hard; both were skipped to get a working feature in front of a person.
##
## 90,000 N is what the user played and accepted. If it ever needs to change, do the measurement
## properly first rather than nudging this number against the same noise.
@export_range(0.0, 400000.0, 100.0) var push_force: float = 90000.0

## Rises by one each time a shove is accepted. Replicated, never reset.
##
## A serial for the same reason [member stroke_serial] is one: a shove is momentary, and a flag
## true for a single frame can fall between two synchroniser samples and never be seen.
var push_serial: int = 0

## Seconds since each pusher's last accepted shove began, by instance id.
##
## One clock rather than two, because the shove and the rest that follows it are one gesture:
## force is applied while this is under [constant PUSH_DURATION], and another shove is refused
## while it is under [constant PUSH_COOLDOWN]. An entry is dropped once the longer of the two has
## passed, so the dictionary holds only pushers who are mid-heave or mid-rest.
var _push_elapsed: Dictionary = {}

## The direction each pusher's shove is committed to, by instance id.
var _push_direction: Dictionary = {}

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
	_advance_pushes(delta)


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


## Shoves the raft away from [param pusher], and says whether it was allowed.
##
## Server-side by construction, exactly as [method request_stroke] is: the client publishes only
## a rising count and every condition is tested here. A client cannot submit a direction, a force
## or a target — only the fact that it asked.
##
## [b]The pusher must be OFF the raft.[/b] This is the inverse of a stroke's test rather than an
## arbitrary restriction: a shove needs something to brace against, and someone standing on the
## hull braces against the hull, so the force and its reaction cancel through their own feet.
## Standing on the beach, the reaction goes into the beach and the raft moves.
##
## Direction is away from the pusher, flattened to horizontal, and taken at the moment of the
## shove. Not the raft's forward — a shove is directional from where the pusher stands, which is
## the whole point of getting off and walking round to the landward side.
func request_push(pusher: NetworkPlayer) -> PushResult:
	if not is_multiplayer_authority():
		return PushResult.NOT_AUTHORITY
	if pusher == null:
		return PushResult.NO_FOOTING
	var footing := pusher.standing_on()
	# Asking the player rather than re-casting, for the same reason a stroke does: one answer to
	# "what is this body standing on" per frame, already decided when its stance was.
	if footing == self:
		return PushResult.ABOARD
	if footing == null:
		return PushResult.NO_FOOTING
	# Horizontal only, like boarding: the pusher stands on a beach below the deck or a rock above
	# it, and both are within arm's reach of the hull.
	var offset := global_position - pusher.global_position
	var flat := Vector2(offset.x, offset.z)
	if flat.length() > PUSH_RANGE:
		return PushResult.OUT_OF_REACH
	if _push_elapsed.get(pusher.get_instance_id(), PUSH_COOLDOWN) < PUSH_COOLDOWN:
		return PushResult.COOLING_DOWN

	# Direction is locked in at the shove, like a stroke's arm: if the pusher is knocked aside
	# mid-push, the effort already committed does not swing round to follow them.
	var direction := Vector3(flat.x, 0.0, flat.y)
	if direction.length_squared() <= 0.0:
		# Standing exactly under the hull's centre in plan view is not a direction. Refused as its
		# own case rather than as OUT_OF_REACH, which would be a refusal passing for the wrong
		# reason. The consequence of not refusing is mild but silly: Vector3.ZERO.normalized()
		# returns zero rather than NaN, so the shove would apply no force while still spending
		# the cooldown and raising the serial — a press that costs the player their next one.
		return PushResult.TOO_CLOSE
	_push_elapsed[pusher.get_instance_id()] = 0.0
	_push_direction[pusher.get_instance_id()] = direction.normalized()

	push_serial += 1
	return PushResult.ACCEPTED


## Runs the shove clocks down, applying each one's force for as long as it lasts.
##
## Applied EVERY physics step for the length of the shove, not once when it is accepted, for the
## reason [method _advance_strokes] documents: [method RigidBody3D.apply_force] is cleared at the
## end of the step, so a single call would deliver its force for one tick and nothing after.
##
## The force is applied at the hull's centre of mass rather than at the pusher's hands. A shove
## against a beached raft is a whole-body effort against a hull already resting on something, and
## an off-centre impulse at this mass spins it instead of freeing it — which reads as the raft
## refusing to move while slewing sideways.
func _advance_pushes(delta: float) -> void:
	if _push_elapsed.is_empty():
		return
	# keys() returns a snapshot array, so erasing inside the loop is safe — verified rather than
	# assumed, as _advance_strokes does the same thing.
	for id: int in _push_elapsed.keys():
		var elapsed: float = float(_push_elapsed[id]) + delta
		if elapsed >= PUSH_COOLDOWN:
			# The rest is over as well as the heave; this pusher is free to shove again.
			_push_elapsed.erase(id)
			_push_direction.erase(id)
			continue
		_push_elapsed[id] = elapsed
		# Force for the heave only. The remainder of the entry's life is the rest that stops a
		# player tapping the key into a continuous engine.
		if elapsed < PUSH_DURATION:
			var direction: Vector3 = _push_direction.get(id, Vector3.ZERO)
			apply_central_force(direction * push_force)


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
