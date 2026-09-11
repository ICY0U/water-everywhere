extends SceneTree

## Assertions on the spray and rain particle systems.
##
## Three kinds of check live here. How much spray the wind raises, and which weathers rain,
## is plain arithmetic on the CPU. Whether those numbers actually reach the particles is not
## visible from outside the shader materials, so they are read back out of the live scene.
## And where the particles think the water is, is not observable at all: they find it
## by evaluating [code]gerstner_waves.gdshaderinc[/code] on the GPU, which nothing on the CPU
## can observe. So a probe shader renders that include into a float texture, which is read
## back and compared point by point against [WaveField] — the field that buoyancy and every
## CPU query already trust, and that [code]verify_waves.gd[/code] pins to the physics. If
## the two ever drift, droplets land in mid-air or sink into crests, and this says so.
##
## The GPU checks need a real renderer, so run it WITHOUT [code]--headless[/code]:
## [codeblock lang=text]
## godot --path . --script tools/verify_spray.gd --rendering-driver d3d12
## [/codeblock]
## Exits non-zero if any check fails, so it is usable from CI.

## Column width for the check name, so results line up in the terminal.
const LABEL_WIDTH: int = 40

## Points probed along each axis of the sampled area.
const PROBE_SIZE: int = 24

## Half-width of the sea area probed, in metres.
const PROBE_EXTENT: float = 60.0

## Scale mapping a probed value into the texture around 0.5.
const ENCODE_SCALE: float = 0.05

## Largest GPU/CPU disagreement accepted, in metres or metres per second.
##
## Set by the half-float buffer rather than by the maths: near 0.75 a 16-bit float resolves
## about 5e-4, which is 1 cm once divided by [constant ENCODE_SCALE].
const TOLERANCE: float = 0.02

## Wave clock the comparison is made at. Arbitrary, but well away from t = 0.
const PROBE_TIME: float = 37.25

## Frames rendered after changing the probe before reading it back.
const RENDER_FRAMES: int = 3

## Fixed values the calibration pass writes. Must match [code]wave_probe.gdshader[/code].
const CALIBRATION_VALUES: Vector3 = Vector3(1.5, -2.25, 4.0)

const PROBE_SHADER: Shader = preload("res://tools/wave_probe.gdshader")

## What the probe shader writes into each pixel. Must match [code]wave_probe.gdshader[/code].
enum Quantity {
	HEIGHT_COMPRESSION_SURFACE,
	NORMAL,
	VELOCITY,
	DISPLACEMENT_XZ,
	CALIBRATION,
}

var _viewport: SubViewport
var _probe_material: ShaderMaterial


func _initialize() -> void:
	_run()


func _run() -> void:
	var failures := 0

	failures += _check_spray_follows_beaufort()
	failures += _check_spindrift_needs_a_gale()
	failures += _check_rain_is_authored_per_weather()
	failures += await _check_weather_reaches_the_particles()

	_create_probe()
	failures += await _check_probe_round_trip()

	var breeze := WaveField.new()
	failures += await _check_gpu_matches_cpu(breeze, "breeze (10 m/s)")

	var gale := WaveField.new()
	gale.wind_speed = 19.0
	gale.steepness = 0.92
	failures += await _check_gpu_matches_cpu(gale, "gale (19 m/s)")

	if failures == 0:
		print("\nAll spray checks PASSED")
	else:
		printerr("\n%d spray check(s) FAILED" % failures)
	quit(1 if failures > 0 else 0)


## Prints one result row and returns the number of failures it represents.
func _report(label: String, passed: bool, detail: String) -> int:
	print("%s  %s  %s" % ["PASS" if passed else "FAIL", label.rpad(LABEL_WIDTH), detail])
	return 0 if passed else 1


## Spray must appear across Beaufort forces 5 and 6, and never fall as the wind rises.
func _check_spray_follows_beaufort() -> int:
	var failures := 0
	var below := OceanSpray.spray_amount_for_wind(OceanSpray.SPRAY_ONSET_WIND - 0.1)
	failures += _report("no spray below force 5", below == 0.0, "amount=%.3f" % below)

	var full := OceanSpray.spray_amount_for_wind(OceanSpray.SPRAY_FULL_WIND)
	failures += _report(
		"full spray by the top of force 6", is_equal_approx(full, 1.0), "amount=%.3f" % full
	)

	var monotonic := true
	var previous := 0.0
	for step in 61:
		var amount := OceanSpray.spray_amount_for_wind(step * 0.5)
		monotonic = monotonic and amount >= previous
		previous = amount
	failures += _report("spray never falls as wind rises", monotonic, "0-30 m/s in 0.5 steps")

	# The sunny breeze sits just inside force 5: "chance of some spray" means a little.
	var sunny := _load_preset("sunny")
	var sunny_amount := OceanSpray.spray_amount_for_wind(sunny.wind_speed)
	failures += _report(
		"a sunny breeze throws only a little",
		sunny_amount > 0.0 and sunny_amount < 0.25,
		"wind=%.1f amount=%.3f" % [sunny.wind_speed, sunny_amount],
	)
	return failures


## Spindrift is a gale phenomenon: absent until force 7, dominant by force 8.
func _check_spindrift_needs_a_gale() -> int:
	var failures := 0
	var overcast := _load_preset("overcast")
	var stormy := _load_preset("stormy")

	var calm := OceanSpray.spindrift_amount_for_wind(overcast.wind_speed)
	failures += _report(
		"no spindrift below a gale", calm == 0.0, "wind=%.1f amount=%.3f" % [
			overcast.wind_speed, calm,
		]
	)

	var storm := OceanSpray.spindrift_amount_for_wind(stormy.wind_speed)
	failures += _report(
		"the storm streams spindrift", storm > 0.5, "wind=%.1f amount=%.3f" % [
			stormy.wind_speed, storm,
		]
	)
	return failures


## Sunny weather is dry, and the storm rains hardest of all.
func _check_rain_is_authored_per_weather() -> int:
	var failures := 0
	var sunny := _load_preset("sunny")
	var overcast := _load_preset("overcast")
	var stormy := _load_preset("stormy")

	failures += _report(
		"sunny weather is dry", sunny.rain_intensity == 0.0, "rain=%.2f" % sunny.rain_intensity
	)
	failures += _report(
		"the storm rains hardest",
		stormy.rain_intensity > overcast.rain_intensity
			and stormy.rain_intensity > sunny.rain_intensity,
		"sunny=%.2f overcast=%.2f stormy=%.2f" % [
			sunny.rain_intensity, overcast.rain_intensity, stormy.rain_intensity,
		],
	)
	return failures


## Applying a weather must reach the particles, not merely reach the scene.
##
## How much spray and rain there is lives entirely in shader uniforms, where nothing else can
## observe it — so a preset that never arrives looks exactly like an effect that is simply
## subtle, and no amount of staring at a screenshot tells the two apart. These read the
## values back out of the live materials after each weather is applied.
func _check_weather_reaches_the_particles() -> int:
	var demo: Node = (load("res://scenes/ocean_demo.tscn") as PackedScene).instantiate()
	root.add_child(demo)
	await process_frame

	var spray := demo.get_node("OceanSpray") as OceanSpray
	var rain := demo.get_node("RainShower") as RainShower
	var weather := demo.get_node("Weather") as WeatherController
	var failures := 0

	var spray_emitter := spray.get_node("Spray") as GPUParticles3D
	var spray_material := spray_emitter.process_material as ShaderMaterial
	var rain_emitter := rain.get_node("Rain") as GPUParticles3D
	var rain_material := rain_emitter.process_material as ShaderMaterial

	# Every landing has somewhere to put its ring, or the rings silently never appear.
	var ripples := spray_emitter.get_node_or_null(spray_emitter.sub_emitter)
	failures += _report(
		"spray ripples are wired as a sub-emitter",
		ripples is GPUParticles3D,
		"sub_emitter=%s" % spray_emitter.sub_emitter,
	)

	for index in weather.presets.size():
		weather.apply_index(index)
		await process_frame
		var preset := weather.presets[index]

		var expected_spray := OceanSpray.spray_amount_for_wind(preset.wind_speed)
		var actual_spray: float = spray_material.get_shader_parameter(&"spray_amount")
		failures += _report(
			"%s: spray follows the wind" % preset.display_name,
			is_equal_approx(actual_spray, expected_spray * spray.amount_scale),
			"wind=%.1f expected=%.3f actual=%.3f" % [
				preset.wind_speed, expected_spray, actual_spray,
			],
		)

		var expected_threshold: float = preset.whitecap_threshold - spray.threshold_offset
		var actual_threshold: float = spray_material.get_shader_parameter(&"breaking_threshold")
		failures += _report(
			"%s: spray breaks where foam does" % preset.display_name,
			is_equal_approx(actual_threshold, expected_threshold),
			"expected=%.3f actual=%.3f" % [expected_threshold, actual_threshold],
		)

		var actual_rain: float = rain_material.get_shader_parameter(&"rain_amount")
		failures += _report(
			"%s: rain follows the preset" % preset.display_name,
			is_equal_approx(actual_rain, preset.rain_intensity)
				and rain_emitter.emitting == (preset.rain_intensity > 0.0),
			"expected=%.2f actual=%.2f emitting=%s" % [
				preset.rain_intensity, actual_rain, rain_emitter.emitting,
			],
		)

	demo.free()
	return failures


## The probe must return exactly what it was told to write.
##
## If the viewport converted colour space on the way out, every comparison after this would
## fail for a reason that has nothing to do with the waves. Checking a fixed value first
## separates "the read-back is broken" from "the include is wrong".
func _check_probe_round_trip() -> int:
	var image: Image = await _render(Quantity.CALIBRATION)
	var decoded := _decode(image.get_pixel(PROBE_SIZE / 2, PROBE_SIZE / 2))
	var error := (decoded - CALIBRATION_VALUES).abs()
	var worst := maxf(error.x, maxf(error.y, error.z))
	return _report(
		"probe read-back is linear and exact",
		worst < TOLERANCE * 0.5,
		"wrote %s read %s" % [CALIBRATION_VALUES, decoded.snappedf(0.001)],
	)


## Every quantity the particles use must agree with [WaveField] across the probed area.
func _check_gpu_matches_cpu(field: WaveField, label: String) -> int:
	field.apply_to_material(_probe_material)

	var surface_image: Image = await _render(Quantity.HEIGHT_COMPRESSION_SURFACE)
	var normal_image: Image = await _render(Quantity.NORMAL)
	var velocity_image: Image = await _render(Quantity.VELOCITY)
	var lateral_image: Image = await _render(Quantity.DISPLACEMENT_XZ)

	var worst_height := 0.0
	var worst_compression := 0.0
	var worst_surface := 0.0
	var worst_normal := 0.0
	var worst_velocity := 0.0
	var worst_lateral := 0.0

	for row in PROBE_SIZE:
		for column in PROBE_SIZE:
			var point := _probe_point(column, row)
			var surface := _decode(surface_image.get_pixel(column, row))
			var normal := _decode(normal_image.get_pixel(column, row))
			var velocity := _decode(velocity_image.get_pixel(column, row))
			var lateral := _decode(lateral_image.get_pixel(column, row))
			var displacement := field.sample_displacement(point, PROBE_TIME)

			worst_height = maxf(
				worst_height, absf(surface.x - field.sample_height(point, PROBE_TIME))
			)
			worst_compression = maxf(
				worst_compression, absf(surface.y - field.sample_jacobian(point, PROBE_TIME))
			)
			worst_surface = maxf(
				worst_surface,
				absf(surface.z - field.sample_surface_point(point, PROBE_TIME).y),
			)
			worst_normal = maxf(
				worst_normal, (normal - field.sample_normal(point, PROBE_TIME)).length()
			)
			worst_velocity = maxf(
				worst_velocity, (velocity - field.sample_velocity(point, PROBE_TIME)).length()
			)
			worst_lateral = maxf(
				worst_lateral,
				Vector2(lateral.x - displacement.x, lateral.y - displacement.z).length(),
			)

	var failures := 0
	failures += _report_agreement("%s: wave height" % label, worst_height)
	failures += _report_agreement("%s: compression" % label, worst_compression)
	failures += _report_agreement("%s: surface above a column" % label, worst_surface)
	failures += _report_agreement("%s: normal" % label, worst_normal)
	failures += _report_agreement("%s: water velocity" % label, worst_velocity)
	failures += _report_agreement("%s: lateral displacement" % label, worst_lateral)
	return failures


func _report_agreement(label: String, worst: float) -> int:
	return _report(label, worst < TOLERANCE, "worst |GPU - CPU| = %.4f" % worst)


func _create_probe() -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(PROBE_SIZE, PROBE_SIZE)
	_viewport.disable_3d = true
	# Half-float storage. An 8-bit target would quantise every value to 1/255 of the range.
	_viewport.use_hdr_2d = true
	_viewport.transparent_bg = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS

	_probe_material = ShaderMaterial.new()
	_probe_material.shader = PROBE_SHADER
	_probe_material.set_shader_parameter(&"area_min", Vector2.ONE * -PROBE_EXTENT)
	_probe_material.set_shader_parameter(&"area_size", Vector2.ONE * PROBE_EXTENT * 2.0)
	_probe_material.set_shader_parameter(&"encode_scale", ENCODE_SCALE)
	_probe_material.set_shader_parameter(&"wave_time", PROBE_TIME)
	_probe_material.set_shader_parameter(&"sea_level", 0.0)

	var surface := ColorRect.new()
	surface.size = Vector2(PROBE_SIZE, PROBE_SIZE)
	surface.material = _probe_material
	_viewport.add_child(surface)
	root.add_child(_viewport)


## Renders [param quantity] and returns the probe's contents.
func _render(quantity: Quantity) -> Image:
	_probe_material.set_shader_parameter(&"quantity", quantity)
	# More than one frame: the frame in flight when the parameter changed was recorded with
	# the old value.
	for _frame in RENDER_FRAMES:
		await RenderingServer.frame_post_draw
	return _viewport.get_texture().get_image()


## Returns the world XZ sampled by the probe pixel at [param column], [param row].
func _probe_point(column: int, row: int) -> Vector2:
	var uv := (Vector2(column, row) + Vector2(0.5, 0.5)) / float(PROBE_SIZE)
	return Vector2.ONE * -PROBE_EXTENT + uv * PROBE_EXTENT * 2.0


func _decode(pixel: Color) -> Vector3:
	return (Vector3(pixel.r, pixel.g, pixel.b) - Vector3.ONE * 0.5) / ENCODE_SCALE


func _load_preset(preset_name: String) -> WeatherPreset:
	return load("res://resources/weather/%s.tres" % preset_name) as WeatherPreset
