class_name PlayerInput
extends Node

## The owning client sends world X/Z intent; only the server applies forces.
const SLOW_MULTIPLIER: float = 0.35

@export var move_direction: Vector2 = Vector2.ZERO
@export var wants_up: bool = false
@export var wants_down: bool = false
@export var wants_sprint: bool = false

## How many times the owner has asked to climb onto the raft.
##
## A running count rather than a pressed flag, because boarding is momentary where the movement
## keys are held. A flag true for a single frame can flip back before the synchronizer next
## samples it, so some presses would silently do nothing and F would feel unreliable. A count
## only rises, so the server boards once per increment however many frames it missed, and
## re-reading the same value boards nothing.
##
## Bound to F, which [code]free_camera.gd[/code] also matches as a raw key to reset its height.
## Different scene and different script — the camera lives in [code]ocean_demo[/code] and no
## player does — but a free camera added to the multiplayer scene would trigger both.
@export var board_requests: int = 0

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
	if Input.is_action_just_pressed(&"board"):
		board_requests += 1


## Releases thrust immediately; passive drift and buoyancy continue.
func clear_intent() -> void:
	move_direction = Vector2.ZERO
	wants_up = false
	wants_down = false
	wants_sprint = false
	# board_requests is deliberately left alone: it is a running count, and zeroing it would read
	# as a decrease on the server, which would then ignore every request until the client caught
	# back up to the count it had already served.


## Validates remote intent before it reaches the physics solver.
func world_direction() -> Vector3:
	if not move_direction.is_finite():
		return Vector3.ZERO
	var limited := move_direction.limit_length(1.0)
	return Vector3(limited.x, 0.0, limited.y)
