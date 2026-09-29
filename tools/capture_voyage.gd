extends SceneTree

## Photographs the voyage's landmarks: the jetty with its moored raft, and the lighthouse.
##
## The crossing suite proves the voyage can be sailed; it cannot say whether the jetty reads as
## the way to the raft, whether the lighthouse reads as the destination from the far side of the
## water, or whether either looks like it belongs in the painted world. Each framing asks one.
##
## Run with a display (a real GPU, or Xvfb with a software Vulkan driver):
## [codeblock lang=text]
## godot --path . --script tools/capture_voyage.gd --resolution 1600x900
## [/codeblock]
## Images land in [code]res://docs/voyage/[/code], or the directory given by
## [code]-- --out=PATH[/code].

const SCENE_PATH: String = "res://scenes/voyage.tscn"

## Frames drawn before anything is photographed, so shaders compile and the raft settles.
const WARMUP_FRAMES: int = 40

## Frames held at each framing before it is saved.
const FRAMING_FRAMES: int = 6

## Camera framings: position, look-at target and what the picture is evidence of.
const SHOTS: Array[Dictionary] = [
	{"name": "01_jetty_from_spawn", "position": Vector3(-14, 9.5, 6),
		"target": Vector3(-52, 1.5, 0), "note": "the jetty and the moored raft from where a crew arrives"},
	{"name": "02_raft_moored", "position": Vector3(-44, 6.5, 14),
		"target": Vector3(-56, 1.0, 0), "note": "the raft on its mooring line at the jetty's end"},
	{"name": "03_lighthouse_from_sea", "position": Vector3(-80, 5, 4),
		"target": Vector3(-212, 18, 8), "note": "the destination as seen from the raft mid-crossing"},
	{"name": "04_lighthouse_close", "position": Vector3(-178, 12, 30),
		"target": Vector3(-212, 14, 8), "note": "the lighthouse and cottage from the landing beach"},
]

var _out_dir: String = "res://docs/voyage"


func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--out="):
			_out_dir = argument.trim_prefix("--out=")
	_run.call_deferred()


func _run() -> void:
	create_timer(900.0).timeout.connect(func() -> void: quit(2))
	if DisplayServer.get_name() == "headless":
		printerr("capture_voyage: needs a display; run without --headless")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out_dir))

	var scene := (load(SCENE_PATH) as PackedScene).instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene
	for node_name: String in ["HUD", "GameUI"]:
		var ui := scene.get_node_or_null(node_name) as CanvasLayer
		if ui != null:
			ui.hide()
	var rig := scene.get_node_or_null("PlayerCamera")
	if rig != null:
		rig.set_process(false)
		rig.set_process_unhandled_input(false)

	var camera := Camera3D.new()
	camera.fov = 60.0
	camera.far = 4000.0
	scene.add_child(camera)
	camera.current = true
	for node_name: String in ["Ocean", "Atmosphere", "OceanSpray", "RainShower"]:
		var node := scene.get_node_or_null(node_name)
		if node != null:
			node.set("follow_target", camera)

	camera.global_position = SHOTS[0]["position"]
	camera.look_at(SHOTS[0]["target"])
	for _frame: int in WARMUP_FRAMES:
		await RenderingServer.frame_post_draw

	for shot: Dictionary in SHOTS:
		camera.global_position = shot["position"]
		camera.look_at(shot["target"])
		for _frame: int in FRAMING_FRAMES:
			await RenderingServer.frame_post_draw
		var path := "%s/%s.png" % [_out_dir, shot["name"]]
		var error := root.get_texture().get_image().save_png(path)
		print("%s %s — %s" % ["wrote" if error == OK else "FAILED", path, shot["note"]])
	quit(0)
