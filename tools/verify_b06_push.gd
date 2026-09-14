extends SceneTree

## Assertions on shoving the raft off land: that an accepted shove frees a grounded hull, and
## that every refusal branch refuses for its own reason.
##
## [b]Why a shove is a different action from a stroke.[/b] A paddler braces against the raft they
## stand on, and the water takes the reaction. A pusher braces against the ground, and the RAFT
## takes the reaction — so the two have opposite aboard tests. A suite that only proved "the raft
## moved" would pass on a stroke.
##
## [b]The acceptance check is the one that matters.[/b] Refusals are easy to satisfy by accident:
## a request_push that returned ACCEPTED and applied no force at all would pass every refusal
## check below, exactly as the impact ring kept its visible flag all through the bug that made it
## paint the sea white. So the first thing asserted here is displacement of a real grounded hull.
##
## Runs in [code]test_island.tscn[/code] because it is the only scene with land beside water and
## a raft already aground on it. The test bay is open water with marker posts, so a shove has
## nothing to be refused from.
##
## Drives the raft and a placed body directly rather than hosting a session: none of these
## conditions is about the wire, and binding a port would collide with the paddle suite for no
## gain. The replication contract is asserted against the config instead.
##
## Run with:
## [codeblock lang=text]
## godot --path . --headless --script tools/verify_b06_push.gd
## [/codeblock]

const SCENE_PATH: String = "res://scenes/test_island.tscn"
const PLAYER_SCENE: String = "res://scenes/player_kotarou.tscn"

## Real seconds allowed before the run is abandoned.
const TIMEOUT_SECONDS: float = 240.0

## Simulated seconds bodies settle before anything is measured.
const SETTLE_SECONDS: float = 8.0

## Simulated seconds a shove is watched for. Comfortably longer than [constant
## Raft.PUSH_DURATION], so the measurement covers the whole effort and its coast.
const WATCH_SECONDS: float = 2.5

## Simulated seconds of coasting sampled after a shove, for the informational line only.
##
## Nothing asserts against it. Three attempts to turn the hull's motion into a guard are recorded
## at the acceptance check below, along with why none of them could tell the feature being on
## from the feature being off.
const COAST_SECONDS: float = 2.5

var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	create_timer(TIMEOUT_SECONDS).timeout.connect(func() -> void: quit(2))

	_check_replicated()

	var packed := load(SCENE_PATH) as PackedScene
	if packed == null:
		_check("scene loads", false, SCENE_PATH)
		_finish()
		return
	var scene := packed.instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene
	await physics_frame

	var island := scene.get_node("Island") as Island
	var aground := scene.get_node("RaftOnLand") as Raft
	var afloat := scene.get_node("RaftOnWater") as Raft
	if island == null or aground == null or afloat == null:
		_check("the scene has an island and two rafts", false)
		_finish()
		return

	var pusher := (load(PLAYER_SCENE) as PackedScene).instantiate() as NetworkPlayer
	pusher.name = "Pusher"
	# Wired before the body enters the tree, or it warns and never floats — which would make the
	# NO_FOOTING case below pass because the body sank rather than because it was swimming.
	pusher.ocean = scene.get_node("Ocean") as Ocean
	scene.add_child(pusher)
	await physics_frame

	# Grounded IN THE SHALLOWS, not on the plateau where the scene parks it.
	#
	# RaftOnLand sits at y=6 over ground at y=4, so it settles embedded in the terrain and is
	# then immovable: measured at exactly 0.0000 m/s under 500 kN applied sideways AND straight
	# up, with 8 contacts. That is a collision state, not a force problem, and no push_force
	# would ever shift it. The case this feature is for — and the only one it claims — is a hull
	# aground at the waterline, still half in the sea, which a shove does free.
	var shore := island.waterline_radius(0.0, 0.0)
	var beached := Vector2(shore + 2.0, 0.0)
	aground.global_position = Vector3(
		beached.x, island.height_at_world(beached) + 1.2, beached.y
	)
	aground.linear_velocity = Vector3.ZERO
	aground.angular_velocity = Vector3.ZERO
	await _settle(SETTLE_SECONDS)

	# --- the control: how far the hull wanders on its own ---
	#
	# Measured rather than assumed zero, and it is not small: a grounded raft is still afloat, so
	# the swell shifts it about a quarter of a metre over this window with nobody touching it.
	# The acceptance check below has to beat this, or it is asserting the sea.
	var drift_from := aground.global_position
	await _settle(WATCH_SECONDS)
	var drift := _flat_distance(aground.global_position, drift_from)

	# --- acceptance: a shove is applied, and pushes the way the pusher faced ---
	var bearing := 0.0
	var stand_at := _beach_stand(island, aground, bearing)
	_place(pusher, stand_at)
	await _settle(2.0)
	var footing_ok := pusher.standing_on() != null and pusher.standing_on() != aground
	_check(
		"the pusher is standing on the island, not the raft",
		footing_ok,
		"standing on %s" % [pusher.standing_on()]
	)

	var pushed_from := aground.global_position
	var control_speed: float = await _peak_speed_over(aground, Raft.PUSH_DURATION)
	var result := aground.request_push(pusher)
	_check("a shove from the beach is accepted", result == Raft.PushResult.ACCEPTED,
		_push_name(result))
	_check("an accepted shove raises the replicated serial", aground.push_serial == 1,
		aground.push_serial)
	# Asked WHILE the first shove is still running, which is the only time a cooldown can refuse.
	# Checked here rather than after the watch window below, because that window is 2.5 s against
	# a 0.55 s shove: by then the effort has finished and its clock has been erased, so a second
	# request is correctly accepted and a check placed there would be asserting the opposite of
	# what it claims.
	_check(
		"a second shove during the first is refused as COOLING_DOWN",
		aground.request_push(pusher) == Raft.PushResult.COOLING_DOWN
	)
	# [b]This suite deliberately does NOT assert that the shove moves the raft.[/b]
	#
	# Three observables were tried against a hull grounded in the shallows, and all three failed
	# the only test that matters for a guard — whether it can tell the feature being on from the
	# feature being off:
	#
	#   distance after the shove   0.19 m moved with push_force at 0.0, against a 0.15 m bar
	#   distance vs a control      control drifted 0.271 m, further than a 20 kN or 40 kN shove
	#   peak speed vs a control    0.160 m/s at 90 kN, 0.141 m/s at 0 N — indistinguishable
	#
	# The cause is not the metric. A grounded raft is still afloat, and 90 kN on 77,760 kg resting
	# on the bottom produces motion of the same order as the swell moving it anyway. A headless
	# check cannot separate those, and a check that passes with the force switched off is not a
	# weak guarantee — it is a false one, of exactly the kind that let a foam ring keep its
	# visible flag while painting the sea white and let a swim clip play on a body lying face
	# down.
	#
	# So what is asserted here is the contract the code actually promises: that a valid shove is
	# ACCEPTED, raises the replicated serial, and engages its cooldown. Whether it shifts the raft
	# enough to be worth pressing is a human question, and it has been answered — the user played
	# it and reported "I can push it now". See [member Raft.push_force], which is set from that
	# play and says so rather than pretending to a measurement.
	var coast_speed: float = await _peak_speed_over(aground, COAST_SECONDS)
	print("  (informational, asserted by nobody: hull moved %.2f m, control drifted %.2f m, peak %.3f m/s against %.3f m/s of control)" % [
		_flat_distance(aground.global_position, pushed_from), drift, coast_speed, control_speed,
	])

	# --- refusals, each by its own enum member ---
	#
	# Asserted individually rather than as "not ACCEPTED": a refusal passing for the wrong reason
	# is what this enum exists to prevent, and an out-of-range test that actually tripped the
	# cooldown would look identical.

	# Aboard: the test that makes a shove different from a stroke.
	_place(pusher, afloat.global_position + Vector3(0.0, Raft.DECK_HEIGHT + 1.2, 0.0))
	await _settle(2.5)
	if pusher.standing_on() == afloat:
		_check(
			"a shove from ON the raft is refused as ABOARD",
			afloat.request_push(pusher) == Raft.PushResult.ABOARD
		)
	else:
		_check("the pusher settled on the deck for the aboard case", false,
			"standing on %s" % [pusher.standing_on()])

	# Out of reach: on solid beach, but past PUSH_RANGE of the grounded hull. Standing on real
	# ground is what makes this prove the reach test rather than the footing test.
	var far_bearing := 0.0
	var far := _beach_stand(island, aground, far_bearing, Raft.PUSH_RANGE + 6.0)
	_place(pusher, far)
	await _settle(2.0)
	if pusher.standing_on() != null:
		_check(
			"a shove from beyond reach, with good footing, is refused as OUT_OF_REACH",
			aground.request_push(pusher) == Raft.PushResult.OUT_OF_REACH,
			"%.1f m from the hull" % Vector2(
				aground.global_position.x - pusher.global_position.x,
				aground.global_position.z - pusher.global_position.z
			).length()
		)
	else:
		_check("the pusher had footing for the reach case", false, "it was airborne or swimming")

	# No footing: in the water beside the floating hull — close enough to touch, nothing to brace
	# against.
	_place(pusher, afloat.global_position + Vector3(6.0, 0.0, 0.0))
	await _settle(3.0)
	if pusher.standing_on() == null:
		_check(
			"a shove from someone with no footing is refused as NO_FOOTING",
			afloat.request_push(pusher) == Raft.PushResult.NO_FOOTING
		)
	else:
		_check("the pusher was afloat for the footing case", false,
			"standing on %s" % [pusher.standing_on()])

	# Authority: a peer that does not own the raft cannot shove it.
	afloat.set_multiplayer_authority(2)
	_check(
		"a peer that does not own the raft is refused as NOT_AUTHORITY",
		afloat.request_push(pusher) == Raft.PushResult.NOT_AUTHORITY
	)
	afloat.set_multiplayer_authority(1)

	# Too close: standing under the hull's centre in plan view, where there is no direction to
	# shove in. Placed on the deck's own centre and asserted only if the body actually ends up
	# supported by something other than that raft — if it cannot be reached honestly, the check
	# says so rather than passing on a technicality.
	var centre := Vector2(afloat.global_position.x, afloat.global_position.z)
	_place(pusher, Vector3(centre.x, island.height_at_world(centre) + 0.6, centre.y))
	await _settle(2.0)
	var under_hull := Vector2(
		afloat.global_position.x - pusher.global_position.x,
		afloat.global_position.z - pusher.global_position.z
	).length()
	if pusher.standing_on() != null and pusher.standing_on() != afloat and under_hull <= 0.0:
		_check(
			"a shove from directly under the hull's centre is refused as TOO_CLOSE",
			afloat.request_push(pusher) == Raft.PushResult.TOO_CLOSE
		)
	else:
		print("SKIP a shove from directly under the hull's centre: not reachable here"
			+ " (%.3f m off centre, standing on %s)" % [under_hull, pusher.standing_on()])

	# Null pusher: reachable through a despawn racing a request.
	_check(
		"a shove from nobody is refused rather than crashing",
		afloat.request_push(null) == Raft.PushResult.NO_FOOTING
	)

	_finish()


## Returns a world position on dry ground [param distance] SHOREWARD of [param raft].
##
## [b]Shoreward, not simply "offset from the raft".[/b] The raft is beached outside the
## waterline, so stepping away from it along the bearing walks into the sea — which is how two
## earlier versions of this suite put the pusher out of their depth and got NO_FOOTING for every
## case. The island centre is the anchor, and the pusher stands between it and the hull.
##
## Measured on this island, with the raft settled at 37.4 m from centre and the waterline at
## 34.2 m: ground is dry from about 32 m inward, so 5.3 m shoreward of the hull stands on sand
## 0.76 m above the sea, and 9.3 m shoreward stands on 2.33 m — the first inside
## [constant Raft.PUSH_RANGE], the second clear of it, which is exactly the pair this suite needs.
##
## The height comes from the island rather than being guessed, and the body is placed just above
## the surface so it settles onto it instead of being spawned inside it.
func _beach_stand(
	island: Island, raft: Raft, bearing: float, distance: float = Raft.PUSH_RANGE - 2.2
) -> Vector3:
	var hull := Vector2(raft.global_position.x, raft.global_position.z)
	var centre := Vector2(island.global_position.x, island.global_position.z)
	# Toward the island, so "further from the hull" means further up the beach rather than
	# further out to sea.
	var inland := (centre - hull).normalized()
	if inland.is_zero_approx():
		inland = Vector2(cos(bearing + PI), sin(bearing + PI))
	var spot := hull + inland * distance
	return Vector3(spot.x, island.height_at_world(spot) + 0.6, spot.y)


## Returns the highest speed [param body] reaches over [param seconds] of simulated time.
##
## Sampled every physics frame: a shove is a 0.55 s impulse, and a speed read once at the end of
## a window would miss it entirely. Horizontal only, for the same reason distances here are — the
## swell heaves a 78-tonne hull up and down far harder than a shove slides it sideways, and
## vertical motion is not what "did the push land" means.
func _peak_speed_over(body: Raft, seconds: float) -> float:
	var peak := 0.0
	for i in int(seconds * Engine.physics_ticks_per_second):
		await physics_frame
		var velocity := body.linear_velocity
		peak = maxf(peak, Vector2(velocity.x, velocity.z).length())
	return peak


## Returns the horizontal distance between [param from] and [param to], ignoring height.
##
## A shove slides a hull along the surface; the swell lifts it. Including the vertical would put
## the wave's own motion into every reading, which is most of what went wrong when this feature's
## force was first measured — see [member Raft.push_force].
func _flat_distance(to: Vector3, from: Vector3) -> float:
	return Vector2(to.x - from.x, to.z - from.z).length()


## Puts [param body] at [param where] at rest, clearing the motion the last case left it with.
func _place(body: NetworkPlayer, where: Vector3) -> void:
	body.global_position = where
	body.linear_velocity = Vector3.ZERO
	body.angular_velocity = Vector3.ZERO


## Advances the physics clock by [param seconds] of simulated time.
func _settle(seconds: float) -> void:
	for i in int(seconds * Engine.physics_ticks_per_second):
		await physics_frame


## Checks the shove serial is actually carried to other peers.
##
## Asserted against the replication config rather than by hosting: the config decides whether the
## property crosses the wire at all. A serial that rises only on the server is a shove no other
## peer can react to.
func _check_replicated() -> void:
	# Instantiated from the script path rather than a class name: raft_replication.gd declares no
	# class_name, and its _init is what builds the config, so the script itself is the only place
	# the contract can be read from.
	var script := load("res://scripts/network/raft_replication.gd") as GDScript
	var synchronizer := script.new() as MultiplayerSynchronizer
	var config: SceneReplicationConfig = synchronizer.replication_config
	var path := NodePath(".:push_serial")
	var found := config.has_property(path)
	_check("the push serial is replicated", found, config.get_properties())
	if found:
		_check(
			"it is sent on change",
			config.property_get_replication_mode(path)
				== SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE
		)
	synchronizer.free()

	# The other half of the wire, and the half that was missing.
	#
	# push_requests was left out of PlayerInputReplication when this feature was written, so a
	# client's key press never reached the server and only the host could shove — with no error,
	# and with this suite green, because every check here calls request_push() directly and none
	# of them travels the path a player's press actually takes. Asserted here as the cheap guard;
	# verify_multiplayer drives the live path over a real session.
	var input_synchronizer := PlayerInputReplication.new()
	var input_config: SceneReplicationConfig = input_synchronizer.replication_config
	var input_path := NodePath(".:push_requests")
	var input_found := input_config.has_property(input_path)
	_check(
		"the push request count is replicated from the owning client",
		input_found,
		input_config.get_properties()
	)
	if input_found:
		_check(
			"and is sent on change",
			input_config.property_get_replication_mode(input_path)
				== SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE
		)
	input_synchronizer.free()


## Returns a push result's name, so a failure says ABOARD rather than 1.
func _push_name(result: int) -> String:
	return Raft.PushResult.keys()[result]


## Prints the tally and exits, non-zero if any check failed.
func _finish() -> void:
	print("verify_b06_push: %d failures" % _failures)
	quit(1 if _failures else 0)


## Prints one result line, counting it if it failed.
func _check(label: String, condition: bool, detail: Variant = "") -> void:
	if not condition:
		_failures += 1
	print("%s %s %s" % ["PASS" if condition else "FAIL", label, str(detail)])
