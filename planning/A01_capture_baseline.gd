extends SceneTree

# A01 evidence harness only: no project settings or gameplay scripts are changed.
var game: Node
var role: String
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	create_timer(60.0).timeout.connect(func():
		printerr("A01 capture timed out")
		quit(2))
	role = "host" if "--server" in OS.get_cmdline_user_args() else "client"
	game = load("res://scenes/archipelago.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	while game.get_node("Players").get_child_count() != 2:
		await process_frame
	await create_timer(3.0).timeout
	var session = root.get_node("NetworkSession")
	var player = game.get_node("Players/%d" % game.multiplayer.get_unique_id())
	var camera = game.get_node("PlayerCamera")
	_check("camera follows local owner", camera.target() == player)
	_check("two players visible in scene", game.get_node("Players").get_child_count() == 2)
	var input = player.input_node()
	input.set_process(false)
	var start: Vector3 = player.position
	input.move_direction = Vector2.RIGHT
	await create_timer(1.0).timeout
	input.move_direction = Vector2.ZERO
	await create_timer(0.5).timeout
	_check("injected owner intent moves local replicated body", player.position.x - start.x > 0.5)
	print("movement_delta=", player.position - start)
	await _shot("third_person")
	camera.toggle_view_mode()
	await create_timer(0.5).timeout
	_check("first person selected", camera.view_mode() == 1)
	await _shot("first_person")
	camera.toggle_view_mode()
	_check("third person restored", camera.view_mode() == 0)
	print("A01_RENDERED_", role, ": ", failures, " failures; renderer=", RenderingServer.get_video_adapter_name())
	# Both processes finish photographs before authority exits.
	await create_timer(8.0 if role == "host" else 2.0).timeout
	session.leave()
	quit(0 if failures == 0 else 1)

func _shot(label: String) -> void:
	await RenderingServer.frame_post_draw
	var path := "res://docs/a01_baseline/%s_%s.png" % [role, label]
	_check("capture " + label, root.get_texture().get_image().save_png(path) == OK)
	for body in game.get_node("Players").get_children():
		print(role, " player=", body.name, " position=", body.position, " stance=", body.stance, " frozen=", body.freeze)

func _check(label: String, passed: bool) -> void:
	print("PASS " if passed else "FAIL ", label)
	if not passed:
		failures += 1
