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

## How many paddle strokes the owner has asked for.
##
## A running count for the same reason as [member board_requests], and for one more that
## matters here: a stroke has to keep arriving for the raft to keep moving. A held flag left
## true on the server by an owner whose packets stopped would paddle indefinitely, where a count
## that stops rising stops the raft within a stroke. That is B01's "missing input stops thrust".
##
## Holding the key keeps paddling. The press asks for one stroke and every
## [constant Raft.STROKE_DURATION] held asks for another, so the owner's rhythm is the raft's own
## cooldown rather than a second number that drifts from it. The server's half is
## [method NetworkPlayer._apply_paddling].
@export var paddle_strokes: int = 0

## Local-only camera and capture gate.
var movement_camera: PlayerCamera
var controls_enabled: bool = false:
	set(value):
		controls_enabled = value
		if not value:
			clear_intent()

## Whether the paddle key was down last frame, so a hold is timed from its press.
var _paddle_held: bool = false

## Seconds since the held paddle key last asked for a stroke.
var _paddle_elapsed: float = 0.0


func _process(delta: float) -> void:
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
	_update_paddle(delta)


## Releases thrust immediately; passive drift and buoyancy continue.
func clear_intent() -> void:
	move_direction = Vector2.ZERO
	wants_up = false
	wants_down = false
	wants_sprint = false
	# A paddle still down when control comes back starts again from a fresh press.
	_paddle_held = false
	_paddle_elapsed = 0.0
	# board_requests and paddle_strokes are deliberately left alone: they are running counts, and
	# zeroing one would read as a decrease on the server, which would then ignore every request
	# until the client caught back up to the count it had already served.


## Validates remote intent before it reaches the physics solver.
func world_direction() -> Vector3:
	if not move_direction.is_finite():
		return Vector3.ZERO
	var limited := move_direction.limit_length(1.0)
	return Vector3(limited.x, 0.0, limited.y)


## Asks for a stroke when the paddle key goes down, and another each stroke while it stays down.
func _update_paddle(delta: float) -> void:
	if not Input.is_action_pressed(&"paddle"):
		_paddle_held = false
		_paddle_elapsed = 0.0
		return
	if not _paddle_held:
		_paddle_held = true
		_paddle_elapsed = 0.0
		paddle_strokes += 1
		return
	_paddle_elapsed += delta
	if _paddle_elapsed < Raft.STROKE_DURATION:
		return
	# One stroke however long the frame was. A hitch spanning several strokes would otherwise ask
	# for all of them at once, and the server keeps only one outstanding request anyway.
	_paddle_elapsed = fmod(_paddle_elapsed, Raft.STROKE_DURATION)
	paddle_strokes += 1
