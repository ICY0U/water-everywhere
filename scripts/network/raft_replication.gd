extends MultiplayerSynchronizer

## The level raft exists on every peer; only the server integrates its physics.
func _init() -> void:
	replication_config = SceneReplicationConfig.new()
	for property in [".:position", ".:rotation", ".:linear_velocity", ".:angular_velocity"]:
		var path := NodePath(property)
		replication_config.add_property(path)
		replication_config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
