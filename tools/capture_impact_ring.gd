extends SceneTree

## Photographs one impact ring across its whole life, and measures how much of the quad it covers.
##
## Written for a bug that a still frame taken at the wrong moment cannot see. The ring lives
## 0.65-1.8 s, and the failure was age-dependent: the white core term lost its sign partway
## through, every fragment landed exactly on [code]ALPHA_SCISSOR_THRESHOLD[/code], and a
## scissored fragment at the threshold is kept and drawn opaque — so the quad turned solid white
## and then into a starburst as erosion ate direction-space cells out of it. A shutter before
## that moment shows a perfectly good ring.
##
## So this samples several ages of the SAME ring and reports the fraction of the frame that is
## near-white, which is the number that separates "a foam crown" from "an 18 m white slab".
##
## Run with (no [code]--headless[/code]: it has to render):
## [codeblock lang=text]
## godot --path . --script tools/capture_impact_ring.gd -- --output=docs/impact_ring
## [/codeblock]

const SCENE_PATH: String = "res://scenes/multiplayer_demo.tscn"

## Ages through the ring's life to photograph. Spread either side of the erosion threshold at
## 0.42 and the core fade ending at 0.38, because that is where the failure appeared.
const AGES: Array[float] = [0.05, 0.2, 0.4, 0.55, 0.75, 0.95]

## Impact standing in for a raft hull hitting the water: the large-radius case David reported.
const RAFT_RADIUS: float = 4.8
const RAFT_ENERGY: float = 8721.0
const RAFT_IMPULSE: float = 41000.0
const RAFT_VOLUME: float = 26.0

## Luma above which a pixel counts as "white slab" rather than sea or foam edge.
const WHITE_LUMA: float = 0.93

var _output: String = "user://impact_ring"


func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--output="):
			_output = argument.trim_prefix("--output=")
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(_output)

	var game := (load(SCENE_PATH) as PackedScene).instantiate() as Node3D
	root.add_child(game)
	current_scene = game
	await physics_frame

	var ocean := game.get_node("Ocean") as Ocean
	var reactions := game.get_node("WaterReactions") as WaterReactionSystem

	# Let the sea and its shaders come up before anything is judged: a first frame is of a world
	# that has not started.
	for i in 90:
		await process_frame

	var where := Vector2(6.0, -4.0)
	var impact := WaterImpact.new()
	impact.position = ocean.get_surface_point(where)
	impact.normal = ocean.get_water_normal(where)
	impact.impact_speed = 1.15
	impact.relative_velocity = Vector3(0.0, -1.15, 0.0)
	impact.waterline_radius = RAFT_RADIUS
	impact.volume = RAFT_VOLUME
	impact.impulse = RAFT_IMPULSE
	impact.energy = RAFT_ENERGY
	impact.kind = Ocean.ImpactKind.ENTRY
	ocean.report_impact(impact)
	await process_frame

	var ring := reactions.get_node("ImpactRing0") as MeshInstance3D
	var material := ring.material_override as ShaderMaterial

	var camera := Camera3D.new()
	camera.current = true
	game.add_child(camera)
	camera.global_position = impact.position + Vector3(0.0, 11.0, 11.0)
	camera.look_at(impact.position)

	# The system advances age from its own clock, so the age is pinned per shot instead: the point
	# is to see chosen ages, not whichever ones the frame rate happens to land on.
	var worst := 0.0
	var worst_age := 0.0
	for age: float in AGES:
		material.set_shader_parameter(&"age", age)
		await process_frame
		await process_frame
		var image := get_root().get_texture().get_image()
		var white := _white_fraction(image)
		worst = maxf(worst, white)
		if white >= worst:
			worst_age = age
		var path := "%s/ring_age_%02d.png" % [_output, roundi(age * 100.0)]
		image.save_png(path)
		print("age %.2f: %5.2f%% of frame near-white  ->  %s" % [age * 100.0 / 100.0, white * 100.0, path])

	print("worst coverage %.2f%% at age %.2f" % [worst * 100.0, worst_age])
	quit(0)


## Returns the fraction of pixels brighter than [constant WHITE_LUMA].
##
## Sampled on a grid rather than per pixel: the number only has to separate a foam crown from a
## quad-filling slab, and a full read of a 1080p frame per shot is wasted work.
func _white_fraction(image: Image) -> float:
	var white := 0
	var total := 0
	for y in range(0, image.get_height(), 4):
		for x in range(0, image.get_width(), 4):
			var colour := image.get_pixel(x, y)
			var luma := colour.r * 0.2126 + colour.g * 0.7152 + colour.b * 0.0722
			if luma >= WHITE_LUMA:
				white += 1
			total += 1
	return float(white) / float(maxi(total, 1))
