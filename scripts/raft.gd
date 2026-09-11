class_name Raft
extends BuoyantBody

## Imported barrel raft with a simple closed displacement/collision envelope.
const DECK_HEIGHT: float = 1.804
const SPAWN_OFFSETS: Array[Vector2] = [
	Vector2.ZERO, Vector2(-2.7, 0), Vector2(2.7, 0),
	Vector2(0, -2.7), Vector2(-2.7, -2.7), Vector2(2.7, -2.7),
	Vector2(-2.7, 2.7), Vector2(2.7, 2.7), Vector2(0, 2.7),
]

func _physics_process(delta: float) -> void:
	# Authority can change after _ready when a player chooses Join from the offline menu.
	freeze = not is_multiplayer_authority()
	if not freeze:
		super(delta)


func spawn_position(players: Node3D) -> Vector3:
	# Choose the clearest deck slot in the raft's CURRENT transform, including late joins.
	var best := Vector3.ZERO
	var best_clearance := -1.0
	for offset in SPAWN_OFFSETS:
		var candidate := to_global(Vector3(offset.x, DECK_HEIGHT, offset.y))
		# Players spawn upright; account for their box extent along the tilted deck normal.
		var up := global_basis.y.normalized()
		var half_extent := absf(up.x) + absf(up.y) + absf(up.z)
		candidate += up * (half_extent + 0.15)
		var clearance := INF
		for player: Node3D in players.get_children():
			clearance = minf(clearance, candidate.distance_squared_to(player.global_position))
		if clearance > best_clearance:
			best = candidate
			best_clearance = clearance
	return best
