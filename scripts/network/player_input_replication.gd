class_name PlayerInputReplication
extends MultiplayerSynchronizer

## Authority belongs to the synchronizer, not the properties it references.
## This child inherits the input owner's authority before entering the tree.
func _init() -> void:
	root_path = NodePath("..")
	replication_config = SceneReplicationConfig.new()
	for property in [
		"move_direction", "wants_up", "wants_down", "wants_sprint", "board_requests",
		"paddle_strokes", "push_requests",
	]:
		var path := NodePath(".:" + property)
		replication_config.add_property(path)
		replication_config.property_set_spawn(path, false)
		replication_config.property_set_replication_mode(
			path, SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE
		)
