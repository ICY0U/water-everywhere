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

## Files that each keep their own copy of the wave spectrum's fixed constants.
##
## The CPU copy comes first: it is the one the checks above pin to physical behaviour, so it is
## treated as the reference the GPU copies must match.
const SPECTRUM_SOURCES: Array[String] = [
	"res://scripts/wave_field.gd",
	"res://shaders/gerstner_waves.gdshaderinc",
	"res://shaders/foam_sim.gdshader",
]

## Spectrum constants that must hold the same numbers everywhere, and what each source calls
## them. One row per quantity; the names run in the same order as [constant SPECTRUM_SOURCES].
##
## The spellings differ because the include prefixes its globals with [code]WAVE_[/code] to
## avoid colliding with the shaders that include it. Keying on one spelling would find nothing
## in the other two files and pass for the wrong reason.
const SPECTRUM_CONSTANTS: Array[Array] = [
	["GRAVITY", "WAVE_GRAVITY", "GRAVITY"],
	["WAVE_COUNT", "WAVE_COUNT", "WAVE_COUNT"],
	["OCTAVE_DIRECTION_OFFSETS", "WAVE_DIRECTION_OFFSETS", "OCTAVE_DIRECTION_OFFSETS"],
	["OCTAVE_PHASES", "WAVE_PHASES", "OCTAVE_PHASES"],
	["LONGEST_WAVE_SPREAD", "WAVE_LONGEST_SPREAD", "LONGEST_WAVE_SPREAD"],
]

## Short name for each row of [constant SPECTRUM_CONSTANTS], for the result rows. The constants'
## own names are too long to line up, and differ per source anyway.
const SPECTRUM_LABELS: Array[String] = [
	"gravity", "wave count", "direction offsets", "phases", "longest spread",
]

## The surface shader, which is expected to take the spectrum from [constant SPECTRUM_INCLUDE]
## rather than keep its own copy.
const OCEAN_SHADER: String = "res://shaders/ocean.gdshader"

## The shared GPU source of truth for the spectrum.
const SPECTRUM_INCLUDE: String = "res://shaders/gerstner_waves.gdshaderinc"


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
	failures += _check_spectrum_copies_agree()
	failures += _check_ocean_keeps_no_stale_spectrum()

	if failures == 0:
		print("\nAll wave checks PASSED")
	else:
		printerr("\n%d wave check(s) FAILED" % failures)

	quit(1 if failures > 0 else 0)


## Prints one result row and returns the number of failures it represents.
func _report(label: String, passed: bool, detail: String) -> int:
	print("%s  %s  %s" % ["PASS" if passed else "FAIL", label.rpad(LABEL_WIDTH), detail])
	return 0 if passed else 1


## Checks every source in [constant SPECTRUM_SOURCES] holds the same spectrum constants.
##
## The spectrum is written out three times, in two languages. `ocean.gdshader` now takes its
## copy from the include, but `foam_sim.gdshader` keeps its own deliberately: it needs only the
## two tables and a horizontal-only compression, where the include computes a full 3D frame for
## every texel of the simulation buffer. That is a sound trade, and it leaves copies that must
## agree bit for bit.
##
## `verify_spray.gd` compares the include against the CPU by rendering both, which is the
## stronger check where it reaches — but it never evaluates `foam_sim.gdshader`, so a typo in
## foam's tables would show up as foam appearing where no crest is breaking and nothing would
## fail. This compares the numbers as written instead, which costs nothing and covers all three.
func _check_spectrum_copies_agree() -> int:
	var failures := 0
	var sources: Array[String] = []
	for path: String in SPECTRUM_SOURCES:
		sources.append(FileAccess.get_file_as_string(path))

	for row: int in SPECTRUM_CONSTANTS.size():
		var names: Array = SPECTRUM_CONSTANTS[row]
		var reference := _spectrum_numbers(sources[0], names[0], SPECTRUM_SOURCES[0])
		var problems := PackedStringArray()
		if reference.is_empty():
			problems.append("%s not found in %s" % [names[0], SPECTRUM_SOURCES[0].get_file()])
		elif reference.size() > 1 and reference.size() != WaveField.WAVE_COUNT:
			problems.append("%s has %d entries, expected WAVE_COUNT" % [names[0], reference.size()])

		for index: int in range(1, SPECTRUM_SOURCES.size()):
			var path: String = SPECTRUM_SOURCES[index]
			var copy := _spectrum_numbers(sources[index], names[index], path)
			if copy.is_empty():
				problems.append("%s not found in %s" % [names[index], path.get_file()])
			elif copy != reference:
				problems.append("%s in %s is %s" % [names[index], path.get_file(), copy])

		var detail := "%d value(s) across %d sources" % [
			reference.size(), SPECTRUM_SOURCES.size()
		]
		if not problems.is_empty():
			detail = ", ".join(problems)
		failures += _report(
			"%s copies agree" % SPECTRUM_LABELS[row], problems.is_empty(), detail
		)
	return failures


## Checks [constant OCEAN_SHADER] has not grown a private copy of the spectrum that drifts.
##
## The surface shader used to keep its own copy of these constants, and that copy was collapsed
## onto [constant SPECTRUM_INCLUDE]. That leaves nothing in the file for
## [method _check_spectrum_copies_agree] to compare, so a table re-added here later would be
## invisible to it — reintroducing the duplication that was removed, unwatched.
##
## The invariant is therefore written to hold in both states: anything declared locally must
## agree with the CPU copy, and a file declaring none of them must take them from the include.
## A shader that declared its own tables and matched would pass, which is what the file looked
## like before the collapse.
func _check_ocean_keeps_no_stale_spectrum() -> int:
	var code := FileAccess.get_file_as_string(OCEAN_SHADER)
	var declared := _locally_declared_spectrum_names(code)
	var problems := _stale_spectrum_problems(code, FileAccess.get_file_as_string(
		SPECTRUM_SOURCES[0]
	))
	return _report(
		"ocean keeps no stale spectrum",
		problems.is_empty(),
		_stale_spectrum_detail(declared, problems)
	)


## Returns the spectrum constants [param code] declares itself, under any of the spellings the
## include and the other shaders use.
static func _locally_declared_spectrum_names(code: String) -> PackedStringArray:
	var declared := PackedStringArray()
	for row: Array in SPECTRUM_CONSTANTS:
		# Columns 1 and 2: the include's WAVE_-prefixed spelling, and the shaders' own.
		for name: String in [row[1], row[2]]:
			if declared.has(name):
				continue
			if not _spectrum_numbers(code, name, OCEAN_SHADER).is_empty():
				declared.append(name)
	return declared


## Describes every way [param ocean_code] fails the invariant in
## [method _check_ocean_keeps_no_stale_spectrum], against the CPU copy in [param cpu_code].
static func _stale_spectrum_problems(ocean_code: String, cpu_code: String) -> PackedStringArray:
	var problems := PackedStringArray()
	var declared := _locally_declared_spectrum_names(ocean_code)
	if declared.is_empty():
		if not ocean_code.contains(SPECTRUM_INCLUDE):
			problems.append("declares no spectrum and does not include %s" % [
				SPECTRUM_INCLUDE.get_file()
			])
		return problems

	for row: Array in SPECTRUM_CONSTANTS:
		var reference := _spectrum_numbers(cpu_code, row[0], SPECTRUM_SOURCES[0])
		for name: String in [row[1], row[2]]:
			var local := _spectrum_numbers(ocean_code, name, OCEAN_SHADER)
			if not local.is_empty() and local != reference:
				problems.append("local %s is %s" % [name, local])
	return problems


## Returns the result detail for [method _check_ocean_keeps_no_stale_spectrum].
##
## A failure carries the problems themselves. Describing the state the check wanted — "matching
## the CPU" — beside a FAIL would assert the opposite of what happened and send the reader
## looking in the wrong file, which is worse than saying nothing.
static func _stale_spectrum_detail(
	declared: PackedStringArray, problems: PackedStringArray
) -> String:
	if not problems.is_empty():
		return ", ".join(problems)
	if declared.is_empty():
		return "none declared; taken from %s" % SPECTRUM_INCLUDE.get_file()
	return "%d declared locally, matching the CPU" % declared.size()


## Returns the numbers a constant named [param name] is declared with in [param code].
##
## [param path] selects the syntax: a GLSL declaration ends at its semicolon and may carry a
## [code]float[8](…)[/code] constructor, a GDScript one ends at the closing bracket of its array
## or at the end of its line. Comments are stripped first, so a commented-out declaration reads
## as absent rather than shadowing the live one.
##
## Only literal numbers are read, and every literal in the value is returned. A value written as
## an expression therefore reports its operands — [code]9.0 + 0.81[/code] reads as two numbers,
## not as 9.81 — which fails the comparison rather than being quietly evaluated. That is the
## intended behaviour: these constants are meant to be written out literally in every copy.
static func _spectrum_numbers(code: String, name: String, path: String) -> PackedFloat64Array:
	var comments := RegEx.create_from_string(r"#[^\n]*|//[^\n]*|/\*[\s\S]*?\*/")
	var source := comments.sub(code, "", true)
	var declaration := RegEx.create_from_string(
		r"(?m)^[^\S\n]*const\s+[^\n=]*\b" + name + r"\b[^\n=]*=(.*(?:\n[^\n]*)?)"
	)
	var found := declaration.search(source)
	var numbers := PackedFloat64Array()
	if found == null:
		return numbers

	var rest := source.substr(found.get_start(1))
	var value := ""
	if path.get_extension().begins_with("gdshader"):
		value = rest.substr(0, rest.find(";"))
		var constructor := RegEx.create_from_string(r"^\s*\w+\s*\[\s*\d*\s*\]\s*\(")
		var prefix := constructor.search(value)
		if prefix != null:
			value = value.substr(prefix.get_end())
	elif rest.strip_edges(true, false).begins_with("["):
		value = rest.substr(0, rest.find("]"))
	else:
		value = rest.substr(0, rest.find("\n"))

	var literal := RegEx.create_from_string(r"-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?")
	for entry: RegExMatch in literal.search_all(value):
		numbers.append(entry.get_string().to_float())
	return numbers


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
