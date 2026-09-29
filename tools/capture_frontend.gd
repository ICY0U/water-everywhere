extends SceneTree

## Photographs the front end in the states a player sees it: the title and its panels, the HUD
## ashore and aboard, the pause menu and the summary.
##
## The flow suite proves the screens change state correctly; it cannot say whether the title reads
## over a bright sea, whether the compass and raft panel are legible, or whether anything overlaps
## at the default resolution. Those are questions for a picture.
##
## Run with a display (a real GPU, or Xvfb with a software Vulkan driver):
## [codeblock lang=text]
## godot --path . --script tools/capture_frontend.gd --resolution 1600x900
## [/codeblock]
## Images land in [code]res://docs/frontend/[/code], or the directory given by
## [code]-- --out=PATH[/code].

const SCENE_PATH: String = "res://scenes/voyage.tscn"

## Frames drawn before the first picture, for shaders to compile and the fade to finish.
const WARMUP_FRAMES: int = 30

## Frames held before each picture.
const SETTLE_FRAMES: int = 6

var _out_dir: String = "res://docs/frontend"
var _game: Node3D
var _ui: CanvasLayer


func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--out="):
			_out_dir = argument.trim_prefix("--out=")
	_run.call_deferred()


func _run() -> void:
	create_timer(1200.0).timeout.connect(func() -> void: quit(2))
	if DisplayServer.get_name() == "headless":
		printerr("capture_frontend: needs a display; run without --headless")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out_dir))

	_game = (load(SCENE_PATH) as PackedScene).instantiate() as Node3D
	root.add_child(_game)
	current_scene = _game
	_ui = _game.call("ui")
	await _frames(WARMUP_FRAMES)
	await _shot("01_title")

	var title: Control = _ui.get_node("Root/Title")
	title.call("_show_only", title.get("_solo"))
	await _shot("02_set_sail")
	title.call("show_main")

	_ui.call("open_overlay", &"settings")
	await _shot("03_settings")
	_ui.call("close_overlay")
	_ui.call("open_overlay", &"help")
	await _shot("04_how_to_play")
	_ui.call("close_overlay")

	_ui.call("start_solo", 0)
	await _frames(40)
	await _shot("05_hud_ashore")

	var body: RigidBody3D = _game.get_node_or_null("Players/1")
	var raft: RigidBody3D = _game.get("raft")
	if body != null and raft != null:
		await _teleport(body, raft.to_global(Vector3(2.0, 1.804 + 0.3, 0.5)), raft.linear_velocity)
		await _frames(30)
		await _shot("06_hud_aboard")

	_ui.call("open_pause")
	await _shot("07_pause")
	_ui.call("resume")

	if body != null:
		var mainland: Node3D = _game.get("mainland")
		await _teleport(body, mainland.global_position + Vector3(50, 12, 6), Vector3.ZERO)
		await _frames(24)
		await _shot("08_summary")
	quit(0)


## Moves [param body] on a physics frame. Set from a render callback instead, the move is
## overwritten by the physics server's own state on its next step and the body snaps back.
func _teleport(body: RigidBody3D, where: Vector3, velocity: Vector3) -> void:
	await physics_frame
	body.global_position = where
	body.linear_velocity = velocity


func _frames(count: int) -> void:
	for _frame in count:
		await RenderingServer.frame_post_draw


func _shot(shot_name: String) -> void:
	await _frames(SETTLE_FRAMES)
	var path := "%s/%s.png" % [_out_dir, shot_name]
	var error := root.get_texture().get_image().save_png(path)
	print("%s %s" % ["wrote" if error == OK else "FAILED", path])
