class_name PlayerReplication
extends MultiplayerSynchronizer

## The [MultiplayerSynchronizer] for a player, configured in code rather than in the scene.
##
## The property list is built here, beside the properties themselves, instead of being authored
## into [code]player.tscn[/code]. A [SceneReplicationConfig] stored in a scene is a list of
## NodePaths with no connection to the script that owns them: renaming a property leaves the
## config silently pointing at nothing, and the only symptom is a body that stops moving on
## everyone else's screen.
##
## [b]Why a subclass rather than a child node.[/b] The config has to exist before the
## synchronizer starts replicating, and replication starts as the node enters the tree — before
## any child's [method Node._ready] has run. A child node setting the config was therefore
## always too late, and the engine reported it as
## [code]ERR_UNCONFIGURED[/code] from [code]on_replication_start[/code]. Building the config in
## [method Node._init] is early enough by construction.
##
## [b]What is replicated, and why each mode.[/b]
##
## * [b]Transform[/b] — ALWAYS. The server owns the body and its position changes every frame,
##   so this streams unreliably: a dropped packet is worth less than the one behind it.
## * [b]Velocities[/b] — ALWAYS, so a client can carry a body between updates rather than
##   snapping it from one position to the next.
## * [b]Identity[/b] — spawn only. Name, colour and owning peer never change during a life, so
##   they ride along with the spawn rather than costing bandwidth forever.
## * [b]Input[/b] — ON_CHANGE, and therefore reliable, from the owning client. A movement key
##   that was pressed and whose release went missing would otherwise leave a player running
##   into the horizon.

## Properties streamed continuously from the authority.
const STREAMED_PROPERTIES: PackedStringArray = [
	".:position",
	".:rotation",
	".:linear_velocity",
	".:angular_velocity",
]

## Properties sent once, with the spawn.
const SPAWN_PROPERTIES: PackedStringArray = [
	".:owner_peer_id",
	".:player_name",
	".:player_color",
]

func _init() -> void:
	replication_config = build_config()


## Returns the replication config a player synchronizer needs.
##
## Static so a test can assert the list without instancing a scene.
static func build_config() -> SceneReplicationConfig:
	var config := SceneReplicationConfig.new()

	for path in SPAWN_PROPERTIES:
		var node_path := NodePath(path)
		config.add_property(node_path)
		config.property_set_spawn(node_path, true)
		# Spawn-only: carried in the spawn state and never streamed afterwards.
		config.property_set_replication_mode(
			node_path, SceneReplicationConfig.REPLICATION_MODE_NEVER
		)

	for path in STREAMED_PROPERTIES:
		var node_path := NodePath(path)
		config.add_property(node_path)
		# Spawned as well as streamed, so a body appears where it belongs rather than at the
		# origin for the frame before its first update lands.
		config.property_set_spawn(node_path, true)
		config.property_set_replication_mode(
			node_path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS
		)

	return config
