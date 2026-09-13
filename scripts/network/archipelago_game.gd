extends IslandGame

## Uses the normal offline H/J session flow, with a sheltered island spawn.

func _spawn_position(_peer_id: int) -> Vector3:
	# Eight clearly separated arrivals in the starter island's protected clearing.
	for slot in 8:
		var point := island.global_position + Vector3(18.0 + (slot % 4) * 4.0, 0.0,
			18.0 + floori(float(slot) / 4.0) * 5.0)
		point.y = island.height_at_world(Vector2(point.x, point.z)) + SPAWN_DROP_HEIGHT
		var occupied := false
		for player in _players.get_children():
			if (player as Node3D).global_position.distance_to(point) < 3.5:
				occupied = true
				break
		if not occupied:
			return point
	return super(_peer_id)
