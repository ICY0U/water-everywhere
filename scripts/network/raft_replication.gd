extends MultiplayerSynchronizer

## The level raft exists on every peer; only the server integrates its physics.
func _init() -> void:
	replication_config = SceneReplicationConfig.new()
	for property in [".:position", ".:rotation", ".:linear_velocity", ".:angular_velocity"]:
		var path := NodePath(property)
		replication_config.add_property(path)
		replication_config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)

	# Paddling state. Remote peers must not infer a stroke from the raft's velocity — the sea
	# moves it too, so a client reading motion would show paddling on every passing wave. The
	# serial and the flag are written only by the authority, in Raft.request_stroke.
	#
	# ON_CHANGE rather than ALWAYS: these change a few times a second at most, where the pose
	# changes every frame, and a stroke that is missed is not recoverable by the next packet the
	# way a position is.
	for property in [".:stroke_serial", ".:thrusting", ".:push_serial"]:
		var path := NodePath(property)
		replication_config.add_property(path)
		replication_config.property_set_replication_mode(
			path, SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE
		)
