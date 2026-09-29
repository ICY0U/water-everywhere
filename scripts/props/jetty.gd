class_name Jetty
extends StaticBody3D

## A timber jetty: a plank walkway on piles, running from a beach out over deeper water.
##
## It exists because the raft cannot wait on the beach. A 77 t hull left in the shallows grounds
## in every trough, and a shove barely moves it in a swell — measured at 1.5 m over six shoves in
## the sunny sea — so a crew that had to launch it from the sand spent the opening minute of the
## voyage failing to. Moored off the end of a jetty the raft floats free in deep water, and
## boarding is a walk down the planks.
##
## Built in code, like [Island], so the whole prop is a handful of numbers, the collider always
## matches what is drawn, and nothing generated is saved back into the scene.
##
## [b]Orientation.[/b] The origin is the landward end at the top of the deck, and the walkway runs
## along local -Z. Place it on the beach and point it out to sea.
##
## [b]The collider is solid to the sea bed[/b], not a thin deck on posts. A raft heaving in the
## swell alongside a thin deck can ride up under it and jam; a full-depth block turns that into a
## bump against the jetty's side, which is what a real pier's fendering is for.

## Length of the walkway, in metres.
@export_range(4.0, 60.0, 0.5) var length: float = 20.0

## Width of the walkway, in metres. The player is 1.55 m across.
@export_range(1.5, 8.0, 0.1) var width: float = 3.4

## How far the piles reach below the deck, in metres.
@export_range(1.0, 40.0, 0.5) var pile_depth: float = 16.0

## Raft whose mooring line is drawn to this jetty's bollard while it is tied up.
##
## Presentation only: the line is drawn from [member Raft.moored], which the server decides and
## replicates, and it holds nothing. The raft keeps itself on station.
@export var moored_raft: Raft

@export_group("Colours")
@export var plank_color: Color = Color(0.620, 0.463, 0.322)
@export var plank_alt_color: Color = Color(0.557, 0.408, 0.282)
@export var timber_color: Color = Color(0.380, 0.278, 0.200)
@export var rope_color: Color = Color(0.851, 0.741, 0.529)

## Thickness of a plank, in metres.
const PLANK_THICKNESS: float = 0.22

## Width of one plank along the walkway, in metres, and the gap left between planks.
const PLANK_PITCH: float = 0.72
const PLANK_GAP: float = 0.07

## Metres between pairs of piles along the walkway.
const PILE_SPACING: float = 4.0

## Segments the mooring line is drawn in. Enough to read as a sagging rope, not a rod.
const ROPE_SEGMENTS: int = 7

## How far the mooring line sags at its middle, as a fraction of its length.
const ROPE_SAG: float = 0.08

## Where on the raft the line is made fast, in the raft's own space: the middle of its stern.
const RAFT_CLEAT: Vector3 = Vector3(0.0, Raft.DECK_HEIGHT - 0.35, 4.55)

var _rope: Array[MeshInstance3D] = []


func _ready() -> void:
	_build_deck()
	_build_piles()
	_build_bollard()
	_build_collider()
	_build_rope()


func _process(_delta: float) -> void:
	_update_rope()


## Returns where the mooring line is made fast on the jetty, in world space.
func bollard_position() -> Vector3:
	return to_global(Vector3(0.0, 0.55, -length + 0.7))


## Returns the seaward end of the walkway, in world space, for anything that wants to guide a
## player there.
func end_position() -> Vector3:
	return to_global(Vector3(0.0, 0.0, -length))


func _build_deck() -> void:
	var even := PropMaterials.begin()
	var odd := PropMaterials.begin()
	var count := floori(length / PLANK_PITCH)
	for index in count:
		var z := -(float(index) + 0.5) * PLANK_PITCH
		# A slight, fixed irregularity in plank length and angle is what makes a walkway read as
		# hand-built rather than extruded. Derived from the index, so every peer draws the same.
		var jitter := sin(float(index) * 12.9898) * 0.5
		var tool := even if index % 2 == 0 else odd
		PropMaterials.add_box(
			tool,
			Vector3(width + jitter * 0.3, PLANK_THICKNESS, PLANK_PITCH - PLANK_GAP),
			Vector3(jitter * 0.12, -PLANK_THICKNESS * 0.5, z),
			Basis(Vector3.UP, jitter * 0.03),
		)
	PropMaterials.commit(even, self, "Planks", PropMaterials.cel(plank_color))
	PropMaterials.commit(odd, self, "PlanksAlt", PropMaterials.cel(plank_alt_color))

	# Two stringers under the planks, running the length of the jetty.
	var beams := PropMaterials.begin()
	for side in [-1.0, 1.0]:
		PropMaterials.add_box(
			beams,
			Vector3(0.32, 0.4, length),
			Vector3(side * (width * 0.5 - 0.35), -PLANK_THICKNESS - 0.2, -length * 0.5),
		)
	PropMaterials.commit(beams, self, "Stringers", PropMaterials.cel(timber_color))


func _build_piles() -> void:
	var tool := PropMaterials.begin()
	var pairs := maxi(2, ceili(length / PILE_SPACING) + 1)
	for index in pairs:
		var z := -minf(float(index) * PILE_SPACING, length - 0.3)
		for side in [-1.0, 1.0]:
			PropMaterials.add_cylinder(
				tool, 0.24, 0.22, pile_depth + 0.5,
				Vector3(side * (width * 0.5 + 0.1), -pile_depth, z), 8,
			)
	PropMaterials.commit(tool, self, "Piles", PropMaterials.cel(timber_color))


func _build_bollard() -> void:
	var tool := PropMaterials.begin()
	var base := Vector3(0.0, 0.0, -length + 0.7)
	PropMaterials.add_cylinder(tool, 0.3, 0.26, 0.55, base, 10)
	PropMaterials.add_cylinder(tool, 0.38, 0.38, 0.12, base + Vector3.UP * 0.55, 10)
	PropMaterials.commit(tool, self, "Bollard", PropMaterials.cel(timber_color.darkened(0.25)))


## One box for the walkway and a full-depth block beneath it; see the class description.
func _build_collider() -> void:
	var deck := CollisionShape3D.new()
	deck.name = "Walkway"
	var shape := BoxShape3D.new()
	var depth := pile_depth + 0.6
	shape.size = Vector3(width + 0.4, depth, length)
	deck.shape = shape
	deck.position = Vector3(0.0, -depth * 0.5, -length * 0.5)
	add_child(deck)


func _build_rope() -> void:
	var segment := CylinderMesh.new()
	segment.top_radius = 0.06
	segment.bottom_radius = 0.06
	segment.height = 1.0
	segment.radial_segments = 6
	segment.rings = 1
	var material := PropMaterials.cel(rope_color)
	for index in ROPE_SEGMENTS:
		var piece := MeshInstance3D.new()
		piece.name = "Rope%d" % index
		piece.mesh = segment
		piece.material_override = material
		piece.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		piece.top_level = true
		piece.visible = false
		add_child(piece)
		_rope.append(piece)


## Hangs the line between the bollard and the raft's stern while the raft is moored.
##
## A parabola sagging below the chord, drawn as straight segments: close enough to a catenary at
## this slack, and it stays readable as a rope when the raft swings on it.
func _update_rope() -> void:
	var tied := is_instance_valid(moored_raft) and moored_raft.moored
	for piece in _rope:
		piece.visible = tied
	if not tied:
		return
	var from := bollard_position()
	var to := moored_raft.to_global(RAFT_CLEAT)
	var sag := from.distance_to(to) * ROPE_SAG
	var previous := from
	for index in ROPE_SEGMENTS:
		var t := float(index + 1) / float(ROPE_SEGMENTS)
		var point := from.lerp(to, t) + Vector3.DOWN * sag * 4.0 * t * (1.0 - t)
		_place_segment(_rope[index], previous, point)
		previous = point


func _place_segment(piece: MeshInstance3D, from: Vector3, to: Vector3) -> void:
	var span := to - from
	var span_length := span.length()
	if span_length < 0.001:
		piece.visible = false
		return
	var up := span / span_length
	# Any vector not parallel to the segment completes the basis; world X is almost never close.
	var side := up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD).normalized()
	var forward := side.cross(up).normalized()
	piece.global_transform = Transform3D(
		Basis(side, up * span_length, forward), (from + to) * 0.5
	)
