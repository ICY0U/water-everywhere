extends SceneTree

## Exercises the actual rigid-body controller through starts, corners, reversals and stops.
## Run headless with --fixed-fps 60.
const PLAYER = preload("res://scenes/player_kotarou.tscn")
var _failures: int = 0
var _player: NetworkPlayer
var _floor: StaticBody3D


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	current_scene = world
	_floor = StaticBody3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(400.0, 1.0, 400.0)
	var collider := CollisionShape3D.new()
	collider.shape = shape
	_floor.add_child(collider)
	_floor.position.y = -0.5
	world.add_child(_floor)
	_player = PLAYER.instantiate()
	if "--central-force" in OS.get_cmdline_user_args():
		_player.foot_force_enabled = false
	_player.position.y = 0.02
	world.add_child(_player)
	_player.input_node().set_process(false)
	await _frames(60)
	await _exercise(false)
	await _exercise(true)
	await _slope()
	_player.input_node().clear_intent()
	_player.position = Vector3(0.0, 0.7, 0.0)
	_player.linear_velocity = Vector3.ZERO
	_player.angular_velocity = Vector3.ZERO
	await _frames(2)
	_check("feet above ground do not count as supported", 
		_player.stance == NetworkPlayer.Stance.AIRBORNE, str(_player.stance))
	print("verify_locomotion: %s" % ("all checks passed" if _failures == 0 else "%d failures" % _failures))
	quit(0 if _failures == 0 else 1)


func _slope() -> void:
	_floor.rotation.z = deg_to_rad(18.0)
	_player.input_node().clear_intent()
	_player.position = Vector3(0.0, 0.35, 0.0)
	_player.rotation = Vector3.ZERO
	_player.linear_velocity = Vector3.ZERO
	_player.angular_velocity = Vector3.ZERO
	await _frames(120)
	var start := _player.position
	await _frames(120)
	_check("idle on a slope does not slide", _player.position.distance_to(start) < 0.15,
		"%.3f m" % _player.position.distance_to(start))
	_player.input_node().move_direction = Vector2.RIGHT
	var tilt := 0.0
	for frame in 150:
		await physics_frame
		tilt = maxf(tilt, rad_to_deg(_player.global_basis.y.angle_to(Vector3.UP)))
	_check("walking uphill stays upright", tilt < 5.0, "%.2f degrees" % tilt)
	_check("walks up a slope", _player.position.x > start.x + 5.0, str(_player.position - start))
	_floor.rotation = Vector3.ZERO


func _exercise(sprint: bool) -> void:
	_player.position = Vector3(0.0, 0.02, 0.0)
	_player.rotation = Vector3.ZERO
	_player.linear_velocity = Vector3.ZERO
	_player.angular_velocity = Vector3.ZERO
	_player.input_node().clear_intent()
	await _frames(45)
	_player.input_node().wants_sprint = sprint
	var tilt := 0.0
	var unsupported := 0
	var label := "sprint" if sprint else "walk"
	for direction in [Vector2.UP, Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN,
		Vector2(1.0, -1.0).normalized(), Vector2(-1.0, 1.0).normalized()]:
		_player.input_node().move_direction = direction
		for frame in 90:
			await physics_frame
			tilt = maxf(tilt, rad_to_deg(_player.global_basis.y.angle_to(Vector3.UP)))
			if _player.stance != NetworkPlayer.Stance.GROUNDED:
				unsupported += 1
	_check(label + " stays upright through sharp turns and reversals", tilt < 5.0,
		"peak tilt %.2f degrees" % tilt)
	_check(label + " retains ground support", unsupported == 0, "%d unsupported frames" % unsupported)
	var speed := Vector2(_player.linear_velocity.x, _player.linear_velocity.z).length()
	var target := NetworkPlayer.WALK_SPEED * (NetworkPlayer.SPRINT_MULTIPLIER if sprint else 1.0)
	_check(label + " reaches intended speed", speed > target * 0.85,
		"%.2f / %.2f m/s" % [speed, target])
	_player.input_node().clear_intent()
	var stop_start := _player.position
	await _frames(30)
	var stop_distance := Vector2(_player.position.x - stop_start.x, _player.position.z - stop_start.z).length()
	_check(label + " stops promptly", stop_distance < (1.3 if sprint else 0.45),
		"%.3f m" % stop_distance)
	_check(label + " settles without sliding", Vector2(_player.linear_velocity.x,
		_player.linear_velocity.z).length() < 0.1, str(_player.linear_velocity))


func _frames(count: int) -> void:
	for frame in count:
		await physics_frame


func _check(label: String, passed: bool, detail: String) -> void:
	print("  %s  %s: %s" % ["PASS" if passed else "FAIL", label, detail])
	if not passed:
		_failures += 1
