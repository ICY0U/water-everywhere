class_name CreditsPanel
extends Control

## Who and what made the game, and the licence notices the engine and fonts require.

var ui: GameUI


func _ready() -> void:
	var stack := UiStyle.modal(self, 760)
	var heading := UiStyle.heading("Credits", 44)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stack.add_child(heading)
	var text := RichTextLabel.new()
	text.bbcode_enabled = true
	text.fit_content = false
	text.scroll_active = true
	text.custom_minimum_size = Vector2(696, 420)
	text.focus_mode = Control.FOCUS_ALL
	text.text = _credits()
	stack.add_child(text)
	stack.add_child(UiStyle.button("Back", func() -> void: ui.close_overlay(), true))


func focus_first() -> void:
	var first := UiStyle.first_focusable(self)
	if first != null:
		first.grab_focus()


func _credits() -> String:
	var engine := Engine.get_version_info()
	var lines := PackedStringArray([
		"[b]Water EveryWhere[/b] — a cooperative raft voyage. Demo build v%s." % (
			ProjectSettings.get_setting("application/config/version", "0")),
		"",
		"[b]Ocean, weather and physics[/b]",
		"Gerstner wave spectrum after Pierson–Moskowitz, clipped-hull buoyancy and Morison "
		+ "hydrodynamics, simulated foam, spray and rain — all written for this project.",
		"",
		"[b]Characters and props[/b]",
		"Kotarou, the player character, modelled and animated in Blender for this project. "
		+ "Barrel raft model. Islands, jetty and lighthouse are generated in code.",
		"",
		"[b]Music and sound[/b]",
		"Every sound and all three pieces of music are synthesised from scratch by "
		+ "tools/generate_audio.py. No samples were used.",
		"",
		"[b]Fonts[/b]",
		"Fredoka, copyright 2016 The Fredoka Project Authors. "
		+ "Nunito, copyright 2014 The Nunito Project Authors. Both under the SIL Open Font "
		+ "License 1.1; the licence texts ship in assets/fonts.",
		"",
		"[b]Engine[/b]",
		"Made with Godot Engine %s.%s.%s and Jolt Physics." % [
			engine.get("major", 4), engine.get("minor", 0), engine.get("patch", 0)],
		"",
		"[font_size=15]%s[/font_size]" % Engine.get_license_text().strip_edges().replace("[", "[lb]"),
	])
	return "\n".join(lines)
