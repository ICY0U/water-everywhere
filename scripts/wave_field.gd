class_name WaveField
extends Resource

## A wind-driven spectrum of Gerstner waves, evaluated identically on the CPU and the GPU.
##
## The sea state is derived from one physical quantity — [member wind_speed] — through the
## Pierson-Moskowitz model of a fully developed sea. Significant wave height and peak
## wavelength both follow from it, so raising the wind gives a sea that is taller, longer
## and slower-breathing in the proportions a real ocean has, instead of three dials that
## have to be kept plausible by hand.
##
## The GPU displaces the ocean mesh from this spectrum; nothing on the CPU can read that
## displacement back cheaply. Anything that needs to know where the surface actually is —
## buoyancy, foam, a camera that floats — evaluates the same maths here instead. Keeping
## the two in agreement is the whole point of this class, so [method apply_to_material]
## pushes the [i]derived[/i] spectrum to the shader: the Pierson-Moskowitz maths lives here
## only, and the shader is simply told the answer. Changing any parameter emits
## [signal Resource.changed].
##
## Waves obey the deep-water dispersion relation, so phase speed follows from wavelength
## rather than being an independent dial. Horizontal displacement is capped across the
## spectrum so the summed surface cannot fold through itself.
##
## @tutorial(Trochoidal (Gerstner) waves): https://en.wikipedia.org/wiki/Trochoidal_wave
## @tutorial(Pierson-Moskowitz spectrum): https://en.wikipedia.org/wiki/Wind_wave

## Gravitational acceleration used by the dispersion relation, in metres per second squared.
const GRAVITY: float = 9.81

## Number of waves summed. Must match [code]WAVE_COUNT[/code] in
## [code]gerstner_waves.gdshaderinc[/code], which every GPU consumer of the spectrum includes,
## and in [code]foam_sim.gdshader[/code], which keeps its own copy on purpose — it needs only a
## horizontal compression term, and routing it through the full sample would compute vertical
## terms it discards for every texel of the simulation buffer.
const WAVE_COUNT: int = 8

## Significant wave height of a fully developed sea: [code]H = 0.21 * U^2 / g[/code].
##
## From the Pierson-Moskowitz spectrum, where [code]U[/code] is the wind speed ten metres
## above the surface.
const PM_HEIGHT_COEFFICIENT: float = 0.21

## Peak wavelength of a fully developed sea: [code]L = 8.17 * U^2 / g[/code].
##
## Follows from the Pierson-Moskowitz peak frequency through the dispersion relation.
const PM_LENGTH_COEFFICIENT: float = 8.17

## Fixed per-octave fan offsets, as a fraction of [member wind_spread].
##
## Real seas are not symmetric about the wind: a strictly alternating fan produces a
## visible cross-hatch that the eye reads as a repeating texture. These offsets are
## irregular and fixed, so the CPU and the shader can share them exactly — a hash function
## evaluated in both languages would not be guaranteed to agree bit for bit.
const OCTAVE_DIRECTION_OFFSETS: Array[float] = [
	0.0, 0.62, -0.41, 0.87, -0.73, 0.29, -0.95, 0.53,
]

## Fixed per-octave phase offsets, in radians.
##
## Without them every wave is in phase at the world origin at [code]t = 0[/code], which
## stacks the whole spectrum into one implausible spike that then travels outward as a
## visible ring. Offsetting the phases removes the origin artefact entirely.
const OCTAVE_PHASES: Array[float] = [
	0.0, 2.31, 5.02, 1.17, 3.94, 0.58, 4.61, 2.87,
]

## Fraction of [member wind_spread] applied to the longest wave in the spectrum.
##
## Real directional spreading narrows with wavelength: swell arrives from one bearing while
## short chop fans out widely. The spread is ramped from this fraction up to the full value
## across the spectrum.
const LONGEST_WAVE_SPREAD: float = 0.35

## Iterations used by [method sample_surface_point] to invert horizontal displacement.
##
## Three is comfortably convergent for steepness values up to 1.0.
const SURFACE_POINT_ITERATIONS: int = 3

@export_group("Sea State")

## Wind speed ten metres above the surface, in metres per second.
##
## This is the single driver of how big the sea is. Roughly: 5 is a light breeze with
## 0.5 m waves, 10 is a fresh breeze with 2 m waves, 20 is a gale with 8 m waves.
@export_range(0.0, 30.0, 0.1) var wind_speed: float = 10.0:
	set(value):
		wind_speed = value
		emit_changed()

## Direction the wind blows towards, in degrees around the Y axis.
@export_range(0.0, 360.0, 1.0) var wind_angle: float = 45.0:
	set(value):
		wind_angle = value
		emit_changed()

## Widest angle any wave in the spectrum deviates from [member wind_angle], in degrees.
##
## Zero gives an unnaturally uniform swell; wider values look choppier and more open-ocean.
@export_range(0.0, 90.0, 1.0) var wind_spread: float = 42.0:
	set(value):
		wind_spread = value
		emit_changed()

## Crest sharpness, from a smooth sine surface at 0 to a fully cusped trochoid at 1.
##
## Physically this is wave age: young, fetch-limited seas are steeper than fully developed
## ones at the same height. Capped internally across the spectrum, so even 1.0 cannot fold
## the surface over itself.
@export_range(0.0, 1.0, 0.01) var steepness: float = 0.72:
	set(value):
		steepness = value
		emit_changed()

@export_group("Art Direction")

## Multiplier on the physically derived wave height.
@export_range(0.1, 4.0, 0.01) var amplitude_scale: float = 1.0:
	set(value):
		amplitude_scale = value
		emit_changed()

## Multiplier on the physically derived peak wavelength.
##
## Defaults below 1 on purpose. A real fully developed swell is so long that from any
## normal camera height it reads as a slowly tilting plane rather than as waves; shortening
## it brings the crests into frame without changing how they move relative to each other.
@export_range(0.1, 2.0, 0.01) var wavelength_scale: float = 0.5:
	set(value):
		wavelength_scale = value
		emit_changed()

## Multiplier on the rate at which waves travel. 1.0 is physically correct.
@export_range(0.0, 3.0, 0.01) var speed: float = 1.0:
	set(value):
		speed = value
		emit_changed()

## Per-octave scaling of amplitude and wavelength.
##
## Both scale together, which holds wave steepness constant down the spectrum — the
## equilibrium range of a real wind sea behaves this way. Smaller values reach further into
## fine chop from the same number of waves, at the cost of a gap between scales.
@export_range(0.4, 0.95, 0.01) var octave_ratio: float = 0.74:
	set(value):
		octave_ratio = value
		emit_changed()


## Returns the significant wave height this spectrum produces, in metres.
##
## The standard oceanographic measure: the mean height of the highest third of waves, and
## the number a marine forecast quotes as "wave height". [member amplitude_scale] is folded
## in so this stays the height actually rendered, not the height physics alone would ask
## for — which is what makes it a usable assertion target.
func significant_wave_height() -> float:
	return PM_HEIGHT_COEFFICIENT * wind_speed * wind_speed / GRAVITY * amplitude_scale


## Returns the wavelength of the dominant wave, in metres.
func peak_wavelength() -> float:
	return PM_LENGTH_COEFFICIENT * wind_speed * wind_speed / GRAVITY * wavelength_scale


## Returns the amplitude of the dominant wave, in metres.
##
## Chosen so the whole spectrum reproduces [method significant_wave_height]. For a sum of
## sinusoids the surface elevation has standard deviation [code]sqrt(sum(a^2) / 2)[/code]
## and [code]H = 4 * that[/code], so the dominant amplitude is what remains once the
## geometric series of the other octaves is divided out.
func peak_amplitude() -> float:
	var ratio_squared := octave_ratio * octave_ratio
	var energy_sum := (1.0 - pow(ratio_squared, WAVE_COUNT)) / maxf(1.0 - ratio_squared, 1e-6)
	return significant_wave_height() / (4.0 * sqrt(energy_sum * 0.5))


## Returns the steepness [code]k * A[/code] shared by every octave.
##
## Amplitude and wavelength scale by the same [member octave_ratio], so this quantity is
## identical for every wave in the spectrum. It is the true measure of how peaked the
## surface is: a single Gerstner wave cusps at [code]k * A = 1[/code].
func octave_steepness() -> float:
	return TAU * peak_amplitude() / maxf(peak_wavelength(), 0.0001)


## Returns the summed amplitude of the spectrum: the maximum possible wave height.
##
## This is the once-in-a-storm case where every octave crests together, roughly twice
## [method significant_wave_height].
func total_amplitude() -> float:
	var geometric := (1.0 - pow(octave_ratio, WAVE_COUNT)) / maxf(1.0 - octave_ratio, 1e-6)
	return peak_amplitude() * geometric


## Returns the wavelength of the given octave, in metres.
func octave_wavelength(octave: int) -> float:
	return peak_wavelength() * pow(octave_ratio, octave)


## Returns the amplitude of the given octave, in metres.
func octave_amplitude(octave: int) -> float:
	return peak_amplitude() * pow(octave_ratio, octave)


## Returns the phase speed of the given octave, in metres per second.
##
## The deep-water dispersion relation, [code]c = sqrt(g / k)[/code]. Speed is derived from
## wavelength rather than being a dial of its own, which is what makes long swells outrun
## short chop without anyone tuning them to.
func octave_phase_speed(octave: int) -> float:
	return sqrt(GRAVITY * octave_wavelength(octave) / TAU)


## Returns the fixed phase offset of the given octave, in radians.
func octave_phase_offset(octave: int) -> float:
	return OCTAVE_PHASES[octave]


## Returns the unit travel direction of the given octave on the XZ plane.
##
## Mirrored exactly in the shaders.
func octave_direction(octave: int) -> Vector2:
	var angle := deg_to_rad(wind_angle + wind_spread * _octave_spread(octave))
	return Vector2(cos(angle), sin(angle))


## Returns the full surface displacement at [param world_xz] at [param time] seconds.
##
## Gerstner waves move water horizontally as well as vertically — that lateral motion is
## what sharpens crests and broadens troughs — so the X and Z components are non-zero and
## matter when placing anything precisely on the surface.
func sample_displacement(world_xz: Vector2, time: float) -> Vector3:
	var displacement := Vector3.ZERO
	var current_amplitude := peak_amplitude()
	var current_wavelength := peak_wavelength()
	var chop := _chop_factor()
	var scaled_time := time * speed

	for octave in WAVE_COUNT:
		var direction := octave_direction(octave)
		var wave_number := TAU / maxf(current_wavelength, 0.0001)
		var phase_speed := sqrt(GRAVITY / wave_number)
		var phase := (
			wave_number * (direction.dot(world_xz) - phase_speed * scaled_time)
			+ OCTAVE_PHASES[octave]
		)
		var lateral := chop * current_amplitude

		displacement.x += lateral * direction.x * cos(phase)
		displacement.y += current_amplitude * sin(phase)
		displacement.z += lateral * direction.y * cos(phase)

		current_amplitude *= octave_ratio
		current_wavelength *= octave_ratio

	return displacement


## Returns the wave height generated at [param world_xz] at [param time] seconds.
##
## Note this is the height of the wave generated at that column, not the height of the
## water that has been displaced sideways to sit above it. The difference is well under
## the wave amplitude; use [method sample_surface_point] when it matters.
func sample_height(world_xz: Vector2, time: float) -> float:
	return sample_displacement(world_xz, time).y


## Returns the actual surface point above [param world_xz], inverting lateral displacement.
##
## Because Gerstner waves shift water sideways, the surface directly above a column was
## generated somewhere else. This walks back to that origin by fixed-point iteration.
func sample_surface_point(world_xz: Vector2, time: float) -> Vector3:
	var origin := world_xz
	for _iteration in SURFACE_POINT_ITERATIONS:
		var displacement := sample_displacement(origin, time)
		var lateral := Vector2(displacement.x, displacement.z)
		origin += world_xz - (origin + lateral)

	var final_displacement := sample_displacement(origin, time)
	return Vector3(world_xz.x, final_displacement.y, world_xz.y)


## Returns the velocity of the water surface at [param world_xz], in metres per second.
##
## The exact time derivative of [method sample_displacement], so it includes the circular
## orbital motion that carries floating objects forward under a crest and back in a trough.
## Feeding this to drag is what makes a floating body get [i]pushed[/i] by waves rather than
## merely lifted by them.
func sample_velocity(world_xz: Vector2, time: float) -> Vector3:
	var velocity := Vector3.ZERO
	var current_amplitude := peak_amplitude()
	var current_wavelength := peak_wavelength()
	var chop := _chop_factor()
	var scaled_time := time * speed

	for octave in WAVE_COUNT:
		var direction := octave_direction(octave)
		var wave_number := TAU / maxf(current_wavelength, 0.0001)
		var phase_speed := sqrt(GRAVITY / wave_number)
		var phase := (
			wave_number * (direction.dot(world_xz) - phase_speed * scaled_time)
			+ OCTAVE_PHASES[octave]
		)
		# d(phase)/dt, negated: the phase runs backwards as the wave travels forwards.
		var angular_rate := wave_number * phase_speed * speed
		var lateral := chop * current_amplitude

		velocity.x += lateral * direction.x * sin(phase) * angular_rate
		velocity.y += -current_amplitude * cos(phase) * angular_rate
		velocity.z += lateral * direction.y * sin(phase) * angular_rate

		current_amplitude *= octave_ratio
		current_wavelength *= octave_ratio

	return velocity


## Returns the unit surface normal at [param world_xz] at [param time] seconds.
##
## Derived from analytic partial derivatives of the same wave sum rather than by finite
## differences, so it matches the shader's normals exactly.
func sample_normal(world_xz: Vector2, time: float) -> Vector3:
	var frame := _sample_tangent_frame(world_xz, time)
	return frame[1].cross(frame[0]).normalized()


## Returns the horizontal compression of the surface at [param world_xz].
##
## This is the determinant of the Jacobian of the horizontal displacement field. It is 1 on
## undisturbed water, above 1 where the surface is being stretched apart in a trough, and
## below 1 where water is piling up against itself on the steep face of a crest. Values
## approaching 0 are where a real wave breaks, which makes this the physical criterion for
## whitecap foam — see [code]foam_sim.gdshader[/code], which computes the same quantity.
func sample_jacobian(world_xz: Vector2, time: float) -> float:
	var frame := _sample_tangent_frame(world_xz, time)
	return frame[0].x * frame[1].z - frame[0].z * frame[1].x


## Writes the derived spectrum to [param target], keeping the GPU surface in sync.
##
## Both the ocean surface and the foam simulation take the same uniform names, so one
## field can drive both.
func apply_to_material(target: ShaderMaterial) -> void:
	if target == null:
		return
	target.set_shader_parameter(&"peak_amplitude", peak_amplitude())
	target.set_shader_parameter(&"peak_wavelength", peak_wavelength())
	target.set_shader_parameter(&"octave_ratio", octave_ratio)
	target.set_shader_parameter(&"wave_chop", _chop_factor())
	target.set_shader_parameter(&"wind_angle", wind_angle)
	target.set_shader_parameter(&"wind_spread", wind_spread)
	target.set_shader_parameter(&"wave_speed", speed)
	target.set_shader_parameter(&"wave_total_amplitude", total_amplitude())


## Returns the fan offset of the given octave, as a signed fraction of [member wind_spread].
func _octave_spread(octave: int) -> float:
	var shortness := float(octave) / float(WAVE_COUNT - 1)
	var narrowing := LONGEST_WAVE_SPREAD + (1.0 - LONGEST_WAVE_SPREAD) * shortness
	return OCTAVE_DIRECTION_OFFSETS[octave] * narrowing


## Returns horizontal displacement as a fraction of vertical amplitude, for every octave.
##
## An exact trochoid displaces water sideways by the same amplitude it lifts it, and cusps
## when [code]k * A[/code] reaches 1. Summing [constant WAVE_COUNT] of them would reach that
## limit [constant WAVE_COUNT] times sooner, so the requested steepness is divided by the
## spectrum's total steepness whenever that total exceeds 1. Below that threshold the
## division is skipped, so a calm sea is not artificially flattened.
func _chop_factor() -> float:
	return steepness / maxf(1.0, octave_steepness() * float(WAVE_COUNT))


## Returns the surface tangent frame at [param world_xz] as [code][tangent, binormal][/code].
##
## Both the normal and the horizontal Jacobian fall out of the same accumulation, so they
## are gathered once here rather than in two near-identical loops.
func _sample_tangent_frame(world_xz: Vector2, time: float) -> Array[Vector3]:
	var tangent := Vector3(1.0, 0.0, 0.0)
	var binormal := Vector3(0.0, 0.0, 1.0)
	var current_amplitude := peak_amplitude()
	var current_wavelength := peak_wavelength()
	var chop := _chop_factor()
	var scaled_time := time * speed

	for octave in WAVE_COUNT:
		var direction := octave_direction(octave)
		var wave_number := TAU / maxf(current_wavelength, 0.0001)
		var phase_speed := sqrt(GRAVITY / wave_number)
		var phase := (
			wave_number * (direction.dot(world_xz) - phase_speed * scaled_time)
			+ OCTAVE_PHASES[octave]
		)
		var slope := wave_number * current_amplitude
		var lateral_slope := chop * slope
		var cos_phase := cos(phase)
		var sin_phase := sin(phase)

		tangent += Vector3(
			-lateral_slope * direction.x * direction.x * sin_phase,
			direction.x * slope * cos_phase,
			-lateral_slope * direction.x * direction.y * sin_phase,
		)
		binormal += Vector3(
			-lateral_slope * direction.x * direction.y * sin_phase,
			direction.y * slope * cos_phase,
			-lateral_slope * direction.y * direction.y * sin_phase,
		)

		current_amplitude *= octave_ratio
		current_wavelength *= octave_ratio

	return [tangent, binormal]
