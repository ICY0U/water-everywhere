extends SceneTree

## Checks the Kotarou player scene: dimensions, clip selection, tinting and hull derivation.
##
## The character replaces a 4.5 m box with a 1.65 m human, and everything downstream of the
## player's size is derived rather than declared — the buoyancy hull comes from the collider,
## and the raft suite's height windows assume the origin sits at the feet. So the checks here
## are mostly about geometry agreeing with the rest of the project, not about the model looking
## right; see the capture tools for that.

const PLAYER_SCENE := "res://scenes/player_kotarou.tscn"

## Height the character stands at in game, in metres.
##
## The model is authored 1.65 m in Blender and scaled 2.5x in the player scene, a deliberate
## art decision so the character reads against the raft and the island rather than against a
## human. The collider is scaled by the same factor, so the two agree: a body whose collision
## box is a different size from the character drawn on it is the defect this checks for.
const EXPECTED_HEIGHT: float = 4.125

## Width and depth of the collider, in metres: the authored 0.62 m under the same 2.5x scale.
const EXPECTED_WIDTH: float = 1.55

var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var scene: PackedScene = load(PLAYER_SCENE)
	if scene == null:
		_fail("player scene failed to load")
		_finish()
		return
	var player: NetworkPlayer = scene.instantiate()
	get_root().add_child(player)
	await process_frame

	_check_origin_at_feet(player)
	_check_model_present(player)
	await _check_clip_selection(player)
	_check_tint(player)
	_check_hull(player)
	await _check_facing(player)
	await _check_intent_stops_walk(player)
	_finish()


## The project puts a player's origin at its feet; the raft suite's deck heights depend on it.
func _check_origin_at_feet(player: NetworkPlayer) -> void:
	var collider := player.get_node_or_null("Collision") as CollisionShape3D
	if collider == null:
		_fail("no Collision node")
		return
	var box := collider.shape as BoxShape3D
	if box == null:
		_fail("collider is not a BoxShape3D")
		return
	var bottom := collider.position.y - box.size.y * 0.5
	_expect(absf(bottom) < 0.02, "collider bottom sits at the origin (got %.4f)" % bottom)
	_expect(
		absf(box.size.y - EXPECTED_HEIGHT) < 0.05,
		"collider is the character's height (got %.3f, want %.2f)" % [box.size.y, EXPECTED_HEIGHT]
	)


func _check_model_present(player: NetworkPlayer) -> void:
	var visual := player.get_node_or_null("Visual") as CharacterVisual
	if visual == null:
		_fail("no CharacterVisual under the player")
		return
	var skeleton := visual.find_child("Skeleton3D", true, false) as Skeleton3D
	_expect(skeleton != null, "the model brought a skeleton")
	if skeleton != null:
		_expect(skeleton.get_bone_count() == 53, "skeleton has its 53 bones (got %d)" % skeleton.get_bone_count())
	var animation := visual.find_child("AnimationPlayer", true, false) as AnimationPlayer
	_expect(animation != null, "the model brought an AnimationPlayer")
	if animation == null:
		return
	for clip in [CharacterVisual.CLIP_IDLE, CharacterVisual.CLIP_WALK, CharacterVisual.CLIP_SWIM]:
		_expect(animation.has_animation(clip), "clip '%s' exists" % clip)
		if animation.has_animation(clip):
			var res := animation.get_animation(clip)
			_expect(res.loop_mode != Animation.LOOP_NONE, "clip '%s' loops" % clip)


## The clip must follow the body's own motion, because that is all a remote peer has.
func _check_clip_selection(player: NetworkPlayer) -> void:
	var visual := player.get_node_or_null("Visual") as CharacterVisual
	if visual == null:
		return
	var animation := visual.find_child("AnimationPlayer", true, false) as AnimationPlayer

	# The velocity fallback is what a REMOTE player uses, so the intent source is cleared here;
	# the intent path is covered separately by _check_intent_stops_walk().
	visual.input = null
	player.freeze = true
	player.linear_velocity = Vector3.ZERO
	await process_frame
	_expect(
		animation.current_animation == CharacterVisual.CLIP_IDLE,
		"a still remote player idles (got '%s')" % animation.current_animation
	)

	player.linear_velocity = Vector3(3.0, 0.0, 0.0)
	await process_frame
	_expect(
		animation.current_animation == CharacterVisual.CLIP_WALK,
		"a moving remote player walks (got '%s')" % animation.current_animation
	)

	# Vertical motion is heave on a swell, not walking.
	player.linear_velocity = Vector3(0.0, 4.0, 0.0)
	await process_frame
	_expect(
		animation.current_animation == CharacterVisual.CLIP_IDLE,
		"a remote player heaving on a wave does not walk (got '%s')" % animation.current_animation
	)


## Tinting must not repaint the whole character, and must not leak between players.
func _check_tint(player: NetworkPlayer) -> void:
	var visual := player.get_node_or_null("Visual") as CharacterVisual
	if visual == null:
		return
	var skeleton := visual.find_child("Skeleton3D", true, false) as Skeleton3D
	if skeleton == null:
		return
	visual.tint(Color(0.1, 0.9, 0.2))

	var tinted := 0
	var untouched := 0
	for child in skeleton.get_children():
		var mesh_instance := child as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		for surface in mesh_instance.mesh.get_surface_count():
			if mesh_instance.get_surface_override_material(surface) != null:
				tinted += 1
			else:
				untouched += 1
	_expect(tinted > 0, "tinting recoloured the coat (%d surfaces)" % tinted)
	_expect(untouched > 0, "tinting left the face, hair and skin alone (%d surfaces)" % untouched)


## Buoyancy reads the collider, so a wrong hull floats the character at the wrong depth.
func _check_hull(player: NetworkPlayer) -> void:
	var hull := HullGeometry.from_body(player, 32)
	_expect(hull.is_valid(), "a buoyancy hull was derived from the collider")
	if not hull.is_valid():
		return
	# The hull is the collision box, so its volume follows the same scale the character does.
	var expected := EXPECTED_WIDTH * EXPECTED_HEIGHT * EXPECTED_WIDTH
	var error := absf(hull.volume - expected) / expected
	_expect(error < 0.08, "hull volume matches the collider (%.4f m3 vs %.4f, %.1f%%)" % [hull.volume, expected, error * 100.0])
	# At 420 kg/m3 the character must float, not sink.
	_expect(player.body_density < 1025.0, "the character is less dense than sea water")


## The model is authored facing +Z, so a character walking east must end up yawed +90 degrees.
##
## A sign error here is invisible to every other check and to a still screenshot: the character
## simply moonwalks. Measured as a world-space direction rather than an angle so the assertion
## says what a player would see.
func _check_facing(player: NetworkPlayer) -> void:
	var visual := player.get_node_or_null("Visual") as CharacterVisual
	if visual == null:
		return
	# No input authority here, so facing follows the replicated velocity path.
	visual.input = null
	player.freeze = true

	var cases := {
		"east": [Vector3(4.0, 0.0, 0.0), Vector3.RIGHT],
		"west": [Vector3(-4.0, 0.0, 0.0), Vector3.LEFT],
		"south": [Vector3(0.0, 0.0, 4.0), Vector3.BACK],
		"north": [Vector3(0.0, 0.0, -4.0), Vector3.FORWARD],
	}
	for label in cases:
		var case: Array = cases[label]
		player.linear_velocity = case[0]
		# Long enough for the turn rate to bring the model all the way round.
		for i in 60:
			await process_frame
		var facing := visual.global_transform.basis.z.normalized()
		var wanted: Vector3 = case[1]
		var dot := facing.dot(wanted)
		_expect(dot > 0.9, "walking %s faces %s (dot=%.3f)" % [label, wanted, dot])


## Releasing the keys must stop the walk even while the body is still coasting.
##
## The failure this guards against is specific: on a drifting raft the deck servo never lets
## horizontal speed reach zero, so a clip chosen from velocity alone walks on the spot forever.
func _check_intent_stops_walk(player: NetworkPlayer) -> void:
	var visual := player.get_node_or_null("Visual") as CharacterVisual
	if visual == null:
		return
	var animation := visual.find_child("AnimationPlayer", true, false) as AnimationPlayer
	var input := player.input_node()
	input.set_process(false)
	visual.input = input
	player.freeze = true

	input.move_direction = Vector2(1.0, 0.0)
	await process_frame
	_expect(
		animation.current_animation == CharacterVisual.CLIP_WALK,
		"holding a direction walks (got '%s')" % animation.current_animation
	)

	# Key released, but the body keeps coasting - as it does on a moving deck.
	input.move_direction = Vector2.ZERO
	player.linear_velocity = Vector3(3.0, 0.0, 0.0)
	await process_frame
	_expect(
		animation.current_animation == CharacterVisual.CLIP_IDLE,
		"releasing the keys stops the walk while still coasting (got '%s')"
			% animation.current_animation
	)


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("  PASS  ", message)
	else:
		print("  FAIL  ", message)
		_failures += 1


func _fail(message: String) -> void:
	print("  FAIL  ", message)
	_failures += 1


func _finish() -> void:
	print("")
	if _failures == 0:
		print("verify_player_model: all checks passed")
	else:
		print("verify_player_model: %d CHECK(S) FAILED" % _failures)
	quit(1 if _failures > 0 else 0)
