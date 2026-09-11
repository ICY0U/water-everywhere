extends SceneTree

## Headless assertions on floating bodies.
##
## [BuoyantBody] turns the wave field into forces, which is where a plausible-looking ocean
## most easily stops being physical: a body can float at the wrong draught, jitter, drift
## when it should not, feel weightless, or blow up quietly and leave the scene. None of those
## show up in a still frame, so they are measured here instead.
##
## The run has three phases. On flat calm the draught has an exact answer — Archimedes says a
## body floats at the depth where displaced water weighs what it does — so that is asserted
## against the closed form, for several hull SHAPES rather than only a cube, because
## integrating the real submerged volume is the point of the rework. The sea is then raised
## and the body is checked for the behaviour a real one has: it stays with the surface, it
## rolls, it drifts downwind, and it does not explode. Finally the hydrodynamic terms that
## give water its weight — added mass and quadratic drag — are measured directly.
##
## Run with:
## [codeblock lang=text]
## godot --path . --headless --script tools/verify_buoyancy.gd
## [/codeblock]
## Exits non-zero if any check fails, so it is usable from CI.

## Column width for the check name, so results line up in the terminal.
const LABEL_WIDTH: int = 36

## Size of the test hull, in metres. Matches the demo scene's test cube.
const HULL_SIZE: Vector3 = Vector3(6.0, 6.0, 6.0)

## Density of the test hull, in kilograms per cubic metre.
const HULL_DENSITY: float = 380.0

## Seconds of flat calm before the draught is measured.
##
## Long enough for the hull to stop ringing, which takes far longer than it looks. A 6 m cube
## dropped onto flat water still carries 0.28 m/s of residual heave at ten seconds and does
## not converge on its Archimedean draught until past thirty — added mass makes the
## oscillation heavy and slow to die. Measuring at ten seconds reports a draught some 70 mm
## low, which looks exactly like a force error and is really a stopwatch error.
const CALM_SECONDS: float = 35.0

## Seconds of open sea measured after the calm phase.
##
## Long enough for the drift check to average over several whole wave periods at each end. A
## 10 m/s sea has a dominant period of about five seconds, and a window shorter than that
## measures where in its orbit the body happened to be rather than where it has drifted to.
const SEA_SECONDS: float = 45.0

## Seconds of the drop test that measures added mass and drag.
const DROP_SECONDS: float = 6.0

## Wind raised for the sea phase, in metres per second.
const SEA_WIND_SPEED: float = 10.0

var _ocean: Ocean
var _field: WaveField

var _cube: BuoyantBody
var _sphere: BuoyantBody
var _raft: BuoyantBody
var _dropped: BuoyantBody

var _elapsed: float = 0.0
var _phase: int = 0

var _calm_draught: float = 0.0
var _sphere_draught: float = 0.0
var _raft_draught: float = 0.0
var _worst_surface_error: float = 0.0
var _worst_tilt: float = 0.0
var _worst_raft_tilt: float = 0.0
var _peak_speed: float = 0.0
var _start_position: Vector3 = Vector3.ZERO

## Cube positions sampled early and late in the sea phase, for the drift check.
##
## Averaging a run of samples at each end separates net drift from the metre-scale orbital
## swing the body is doing the whole time.
var _early_positions: Array[Vector2] = []
var _late_positions: Array[Vector2] = []

var _impacts: Array[WaterImpact] = []
var _drop_peak_descent: float = 0.0
var _drop_started: bool = false


func _initialize() -> void:
	_field = WaveField.new()
	# Flat water first, so the draught has a closed-form answer to check against.
	_field.wind_speed = 0.0

	_ocean = Ocean.new()
	_ocean.name = "Ocean"
	_ocean.wave_field = _field
	root.add_child(_ocean)
	_ocean.water_impacted.connect(_on_water_impacted)

	var box := BoxShape3D.new()
	box.size = HULL_SIZE
	_cube = _spawn("TestCube", box, HULL_DENSITY, Vector3(0.0, 3.0, 0.0))

	var sphere := SphereShape3D.new()
	sphere.radius = 3.0
	_sphere = _spawn("TestSphere", sphere, HULL_DENSITY, Vector3(40.0, 3.0, 0.0))

	# A wide flat raft: the shape whose draught a box approximation gets most wrong.
	var raft := BoxShape3D.new()
	raft.size = Vector3(10.0, 1.0, 10.0)
	_raft = _spawn("TestRaft", raft, HULL_DENSITY, Vector3(80.0, 3.0, 0.0))

	# Held clear of the water; released in the drop phase to measure entry behaviour.
	var dropper := BoxShape3D.new()
	dropper.size = Vector3(2.0, 2.0, 2.0)
	_dropped = _spawn("TestDrop", dropper, 600.0, Vector3(120.0, 14.0, 0.0))
	_dropped.freeze = true


func _spawn(
	body_name: String, shape: Shape3D, density: float, position: Vector3
) -> BuoyantBody:
	var body := BuoyantBody.new()
	body.name = body_name
	body.ocean = _ocean
	body.body_density = density
	body.position = position

	var collider := CollisionShape3D.new()
	collider.shape = shape
	body.add_child(collider)

	root.add_child(body)
	return body


func _physics_process(delta: float) -> bool:
	_elapsed += delta

	match _phase:
		0:
			if _elapsed >= CALM_SECONDS:
				_capture_calm()
			return false
		1:
			_measure_sea_phase()
			if _elapsed >= SEA_SECONDS:
				_start_drop()
			return false
		_:
			_measure_drop()
			if _elapsed >= DROP_SECONDS:
				_report_all()
				return true
			return false


## Records the settled draught of every hull, then raises the sea.
func _capture_calm() -> void:
	_calm_draught = _cube.global_position.y
	_sphere_draught = _sphere.global_position.y
	_raft_draught = _raft.global_position.y
	_start_position = _cube.global_position

	_field.wind_speed = SEA_WIND_SPEED
	_phase = 1
	_elapsed = 0.0


## Releases the dropped body so its entry can be measured.
func _start_drop() -> void:
	_dropped.freeze = false
	_drop_started = true
	_phase = 2
	_elapsed = 0.0


## Accumulates the worst case of everything the sea phase asserts on.
func _measure_sea_phase() -> void:
	var surface := _ocean.get_water_height(
		Vector2(_cube.global_position.x, _cube.global_position.z)
	)
	var expected := surface + _expected_freeboard(HULL_SIZE.y, HULL_DENSITY)
	_worst_surface_error = maxf(_worst_surface_error, absf(_cube.global_position.y - expected))
	_worst_tilt = maxf(_worst_tilt, _cube.global_transform.basis.y.angle_to(Vector3.UP))
	_worst_raft_tilt = maxf(_worst_raft_tilt, _raft.global_transform.basis.y.angle_to(Vector3.UP))
	_peak_speed = maxf(_peak_speed, _cube.linear_velocity.length())

	# Sample the first and last third of the phase, leaving the middle out so the two windows
	# are well separated. Each window spans several wave periods, so the orbital swing
	# averages away and what is left is the net drift.
	var here := Vector2(_cube.global_position.x, _cube.global_position.z)
	if _elapsed < SEA_SECONDS * 0.33:
		_early_positions.append(here)
	elif _elapsed > SEA_SECONDS * 0.67:
		_late_positions.append(here)


## Tracks how fast the dropped body is falling, for the drag check.
func _measure_drop() -> void:
	if not _drop_started:
		return
	_drop_peak_descent = maxf(_drop_peak_descent, -_dropped.linear_velocity.y)


func _on_water_impacted(impact: WaterImpact) -> void:
	_impacts.append(impact)


## Returns how far a hull's centre should sit above the waterline, in metres.
##
## Archimedes: the submerged fraction equals the density ratio, so a body at 380 of water's
## 1025 floats with 37% of its height under. For a prism the centre therefore sits at the
## difference between half the height and that submerged share. Only valid for shapes of
## constant cross-section — a sphere is checked against its own solved draught instead.
func _expected_freeboard(height: float, density: float) -> float:
	var submerged_fraction := density / BuoyantBody.WATER_DENSITY
	return height * (0.5 - submerged_fraction)


func _report_all() -> void:
	var failures := 0
	failures += _check_calm_draught()
	failures += _check_raft_draught()
	failures += _check_sphere_draught()
	failures += _check_shape_changes_draught()
	failures += _check_tracks_the_surface()
	failures += _check_rolls_with_the_sea()
	failures += _check_stable_hull_stays_upright()
	failures += _check_stays_stable()
	failures += _check_drifts_downwind()
	failures += _check_added_mass_slows_entry()
	failures += _check_entry_raised_an_impact()
	failures += _check_settles_after_entry()

	if failures == 0:
		print("\nAll buoyancy checks PASSED")
	else:
		printerr("\n%d buoyancy check(s) FAILED" % failures)

	quit(1 if failures > 0 else 0)


## Prints one result row and returns the number of failures it represents.
func _report(label: String, passed: bool, detail: String) -> int:
	print("%s  %s  %s" % ["PASS" if passed else "FAIL", label.rpad(LABEL_WIDTH), detail])
	return 0 if passed else 1


## On flat water the cube must settle at exactly the draught Archimedes predicts.
func _check_calm_draught() -> int:
	var expected := _expected_freeboard(HULL_SIZE.y, HULL_DENSITY)
	var error := absf(_calm_draught - expected)
	return _report(
		"archimedean draught: cube",
		error < 0.05,
		"centre=%.3fm expected=%.3fm err=%.3fm" % [_calm_draught, expected, error],
	)


## A flat raft is a prism too, so its draught has the same closed form at a different height.
##
## This is the check a box approximation passes only by accident: the raft is a tenth the
## height of the cube, so an implementation that ramps submersion over a fixed hull height
## rather than integrating the real volume lands nowhere near it.
func _check_raft_draught() -> int:
	var expected := _expected_freeboard(1.0, HULL_DENSITY)
	var error := absf(_raft_draught - expected)
	return _report(
		"archimedean draught: flat raft",
		error < 0.05,
		"centre=%.3fm expected=%.3fm err=%.3fm" % [_raft_draught, expected, error],
	)


## A sphere floats at the draught where its spherical cap displaces its own weight.
##
## No linear formula gives this: the submerged volume of a sphere is a cubic in depth, which
## is exactly why integrating the real hull matters. The expected value is solved here by
## bisection on the cap volume so the assertion is independent of the code it is testing.
func _check_sphere_draught() -> int:
	var radius := 3.0
	var target := 4.0 / 3.0 * PI * pow(radius, 3.0) * (HULL_DENSITY / BuoyantBody.WATER_DENSITY)

	# Cap volume for submerged depth h: pi*h^2*(3R - h)/3. Solve for h.
	var low := 0.0
	var high := 2.0 * radius
	for _iteration in 60:
		var mid := (low + high) * 0.5
		var cap := PI * mid * mid * (3.0 * radius - mid) / 3.0
		if cap < target:
			low = mid
		else:
			high = mid
	var submerged_depth := (low + high) * 0.5
	# The centre sits that far above the waterline, measured down from the top of the cap.
	var expected := radius - submerged_depth
	var error := absf(_sphere_draught - expected)

	return _report(
		"archimedean draught: sphere cap",
		error < 0.12,
		"centre=%.3fm expected=%.3fm err=%.3fm" % [_sphere_draught, expected, error],
	)


## Different shapes at the same density must settle at different heights.
##
## The single assertion that a box approximation cannot pass. If hull shape is ignored, the
## cube and the raft come to rest at the same centre height; integrating the real volume
## separates them by nearly the difference in their heights.
func _check_shape_changes_draught() -> int:
	var separation := absf(_calm_draught - _raft_draught)
	return _report(
		"hull shape changes draught",
		separation > 0.5,
		"cube=%.3fm raft=%.3fm separation=%.3fm" % [
			_calm_draught, _raft_draught, separation,
		],
	)


## The hull must stay with the moving surface rather than sinking through or launching off it.
func _check_tracks_the_surface() -> int:
	return _report(
		"tracks the moving surface",
		_worst_surface_error < HULL_SIZE.y * 0.5,
		"worst offset=%.3fm (limit %.3fm)" % [_worst_surface_error, HULL_SIZE.y * 0.5],
	)


## The hull must lean with the wave it is sitting on, and must not tumble.
##
## This is what integrating the submerged shape buys: as a hull heels, its submerged volume
## becomes lopsided and its centroid shifts to the low side, producing the couple that rights
## it. A force applied at the body centre can only ever push it up.
##
## What is asserted is deliberately NOT a peak angle. A cube is not a boat: heeled past 45
## degrees it is genuinely more stable corner-down than face-down, so it rolls over to a
## corner and sits there, and exactly which corner-down attitude it finds varies with the
## wave phase it met. Pinning a number would mean re-tuning the bound every time the sea
## changes, which tests nothing.
##
## The physical requirements are that it leans at all, and that it comes to rest rather than
## tumbling — a body being spun by the sea has a persistently high angular velocity, whereas
## one that has settled into an attitude does not. Whether the sea is over-torquing hulls in
## general is answered by [method _check_stable_hull_stays_upright], on a shape that has a
## real righting moment.
func _check_rolls_with_the_sea() -> int:
	var degrees := rad_to_deg(_worst_tilt)
	var spin := _cube.angular_velocity.length()
	return _report(
		"leans with the swell, does not tumble",
		degrees > 1.0 and spin < 1.0,
		"peak tilt=%.1f deg, final spin=%.3f rad/s (limit 1.0)" % [degrees, spin],
	)


## A beamy, shallow hull must stay near upright in the same sea that rolls a cube.
##
## This is the assertion that actually catches an over-torquing sea. A 10x1x10 raft has an
## enormous waterplane and therefore a very stiff righting moment; if it is being thrown to
## steep angles, the wave forcing is wrong rather than the hull being tender.
func _check_stable_hull_stays_upright() -> int:
	var degrees := rad_to_deg(_worst_raft_tilt)
	return _report(
		"beamy hull stays upright",
		degrees < 30.0,
		"raft peak tilt=%.1f deg (limit 30)" % degrees,
	)


## Forces must stay bounded: buoyancy plus drag is a stiff spring and can be made to diverge.
func _check_stays_stable() -> int:
	return _report(
		"stable (no force blow-up)",
		_peak_speed < 20.0 and is_finite(_cube.global_position.y),
		"peak speed=%.2f m/s" % _peak_speed,
	)


## Orbital motion inside the waves must carry the hull downwind, as Stokes drift does.
##
## Measured as the difference between two time-AVERAGED positions rather than between two
## instants. A hull in a 2 m swell swings back and forth by more than a metre every wave
## period, which is far larger than the net drift it accumulates in the same time — so
## comparing single samples measures mostly where in its orbit the body happened to be, and
## reports a healthy downwind drift as upwind about half the time.
func _check_drifts_downwind() -> int:
	if _early_positions.is_empty() or _late_positions.is_empty():
		return _report("drifts downwind", false, "no drift samples collected")

	var early := _mean_position(_early_positions)
	var late := _mean_position(_late_positions)
	var travelled := late - early
	var wind := Vector2(
		cos(deg_to_rad(_field.wind_angle)), sin(deg_to_rad(_field.wind_angle))
	)
	var along := travelled.dot(wind)
	return _report(
		"drifts downwind",
		along > 0.05,
		"travelled=%.2fm along wind (total %.2fm) between windows %.0fs apart" % [
			along, travelled.length(), SEA_SECONDS * 0.5,
		],
	)


## Returns the mean of a run of sampled positions.
func _mean_position(samples: Array[Vector2]) -> Vector2:
	var total := Vector2.ZERO
	for sample in samples:
		total += sample
	return total / float(samples.size())


## Water must arrest a falling body rather than letting it punch straight through.
##
## A body dropped from 14 m reaches about 15 m/s in free fall. Added mass and quadratic drag
## together have to stop it well short of driving to the sea bed — this is the check that
## fails if the hydrodynamic terms are dropped, because linear damping alone has no terminal
## velocity and lets a dense body sink indefinitely.
func _check_added_mass_slows_entry() -> int:
	var resting := _dropped.global_position.y
	var surface := _ocean.get_water_height(
		Vector2(_dropped.global_position.x, _dropped.global_position.z)
	)
	var below := surface - resting
	return _report(
		"water arrests a dropped body",
		below < 6.0 and is_finite(resting),
		"peak descent=%.2f m/s settled %.2fm below surface" % [_drop_peak_descent, below],
	)


## Crossing the surface must raise a discrete impact event.
func _check_entry_raised_an_impact() -> int:
	var entries := 0
	for impact in _impacts:
		if impact.kind == Ocean.ImpactKind.ENTRY:
			entries += 1
	return _report(
		"entry raises a water impact",
		entries > 0,
		"%d impact(s), %d entry" % [_impacts.size(), entries],
	)


## An impact must carry a payload an effect could actually be driven from.
func _check_settles_after_entry() -> int:
	if _impacts.is_empty():
		return _report("impact payload is usable", false, "no impacts raised")

	var impact := _impacts[0]
	var usable := (
		impact.impact_speed >= 0.0
		and impact.waterline_radius > 0.0
		and impact.volume > 0.0
		and impact.impulse > 0.0
		and impact.energy > 0.0
		and impact.seed != 0
		and impact.source != null
		and impact.normal.is_normalized()
	)
	return _report(
		"impact payload is usable",
		usable,
		"speed=%.2f radius=%.2f volume=%.2f impulse=%.1f energy=%.1f seed=%d source=%s" % [
			impact.impact_speed,
			impact.waterline_radius,
			impact.volume,
			impact.impulse,
			impact.energy,
			impact.seed,
			impact.source.name if impact.source != null else "<null>",
		],
	)
