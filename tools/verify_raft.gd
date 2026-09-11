extends SceneTree

## Runs the shipping scene, then checks loaded buoyancy, deck movement and late spawns.
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, condition: bool, detail: Variant = "") -> void:
	print("%s %s %s" % ["PASS" if condition else "FAIL", label, str(detail)])
	if not condition:
		failures += 1

func _run() -> void:
	create_timer(45.0).timeout.connect(func(): quit(2))
	var game := load("res://scenes/multiplayer_demo.tscn").instantiate() as Node3D
	root.add_child(game)
	current_scene = game
	var session := root.get_node("NetworkSession")
	session.host(27103, "Raft test")
	await physics_frame
	var raft := game.get("raft") as Raft
	var players := game.get_node("Players") as Node3D
	var player := players.get_child(0) as NetworkPlayer
	check("spawn above deck", raft.to_local(player.position).y > Raft.DECK_HEIGHT + 1.0)
	check("imported model has materials", (raft.get_node("Model") as MeshInstance3D).mesh.get_surface_count() >= 5)
	await create_timer(10.0).timeout
	var local := raft.to_local(player.global_position)
	check("raft floats with player aboard", raft.submersion() > 0.01 and raft.submersion() < 0.8, raft.submersion())
	check("player settles on deck", absf(local.x) < 4 and absf(local.z) < 4 and local.y > Raft.DECK_HEIGHT + 0.8 and local.y < Raft.DECK_HEIGHT + 1.7, local)
	check("raft stays upright", raft.global_basis.y.dot(Vector3.UP) > 0.8)
	# Move via the same input consumed by server physics, with live input sampling disabled.
	player.input_node().set_process(false)
	player.input_node().set_physics_process(false)
	player.input_node().move_direction = Vector2(1, 0)
	var before := raft.to_local(player.position)
	await create_timer(0.6).timeout
	player.input_node().move_direction = Vector2.ZERO
	var after := raft.to_local(player.position)
	check("WASD moves along deck", after.x - before.x > 0.3, after - before)
	await create_timer(2.0).timeout
	# Spawn a second real player through the production spawner after the raft has drifted.
	game._spawn_for_peer(2)
	await physics_frame
	var guest := players.get_node("2") as NetworkPlayer
	check("late spawn tracks raft", raft.to_local(guest.global_position).y > Raft.DECK_HEIGHT + 0.9)
	check("late spawn avoids host", guest.global_position.distance_to(player.global_position) > 2.5)
	await create_timer(8.0).timeout
	local = raft.to_local(guest.global_position)
	check("second player supported", absf(local.x) < 4.5 and absf(local.z) < 4.8 and local.y > Raft.DECK_HEIGHT + 0.6, local)
	check("loaded raft remains afloat", raft.submersion() < 0.85 and raft.global_basis.y.dot(Vector3.UP) > 0.75, raft.submersion())
	if DisplayServer.get_name() != "headless":
		# A fixed overview shows the full asset and the two supported players.
		game.get_node("PlayerCamera").set_process(false)
		game.get_node("PlayerCamera").set_physics_process(false)
		var camera := Camera3D.new()
		game.add_child(camera)
		camera.global_position = raft.global_position + Vector3(13, 11, 17)
		camera.look_at(raft.global_position + Vector3.UP)
		camera.current = true
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://docs/raft_in_game.png")
	session.leave()
	print("verify_raft: %d failures" % failures)
	quit(1 if failures else 0)
