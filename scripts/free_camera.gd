class_name FreeCamera
extends Camera3D

## Free-flying observation camera with an optional wave-riding mode.
##
## Provides standard WASD-and-mouselook flight for inspecting a scene. When
## [member ride_waves] is enabled the camera is held a fixed height above the moving water
## surface, which is the vantage point where wave silhouettes and cel banding read most
## clearly.
##
## Requires the input actions listed in [constant REQUIRED_ACTIONS]; missing actions are
## reported once on ready rather than failing silently at runtime.

## Emitted when [member ride_waves] is toggled, with the new state in [param enabled].
signal ride_waves_toggled(enabled: bool)

## Input actions this camera reads. Verified on ready.
const REQUIRED_ACTIONS: PackedStringArray = [
	&"move_forward",
	&"move_back",
	&"move_left",
	&"move_right",
	&"move_up",
	&"move_down",
	&"move_sprint",
	&"move_slow",
]

## Height the camera returns to when the reset key is pressed, in metres.
const RESET_HEIGHT: float = 25.0

@export_group("Movement")

## Base movement speed in metres per second.
@export_range(0.1, 200.0, 0.1, "or_greater") var move_speed: float = 12.0

## Multiplier applied to [member move_speed] while the sprint action is held.
@export_range(1.0, 20.0, 0.1) var sprint_multiplier: float = 4.0

## Multiplier applied to [member move_speed] while the slow action is held.
@export_range(0.01, 1.0, 0.01) var slow_multiplier: float = 0.2

## Time constant for reaching the target velocity, in seconds.
##
## Small values feel responsive; larger values feel cinematic. Smoothing is exponential
## and therefore frame-rate independent.
@export_range(0.0, 1.0, 0.01) var acceleration_time: float = 0.12

@export_group("Look")

## Degrees of rotation per pixel of mouse motion.
@export_range(0.01, 1.0, 0.01) var mouse_sensitivity: float = 0.25

## Maximum pitch away from the horizon, in degrees.
##
## Held below 90 degrees so the view basis cannot become degenerate at the poles.
@export_range(0.0, 89.9, 0.1) var pitch_limit: float = 89.0

@export_group("Wave Riding")

## Whether the camera tracks the water surface instead of holding its altitude.
@export var ride_waves: bool = false:
	set(value):
		if ride_waves == value:
			return
		ride_waves = value
		ride_waves_toggled.emit(ride_waves)

## Height maintained above the water surface while riding, in metres.
@export_range(0.1, 50.0, 0.1) var ride_height: float = 1.8

## How quickly the camera settles onto the surface, as an exponential rate.
##
## Lower values lag behind the swell and read as bobbing; higher values track it rigidly.
@export_range(0.5, 30.0, 0.5) var ride_stiffness: float = 6.0

## Ocean whose surface the camera rides. Optional unless [member ride_waves] is used.
@export var ocean: Ocean

## Weather to drive from the number keys and C. Optional.
@export var weather: WeatherController

var _yaw: float = 0.0
var _pitch: float = 0.0
var _velocity: Vector3 = Vector3.ZERO
var _mouse_captured: bool = false


func _ready() -> void:
	_warn_on_missing_actions()

	var euler := global_transform.basis.get_euler()
	_yaw = euler.y
	_pitch = euler.x

	_set_mouse_captured(true)


func _process(delta: float) -> void:
	_apply_look()
	_apply_movement(delta)
	if ride_waves:
		_apply_wave_ride(delta)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _mouse_captured:
		_accumulate_look(event as InputEventMouseMotion)
		return

	if event.is_action_pressed(&"ui_cancel"):
		_set_mouse_captured(not _mouse_captured)
		return

	if event is InputEventMouseButton and event.is_pressed() and not _mouse_captured:
		_set_mouse_captured(true)
		return

	var key_event := event as InputEventKey
	if key_event == null or not key_event.is_pressed() or key_event.echo:
		return

	match key_event.keycode:
		KEY_R:
			ride_waves = not ride_waves
		KEY_F:
			global_position.y = RESET_HEIGHT
		KEY_C:
			if weather != null:
				weather.next()
		KEY_1, KEY_2, KEY_3:
			if weather != null:
				weather.apply_index(key_event.keycode - KEY_1)


## Reports any input actions this camera needs but the project does not define.
##
## Checked once rather than per frame: a missing action otherwise reads as unresponsive
## controls with no indication of why.
func _warn_on_missing_actions() -> void:
	var missing := PackedStringArray()
	for action in REQUIRED_ACTIONS:
		if not InputMap.has_action(action):
			missing.append(action)

	if not missing.is_empty():
		push_warning(
			"%s: missing input actions %s. Define them in Project Settings > Input Map."
			% [name, ", ".join(missing)]
		)


func _accumulate_look(event: InputEventMouseMotion) -> void:
	_yaw -= deg_to_rad(event.relative.x * mouse_sensitivity)
	_pitch -= deg_to_rad(event.relative.y * mouse_sensitivity)
	_pitch = clampf(_pitch, -deg_to_rad(pitch_limit), deg_to_rad(pitch_limit))


func _apply_look() -> void:
	global_transform.basis = Basis.from_euler(Vector3(_pitch, _yaw, 0.0))


func _apply_movement(delta: float) -> void:
	var target_velocity := _read_movement_input() * _current_speed()

	# Exponential smoothing towards the target, expressed so the result does not depend on
	# frame rate.
	var weight := 1.0 - exp(-delta / maxf(acceleration_time, 0.0001))
	_velocity = _velocity.lerp(target_velocity, weight)
	global_position += _velocity * delta


## Returns the desired direction of travel in world space, at most one unit long.
##
## Horizontal movement follows the camera's facing while vertical movement stays world
## aligned, so ascending does not drift forwards when looking down.
func _read_movement_input() -> Vector3:
	var strafe := Input.get_axis(&"move_left", &"move_right")
	var forward := Input.get_axis(&"move_forward", &"move_back")
	var lift := Input.get_axis(&"move_down", &"move_up")

	var basis := global_transform.basis
	var direction := basis.x * strafe + basis.z * forward
	direction.y = 0.0

	# Renormalise to the joystick magnitude so diagonal input is not faster than cardinal.
	var horizontal_magnitude := minf(Vector2(strafe, forward).length(), 1.0)
	direction = direction.normalized() * horizontal_magnitude
	direction.y = lift

	return direction


func _current_speed() -> float:
	if Input.is_action_pressed(&"move_sprint"):
		return move_speed * sprint_multiplier
	if Input.is_action_pressed(&"move_slow"):
		return move_speed * slow_multiplier
	return move_speed


## Eases the camera towards a fixed height above the swell.
func _apply_wave_ride(delta: float) -> void:
	if ocean == null:
		return

	var surface_height := ocean.get_water_height(
		Vector2(global_position.x, global_position.z)
	)
	var target_height := surface_height + ride_height
	var weight := 1.0 - exp(-delta * ride_stiffness)
	global_position.y = lerpf(global_position.y, target_height, weight)


func _set_mouse_captured(captured: bool) -> void:
	_mouse_captured = captured
	Input.mouse_mode = (
		Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE
	)
