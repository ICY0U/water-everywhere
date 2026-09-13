extends SceneTree

## Photographs a player standing on the island in the real scene, so the spawn can be checked
## visually rather than only as coordinates.

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var output := "user://island_shots"
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--output="):
			output = argument.trim_prefix("--output=")
	DirAccess.make_dir_recursive_absolute(output)

	var game: Node3D = load("res://scenes/island_multiplayer.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	await physics_frame
	game._spawn_for_peer(1)
	game._spawn_for_peer(2)

	for i in 150:
		await physics_frame

	var body := game.get_node("Players").get_child(0) as Node3D
	var camera := Camera3D.new()
	camera.current = true
	game.add_child(camera)

	var shots := {
		"island_close": [Vector3(3.2, 1.6, 3.2), Vector3(-12.0, 45.0, 0.0)],
		"island_wide": [Vector3(14.0, 7.0, 14.0), Vector3(-18.0, 45.0, 0.0)],
		"island_feet": [Vector3(1.8, 0.5, 1.8), Vector3(-4.0, 45.0, 0.0)],
	}
	for name in shots:
		var where: Array = shots[name]
		camera.global_position = body.global_position + (where[0] as Vector3)
		camera.rotation_degrees = where[1]
		await process_frame
		await process_frame
		get_root().get_texture().get_image().save_png("%s/%s.png" % [output, name])

	print("island shots written to ", ProjectSettings.globalize_path(output))
	quit(0)
