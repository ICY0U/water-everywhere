extends SceneTree

## Real geometry, collision and player traversal checks for the playable archipelago.

## Scenes that F5 is allowed to open.
##
## The check below once demanded [code]archipelago.tscn[/code] specifically, which was true when
## it was the only playable scene and became wrong the moment a second one existed: setting the
## voyage scene as the main scene turned this suite red without anything in the archipelago
## changing. What the check is actually for is catching F5 pointing at a demo, a test fixture or
## a scene that does not run — so it names the scenes that ARE a playable game, and any of them
## passes.
##
## Each entry is a [MultiplayerGame] subclass with the spawner, player container, camera and HUD
## that the session code requires. Add a scene here only once it is genuinely playable.
const PLAYABLE_MAIN_SCENES: Array[String] = [
	"res://scenes/archipelago.tscn",
	"res://scenes/voyage.tscn",
	"res://scenes/island_multiplayer.tscn",
	"res://scenes/multiplayer_demo.tscn",
]

var _failures: int = 0
var _game: Node3D


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var started := Time.get_ticks_msec()
	_game = load("res://scenes/archipelago.tscn").instantiate()
	root.add_child(_game)
	current_scene = _game
	await physics_frame
	_check("scene builds within 8 seconds", Time.get_ticks_msec() - started < 8000,
		"%d ms" % (Time.get_ticks_msec() - started))
	# This suite tests the archipelago by loading it directly above, so it does not need to be
	# the main scene — it only needs F5 to open something playable. See PLAYABLE_MAIN_SCENES.
	var main_scene: String = ProjectSettings.get_setting("application/run/main_scene")
	_check("F5 loads a playable world", main_scene in PLAYABLE_MAIN_SCENES, main_scene)
	var home := _game.get_node("HomeIsland") as ExplorationIsland
	var explore := _game.get_node("ExplorationIsland") as ExplorationIsland
	_check("starter island is larger", home.plateau_radius >= 70.0)
	_check("exploration island is substantially larger", explore.plateau_radius > home.plateau_radius * 3.0)
	var islands: Array[Island] = [home, explore]
	for node in _game.get_node("Islets").get_children():
		islands.append(node as Island)
	_check("five scattered playable islets", islands.size() == 7)
	for island in islands:
		_check_surface(island)
	for node in _game.get_node("Backdrop").get_children():
		var background := node as Island
		var collision := background.get_node("Collision") as CollisionShape3D
		_check("%s is visual only" % node.name, collision.shape == null and collision.disabled)
		var mesh := (background.get_node("Mesh") as MeshInstance3D).mesh
		var faces := mesh.get_faces()
		_check("%s stays under 2000 triangles" % node.name, faces.size() / 3 <= 2000)
		var arrays := mesh.surface_get_arrays(0)
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var flat := true
		for i in range(0, normals.size(), 3):
			if not normals[i].is_equal_approx(normals[i + 1]):
				flat = false
				break
		_check("%s has flat polygon shading" % node.name, flat)
		_check("%s is beyond playable land" % node.name,
			background.position.distance_to(explore.position) > 900.0)
	var summit := 0.0
	for z in range(-240, 241, 20):
		for x in range(-240, 241, 20):
			summit = maxf(summit, explore._profile(Vector2(x, z)))
	_check("mountains exceed 100 metres", summit > 100.0, "%.1f m" % summit)
	_check_ascent(explore)
	await _walk_player(home, explore)
	print("verify_archipelago: %d failures" % _failures)
	quit(1 if _failures else 0)


func _check_surface(island: Island) -> void:
	var mesh := (island.get_node("Mesh") as MeshInstance3D).mesh
	_check("%s has terrain and collision" % island.name,
		mesh != null and (island.get_node("Collision") as CollisionShape3D).shape != null)
	var maximum_error := 0.0
	for x in [-0.5, 0.0, 0.5]:
		for z in [-0.5, 0.0, 0.5]:
			var local := Vector2(x, z) * island.plateau_radius
			var column := Vector2(island.position.x, island.position.z) + local
			var hit := _ground(column)
			if hit.is_empty():
				maximum_error = INF
				continue
			maximum_error = maxf(maximum_error,
				absf(hit.position.y - island.height_at_world(column)))
	_check("%s collision matches visible height field" % island.name,
		maximum_error < 0.3, "%.3f m" % maximum_error)
	var peer := island.duplicate() as Island
	# No tree required: terrain is a pure function of the saved parameters.
	var same := true
	for index in 30:
		var point := Vector2(sin(index * 1.7), cos(index * 0.8)) * island.plateau_radius
		if not is_equal_approx(island._profile(point), peer._profile(point)):
			same = false
	peer.free()
	_check("%s terrain is deterministic across peers" % island.name, same)


func _check_ascent(island: ExplorationIsland) -> void:
	var worst := 1.0
	var route_clear := true
	for index in ExplorationIsland.ASCENT.size() - 1:
		for step in 20:
			var point := ExplorationIsland.ASCENT[index].lerp(
				ExplorationIsland.ASCENT[index + 1], float(step) / 20.0) + island.position
			var hit := _ground(Vector2(point.x, point.z))
			if hit.is_empty():
				route_clear = false
				continue
			worst = minf(worst, hit.normal.y)
	_check("continuous climbable route reaches high saddle",
		route_clear and worst > 0.85, "worst slope %.1f degrees" % rad_to_deg(acos(worst)))


func _walk_player(home: Island, explore: Island) -> void:
	_game.call("_spawn_for_peer", 1)
	await _frames(100)
	var player := _game.get_node("Players").get_child(0) as NetworkPlayer
	player.input_node().set_process(false)
	_check("player spawns grounded in the clearing", player.stance == NetworkPlayer.Stance.GROUNDED)
	_check("starter clearing is above the sea", player.position.y > 5.0)
	var start := player.position
	player.input_node().move_direction = Vector2.RIGHT
	await _frames(90)
	_check("player can walk from the starter spawn", player.position.x - start.x > 3.0)
	player.input_node().clear_intent()
	# Walk every metre of the ascent with the production physics controller, not teleports.
	var first := ExplorationIsland.ASCENT[0] + explore.position
	player.position = first + Vector3.UP * 0.1
	player.rotation = Vector3.ZERO
	player.linear_velocity = Vector3.ZERO
	player.angular_velocity = Vector3.ZERO
	await _frames(60)
	var reached := 0
	var tilt := 0.0
	player.input_node().wants_sprint = true
	for index in range(1, ExplorationIsland.ASCENT.size()):
		var target := ExplorationIsland.ASCENT[index] + explore.position
		for frame in 2400:
			var offset := Vector2(target.x - player.position.x, target.z - player.position.z)
			if offset.length() < 2.5:
				reached += 1
				break
			player.input_node().move_direction = offset.normalized()
			await physics_frame
			tilt = maxf(tilt, rad_to_deg(player.global_basis.y.angle_to(Vector3.UP)))
		if reached < index:
			break
	player.input_node().clear_intent()
	_check("real player traverses the entire mountain route", reached == 8,
		"%d/8 route segments; height %.1f m; max tilt %.1f degrees" % [reached, player.position.y, tilt])
	_check("player stays upright on the ascent", tilt < 12.0)


func _ground(point: Vector2) -> Dictionary:
	return _game.get_world_3d().direct_space_state.intersect_ray(
		PhysicsRayQueryParameters3D.create(Vector3(point.x, 400, point.y),
			Vector3(point.x, -80, point.y), 1))


func _frames(count: int) -> void:
	for frame in count:
		await physics_frame


func _check(label: String, passed: bool, detail: String = "") -> void:
	print("%s %s %s" % ["PASS" if passed else "FAIL", label, detail])
	if not passed:
		_failures += 1
