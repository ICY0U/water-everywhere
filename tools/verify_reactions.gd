extends SceneTree

## Structural and live-event checks for the water reaction/replication pass.

var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var packed := load("res://scenes/ocean_demo.tscn") as PackedScene
	var demo := packed.instantiate()
	root.add_child(demo)
	await process_frame

	var ocean := demo.get_node("Ocean") as Ocean
	var reactions := demo.get_node("WaterReactions") as WaterReactionSystem
	_check("reaction system is in the playable scene", ocean != null and reactions != null)
	_check(
		"reaction pool is preallocated",
		reactions.get_node_or_null("ImpactSpray0") is CPUParticles3D
			and reactions.get_node_or_null("ImpactRing0") is MeshInstance3D,
	)

	var impact := WaterImpact.new()
	impact.position = ocean.get_surface_point(Vector2(2.0, -3.0))
	impact.normal = ocean.get_water_normal(Vector2(2.0, -3.0))
	impact.impact_speed = 7.0
	impact.relative_velocity = Vector3(3.0, -7.0, 1.0)
	impact.waterline_radius = 1.5
	impact.volume = 2.0
	impact.impulse = 14350.0
	impact.energy = 50225.0
	impact.kind = Ocean.ImpactKind.ENTRY
	ocean.report_impact(impact)
	await process_frame

	var spray := reactions.get_node("ImpactSpray0") as CPUParticles3D
	var ring := reactions.get_node("ImpactRing0") as MeshInstance3D
	_check("authority assigns a stable impact seed", impact.seed != 0)
	_check("impact starts a pooled spray burst", spray.emitting and spray.seed >= 0)
	_check("impact starts a foam/ripple crown", ring.visible)

	var multiplayer_packed := load("res://scenes/multiplayer_demo.tscn") as PackedScene
	var multiplayer_demo := multiplayer_packed.instantiate()
	_check(
		"multiplayer scene carries the full weather/VFX stack",
		multiplayer_demo.get_node_or_null("Atmosphere") is Atmosphere
			and multiplayer_demo.get_node_or_null("OceanSpray") is OceanSpray
			and multiplayer_demo.get_node_or_null("RainShower") is RainShower
			and multiplayer_demo.get_node_or_null("WaterReactions") is WaterReactionSystem,
	)
	multiplayer_demo.free()
	demo.free()

	if _failures == 0:
		print("\nAll water reaction checks PASSED")
		quit(0)
	else:
		print("\n%d water reaction check(s) FAILED" % _failures)
		quit(1)


func _check(label: String, passed: bool) -> void:
	print("%s  %s" % ["PASS" if passed else "FAIL", label])
	if not passed:
		_failures += 1
