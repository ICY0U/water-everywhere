class_name MountainIsland
extends Island

## An [Island] with mountains rising out of its plateau.
##
## Everything below the summit is inherited: the beach and shelf profile, the irregular
## shoreline, the generated normals, the trimesh collider, [method Island.height_at_world] and
## the shoreline surf. This class contributes one thing — relief added on top of the plateau —
## by overriding [method Island._profile], which is the single function the mesh builder, the
## height query and the waterline solver all ask. Adding the mountains there means they are real
## ground: a body can stand on one, a ray can hit one, and a test can ask how high one is,
## without any of those paths knowing mountains exist.
##
## [b]Peaks are confined to the plateau, by construction.[/b] Each peak's centre is placed so
## that its whole footprint — including the ridge wobble that widens it — falls inside
## [member Island.plateau_radius]. Two inherited behaviours depend on it. The beach keeps its
## shape, because relief is zero by the time the profile starts descending. And
## [method Island.waterline_radius] stays correct: it finds the shore by bisection, which is
## only valid because the profile descends monotonically from the plateau outwards, and a
## mountain spilling onto the beach would put a second crossing in the way and let the bisection
## converge on the wrong one.
##
## [b]Peaks combine with max(), not by adding.[/b] Summing two overlapping cones raises the
## saddle between them and the massif reads as one swollen dome; taking the greater leaves the
## saddle where the cones cross, which is what makes a distant ridge legible as separate peaks.
##
## [b]The terrain is deterministic.[/b] It is generated from [member peak_seed] through a local
## [RandomNumberGenerator], never from the global one, so every peer builds identical ground
## from the scene file alone — no terrain is replicated, and no client can disagree about where
## a mountain is. Changing the seed is the intended way to get a different mountain; changing it
## at runtime is not, and neither is anything else that would make two peers differ.

## Number of peaks in the massif.
##
## One reads as a volcano, two or three as a ridge. Beyond about four they crowd the plateau and
## each has to be small enough that the silhouette turns lumpy rather than mountainous.
@export_range(0, 8, 1) var peak_count: int = 3:
	set(value):
		peak_count = value
		_invalidate_peaks()

## Height of the tallest peak above the plateau, in metres.
##
## For a background island this is mostly a question of how far away it sits: seen at 600 m
## through a 70-degree lens, 40 m of mountain is about fifty pixels tall on a 900-pixel frame,
## which is the point at which a silhouette starts to read as terrain rather than as a speck.
@export_range(0.0, 400.0, 1.0) var peak_height: float = 90.0:
	set(value):
		peak_height = value
		_invalidate_peaks()

## How much shorter each successive peak is, as a fraction of the one before it.
##
## Equal peaks look manufactured. A drop gives the massif a clear summit and reads as one
## mountain with shoulders rather than as several mountains that happen to touch.
@export_range(0.0, 0.9, 0.01) var height_falloff: float = 0.28:
	set(value):
		height_falloff = value
		_invalidate_peaks()

## How far peaks are scattered from the island's centre, as a fraction of the plateau radius.
@export_range(0.0, 1.0, 0.01) var peak_spread: float = 0.45:
	set(value):
		peak_spread = value
		_invalidate_peaks()

## Radius of the tallest peak's base, as a fraction of the plateau radius.
##
## This is capped when the peaks are generated so the footprint stays inside the plateau; asking
## for a peak broader than the island it stands on yields the broadest one that still fits.
@export_range(0.05, 1.0, 0.01) var peak_breadth: float = 0.62:
	set(value):
		peak_breadth = value
		_invalidate_peaks()

## How much the summit is sharpened, as an exponent on the flank curve.
##
## The flank itself is a smoothstep, so at 1.0 the mountain is a rounded dome: flat where it
## leaves the plateau and flat again at the summit. Raising this pulls the summit into a peak
## while leaving the foot alone; lowering it flattens the top toward a mesa. The backdrop sits
## near 1.0.
##
## It is not the main control over whether a mountain looks like a mountain — aspect ratio is. A
## 148 m peak on a 48 m base is a 72-degree cone and reads as a fin at any exponent; widening the
## base is what fixed it.
@export_range(0.6, 4.0, 0.05) var peak_sharpness: float = 1.7:
	set(value):
		peak_sharpness = value
		_invalidate_peaks()

## How much a peak's radius varies with bearing, as a fraction.
##
## Breaks the circular plan of a cone into spurs and gullies. The variation is folded into the
## containment maths, so a wider wobble costs reach rather than spilling onto the beach.
@export_range(0.0, 0.5, 0.01) var ridge_variation: float = 0.18:
	set(value):
		ridge_variation = value
		_invalidate_peaks()

## Seed the massif is generated from.
##
## The only intended way to get different mountains. Two islands sharing a seed are identical;
## two peers sharing a scene are identical, which is the property that matters.
@export var peak_seed: int = 1:
	set(value):
		peak_seed = value
		_invalidate_peaks()

@export_group("Shore")

## Colour of the rock the mountains are made of.
@export var rock_color: Color = Color(0.243, 0.271, 0.318)

## Colour of the sand at the island's shore.
@export var beach_color: Color = Color(0.776, 0.702, 0.525)

## How far above the plateau the sand reaches before rock takes over, in metres.
##
## Measured from [member Island.deck_height], so an island keeps its beach wherever its plateau
## sits. Sand covering the plateau as well as the beach is deliberate: it reads as a sandy island
## with rock rising out of it, rather than as a rock slab with a fringe.
@export_range(0.0, 60.0, 0.5) var shore_rise: float = 6.0

## Height over which sand gives way to rock, in metres.
@export_range(0.5, 60.0, 0.5) var shore_blend: float = 1.5

## Resolution of the generated sand-and-rock map, per side.
##
## The map is sampled from the same profile the mesh is built from, so it follows the irregular
## shoreline for free. It only ever carries a single soft transition, so it needs far less
## resolution than a detail texture would.
@export_range(32, 512, 32) var shore_texture_size: int = 320

## The generated massif: origin, height, radius and phase per peak, in the island's own space.
var _peaks: Array[Dictionary] = []


func _ready() -> void:
	# Before super(), which rebuilds the mesh and therefore asks _profile for every vertex.
	_generate_peaks()
	_apply_shore_colouring()
	super()


## Gives the island a sand-to-rock map, on a private copy of its material.
##
## The alternative was a second material and a second surface, or vertex colours — both of which
## would mean overriding the base class's mesh builder and keeping a copy of it in step. This
## needs neither: the cel shader multiplies [code]albedo_color[/code] by a texture that defaults
## to white, so putting the colours in the texture and leaving the tint white gives the whole
## gradient without changing how the surface is built.
##
## The map is sampled from [method _profile], the same function the mesh is built from, so the
## sand follows the real shoreline — including its irregularity — instead of a circle that only
## approximates it.
##
## The material is DUPLICATED first. Islands share material resources in a scene, and writing a
## texture onto a shared one would give every island that shares it the same shoreline, sampled
## from whichever island got there last.
func _apply_shore_colouring() -> void:
	var shaded := material as ShaderMaterial
	if shaded == null:
		return

	var private := shaded.duplicate() as ShaderMaterial
	private.set_shader_parameter(&"albedo_texture", _build_shore_texture())
	# The tint multiplies the map, so it has to be white or it would darken both colours.
	private.set_shader_parameter(&"albedo_color", Color.WHITE)
	material = private


## Returns a texture of sand and rock, matching the mesh's own UV layout.
func _build_shore_texture() -> ImageTexture:
	var size := shore_texture_size
	var image := Image.create(size, size, false, Image.FORMAT_RGB8)
	var rock_from := deck_height + shore_rise
	var sand_to := rock_from - shore_blend

	for y: int in size:
		for x: int in size:
			# The mesh lays UV (0,0) at local (-extent, -extent) and (1,1) at (+extent, +extent),
			# so the map is sampled in exactly the space the surface reads it in.
			var local := Vector2(
				(float(x) / float(size - 1) * 2.0 - 1.0) * extent,
				(float(y) / float(size - 1) * 2.0 - 1.0) * extent
			)
			var height := _profile(local)
			image.set_pixel(x, y, beach_color.lerp(rock_color, smoothstep(sand_to, rock_from, height)))

	return ImageTexture.create_from_image(image)


## Returns the height of the summit above sea level, in metres.
func summit_height() -> float:
	_ensure_peaks()
	var tallest := 0.0
	for peak in _peaks:
		tallest = maxf(tallest, float(peak["height"]))
	return global_position.y + deck_height + tallest


## Returns each peak's summit as a world-space position.
##
## For tools and tests that need to ask about the mountains themselves rather than about the
## ground under a particular spot.
func peak_summits() -> Array[Vector3]:
	_ensure_peaks()
	var summits: Array[Vector3] = []
	for peak in _peaks:
		var origin: Vector2 = peak["origin"]
		summits.append(
			global_position + Vector3(origin.x, deck_height + float(peak["height"]), origin.y)
		)
	return summits


## Returns the ground height at a point in the island's own space, in metres.
func _profile(local_xz: Vector2) -> float:
	return super(local_xz) + _relief(local_xz)


## Returns how far the mountains lift the ground at a point, in metres, never below zero.
func _relief(local_xz: Vector2) -> float:
	_ensure_peaks()
	var tallest := 0.0
	for peak in _peaks:
		var offset: Vector2 = local_xz - peak["origin"]
		var distance := offset.length()
		var radius := float(peak["radius"])
		# Cheap rejection against the widest the wobble can make this peak, before the atan2.
		if distance >= radius * (1.0 + ridge_variation):
			continue

		var bearing := atan2(offset.y, offset.x)
		var reach := radius * (1.0 + sin(bearing * 3.0 + float(peak["phase"])) * ridge_variation)
		if distance >= reach:
			continue

		# The flank is shaped by a smoothstep, not by the raw distance.
		#
		# A power curve alone cannot be flat at both ends. Raising it to an exponent below 1 to
		# round the summit gives the base an INFINITE slope — the derivative of x^0.85 diverges
		# as x approaches 0 — so each mountain met its plateau at a vertical skirt, which read as
		# a dark collar around the foot and made the sand-to-rock line ragged where it crossed it.
		# smoothstep is flat at both ends by construction, so the mountain leaves the plateau and
		# reaches its summit smoothly, and the exponent then sharpens the summit without ever
		# steepening the foot.
		#
		# pow() is fed a base that cannot go negative: distance is below reach here, so the
		# bracket is in (0, 1]. A negative base with a fractional exponent returns NaN, and a NaN
		# vertex deletes the triangles that use it rather than reporting anything.
		var flank := smoothstep(0.0, 1.0, 1.0 - distance / maxf(reach, 0.0001))
		tallest = maxf(tallest, float(peak["height"]) * pow(flank, peak_sharpness))
	return tallest


## Builds the massif from [member peak_seed], deterministically.
func _generate_peaks() -> void:
	_peaks.clear()
	if peak_count <= 0 or peak_height <= 0.0 or plateau_radius <= 0.0:
		return

	# Local generator, never the global one: the global sequence depends on whatever else in the
	# process drew from it first, which would make two peers disagree about the terrain.
	var rng := RandomNumberGenerator.new()
	rng.seed = peak_seed

	var broadest := plateau_radius * peak_breadth
	for index: int in peak_count:
		# Successive peaks are both shorter and narrower, which is what gives the massif a
		# summit and shoulders instead of a row of equal cones.
		var taper := float(index) / maxf(float(peak_count - 1), 1.0)
		var radius := broadest * lerpf(1.0, 0.55, taper)
		var height := peak_height * pow(1.0 - height_falloff, float(index))

		# The whole footprint, wobble included, must stay inside the plateau — see the class
		# documentation for the two inherited behaviours that depend on it.
		var reach := maxf(plateau_radius - radius * (1.0 + ridge_variation), 0.0)
		var scatter := minf(plateau_radius * peak_spread, reach)
		# The summit sits near the middle; the shoulders are free to wander.
		var distance := rng.randf() * (scatter * 0.35 if index == 0 else scatter)

		var angle := rng.randf() * TAU
		_peaks.append({
			"origin": Vector2(cos(angle), sin(angle)) * distance,
			"height": height,
			"radius": radius,
			"phase": rng.randf() * TAU,
		})


## Regenerates the massif if it has been asked for before, and rebuilds the surface.
func _invalidate_peaks() -> void:
	_peaks.clear()
	if is_inside_tree():
		_generate_peaks()
		rebuild()


## Generates the massif if an export was changed before the island entered the tree.
func _ensure_peaks() -> void:
	if _peaks.is_empty() and peak_count > 0 and peak_height > 0.0:
		_generate_peaks()
