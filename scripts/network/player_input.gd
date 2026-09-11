class_name PlayerInput
extends Node

## The owning client sends world X/Z intent; only the server applies forces.
const SLOW_MULTIPLIER: float = 0.35

@export var move_direction: Vector2 = Vector2.ZERO
@export var wants_up: bool = false
@export var wants_down: bool = false
@export var wants_sprint: bool = false

## Local-only camera and capture gate.
var movement_camera: PlayerCamera
var controls_enabled: bool = false:
	set(value):
		controls_enabled = value
		if not value:
			clear_intent()


func _process(_delta: float) -> void:
	if not is_multiplayer_authority():
		return
	if not controls_enabled or not is_instance_valid(movement_camera):
		clear_intent()
		return
	var requested := Input.get_vector(
		&"move_left", &"move_right", &"move_forward", &"move_back"
	)
	var direction := movement_camera.movement_basis() * Vector3(requested.x, 0.0, requested.y)
	var slow := Input.is_action_pressed(&"move_slow")
	move_direction = Vector2(direction.x, direction.z) * (SLOW_MULTIPLIER if slow else 1.0)
	wants_up = Input.is_action_pressed(&"move_up")
	wants_down = Input.is_action_pressed(&"move_down")
	wants_sprint = Input.is_action_pressed(&"move_sprint") and not slow


## Releases thrust immediately; passive drift and buoyancy continue.
func clear_intent() -> void:
	move_direction = Vector2.ZERO
	wants_up = false
	wants_down = false
	wants_sprint = false


## Validates remote intent before it reaches the physics solver.
func world_direction() -> Vector3:
	if not move_direction.is_finite():
		return Vector3.ZERO
	var limited := move_direction.limit_length(1.0)
	return Vector3(limited.x, 0.0, limited.y)
