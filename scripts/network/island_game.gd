class_name IslandGame
extends MultiplayerGame

## The networked game on dry land: players spawn standing on the island's plateau.
##
## Everything networked — hosting, joining, spawning, the replicated ocean clock and the
## weather — is inherited unchanged from [MultiplayerGame]. The single thing that differs on an
## island is [b]where a player appears[/b]: the demo seats everyone on a floating raft, and
## there is no raft under them here.
##
## Subclassed rather than branched inside [MultiplayerGame] so the sea demo keeps exactly the
## spawn behaviour it has. A scene picks its own starting ground by picking its script.

## Metres between adjacent players in the spawn ring, measured along the ring.
##
## Wide enough that two bodies never overlap on arrival: a player is about 0.62 m across, and
## two spawning inside one another are pushed apart by the solver, which looks like a glitch
## rather than a spawn.
const SPAWN_SPACING: float = 2.6

## Fraction of the plateau's radius the spawn ring sits at.
##
## Kept well inside the rim so a player never arrives on the beach slope and slides off before
## they have taken control.
const SPAWN_RING_FRACTION: float = 0.45

## Metres above the ground a player is dropped from.
##
## Deliberately a short fall rather than an exact placement: the ground is a generated height
## field, and dropping a body the last few centimetres lets the physics solver settle it onto
## the real collision surface instead of trusting the analytic profile to agree with the mesh.
const SPAWN_DROP_HEIGHT: float = 0.35

## Island players stand on. Its surface decides the spawn height.
@export var island: Island


## Returns a free patch of flat ground for [param peer_id].
##
## Overrides the raft slot [MultiplayerGame] would otherwise choose. The height comes from
## [method Island.height_at_world] rather than from [member Island.deck_height], so this still
## lands correctly if the island is moved, scaled or reshaped.
func _spawn_position(peer_id: int) -> Vector3:
	if island == null:
		return super(peer_id)

	var ring := island.plateau_radius * SPAWN_RING_FRACTION
	# Spacing is an arc length, so players stay the same distance apart whatever the radius.
	var step := SPAWN_SPACING / maxf(ring, 0.001)
	var occupied := _players.get_child_count()
	var bearing := float(occupied) * step
	var centre := island.global_position
	var spot := Vector2(
		centre.x + cos(bearing) * ring,
		centre.z + sin(bearing) * ring,
	)
	return Vector3(spot.x, island.height_at_world(spot) + SPAWN_DROP_HEIGHT, spot.y)
