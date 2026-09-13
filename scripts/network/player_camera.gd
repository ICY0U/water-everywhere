class_name PlayerCamera
extends Node3D

## The local player's camera, in third or first person.
##
## This node is the pivot: it sits at the player's eye point and carries the yaw and pitch the
## mouse has chosen. A [SpringArm3D] hangs off it, and the [Camera3D] hangs off that. The
## nesting is not decoration — [SpringArm3D] casts along its own Z axis and moves its direct
## children to whatever it hits, so a camera it is meant to protect has to be its child rather
## than something positioned alongside it.
##
## [b]Third person[/b] extends the arm to [member follow_distance]; [b]first person[/b]
## collapses it to nothing, putting the camera at the pivot itself. The two modes are therefore
## the same rig at two arm lengths, which is why switching between them cannot introduce a
## discontinuity in where the player is looking.
##
## [b]The horizon stays level in both.[/b] The camera follows the hull's position but never its
## rotation. A camera bolted to a body floating on waves inherits every bob and roll, and on a
## two-metre swell the horizon pitches hard enough to make the sea unreadable — the motion
## belongs to the boat, not to the viewer watching it. Rising and falling with the water still
## conveys the swell; tumbling with it only conveys nausea.
##
## [b]Nothing here is replicated.[/b] Where a player is looking is a local concern, and the
## first-person mesh hiding is done with a cull mask, which is a property of this viewer's
## camera rather than of the body being hidden. Both peers see every body; only this one
## declines to draw its own.

## Emitted when the view mode changes, so a HUD can say which one is active.
signal view_mode_changed(mode: ViewMode)

## Render layer carrying the local player's own name tag.
##
## The camera drops this layer from its cull mask in first person. Only the TAG is hidden: a
## name floating in the middle of the screen is useless to the person it names, while the cube
## itself is worth keeping — seeing the hull you are standing on is most of what makes a first
## person view feel located rather than free-floating.
##
## Every other player stays on the default layer and is unaffected, and nothing about the
## hidden tag changes for anyone else: a cull mask belongs to this viewer's camera, not to the
## body being hidden.
const LOCAL_BODY_LAYER: int = 2

## Where the camera sits in first person, relative to the body's centre, in metres.
##
## Both components were set from pictures rather than from the geometry, and each fixes a
## specific failure:
##
## * [b]Height.[/b] A two-metre cube at 420 kg/m³ floats with most of its bulk under water, so
##   an eye derived from the hull's half-height sits barely above the waterline — the view
##   fills with sea and looking down shows only foam.
## * [b]Forward.[/b] An eye directly over the centre looks straight into the far half of the
##   hull, which then occupies the bottom of the screen at every pitch. Moving it to the bow
##   leaves the deck visible when looking down, which is what locates the player, without it
##   dominating the view ahead.
const EYE_OFFSET: Vector3 = Vector3(0.0, 1.5, -0.95)

## Smallest gap between the first-person eye and the water, in metres.
##
## Only a last resort against the view going under in a deep trough. Kept low deliberately:
## the eye is already tied to the hull, and a generous floor would decouple the two exactly
## when the boat drops, turning a wave into a moment of hovering.
const FIRST_PERSON_WATER_CLEARANCE: float = 0.45

## How the world is being viewed.
enum ViewMode {
	## Behind and above the player.
	THIRD_PERSON,
	## From the player's own eye point.
	FIRST_PERSON,
}

@export_group("Third Person")

## Distance behind the player, in metres.
@export_range(2.0, 60.0, 0.5) var follow_distance: float = 12.0

## Height of the pivot above the body's centre, in metres.
@export_range(0.0, 20.0, 0.1) var pivot_height: float = 1.6

## How quickly the pivot closes on the player, as an exponential rate.
##
## Low values drift cinematically; high values track rigidly and reintroduce the bobbing this
## rig exists to avoid.
@export_range(0.5, 30.0, 0.1) var follow_stiffness: float = 6.0

@export_group("First Person")

## How quickly the pivot closes on the player in first person.
##
## Much stiffer than the third-person value. At arm's length a lag reads as a camera drifting
## behind its subject, which is pleasant; at the eye point the same lag reads as the head
## sliding around inside the body, which is not.
@export_range(1.0, 60.0, 0.5) var first_person_stiffness: float = 22.0

## Vertical field of view in first person, in degrees.
##
## Wider than the third-person value, which is the usual compensation for having no visible
## body to give the view a sense of scale.
@export_range(40.0, 110.0, 1.0) var first_person_fov: float = 78.0

@export_group("Look")

## Degrees of rotation per pixel of mouse motion.
@export_range(0.01, 1.0, 0.01) var mouse_sensitivity: float = 0.25

## How far the view can be pitched down from level, in degrees.
@export_range(0.0, 89.0, 1.0) var pitch_down_limit: float = 70.0

## How far the view can be pitched up from level, in degrees.
@export_range(0.0, 89.0, 1.0) var pitch_up_limit: float = 60.0

@export_group("Framing")

## Vertical field of view in third person, in degrees.
@export_range(40.0, 110.0, 1.0) var third_person_fov: float = 70.0

## Height above the water the camera refuses to go below, in metres.
##
## Without a floor the camera dips under the surface in a trough and the whole screen fills
## with the underside of the water.
@export_range(0.2, 20.0, 0.1) var minimum_water_clearance: float = 1.2

## Ocean consulted for the surface height, so the camera can stay above it.
@export var ocean: Ocean

@onready var _arm: SpringArm3D = $SpringArm
@onready var _camera: Camera3D = $SpringArm/Camera

var _target: Node3D = null
var _mode: ViewMode = ViewMode.THIRD_PERSON
var _yaw: float = 0.0
var _pitch: float = -0.18
var _mouse_captured: bool = false

## A local UI owns input while open. Camera follow continues, but look and movement stop.
var input_blocked: bool = false


func _ready() -> void:
	_apply_mode()
	_set_mouse_captured(true)


func _unhandled_input(event: InputEvent) -> void:
	if input_blocked:
		return
	var motion := event as InputEventMouseMotion
	if motion != null and _mouse_captured:
		_yaw -= deg_to_rad(motion.relative.x * mouse_sensitivity)
		_pitch -= deg_to_rad(motion.relative.y * mouse_sensitivity)
		_pitch = clampf(
			_pitch, -deg_to_rad(pitch_down_limit), deg_to_rad(pitch_up_limit)
		)
		return

	if event.is_action_pressed(&"toggle_view"):
		toggle_view_mode()
		return

	if event.is_action_pressed(&"ui_cancel"):
		_set_mouse_captured(not _mouse_captured)
		return

	var button := event as InputEventMouseButton
	if (button != null and button.button_index == MOUSE_BUTTON_LEFT
			and button.is_pressed() and not _mouse_captured):
		_set_mouse_captured(true)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_set_mouse_captured(false)


## Yaw-only movement frame, independent of camera pitch and the hull's rotation.
func movement_basis() -> Basis:
	return Basis(Vector3.UP, _yaw)


func _process(delta: float) -> void:
	# Both conditions are needed. A freed target fails is_instance_valid, but a target that is
	# merely queued for deletion — a player who has just disconnected — is still "valid" while
	# already out of the tree, and reading its transform then is an error rather than a stale
	# value.
	if not is_instance_valid(_target) or not _target.is_inside_tree():
		return

	var wanted := _pivot_position()

	# Kept above the water, or a trough swallows the view. The clearance is smaller in first
	# person: there the eye point is already fixed to the hull, and a large floor would lift the
	# view off the boat every time it dropped into a trough — which reads as the player hovering
	# rather than as the sea rising.
	if ocean != null:
		var clearance := (
			FIRST_PERSON_WATER_CLEARANCE if _mode == ViewMode.FIRST_PERSON
			else minimum_water_clearance
		)
		var surface := ocean.get_water_height(Vector2(wanted.x, wanted.z))
		wanted.y = maxf(wanted.y, surface + clearance)

	var stiffness := (
		first_person_stiffness if _mode == ViewMode.FIRST_PERSON else follow_stiffness
	)
	# Exponential smoothing, expressed so the result does not depend on frame rate.
	var weight := 1.0 - exp(-delta * stiffness)
	global_position = global_position.lerp(wanted, weight)

	# Rotation is set outright rather than smoothed. The mouse is a direct input and any lag
	# between moving it and the view turning reads as sluggishness, not as smoothness —
	# distinct from the POSITION lag above, which is what absorbs the boat's bobbing.
	global_transform.basis = Basis.from_euler(Vector3(_pitch, _yaw, 0.0))


## Points the rig at [param body] and snaps to it, skipping the approach from wherever the
## camera happened to start.
func follow(body: Node3D) -> void:
	if is_instance_valid(_target) and _target is NetworkPlayer:
		(_target as NetworkPlayer).input_node().controls_enabled = false
	_target = body
	if not is_instance_valid(body):
		return
	global_position = _pivot_position()
	global_transform.basis = Basis.from_euler(Vector3(_pitch, _yaw, 0.0))
	_apply_local_body_layer()
	if body is NetworkPlayer:
		var input := (body as NetworkPlayer).input_node()
		input.movement_camera = self
		input.controls_enabled = _mouse_captured and not input_blocked


## Returns the body being followed, or null.
func target() -> Node3D:
	return _target


## Returns which view is active.
func view_mode() -> ViewMode:
	return _mode


## Switches between third and first person.
func toggle_view_mode() -> void:
	set_view_mode(
		ViewMode.THIRD_PERSON if _mode == ViewMode.FIRST_PERSON else ViewMode.FIRST_PERSON
	)


## Sets the view mode, hiding or showing the local body to match.
func set_view_mode(mode: ViewMode) -> void:
	if _mode == mode:
		return
	_mode = mode
	_apply_mode()
	view_mode_changed.emit(_mode)


## Returns where the pivot wants to be this frame, in world space.
##
## The body's POSITION is used and its rotation deliberately ignored, which is what keeps the
## horizon level while still riding the swell.
func _pivot_position() -> Vector3:
	if not is_instance_valid(_target):
		return global_position

	if _mode == ViewMode.FIRST_PERSON:
		# The eye offset is rotated by the view's own yaw rather than by the hull's, so leaning
		# out of a rolling boat does not swing the eye point around with it.
		var facing := Basis.from_euler(Vector3(0.0, _yaw, 0.0))
		return _target.global_position + facing * EYE_OFFSET

	return _target.global_position + Vector3.UP * pivot_height


## Applies everything that differs between the two modes.
func _apply_mode() -> void:
	if _arm == null or _camera == null:
		return

	var first_person: bool = _mode == ViewMode.FIRST_PERSON
	# Collapsing the arm to zero puts the camera at the pivot. The arm still runs its cast at
	# zero length, which costs nothing and keeps the two modes on one code path.
	_arm.spring_length = 0.0 if first_person else follow_distance
	_camera.fov = first_person_fov if first_person else third_person_fov
	_apply_local_body_layer()


## Hides or shows the local player's own name tag for this viewer only.
##
## Done with the camera's cull mask rather than by hiding the node: the tag must stay visible
## to everyone else, and [member Node3D.visible] is a property of the tag itself, so hiding it
## would remove it from every screen at once. A cull mask belongs to the camera, so this one
## viewer declines to draw something that is in every other respect completely normal.
func _apply_local_body_layer() -> void:
	if _camera == null:
		return
	_camera.set_cull_mask_value(LOCAL_BODY_LAYER, _mode != ViewMode.FIRST_PERSON)

	# The tag is moved onto the dedicated layer here rather than in the player scene, because
	# only the LOCAL player's tag should be hidden — the same scene spawns for everyone.
	if not is_instance_valid(_target):
		return
	var tag := _target.get_node_or_null("NameTag") as VisualInstance3D
	if tag != null:
		tag.set_layer_mask_value(1, false)
		tag.set_layer_mask_value(LOCAL_BODY_LAYER, true)


func _set_mouse_captured(captured: bool) -> void:
	captured = captured and not input_blocked
	_mouse_captured = captured
	Input.mouse_mode = (
		Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE
	)
	if is_instance_valid(_target) and _target is NetworkPlayer:
		(_target as NetworkPlayer).input_node().controls_enabled = captured
