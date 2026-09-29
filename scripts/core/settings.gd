extends Node

## The player's preferences, saved between sessions: audio, controls, display and graphics.
##
## Registered as the [code]Settings[/code] autoload, and for the same reason as
## [code]NetworkSession[/code] it carries no [code]class_name[/code]: a global class and an
## autoload cannot share an identifier.
##
## [b]What it applies itself[/b] is everything that belongs to the whole application rather than
## to a scene: bus volumes, window mode, vsync, the root viewport's anti-aliasing and render scale,
## and the renderer's shadow quality. Anything that lives on a node in a scene — the camera's
## sensitivity, the environment's volumetric fog, the foam simulation's resolution — is applied by
## that scene, which listens to [signal changed]. That keeps this file free of node paths, and it
## keeps the classes the verification suites load statically free of any reference to an
## autoload, which [code]tools/verify_island_spawn.gd[/code] documents as a compile-order trap.
##
## [b]Local only.[/b] Nothing here is replicated or ever reaches another peer: one player's
## volume or field of view is nobody else's business.

## Emitted after a value changes, with the key that changed.
signal changed(key: StringName)

## Name of the file the settings are stored in, inside the active profile. See [UserPaths].
const FILE_NAME: String = "settings.cfg"

## Section of the settings file the values live in.
const SECTION: String = "settings"

## Graphics presets, cheapest first.
enum Quality {
	## Integrated graphics and older laptops: no volumetric fog, a scaled render, no MSAA.
	LOW,
	## Mid-range cards: fog and shadows at reduced cost.
	MEDIUM,
	## The look the game is authored for.
	HIGH,
}

## Display names for [enum Quality], in order.
const QUALITY_NAMES: PackedStringArray = ["Low", "Medium", "High"]

## Audio buses the volume settings drive, by setting key.
const BUS_FOR_KEY: Dictionary = {
	&"master_volume": &"Master",
	&"music_volume": &"Music",
	&"sfx_volume": &"SFX",
	&"ambience_volume": &"Ambience",
}

## Every setting and its default. A key missing from here cannot be set: see [method set_value].
const DEFAULTS: Dictionary = {
	&"master_volume": 0.85,
	&"music_volume": 0.55,
	&"sfx_volume": 0.9,
	&"ambience_volume": 0.8,
	&"mouse_sensitivity": 0.25,
	&"pad_sensitivity": 1.0,
	&"invert_y": false,
	&"field_of_view": 70.0,
	&"fullscreen": false,
	&"vsync": true,
	# -1 means "not chosen yet": the first launch picks a preset from the graphics adapter.
	&"quality": -1,
	&"render_scale": 1.0,
	&"show_fps": false,
	&"show_hints": true,
	&"player_name": "",
	&"join_address": "127.0.0.1",
	&"port": 27015,
	&"sea_state": 0,
}

var _values: Dictionary = {}


func _ready() -> void:
	# Settings must be adjustable from the pause menu, and a solo pause stops the tree.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load()
	if int(_values[&"quality"]) < 0:
		_values[&"quality"] = _detect_quality()
	apply_all()


## Returns the value stored for [param key], or its default.
func get_value(key: StringName) -> Variant:
	return _values.get(key, DEFAULTS.get(key))


## Stores [param value] for [param key], applies it, saves, and emits [signal changed].
##
## Unknown keys are refused rather than stored, so a typo in a caller cannot quietly create a
## setting that nothing reads.
func set_value(key: StringName, value: Variant) -> void:
	if not DEFAULTS.has(key):
		push_warning("Settings: unknown setting '%s'." % key)
		return
	if _values.get(key) == value:
		return
	_values[key] = value
	_apply(key)
	save()
	changed.emit(key)


## Returns the active graphics preset.
func quality() -> Quality:
	return clampi(int(get_value(&"quality")), Quality.LOW, Quality.HIGH) as Quality


## Returns the player's display name, or [param fallback] when none has been chosen.
func player_name(fallback: String = "Sailor") -> String:
	var chosen := String(get_value(&"player_name")).strip_edges()
	return chosen if not chosen.is_empty() else fallback


## Applies every setting. Called once on startup.
func apply_all() -> void:
	for key: StringName in DEFAULTS:
		_apply(key)


## Writes the settings to the active profile.
func save() -> void:
	var file := ConfigFile.new()
	for key: StringName in _values:
		file.set_value(SECTION, String(key), _values[key])
	var path := UserPaths.file(FILE_NAME)
	var error := file.save(path)
	if error != OK:
		push_warning("Settings: could not save %s (%s)." % [path, error_string(error)])


## Restores every default, keeping only the name and the address a player typed.
func reset_to_defaults() -> void:
	var keep := {
		&"player_name": get_value(&"player_name"),
		&"join_address": get_value(&"join_address"),
		&"port": get_value(&"port"),
	}
	_values = DEFAULTS.duplicate()
	_values.merge(keep, true)
	_values[&"quality"] = _detect_quality()
	apply_all()
	save()
	for key: StringName in DEFAULTS:
		changed.emit(key)


func _load() -> void:
	_values = DEFAULTS.duplicate()
	var file := ConfigFile.new()
	if file.load(UserPaths.file(FILE_NAME)) != OK:
		return
	for key: StringName in DEFAULTS:
		if not file.has_section_key(SECTION, String(key)):
			continue
		var stored: Variant = file.get_value(SECTION, String(key))
		# A value of the wrong type — a hand-edited file, or one from an older build — is
		# ignored rather than trusted: a string where a volume belongs would break every slider.
		if typeof(stored) == typeof(DEFAULTS[key]) or (
			typeof(stored) in [TYPE_INT, TYPE_FLOAT] and typeof(DEFAULTS[key]) in [TYPE_INT, TYPE_FLOAT]
		):
			_values[key] = stored


## Picks a first-run preset from the graphics adapter.
##
## Integrated graphics get Medium and software rasterisers Low. Only a first guess: the player
## can change it, and once they have, their choice is what is saved.
func _detect_quality() -> Quality:
	if DisplayServer.get_name() == "headless":
		return Quality.HIGH
	match RenderingServer.get_video_adapter_type():
		RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU:
			return Quality.MEDIUM
		RenderingDevice.DEVICE_TYPE_CPU:
			return Quality.LOW
	return Quality.HIGH


func _apply(key: StringName) -> void:
	if BUS_FOR_KEY.has(key):
		_apply_volume(BUS_FOR_KEY[key], float(get_value(key)))
		return
	match key:
		&"fullscreen":
			_apply_window_mode()
		&"vsync":
			if DisplayServer.get_name() != "headless":
				DisplayServer.window_set_vsync_mode(
					DisplayServer.VSYNC_ENABLED if get_value(key) else DisplayServer.VSYNC_DISABLED
				)
		&"render_scale", &"quality":
			_apply_rendering()


func _apply_volume(bus_name: StringName, linear: float) -> void:
	var bus := AudioServer.get_bus_index(bus_name)
	if bus < 0:
		return
	AudioServer.set_bus_mute(bus, linear <= 0.001)
	AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(linear, 0.0001)))


func _apply_window_mode() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var fullscreen: bool = get_value(&"fullscreen")
	var mode := DisplayServer.window_get_mode()
	if fullscreen and mode != DisplayServer.WINDOW_MODE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	elif not fullscreen and mode == DisplayServer.WINDOW_MODE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)


## Applies what the quality preset and render scale control on the root viewport and renderer.
##
## The rest of the preset — volumetric fog, shadow distance, foam resolution — lives on nodes in
## the scene, which [GraphicsQuality] applies when the scene hears [signal changed].
func _apply_rendering() -> void:
	var viewport := get_tree().root if is_inside_tree() else null
	if viewport == null:
		return
	var level := quality()
	var preset: Dictionary = GraphicsQuality.PRESETS[level]
	viewport.msaa_3d = preset["msaa"]
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	var scale := clampf(float(get_value(&"render_scale")), 0.5, 1.0) * float(preset["scale"])
	viewport.scaling_3d_scale = scale
	viewport.scaling_3d_mode = (
		Viewport.SCALING_3D_MODE_FSR if scale < 0.999 else Viewport.SCALING_3D_MODE_BILINEAR
	)
	RenderingServer.directional_shadow_atlas_set_size(preset["shadow_atlas"], true)
	RenderingServer.directional_soft_shadow_filter_set_quality(preset["soft_shadows"])
