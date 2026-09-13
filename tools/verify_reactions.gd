extends SceneTree

## Structural and live-event checks for the water reaction/replication pass.
##
## Also guards the contract between [Ocean]'s contact limit and the shaders that receive the
## contacts; see [method _check_contact_uniforms].

## Shaders that receive the contacts [Ocean] packs, and so must size their contact uniforms to
## [constant Ocean.MAX_CONTACTS].
const CONTACT_SHADERS: Array[String] = [
	"res://shaders/ocean.gdshader",
	"res://shaders/foam_sim.gdshader",
]

## Uniforms in each of [constant CONTACT_SHADERS] that carry the contact limit. The three arrays
## are sized by it; [code]contact_count[/code] carries it as its [code]hint_range[/code] maximum.
const CONTACT_UNIFORMS: Array[String] = [
	"contacts", "contact_motion", "contact_wake", "contact_count",
]

## Deepest [code]#include[/code] chain followed when reading a shader. Godot rejects cyclic
## includes anyway; this only stops a broken one from hanging the suite.
const INCLUDE_DEPTH_LIMIT: int = 4

var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_check_contact_uniforms()

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


## Checks each of [constant CONTACT_SHADERS] sizes its contact uniforms to
## [constant Ocean.MAX_CONTACTS].
##
## GLSL array sizes must be literals, so the shaders cannot read the constant and nothing else
## ties them to it: raise it alone and the extra contacts have nowhere to go, with no error from
## either side. [constant FoamField.MAX_CONTACTS] is derived from the same constant, so this one
## check covers both halves of the contact path.
func _check_contact_uniforms() -> void:
	for path: String in CONTACT_SHADERS:
		var sizes := _contact_uniform_sizes(_shader_source(path))
		var wrong := _contact_size_mismatches(sizes, Ocean.MAX_CONTACTS)
		var label := "%s sizes its contact uniforms to Ocean.MAX_CONTACTS (%d)" % [
			path.get_file(), Ocean.MAX_CONTACTS
		]
		if not wrong.is_empty():
			label += ": " + ", ".join(wrong)
		_check(label, wrong.is_empty())


## Returns the source of the shader at [param path] with its [code]#include[/code] files
## appended, so a uniform moved into an include is still found.
static func _shader_source(path: String, depth: int = 0) -> String:
	var code := FileAccess.get_file_as_string(path)
	if depth >= INCLUDE_DEPTH_LIMIT:
		return code
	var include := RegEx.create_from_string(r'#include\s+"([^"]+)"')
	for found: RegExMatch in include.search_all(code):
		var target := found.get_string(1)
		if target.is_relative_path():
			target = path.get_base_dir().path_join(target)
		code += "\n" + _shader_source(target, depth + 1)
	return code


## Returns the size each contact uniform is declared with in [param code], keyed by name.
##
## Arrays report their length, and [code]contact_count[/code] its [code]hint_range[/code]
## maximum. Comments are stripped first, so a commented-out declaration is not mistaken for the
## live one. A size written as anything but a literal is reported as not found, which fails
## loudly rather than guessing.
static func _contact_uniform_sizes(code: String) -> Dictionary[String, int]:
	var comments := RegEx.create_from_string(r"//[^\n]*|/\*[\s\S]*?\*/")
	code = comments.sub(code, "", true)
	var sizes: Dictionary[String, int] = {}
	var arrays := RegEx.create_from_string(r"uniform\s+vec4\s+(\w+)\s*\[\s*(\d+)\s*\]")
	for found: RegExMatch in arrays.search_all(code):
		sizes[found.get_string(1)] = found.get_string(2).to_int()
	var count := RegEx.create_from_string(
		r"uniform\s+int\s+contact_count\s*:\s*hint_range\s*\(\s*0\s*,\s*(\d+)"
	)
	var hint := count.search(code)
	if hint != null:
		sizes["contact_count"] = hint.get_string(1).to_int()
	return sizes


## Describes each of [constant CONTACT_UNIFORMS] whose size in [param sizes] is not
## [param expected], or that was not found at all. Empty when everything agrees.
static func _contact_size_mismatches(
	sizes: Dictionary[String, int], expected: int
) -> PackedStringArray:
	var wrong := PackedStringArray()
	for uniform_name: String in CONTACT_UNIFORMS:
		if not sizes.has(uniform_name):
			wrong.append("%s not found" % uniform_name)
		elif sizes[uniform_name] != expected:
			wrong.append("%s=%d" % [uniform_name, sizes[uniform_name]])
	return wrong
