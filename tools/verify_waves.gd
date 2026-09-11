extends SceneTree

## Headless assertions on the CPU wave field.
##
## The GPU displaces the ocean mesh while [WaveField] predicts where that surface is. If the
## two disagree, anything that floats sits at the wrong height and foam appears where
## nothing is breaking. These checks pin the properties that keep them in agreement and keep
## the surface physically plausible.
##
## Assertions target invariants rather than specific output values, so they survive
## refactoring: identical results before and after a rewrite prove it preserved behaviour.
## Where a quantity has a closed form and a sampled form — velocity, compression, wave
## height — both are computed and compared, which is what catches an analytic derivative
## quietly drifting away from the field it claims to describe.
##
## Run with:
## [codeblock lang=text]
## godot --path . --headless --script tools/verify_waves.gd
## [/codeblock]
## Exits non-zero if any check fails, so it is usable from CI.

## Column width for the check name, so results line up in the terminal.
const LABEL_WIDTH: int = 34

## Tolerance for checks that should be exact up to floating-point error.
const EPSILON: float = 0.001

## Step used by finite-difference comparisons against analytic derivatives.
const DERIVATIVE_STEP: float = 0.002


func _init() -> void:
	var field := WaveField.new()
	var failures := 0

	failures += _check_dispersion(field)
	failures += _check_spectrum_accessors(field)
	failures += _check_significant_wave_height(field)
	failures += _check_no_self_intersection(field)
	failures += _check_amplitude_bounds(field)
	failures += _check_normals_unit_and_upward(field)
	failures += _check_velocity_is_the_derivative(field)
	failures += _check_compression_is_the_jacobian(field)
	failures += _check_whitecaps_follow_steepness(field)
	failures += _check_phase_offsets_break_the_origin(field)
	failures += _check_surface_point_inversion(field)
	failures += _check_determinism(field)

	if failures == 0:
		print("\nAll wave checks PASSED")
	else:
		printerr("\n%d wave check(s) FAILED" % failures)

	quit(1 if failures > 0 else 0)


## Prints one result row and returns the number of failures it represents.
func _report(label: String, passed: bool, detail: String) -> int:
	print("%s  %s  %s" % ["PASS" if passed else "FAIL", label.rpad(LABEL_WIDTH), detail])
	return 0 if passed else 1


## Restores the field to the defaults the demo ships with.
func _reset(field: WaveField) -> void:
	field.wind_speed = 10.0
	field.wind_angle = 45.0
	field.wind_spread = 42.0
	field.steepness = 0.72
	field.amplitude_scale = 1.0
	field.wavelength_scale = 0.5
	field.speed = 1.0
	field.octave_ratio = 0.74


## Every octave must travel at the deep-water phase speed, c = sqrt(g / k).
##
## This is what makes the motion physical rather than an arbitrary scroll: speed follows
## from wavelength, so the long swell genuinely outruns the chop riding on it, and the
## spectrum never resolves into one rigidly translating pattern.
func _check_dispersion(field: WaveField) -> int:
	_reset(field)

	var worst_error := 0.0
	var monotonic := true
	var previous_speed := INF
	for octave in WaveField.WAVE_COUNT:
		var wave_number: float = TAU / field.octave_wavelength(octave)
		var expected: float = sqrt(WaveField.GRAVITY / wave_number)
		worst_error = maxf(worst_error, absf(field.octave_phase_speed(octave) - expected))
		monotonic = monotonic and field.octave_phase_speed(octave) < previous_speed
		previous_speed = field.octave_phase_speed(octave)

	return _report(
		"deep-water dispersion",
		worst_error < EPSILON and monotonic,
		"c(0)=%.2fm/s c(7)=%.2fm/s err=%.6f" % [
			field.octave_phase_speed(0),
			field.octave_phase_speed(WaveField.WAVE_COUNT - 1),
			worst_error,
		],
	)


## The per-octave accessors must describe the spectrum that is actually sampled.
##
## [method WaveField.sample_displacement] runs its own loop for speed, so the accessors are
## a second implementation of the same spectrum. Rebuilding the surface from them and
## comparing is what stops the two drifting apart — and the dispersion check above is only
## meaningful because this one holds.
func _check_spectrum_accessors(field: WaveField) -> int:
	_reset(field)

	var worst_error := 0.0
	for sample_index in 60:
		var position := Vector2(float(sample_index) * 2.7, float(sample_index) * -1.3)
		var time := float(sample_index) * 0.11
		var rebuilt := 0.0
		for octave in WaveField.WAVE_COUNT:
			var direction := field.octave_direction(octave)
			var wave_number: float = TAU / field.octave_wavelength(octave)
			var phase: float = (
				wave_number * (
					direction.dot(position) - field.octave_phase_speed(octave) * time * field.speed
				)
				+ field.octave_phase_offset(octave)
			)
			rebuilt += field.octave_amplitude(octave) * sin(phase)
		worst_error = maxf(worst_error, absf(rebuilt - field.sample_height(position, time)))

	return _report(
		"accessors match sampled surface",
		worst_error < EPSILON,
		"max height error=%.6f m" % worst_error,
	)


## The sampled surface must actually have the significant wave height it claims.
##
## Significant wave height is four times the standard deviation of surface elevation. The
## spectrum solves for the dominant amplitude that produces a requested height, so this
## measures the surface back and checks the solve was right — which is what lets
## [member WaveField.wind_speed] be quoted in the units a marine forecast uses.
func _check_significant_wave_height(field: WaveField) -> int:
	_reset(field)

	var sum := 0.0
	var sum_squared := 0.0
	var samples := 4000
	for sample_index in samples:
		# Irrational strides, so the samples do not land on a lattice of the wavelengths.
		var position := Vector2(float(sample_index) * 1.61803, float(sample_index) * -2.41421)
		var height := field.sample_height(position, float(sample_index) * 0.0731)
		sum += height
		sum_squared += height * height

	var mean := sum / float(samples)
	var deviation := sqrt(maxf(sum_squared / float(samples) - mean * mean, 0.0))
	var measured := 4.0 * deviation
	var expected := field.significant_wave_height()
	var error := absf(measured - expected) / maxf(expected, 0.0001)

	return _report(
		"significant wave height",
		error < 0.05,
		"measured=%.3fm expected=%.3fm (%.1f%%)" % [measured, expected, error * 100.0],
	)


## The summed surface must never fold back through itself, even at maximum steepness.
##
## A Gerstner wave self-intersects once its horizontal displacement gradient exceeds 1.
## [WaveField] caps displacement across the spectrum to prevent it; this verifies the
## horizontal Jacobian stays positive, which is the condition for the surface remaining
## single-valued — and therefore for the analytic normals meaning anything.
func _check_no_self_intersection(field: WaveField) -> int:
	_reset(field)
	field.wind_speed = 28.0
	field.steepness = 1.0
	field.wavelength_scale = 0.2

	var worst := INF
	for sample_index in 600:
		var position := Vector2(float(sample_index) * 0.37, float(sample_index) * 0.21)
		worst = minf(worst, field.sample_jacobian(position, 3.0))

	return _report(
		"no self-intersection (max steep)",
		worst > 0.0,
		"min jacobian=%.4f (must be > 0)" % worst,
	)


## Displacement must stay within the summed amplitude of the spectrum.
func _check_amplitude_bounds(field: WaveField) -> int:
	_reset(field)

	var bound := field.total_amplitude()
	var peak := 0.0
	for sample_index in 400:
		var position := Vector2(float(sample_index) * 1.7, float(sample_index) * 0.9)
		peak = maxf(peak, absf(field.sample_height(position, float(sample_index) * 0.05)))

	return _report(
		"height within amplitude bound",
		peak <= bound + 0.0001,
		"peak=%.4f bound=%.4f" % [peak, bound],
	)


## Normals must be unit length and point out of the water, never into it.
func _check_normals_unit_and_upward(field: WaveField) -> int:
	_reset(field)
	field.wind_speed = 18.0
	field.steepness = 0.95

	var worst_length_error := 0.0
	var lowest_upward := 1.0
	for sample_index in 300:
		var position := Vector2(float(sample_index) * 2.3, float(sample_index) * -1.1)
		var normal := field.sample_normal(position, float(sample_index) * 0.07)
		worst_length_error = maxf(worst_length_error, absf(normal.length() - 1.0))
		lowest_upward = minf(lowest_upward, normal.y)

	return _report(
		"normals unit + upward",
		worst_length_error < EPSILON and lowest_upward > 0.0,
		"len err=%.6f min n.y=%.4f" % [worst_length_error, lowest_upward],
	)


## Water velocity must be the exact time derivative of the surface it belongs to.
##
## Buoyancy drags a floating body against this, so an error here does not look like a wrong
## number — it looks like objects being shoved by a current that is not there.
func _check_velocity_is_the_derivative(field: WaveField) -> int:
	_reset(field)

	var worst_error := 0.0
	for sample_index in 200:
		var position := Vector2(float(sample_index) * 3.7, float(sample_index) * 2.1)
		var time := float(sample_index) * 0.13
		var ahead := field.sample_displacement(position, time + DERIVATIVE_STEP)
		var behind := field.sample_displacement(position, time - DERIVATIVE_STEP)
		var numeric := (ahead - behind) / (2.0 * DERIVATIVE_STEP)
		var analytic := field.sample_velocity(position, time)
		worst_error = maxf(worst_error, (numeric - analytic).length())

	return _report(
		"velocity is d(displacement)/dt",
		worst_error < 0.01,
		"max error=%.6f m/s" % worst_error,
	)


## Surface compression must be the true Jacobian of the horizontal displacement field.
##
## Foam is sourced from this, so if it is wrong the whitecaps land somewhere other than
## where the water is actually piling up — which is exactly the failure that makes stylised
## foam look painted on.
func _check_compression_is_the_jacobian(field: WaveField) -> int:
	_reset(field)

	var step := 0.01
	var worst_error := 0.0
	for sample_index in 200:
		var position := Vector2(float(sample_index) * 1.9, float(sample_index) * -3.3)
		var time := float(sample_index) * 0.09

		var dx := (
			field.sample_displacement(position + Vector2(step, 0.0), time)
			- field.sample_displacement(position - Vector2(step, 0.0), time)
		) / (2.0 * step)
		var dz := (
			field.sample_displacement(position + Vector2(0.0, step), time)
			- field.sample_displacement(position - Vector2(0.0, step), time)
		) / (2.0 * step)

		# det(I + gradient) of the horizontal displacement.
		var numeric := (1.0 + dx.x) * (1.0 + dz.z) - dx.z * dz.x
		worst_error = maxf(worst_error, absf(numeric - field.sample_jacobian(position, time)))

	return _report(
		"compression is the jacobian",
		worst_error < 0.01,
		"max error=%.6f" % worst_error,
	)


## Steeper seas must break over more of their surface, and a flat calm must not break at all.
##
## This is the behaviour that decides whether foam looks like weather. Whitecap coverage is
## a consequence of steepness in a real sea, not an independent slider, so it has to move
## when steepness does.
func _check_whitecaps_follow_steepness(field: WaveField) -> int:
	var threshold := 0.8
	var coverage := PackedFloat32Array()

	for steepness in [0.0, 0.4, 1.0] as Array[float]:
		_reset(field)
		field.wind_speed = 20.0
		field.wavelength_scale = 0.28
		field.steepness = steepness

		var breaking := 0
		var samples := 2000
		for sample_index in samples:
			var position := Vector2(float(sample_index) * 1.31, float(sample_index) * -0.77)
			if field.sample_jacobian(position, float(sample_index) * 0.037) < threshold:
				breaking += 1
		coverage.append(float(breaking) / float(samples))

	var passed := coverage[0] == 0.0 and coverage[1] > 0.0 and coverage[2] > coverage[1]
	return _report(
		"whitecaps follow steepness",
		passed,
		"coverage: calm=%.1f%% mid=%.1f%% steep=%.1f%%" % [
			coverage[0] * 100.0, coverage[1] * 100.0, coverage[2] * 100.0,
		],
	)


## The spectrum must not stack into one spike at the world origin at t = 0.
##
## Without per-octave phase offsets every wave crests together there, producing a single
## implausible peak that then travels outward as a visible ring — the artefact that gives
## away a procedural ocean the moment the camera sits near the origin.
func _check_phase_offsets_break_the_origin(field: WaveField) -> int:
	_reset(field)

	var origin_height := absf(field.sample_height(Vector2.ZERO, 0.0))
	var stacked := field.total_amplitude()

	return _report(
		"no spike at the origin",
		origin_height < stacked * 0.5,
		"origin=%.3fm vs stacked=%.3fm" % [origin_height, stacked],
	)


## The surface point above a column must land back on the column it was queried for.
func _check_surface_point_inversion(field: WaveField) -> int:
	_reset(field)
	field.steepness = 0.9

	var worst_error := 0.0
	for sample_index in 100:
		var query := Vector2(float(sample_index) * 3.1, float(sample_index) * 1.7)
		var point := field.sample_surface_point(query, 5.0)
		worst_error = maxf(worst_error, absf(point.x - query.x) + absf(point.z - query.y))

	return _report(
		"surface point inversion",
		worst_error < 0.0001,
		"max xz error=%.6f" % worst_error,
	)


## Sampling must be a pure function of position and time, with no accumulated state.
func _check_determinism(field: WaveField) -> int:
	_reset(field)

	var probe := Vector2(12.5, -7.25)
	var before := field.sample_displacement(probe, 4.0)

	for _iteration in 50:
		field.sample_displacement(Vector2(randf() * 100.0, randf() * 100.0), randf() * 10.0)

	var after := field.sample_displacement(probe, 4.0)

	return _report(
		"deterministic sampling",
		before.is_equal_approx(after),
		"%.6f vs %.6f" % [before.y, after.y],
	)
