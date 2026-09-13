extends SceneTree

## Checks the island multiplayer scene: that a spawned player lands on the island's plateau,
## stands on the ground rather than in the sea, is the Kotarou character, and that a second
## player is placed clear of the first.
##
## Spawning is driven through [code]_spawn_for_peer[/code] directly rather than by hosting a
## session. The autoload's NAME is not a resolvable identifier under [code]--script[/code], so
## any script that extends [MultiplayerGame] — which [IslandGame] does — fails to compile if
## the session path is exercised here. The spawn placement this suite exists to check is
## server-side code that a real host runs verbatim, so driving it directly tests the same
## thing without dragging ENet into a geometry check. Session behaviour is covered by
## verify_multiplayer.gd.
##
## Run with:
## [codeblock lang=text]
## godot --path . --headless --script tools/verify_island_spawn.gd
## [/codeblock]
## Exits non-zero if any check fails.

const SCENE := "res://scenes/island_multiplayer.tscn"

## Simulated seconds allowed for a spawned body to settle onto the ground.
const SETTLE_SECONDS: float = 4.0

## How far a settled player's feet may sit below the analytic ground height, in metres.
##
## The island's collision shape is a triangle mesh generated from the same height field, and a
## body resting on a triangle mesh settles a little way into it: the solver allows a small
## penetration before it pushes back. This is the depth that is normal contact rather than a
## body sinking through the world.
const GROUND_PENETRATION: float = 0.2

## How far above the ground a settled player may float, in metres.
const GROUND_CLEARANCE: float = 0.1

var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	create_timer(60.0).timeout.connect(func() -> void: quit(2))

	var game: Node3D = load(SCENE).instantiate()
	root.add_child(game)
	current_scene = game
	await physics_frame

	var island := game.get_node("Island") as Island
	var players := game.get_node("Players") as Node3D
	_expect(island != null, "the scene has an island")
	_expect(game.get("player_scene") != null, "a player scene is assigned")

	_expect(game._spawn_for_peer(1), "the host is given a body")
	_expect(players.get_child_count() == 1, "exactly one body was spawned")
	var body := players.get_child(0) as NetworkPlayer
	if body == null:
		_fail("the spawned node is not a NetworkPlayer")
		_finish()
		return

	# Spawned above the ground, so the body drops onto the real collision surface.
	var spawned := body.global_position
	_expect(spawned.y > island.deck_height, "spawned above the plateau (y=%.2f)" % spawned.y)

	await _wait_physics(SETTLE_SECONDS)

	var here := Vector2(body.global_position.x, body.global_position.z)
	var centre := Vector2(island.global_position.x, island.global_position.z)
	var radius := here.distance_to(centre)
	_expect(
		radius < island.plateau_radius,
		"stands on the plateau, not the beach (r=%.2f < %.1f)" % [radius, island.plateau_radius]
	)

	# The player's origin is at its feet, so this compares straight against the height field.
	var ground := island.height_at_world(here)
	var above := body.global_position.y - ground
	_expect(
		above > -GROUND_PENETRATION and above < GROUND_CLEARANCE,
		"feet rest on the ground (%.4f m from surface, y=%.2f ground=%.2f)" % [
			above, body.global_position.y, ground]
	)
	_expect(ground > 0.0, "the ground under the player is above sea level (%.2f m)" % ground)
	_expect(body.submersion() <= 0.0, "the player is on dry land (submersion=%.2f)" % body.submersion())
	_expect(
		body.get_node_or_null("Visual") is CharacterVisual,
		"the spawned body is the Kotarou character"
	)

	# A second player must not be dropped on top of the first.
	_expect(game._spawn_for_peer(2), "a second peer is given a body")
	await _wait_physics(SETTLE_SECONDS)
	var guest := players.get_node_or_null("2") as NetworkPlayer
	if guest == null:
		_fail("the second peer has no body")
		_finish()
		return
	var spacing := guest.global_position.distance_to(body.global_position)
	_expect(spacing > 1.5, "the second player spawns clear of the first (%.2f m)" % spacing)
	var guest_here := Vector2(guest.global_position.x, guest.global_position.z)
	var guest_above := guest.global_position.y - island.height_at_world(guest_here)
	_expect(
		guest_above > -GROUND_PENETRATION and guest_above < GROUND_CLEARANCE,
		"the second player also stands on the ground (%.4f m)" % guest_above
	)

	_finish()


func _expect(condition: bool, message: String) -> void:
	print("%s %s" % ["PASS " if condition else "FAIL ", message])
	if not condition:
		_failures += 1


func _fail(message: String) -> void:
	_expect(false, message)


func _wait_physics(seconds: float) -> void:
	for _step: int in ceili(seconds * Engine.physics_ticks_per_second):
		await physics_frame


func _finish() -> void:
	print("verify_island_spawn: %d failures" % _failures)
	quit(1 if _failures else 0)
