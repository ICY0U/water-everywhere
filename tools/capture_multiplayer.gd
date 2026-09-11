extends Node

## Photographs the networked demo, so the two windows can be checked without watching them.
##
## Multiplayer fails in ways a log will not show. A player can replicate its position but not
## its name; two clients can each draw a cube in a different place; a name tag can end up
## behind the head it belongs to, or facing away from the camera. All of that is visible only
## in a picture, which is why this exists alongside the headless assertions rather than instead
## of them.
##
## Each instance photographs its own view and names the file after its role, so the server and
## client shots can be put side by side afterwards.
##
## Register it temporarily rather than committing it to [code]project.godot[/code]:
## [codeblock lang=text]
## [autoload]
## MultiplayerShotter="*res://tools/capture_multiplayer.gd"
## [/codeblock]
## Images land in [code]user://shots/[/code].

## Directory the images are written to.
const OUTPUT_DIRECTORY: String = "user://shots"

## Frames to wait before the first capture.
##
## Long enough for the client to connect, for both players to spawn, and for the foam
## simulation to build a wake behind them — foam accumulates over seconds, and a shot taken
## too early shows bare water around bodies that have obviously been sitting there.
const WARMUP_FRAMES: int = 480

## Frames between captures.
const SETTLE_FRAMES: int = 90

## How many shots each instance takes.
const SHOT_COUNT: int = 3

## Frames the SERVER waits after its last shot before quitting.
##
## The server holds the session open: quitting it disconnects every client, and a client that
## is still lining up its own photographs would then take them of an empty sea. Nothing about
## the game requires this — it is purely that the photographer must not demolish the set while
## the other camera is still shooting.
const SERVER_LINGER_FRAMES: int = 600

var _role: String = "solo"


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUTPUT_DIRECTORY)

	for argument in OS.get_cmdline_user_args():
		if argument == "--server":
			_role = "server"
		elif argument == "--client":
			_role = "client"

	await _capture_all()


func _capture_all() -> void:
	for _frame in WARMUP_FRAMES:
		await RenderingServer.frame_post_draw

	for shot in SHOT_COUNT:
		_save("%02d_%s" % [shot + 1, _role])
		for _frame in SETTLE_FRAMES:
			await RenderingServer.frame_post_draw

	# The server stays up until the client has finished, or its exit would disconnect the very
	# session the client is trying to photograph.
	if _role == "server":
		for _frame in SERVER_LINGER_FRAMES:
			await RenderingServer.frame_post_draw

	get_tree().quit(0)


func _save(shot_name: String) -> void:
	var path := "%s/mp_%s.png" % [OUTPUT_DIRECTORY, shot_name]
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(path)
	if error != OK:
		printerr("capture_multiplayer: failed to save %s (error %d)" % [path, error])
		return

	# Printed alongside the file so a shot that looks wrong can be matched against what the
	# game believed at the time — which player bodies existed, and where.
	var players := get_tree().root.find_child("Players", true, false)
	var summary := PackedStringArray()
	if players != null:
		for child in players.get_children():
			var body := child as Node3D
			if body == null:
				continue
			var tag := body.get_node_or_null("NameTag") as Label3D
			summary.append("%s'%s'@%s" % [
				body.name,
				tag.text if tag != null else "?",
				str(body.global_position.snappedf(0.1)),
			])

	print("%s: %s | players: %s" % [
		shot_name, ProjectSettings.globalize_path(path), " ".join(summary),
	])
