class_name ExplorationIsland
extends Island

## Deterministic coastal terrain. Mesh, collision and spawn queries use the same profile.
## The starter has a sheltered level clearing; the larger island has a coastal plain,
## rolling foothills, a connected ridge and a broad switchback route to its lookout.
enum Landscape { STARTER, EXPLORATION, ISLET, HORIZON }
@export var landscape: Landscape = Landscape.STARTER
@export var terrain_seed: int = 17

## A walkable ascent in local X/Z coordinates, from the southern beach to the high saddle.
const ASCENT: Array[Vector3] = [
	Vector3(-90, 7, 215), Vector3(-115, 13, 160), Vector3(-70, 24, 105),
	Vector3(15, 38, 65), Vector3(80, 53, 12), Vector3(30, 69, -40),
	Vector3(-45, 82, -75), Vector3(-5, 101, -128), Vector3(50, 112, -148),
]


func _profile(point: Vector2) -> float:
	var coast := super(point)
	var scaled_radius := point.length() / _bearing_scale(point.angle())
	var interior := 1.0 - smoothstep(plateau_radius * 0.65, plateau_radius, scaled_radius)
	if interior <= 0.0:
		return coast
	var relief := 0.0
	match landscape:
		Landscape.STARTER:
			relief = _hill(point, Vector2(-38, -27), Vector2(33, 29), 17.0)
			relief += _hill(point, Vector2(27, -49), Vector2(28, 22), 10.0)
			relief += _hill(point, Vector2(-48, 30), Vector2(23, 30), 6.0)
			# Keep the south-east arrival clearing broad and gentle.
			relief *= smoothstep(16.0, 32.0, point.distance_to(Vector2(24, 18)))
		Landscape.EXPLORATION:
			relief = _hill(point, Vector2(-80, -75), Vector2(120, 120), 74.0)
			relief += _hill(point, Vector2(70, -135), Vector2(90, 100), 118.0)
			relief += _hill(point, Vector2(150, -45), Vector2(65, 95), 53.0)
			relief += _hill(point, Vector2(-165, 40), Vector2(65, 75), 34.0)
			relief += _hill(point, Vector2(80, 105), Vector2(80, 65), 26.0)
			# Uneven spurs break up the skyline without high-frequency collision noise.
			relief *= 1.0 + 0.09 * sin(point.x * 0.038 + point.y * 0.023)
			relief += (sin(point.x * 0.041) * cos(point.y * 0.032) + 1.0) * 2.0
		Landscape.ISLET:
			relief = _hill(point, Vector2(-8, -4), Vector2(plateau_radius * 0.7,
				plateau_radius * 0.6), 8.0 + float(terrain_seed % 7))
		Landscape.HORIZON:
			# A chain of overlapping shoulders rather than one cone on a circular beach.
			var p := point / plateau_radius
			var ridge := 0.0
			for index in 4:
				var centre := Vector2(-0.55 + index * 0.33,
					sin(float(index + terrain_seed)) * 0.15)
				var offset := (p - centre) / Vector2(0.38, 0.60)
				var peak := maxf(0.0, 1.0 - offset.length())
				var height := 0.62 + 0.34 * sin(float(index * 3 + terrain_seed))
				ridge = maxf(ridge, pow(peak, 1.15) * height)
			relief = ridge * plateau_radius * 1.1
	var height := coast + relief * interior
	if landscape == Landscape.EXPLORATION:
		height = _shape_ascent(point, height)
	return height


func _bearing_scale(bearing: float) -> float:
	var phase := float(terrain_seed) * 0.37
	return 1.0 + shore_variation * (0.52 * sin(bearing * 3.0 + phase)
		+ 0.28 * sin(bearing * 5.0 - phase) + 0.2 * cos(bearing * 7.0 + 0.6))


func _hill(point: Vector2, centre: Vector2, radius: Vector2, height: float) -> float:
	var offset := (point - centre) / radius
	return height * exp(-offset.length_squared() * 1.8)


func _shape_ascent(point: Vector2, height: float) -> float:
	var closest := INF
	var route_height := height
	for index in ASCENT.size() - 1:
		var a := Vector2(ASCENT[index].x, ASCENT[index].z)
		var b := Vector2(ASCENT[index + 1].x, ASCENT[index + 1].z)
		var segment := b - a
		var weight := clampf((point - a).dot(segment) / segment.length_squared(), 0.0, 1.0)
		var distance := point.distance_to(a + segment * weight)
		if distance < closest:
			closest = distance
			route_height = lerpf(ASCENT[index].y, ASCENT[index + 1].y, weight)
	# Broad shoulders blend the route into the land, with a level six-metre walking width.
	return lerpf(route_height, height, smoothstep(6.0, 38.0, closest))
