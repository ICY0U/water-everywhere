extends SceneTree

## Headless assertions on the test island: that a raft on dry ground behaves like ground, and
## that a raft in the water beside it behaves like water.
##
## The scene exists to put those two behaviours side by side, so this suite's job is to prove
## they are genuinely different rather than merely both present. That distinction is what makes
## the checks below stricter than they first look.
##
## [b]A dry raft and a broken raft report the same number.[/b]
## [method BuoyantBody._physics_process] returns immediately when [member BuoyantBody.ocean] is
## unset, which leaves [method BuoyantBody.submersion] at its initial 0.0 — exactly what a
## correctly dry raft reports. Asserting "the land raft is dry" therefore passes just as happily
## on a raft that is not simulating at all. Every dryness check here is paired with proof that
## the body is live: its ocean resolves to the scene's own, it is not frozen, it has a usable
## hull, and it FELL onto the deck rather than being placed there.
##
## [b]The island is measured, not described.[/b] The deck the raft's resting position is checked
## against is found by casting a ray down onto it, so the suite asks what is under the raft
## rather than what shape the scene says the island is. A box, a sloped beach and a heightmap all
## answer that question; reading [code]BoxShape3D.size[/code] answers it for the box alone, and
## answers it wrongly and silently for the rest. The one dimension still asserted outright is the
## plateau's height, because the scene exists to provide dry ground and the raft's resting height
## is predicted from it.
##
## Sea state matters to one check only, and it is not the sea state the wave field ships with.
## [WaveField] defaults to 10 m/s of wind, but the scene's [WeatherController] applies its first
## preset on ready, and Sunny sets 8.5 m/s — a significant height of 1.55 m and a worst-case
## crest of 1.29 m, against the wave field's own 2.14 m and the 2.2 m a reading of the defaults
## would predict. The margin under the +4.0 deck is therefore asserted from the live wave field
## rather than from either number, which is also what keeps the check honest under the Stormy
## preset (19 m/s), where the sea washes over the island and a dry deck would be wrong to pass.
##
## Runs single-player and hosts nothing, so it holds no port and can run alongside any other
## suite.
##
## Run with:
## [codeblock lang=text]
## godot --path . --headless --script tools/verify_test_island.gd
## [/codeblock]
## Exits non-zero if any check fails, so it is usable from CI.

## Scene under test.
const SCENE_PATH: String = "res://scenes/test_island.tscn"

## Real seconds allowed before the run is abandoned.
const TIMEOUT_SECONDS: float = 120.0

## Simulated seconds for both rafts to settle.
##
## The land raft needs barely a second to fall its 0.8 m. This window is set by the water raft,
## which is seeded at a fixed draught into a moving sea and therefore starts out of equilibrium:
## it rings down, and the ringing is violent enough to be mistaken for the steady state. Traced
## frame by frame it is flung 1.6 m clear of the water at twelve seconds — fully out, 0.005
## submerged — falls at 4.4 m/s, plunges 1.4 m under at 0.9 submerged, and only then decays. By
## eighteen seconds it tracks the surface within 0.2 m at the 0.41 submersion its density
## predicts.
##
## Anything measured before that is a phase of the transient, not the behaviour being tested.
## Both this suite at twelve seconds and an earlier probe at six read a plausible-looking
## submersion — 0.697 and 0.449 — and neither was the raft's actual draught.
const SETTLE_SECONDS: float = 25.0

## Expected height of the raft hull's underside below the raft origin, in metres.
##
## The hull is a 3 m box lifted 0.304 m by its [code]Hull[/code] node, so its underside sits
## 1.5 - 0.304 below the origin. The scene is measured for this as well and the two compared:
## the settled height is predicted from this number, so if the hull changes, the prediction has
## to be seen to change with it rather than silently going stale.
const HULL_BOTTOM_DROP: float = 1.196

## Tolerance on the derived hull geometry, in metres.
const GEOMETRY_EPSILON: float = 0.001

## Tolerance on the land raft's settled height, in metres.
##
## Jolt lets resting bodies penetrate slightly rather than resolving contacts to exactly zero,
## so a settled body sits a few millimetres low. This stays far tighter than any failure it must
## catch, all of which are out by a metre or more: not falling at all (0.8 high), floating
## instead of resting, or sinking through the deck.
const LAND_REST_TOLERANCE: float = 0.15

## Simulated seconds the floating raft is watched for, after it has settled.
##
## The sea's peak wavelength is about 30 m, which in deep water is a period of 4.4 s. A window
## shorter than that cannot produce a mean — it returns one arbitrary phase of the cycle wearing
## a mean's name, which is the failure this sampling exists to avoid. This covers nearly three
## periods.
const SAMPLE_SECONDS: float = 12.0

## Largest mean draught error accepted for the floating raft, in metres.
##
## Measured against the sea surface at the raft's own position, with both averaged over the
## window so the phase lag of a heavy hull cancels. A 420 kg/m^3 hull displacing a 9 x 3 x 9.6 m
## box balances with its origin 0.033 m below the surface; the slack covers the asymmetry of a
## real spectrum, where crests are sharper than troughs.
const DRAUGHT_TOLERANCE: float = 0.6

## Submersion above which the hull counts as swamped rather than floating.
const SWAMPED_MAXIMUM: float = 0.9

## Submersion below which the hull has left the water rather than floating in it.
##
## Placed between two measured populations rather than picked as a round number. A settled raft's
## deepest trough over a twelve-second window reads 0.080, repeatably; a raft genuinely thrown
## clear of the water — which this scene's raft is, during its first eighteen seconds — reads
## 0.001 to 0.005. Anything between the two would be a raft skimming the surface, which is a
## failure whichever way it is described.
const AFLOAT_MINIMUM: float = 0.02

## Least submersion a floating raft must report.
##
## A 420 kg/m^3 hull in 1025 kg/m^3 water settles at about 0.41 submerged. Below this band it is
## not floating: it is resting on something, or not simulating.
const FLOATING_MINIMUM: float = 0.2

## Most submersion a floating raft may report before it counts as sinking.
const FLOATING_MAXIMUM: float = 0.75

## Largest submersion a raft on dry ground may report.
const DRY_MAXIMUM: float = 0.001

## Least upright a settled raft must be, as the dot of its up axis with world up.
const UPRIGHT_MINIMUM: float = 0.9

## Height the island's plateau is expected at, in metres.
##
## The one number about the island's shape this suite still pins, because the scene's whole
## premise is dry ground clear of the sea, and because the raft's resting height is predicted
## from it. Everything else about the island — footprint, thickness, whether its sides are
## vertical — is the scene's own business and is measured rather than asserted.
const DECK_TOP_EXPECTED: float = 4.0

## Tolerance on the probed deck height, in metres.
const DECK_TOP_TOLERANCE: float = 0.01

## Height the ground is probed from and to, in metres.
##
## Must start clearly ABOVE the tallest ground the scene might grow. The island's collider is a
## trimesh generated from a height field — one vertex per column, with no sides and no underside
## — so it is an open sheet rather than a solid. A downward ray that starts below it has no
## geometry left to cross and returns nothing at all: not a wrong height, no hit. Sidedness is
## not the mechanism and `backface_collision` does not change it, which a peer measured directly
## — from 11 mm above the deck the ray hits, from 10 mm below it misses, identically either way.
const GROUND_PROBE_HEIGHT: float = 200.0

## Greatest fall accepted across the land raft's footprint before the ground counts as sloped.
const GROUND_FLATNESS: float = 0.05

## Least water beneath the floating raft for it to count as floating in open water, in metres.
##
## Deeper than the hull, so a raft "floating" while resting on a shoal cannot pass.
const DEEP_WATER_MINIMUM: float = 4.0

## How far the raft's visible model hangs below its collision hull, in metres.
##
## [b]This is accepted, not broken.[/b] The barrel model reaches 0.297 m below the box the hull
## is solved against, so a raft resting on solid ground stands with its barrels a third of a
## metre into that ground. On water — which is everywhere the raft is actually used — it cannot
## be seen, because the barrels are submerged to roughly this depth anyway.
##
## It is pinned here so it cannot drift further unnoticed, and so that nobody 'fixes' it by
## accident. Both obvious repairs cost more than the fault: lifting the model raises the visible
## deck away from [constant Raft.DECK_HEIGHT], which [method Raft.spawn_position] places boarding
## players against, and deepening the hull box changes the displaced volume that
## [member BuoyantBody.body_density] was tuned against, moving the draught in the shipping scene
## and every settling check written against it.
const MODEL_OVERHANG_BELOW: float = 0.297

## How far the visible model overhangs the hull sideways, in metres, along x and z.
##
## The same mismatch as [constant MODEL_OVERHANG_BELOW] and accepted on the same grounds; pinned
## so it drifts no further.
const MODEL_OVERHANG_X: float = 0.26
const MODEL_OVERHANG_Z: float = 0.19

## Tolerance on the pinned model overhangs, in metres.
##
## Loose enough that re-importing the .obj and nudging its bounds by a fraction of a millimetre
## does not fail a build, tight enough that any real change to the model or the hull does.
const OVERHANG_TOLERANCE: float = 0.01

var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	# Real time, not simulated: the watchdog exists to catch a run that has stopped advancing.
	create_timer(TIMEOUT_SECONDS).timeout.connect(func() -> void: quit(2))

	var packed := load(SCENE_PATH) as PackedScene
	if packed == null:
		_check("scene loads", false, SCENE_PATH)
		_finish()
		return

	var scene := packed.instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene
	await physics_frame

	if not _check_structure(scene):
		# Nothing below can run against a scene missing its own parts, so stop now rather than
		# crash on a null and sit out the watchdog.
		_finish()
		return

	var ocean := scene.get_node("Ocean") as Ocean
	var island := scene.get_node("Island") as StaticBody3D
	var land := scene.get_node("RaftOnLand") as Raft
	var water := scene.get_node("RaftOnWater") as Raft

	# The land raft being dry only means anything if the sea cannot reach the deck, so the sea is
	# measured first and the ground is then checked against it.
	var crest: float = ocean.wave_field.total_amplitude()
	var rafts: Array[RID] = [land.get_rid(), water.get_rid()]
	var deck_top := _check_ground(island, land, rafts, crest)
	_check_hull_geometry(land)
	_check_model_overhang(land)
	_check_live(land, "land raft", ocean)
	_check_live(water, "water raft", ocean)

	var land_start := land.global_position.y
	_check(
		"land raft starts above the deck",
		land_start - HULL_BOTTOM_DROP > deck_top,
		"origin %.3f m, deck %.2f m" % [land_start, deck_top]
	)

	await _wait_physics(SETTLE_SECONDS)

	# --- the raft on the ground ---
	var land_rest := land.global_position.y
	var expected_rest := deck_top + HULL_BOTTOM_DROP
	_check(
		"land raft settles on the deck",
		absf(land_rest - expected_rest) < LAND_REST_TOLERANCE,
		"origin %.3f m, expected %.3f m" % [land_rest, expected_rest]
	)
	_check(
		"land raft fell rather than being placed",
		land_start - land_rest > LAND_REST_TOLERANCE,
		"dropped %.3f m" % (land_start - land_rest)
	)
	var land_submersion := land.submersion()
	_check("land raft is dry", land_submersion <= DRY_MAXIMUM, land_submersion)
	var land_upright := land.global_basis.y.dot(Vector3.UP)
	_check("land raft stays upright", land_upright > UPRIGHT_MINIMUM, land_upright)

	# --- the raft on the water ---
	#
	# Sampled over a window rather than read once. A floating hull is oscillating, so any single
	# frame is a phase of that oscillation, and because the wave spectrum has fixed phases the
	# reading is REPRODUCIBLE without being representative: this raft reads 0.449 submerged after
	# six seconds of settling and 0.697 after twelve. A check written against one instant passes
	# forever until the tick rate or the settle time moves, and then fails for no reason anyone
	# can see. What the window measures instead is the equilibrium the hull oscillates about,
	# plus the extremes it never exceeds.
	var flotation := await _sample_flotation(water, ocean)
	var water_submersion: float = flotation["submersion_mean"]
	_check(
		"water raft floats",
		water_submersion > FLOATING_MINIMUM and water_submersion < FLOATING_MAXIMUM,
		"mean %.3f over %.0f s" % [water_submersion, SAMPLE_SECONDS]
	)
	_check(
		"water raft is never swamped",
		float(flotation["submersion_max"]) < SWAMPED_MAXIMUM,
		"peak %.3f" % flotation["submersion_max"]
	)
	_check(
		"water raft never leaves the water",
		float(flotation["submersion_min"]) > AFLOAT_MINIMUM,
		"trough %.3f" % flotation["submersion_min"]
	)
	# Averaging both the hull and the surface over the window cancels the phase lag, leaving the
	# draught the hull actually holds: a 420 kg/m^3 box floats with its origin about 0.03 m below
	# the surface, and anything else means it is not finding its own equilibrium.
	_check(
		"water raft holds its draught",
		absf(float(flotation["draught_mean"])) < DRAUGHT_TOLERANCE,
		"mean origin %.3f m below the surface" % -float(flotation["draught_mean"])
	)
	_check(
		"water raft stays upright",
		float(flotation["upright_minimum"]) > UPRIGHT_MINIMUM,
		"worst %.3f" % flotation["upright_minimum"]
	)
	# Floating is only being tested if the raft is over water deep enough to float in. Asked of
	# the ground directly rather than of the island's east face: a shoreline that slopes out to
	# meet the raft would leave it aground while every x it reported still looked clear.
	var water_position := water.global_position
	var sea_bed := _ground_height(island, Vector2(water_position.x, water_position.z), rafts)
	_check(
		"water raft floats over open water, not shallows",
		is_inf(sea_bed) or water_position.y - sea_bed > DEEP_WATER_MINIMUM,
		"sea bed %s" % ("none within reach" if is_inf(sea_bed) else "%.2f m down" % (
			water_position.y - sea_bed
		))
	)

	# --- the comparison the scene exists to make ---
	_check(
		"ground and water behave differently",
		land_submersion <= DRY_MAXIMUM and water_submersion > FLOATING_MINIMUM,
		"land %.3f vs water %.3f" % [land_submersion, water_submersion]
	)

	if DisplayServer.get_name() != "headless":
		await _save_overview(scene, island)

	_finish()


## Watches the floating raft for [constant SAMPLE_SECONDS] and returns what it did.
##
## Reports mean, least and greatest submersion; the mean draught, as the raft's origin relative
## to the sea surface at its own position; the worst uprightness; and the closest the raft came
## to the island. Sampling every physics frame is what separates the equilibrium from the
## oscillation about it — the two are indistinguishable from a single reading.
func _sample_flotation(raft: Raft, ocean: Ocean) -> Dictionary:
	var steps := ceili(SAMPLE_SECONDS * Engine.physics_ticks_per_second)
	var submersion_total := 0.0
	var submersion_least := INF
	var submersion_greatest := -INF
	var draught_total := 0.0
	var upright_least := INF
	var x_least := INF

	for _step: int in steps:
		await physics_frame
		var submersion := raft.submersion()
		submersion_total += submersion
		submersion_least = minf(submersion_least, submersion)
		submersion_greatest = maxf(submersion_greatest, submersion)

		var here := raft.global_position
		draught_total += here.y - ocean.get_water_height(Vector2(here.x, here.z))
		upright_least = minf(upright_least, raft.global_basis.y.dot(Vector3.UP))
		x_least = minf(x_least, here.x)

	var samples := float(steps)
	return {
		"submersion_mean": submersion_total / samples,
		"submersion_min": submersion_least,
		"submersion_max": submersion_greatest,
		"draught_mean": draught_total / samples,
		"upright_minimum": upright_least,
		"x_minimum": x_least,
	}


## Checks every node the suite depends on exists, returning whether all of them do.
func _check_structure(scene: Node3D) -> bool:
	var required: Array[String] = [
		"Ocean",
		"Ocean/FoamField",
		"Island",
		"Island/Collision",
		"Island/Mesh",
		"RaftOnLand",
		"RaftOnWater",
		"Camera",
		"Atmosphere",
		"Weather",
		"OceanSpray",
		"RainShower",
		"WaterReactions",
		"HUD/Help",
	]
	var missing: Array[String] = []
	for path: String in required:
		if scene.get_node_or_null(path) == null:
			missing.append(path)
	_check("scene has its parts", missing.is_empty(), ", ".join(missing))
	if not missing.is_empty():
		return false

	_check("root is named TestIsland", scene.name == "TestIsland", scene.name)
	var camera := scene.get_node("Camera")
	_check("camera is a free camera", camera is FreeCamera, camera.get_class())
	return (
		scene.get_node("Ocean") is Ocean
		and scene.get_node("RaftOnLand") is Raft
		and scene.get_node("RaftOnWater") is Raft
	)


## Checks the ground the land raft rests on, and returns its world height in metres.
##
## The height is found by casting a ray down onto the island rather than by reading its collision
## shape, which is what lets this outlive the island's current shape. A box, a sloped beach and a
## heightmap all answer the same question — what is under this spot, and how high is it — where
## reading [code]BoxShape3D.size[/code] answers it only for the box, and answers it wrongly and
## silently for anything else.
func _check_ground(island: StaticBody3D, land: Raft, rafts: Array[RID], crest: float) -> float:
	# The raft's mask is 3, so the island must be on a layer within it or the raft falls through.
	_check(
		"island collides with the raft",
		(island.collision_layer & 3) != 0,
		island.collision_layer
	)

	var here := Vector2(land.global_position.x, land.global_position.z)
	var deck_top := _ground_height(island, here, rafts)
	if is_inf(deck_top):
		_check("there is ground under the land raft", false, here)
		return 4.0

	# Given an explicit tolerance rather than is_equal_approx: this number now comes off a raycast
	# against a collider, not out of arithmetic, and lands a ten-thousandth high. That clears the
	# default epsilon by so little that a change of collider shape could fail it for precision
	# alone, which would say nothing about the deck.
	_check(
		"deck top is at +4 m",
		absf(deck_top - DECK_TOP_EXPECTED) < DECK_TOP_TOLERANCE,
		"%.4f m" % deck_top
	)
	# What has to hold for the raft to rest dry, whatever shape the island takes.
	_check("the deck stands above the sea", deck_top > crest, "%.2f m over a %.2f m crest" % [
		deck_top, crest
	])

	# A raft settling on a slope slides, and would come to rest somewhere this suite cannot
	# predict. Sampled around the raft's own footprint rather than across the island, because
	# that is the only part of the island the raft can tell anything about.
	var lowest := deck_top
	var highest := deck_top
	for offset: Vector2 in [Vector2(5, 0), Vector2(-5, 0), Vector2(0, 5), Vector2(0, -5)]:
		var sample := _ground_height(island, here + offset, rafts)
		if is_inf(sample):
			lowest = INF
			break
		lowest = minf(lowest, sample)
		highest = maxf(highest, sample)
	_check(
		"the raft rests on flat ground, not a slope",
		not is_inf(lowest) and absf(highest - lowest) < GROUND_FLATNESS,
		"%.3f m of fall across the raft's footprint" % (highest - lowest)
	)
	return deck_top


## Returns the height of the island's surface at [param world_xz], or INF where there is none.
##
## [param rafts] must list every raft in the scene. They sit on the island's own collision layer,
## so a probe that does not exclude them measures the hull it passes through on the way down and
## calls it ground: before they were excluded, the spot under the land raft read 7.80 m, which is
## that raft's own deck, and the sea bed under the floating raft read 1.87 m above the sea.
func _ground_height(island: StaticBody3D, world_xz: Vector2, rafts: Array[RID]) -> float:
	var space := island.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(world_xz.x, GROUND_PROBE_HEIGHT, world_xz.y),
		Vector3(world_xz.x, -GROUND_PROBE_HEIGHT, world_xz.y)
	)
	query.collision_mask = island.collision_layer
	query.exclude = rafts
	var hit := space.intersect_ray(query)
	return hit["position"].y if hit.has("position") else INF


## Checks the hull's underside sits where the resting prediction assumes it does.
func _check_hull_geometry(raft: Raft) -> void:
	var hull := raft.get_node("Hull") as CollisionShape3D
	var box := hull.shape as BoxShape3D
	if box == null:
		_check("raft hull is a box", false, hull.shape)
		return

	var drop := box.size.y * 0.5 - hull.position.y
	_check(
		"hull underside sits %.3f m below the raft origin" % HULL_BOTTOM_DROP,
		absf(drop - HULL_BOTTOM_DROP) < GEOMETRY_EPSILON,
		drop
	)


## Pins how far the raft's visible model overhangs the hull physics is solved against.
##
## Recorded as an accepted quantity rather than hunted as a bug — see
## [constant MODEL_OVERHANG_BELOW] for why both repairs cost more than the fault. What this
## catches is the overhang CHANGING: a re-export of the barrel model, or an edit to the hull box,
## either of which would move how deep the raft sits in the ground it rests on without anyone
## setting out to change it.
func _check_model_overhang(raft: Raft) -> void:
	var hull := raft.get_node("Hull") as CollisionShape3D
	var box := hull.shape as BoxShape3D
	var model := raft.get_node("Model") as MeshInstance3D
	if box == null or model == null or model.mesh == null:
		_check("raft has a hull and a model to compare", false)
		return

	# The model's own bounds, carried into the raft's space by its node transform.
	var bounds := model.mesh.get_aabb()
	var lowest := INF
	var widest_x := 0.0
	var widest_z := 0.0
	for index: int in 8:
		var corner: Vector3 = model.transform * bounds.get_endpoint(index)
		lowest = minf(lowest, corner.y)
		widest_x = maxf(widest_x, absf(corner.x))
		widest_z = maxf(widest_z, absf(corner.z))

	var below := (hull.position.y - box.size.y * 0.5) - lowest
	var over_x := widest_x - box.size.x * 0.5
	var over_z := widest_z - box.size.z * 0.5
	_check(
		"model hangs its accepted %.3f m below the hull" % MODEL_OVERHANG_BELOW,
		absf(below - MODEL_OVERHANG_BELOW) < OVERHANG_TOLERANCE,
		"%.3f m — accepted, not a fault; see MODEL_OVERHANG_BELOW" % below
	)
	_check(
		"model overhangs the hull by its accepted %.2f m in x" % MODEL_OVERHANG_X,
		absf(over_x - MODEL_OVERHANG_X) < OVERHANG_TOLERANCE,
		"%.3f m — accepted, not a fault" % over_x
	)
	_check(
		"model overhangs the hull by its accepted %.2f m in z" % MODEL_OVERHANG_Z,
		absf(over_z - MODEL_OVERHANG_Z) < OVERHANG_TOLERANCE,
		"%.3f m — accepted, not a fault" % over_z
	)


## Checks a raft is actually simulating, so that what it reports describes the water.
##
## Without this a raft with no ocean, or one frozen by the authority check in
## [method Raft._physics_process], reports 0.0 submersion and passes a dryness check while
## proving nothing at all.
func _check_live(raft: Raft, label: String, ocean: Ocean) -> void:
	_check("%s has its ocean" % label, raft.ocean == ocean, raft.ocean)
	_check("%s is not frozen" % label, not raft.freeze)
	_check("%s has a usable hull" % label, raft.hull_volume() > 0.0, raft.hull_volume())


## Saves an overview of both rafts, when there is a display to render it with.
func _save_overview(scene: Node3D, island: StaticBody3D) -> void:
	var free_camera := scene.get_node("Camera")
	free_camera.set_process(false)
	free_camera.set_process_unhandled_input(false)

	var camera := Camera3D.new()
	scene.add_child(camera)
	camera.global_position = island.global_position + Vector3(46, 62, 150)
	camera.look_at(island.global_position + Vector3(14, 0, 0))
	camera.current = true
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/test_island.png")


## Prints the tally and exits, non-zero if any check failed.
func _finish() -> void:
	print("verify_test_island: %d failures" % _failures)
	quit(1 if _failures else 0)


## Prints one result line, counting it if it failed.
func _check(label: String, condition: bool, detail: Variant = "") -> void:
	print("%s %s %s" % ["PASS" if condition else "FAIL", label, str(detail)])
	if not condition:
		_failures += 1


## Returns once the physics simulation has advanced by [param seconds].
func _wait_physics(seconds: float) -> void:
	var steps := ceili(seconds * Engine.physics_ticks_per_second)
	for _step: int in steps:
		await physics_frame
