extends SceneTree

## Checks the normal entry point, then captures the actual player camera when rendered.
func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var game := load(ProjectSettings.get_setting("application/run/main_scene")).instantiate() as Node3D
	root.add_child(game)
	current_scene = game
	var session := root.get_node("NetworkSession")
	for frame in 10:
		await physics_frame
	var offline: bool = not session.is_active() and game.get_node("Players").get_child_count() == 0
	var key := InputEventKey.new()
	key.keycode = KEY_H
	key.pressed = true
	Input.parse_input_event(key)
	for frame in 180:
		await physics_frame
	var players := game.get_node("Players")
	var passed: bool = offline and session.is_active() and players.get_child_count() == 1
	if passed:
		var player := players.get_child(0) as NetworkPlayer
		var camera := game.get_node("PlayerCamera") as PlayerCamera
		passed = player.stance == NetworkPlayer.Stance.GROUNDED and camera.target() == player
		print("spawn=", player.position, " grounded=", player.stance == NetworkPlayer.Stance.GROUNDED)
		if DisplayServer.get_name() != "headless":
			for frame in 40:
				await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png("res://docs/archipelago/07_playable_spawn.png")
	print("verify_archipelago_start: %s" % ("passed" if passed else "FAILED"))
	session.leave()
	quit(0 if passed else 1)
