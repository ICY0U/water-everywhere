class_name UiStyle
extends RefCounted

## The look of every menu and HUD element: palette, fonts, the shared [Theme], and small
## constructors for the widgets the screens are built from.
##
## Built in code rather than authored as a theme resource so the whole visual language is one
## readable file: a colour here is the colour everywhere. The palette is taken from the world —
## deep navy from the ocean's troughs, foam white, the sunset orange of the sun's glow and the
## red of the lighthouse bands — so the interface reads as part of the painted sea rather than
## as a debug overlay sitting on top of it.
##
## Fonts are the two OFL families in [code]assets/fonts[/code]: Fredoka, rounded and friendly,
## for anything that should read at a glance; Nunito for body text. Both are variable fonts
## whose default instance is a hairline Light, so every use goes through a [FontVariation] with an
## explicit weight.

## Deep panel background: the ocean's darkest band, mostly opaque.
const PANEL: Color = Color(0.043, 0.122, 0.184, 0.88)

## A lighter panel, for cards inside a panel and for hovered rows.
const PANEL_LIGHT: Color = Color(0.086, 0.208, 0.290, 0.92)

## Hairline borders and dividers.
const EDGE: Color = Color(0.557, 0.788, 0.855, 0.35)

## Primary text: foam white, slightly warm.
const TEXT: Color = Color(0.965, 0.949, 0.906)

## Secondary text.
const MUTED: Color = Color(0.639, 0.745, 0.788)

## The call to action: the sun's glow.
const ACCENT: Color = Color(1.0, 0.690, 0.302)

## Sea teal, for good news and the player's own markers.
const SEA: Color = Color(0.380, 0.839, 0.784)

## Lighthouse red, for warnings and the destination marker.
const DANGER: Color = Color(0.910, 0.353, 0.278)

## Text outline: every HUD label is drawn over a moving, bright sea.
const OUTLINE: Color = Color(0.020, 0.063, 0.098, 0.85)

const DISPLAY_FONT_FILE: FontFile = preload("res://assets/fonts/Fredoka-Variable.ttf")
const BODY_FONT_FILE: FontFile = preload("res://assets/fonts/Nunito-Variable.ttf")

## Called with a sound name ("hover", "click", "back", "toggle") when a widget built here is
## used. Set by the [code]Audio[/code] autoload, so this file never names an autoload itself:
## see [code]scripts/core/settings.gd[/code] for why that matters to the test suites.
static var sound_player: Callable

static var _theme: Theme
static var _fonts: Dictionary = {}


## Returns the display font (Fredoka) at [param weight].
static func display_font(weight: int = 600) -> Font:
	return _variation(DISPLAY_FONT_FILE, weight)


## Returns the body font (Nunito) at [param weight].
static func body_font(weight: int = 600) -> Font:
	return _variation(BODY_FONT_FILE, weight)


## Plays a UI sound, if an audio system has registered itself.
static func play(sound: StringName) -> void:
	if sound_player.is_valid():
		sound_player.call(sound)


## Returns the shared theme, building it on first use.
static func theme() -> Theme:
	if _theme != null:
		return _theme
	var built := Theme.new()
	built.default_font = body_font(600)
	built.default_font_size = 20

	built.set_color(&"font_color", &"Label", TEXT)
	built.set_color(&"font_outline_color", &"Label", OUTLINE)
	built.set_constant(&"outline_size", &"Label", 0)

	var panel := _box(PANEL, 18, EDGE, 1)
	panel.set_content_margin_all(22)
	built.set_stylebox(&"panel", &"PanelContainer", panel)
	built.set_stylebox(&"panel", &"Panel", panel)

	for state: StringName in [&"normal", &"hover", &"pressed", &"focus", &"disabled"]:
		built.set_stylebox(state, &"Button", _button_box(state))
	built.set_font(&"font", &"Button", display_font(600))
	built.set_font_size(&"font_size", &"Button", 24)
	built.set_color(&"font_color", &"Button", TEXT)
	built.set_color(&"font_hover_color", &"Button", Color(0.114, 0.086, 0.043))
	built.set_color(&"font_pressed_color", &"Button", Color(0.114, 0.086, 0.043))
	built.set_color(&"font_focus_color", &"Button", Color(0.114, 0.086, 0.043))
	built.set_color(&"font_hover_pressed_color", &"Button", Color(0.114, 0.086, 0.043))
	built.set_color(&"font_disabled_color", &"Button", Color(TEXT, 0.35))

	var field := _box(Color(0.02, 0.07, 0.11, 0.9), 10, EDGE, 1)
	field.set_content_margin_all(10)
	var field_focus := _box(Color(0.02, 0.07, 0.11, 0.95), 10, ACCENT, 2)
	field_focus.set_content_margin_all(10)
	built.set_stylebox(&"normal", &"LineEdit", field)
	built.set_stylebox(&"focus", &"LineEdit", field_focus)
	built.set_color(&"font_color", &"LineEdit", TEXT)
	built.set_color(&"caret_color", &"LineEdit", ACCENT)
	built.set_color(&"font_placeholder_color", &"LineEdit", Color(MUTED, 0.6))
	built.set_font_size(&"font_size", &"LineEdit", 20)

	var track := _box(Color(0.02, 0.07, 0.11, 0.9), 6, Color.TRANSPARENT, 0)
	track.content_margin_top = 4
	track.content_margin_bottom = 4
	built.set_stylebox(&"slider", &"HSlider", track)
	var fill := _box(SEA, 6, Color.TRANSPARENT, 0)
	built.set_stylebox(&"grabber_area", &"HSlider", fill)
	built.set_stylebox(&"grabber_area_highlight", &"HSlider", _box(ACCENT, 6, Color.TRANSPARENT, 0))
	built.set_icon(&"grabber", &"HSlider", _dot_texture(22, TEXT))
	built.set_icon(&"grabber_highlight", &"HSlider", _dot_texture(24, ACCENT))

	for state: StringName in [&"normal", &"hover", &"pressed", &"focus"]:
		var option := _box(
			PANEL_LIGHT if state != &"focus" else PANEL_LIGHT.lightened(0.08), 10,
			ACCENT if state == &"focus" else EDGE, 2 if state == &"focus" else 1,
		)
		option.set_content_margin_all(10)
		built.set_stylebox(state, &"OptionButton", option)
	built.set_color(&"font_color", &"OptionButton", TEXT)
	built.set_color(&"font_hover_color", &"OptionButton", ACCENT)
	built.set_color(&"font_focus_color", &"OptionButton", TEXT)
	built.set_font(&"font", &"OptionButton", body_font(700))
	built.set_font_size(&"font_size", &"OptionButton", 20)

	built.set_color(&"font_color", &"CheckButton", TEXT)
	built.set_color(&"font_hover_color", &"CheckButton", ACCENT)
	built.set_color(&"font_focus_color", &"CheckButton", ACCENT)
	var check_focus := _box(Color(1, 1, 1, 0.06), 8, ACCENT, 2)
	built.set_stylebox(&"focus", &"CheckButton", check_focus)
	built.set_stylebox(&"normal", &"CheckButton", StyleBoxEmpty.new())
	built.set_stylebox(&"hover", &"CheckButton", StyleBoxEmpty.new())
	built.set_stylebox(&"pressed", &"CheckButton", StyleBoxEmpty.new())

	var tab_selected := _box(PANEL_LIGHT, 12, ACCENT, 0)
	tab_selected.border_width_bottom = 3
	tab_selected.set_content_margin_all(12)
	var tab_idle := _box(Color(0, 0, 0, 0), 12, Color.TRANSPARENT, 0)
	tab_idle.set_content_margin_all(12)
	built.set_stylebox(&"tab_selected", &"TabContainer", tab_selected)
	built.set_stylebox(&"tab_unselected", &"TabContainer", tab_idle)
	built.set_stylebox(&"tab_hovered", &"TabContainer", tab_idle)
	built.set_stylebox(&"tab_focus", &"TabContainer", _box(Color.TRANSPARENT, 12, ACCENT, 2))
	built.set_stylebox(&"panel", &"TabContainer", StyleBoxEmpty.new())
	built.set_font(&"font", &"TabContainer", display_font(600))
	built.set_font_size(&"font_size", &"TabContainer", 22)
	built.set_color(&"font_selected_color", &"TabContainer", ACCENT)
	built.set_color(&"font_unselected_color", &"TabContainer", MUTED)
	built.set_color(&"font_hovered_color", &"TabContainer", TEXT)

	built.set_color(&"default_color", &"RichTextLabel", TEXT)
	built.set_font(&"bold_font", &"RichTextLabel", body_font(800))
	built.set_font(&"normal_font", &"RichTextLabel", body_font(500))
	built.set_font_size(&"normal_font_size", &"RichTextLabel", 19)
	built.set_font_size(&"bold_font_size", &"RichTextLabel", 19)

	built.set_stylebox(&"panel", &"TooltipPanel", _box(PANEL, 8, EDGE, 1))
	_theme = built
	return _theme


## Returns a label in the body font.
static func label(text: String, size: int = 20, color: Color = TEXT, weight: int = 600) -> Label:
	var made := Label.new()
	made.text = text
	made.add_theme_font_override(&"font", body_font(weight))
	made.add_theme_font_size_override(&"font_size", size)
	made.add_theme_color_override(&"font_color", color)
	return made


## Returns a heading in the display font, outlined so it reads over the sea.
static func heading(text: String, size: int = 36, color: Color = TEXT) -> Label:
	var made := Label.new()
	made.text = text
	made.add_theme_font_override(&"font", display_font(600))
	made.add_theme_font_size_override(&"font_size", size)
	made.add_theme_color_override(&"font_color", color)
	made.add_theme_color_override(&"font_outline_color", OUTLINE)
	made.add_theme_constant_override(&"outline_size", maxi(4, size / 7))
	return made


## Returns a menu button wired to [param on_pressed], with hover and click sounds.
static func button(text: String, on_pressed: Callable, primary: bool = false) -> Button:
	var made := Button.new()
	made.text = text
	made.custom_minimum_size = Vector2(0, 54)
	made.focus_mode = Control.FOCUS_ALL
	if primary:
		for state: StringName in [&"normal"]:
			var box := _button_box(&"hover")
			made.add_theme_stylebox_override(state, box)
		made.add_theme_color_override(&"font_color", Color(0.114, 0.086, 0.043))
	made.mouse_entered.connect(func() -> void: play(&"hover"))
	made.focus_entered.connect(func() -> void: play(&"hover"))
	made.pressed.connect(func() -> void: play(&"click"))
	made.pressed.connect(on_pressed)
	return made


## Returns a panel with a vertical stack inside it, and the stack, as [code][panel, stack][/code].
static func card(separation: int = 14) -> Array:
	var panel := PanelContainer.new()
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override(&"separation", separation)
	panel.add_child(stack)
	return [panel, stack]


## Fills [param screen] with a centred panel, optionally over a dimmed backdrop, and returns the
## panel's vertical stack for the caller to fill.
##
## The backdrop also stops clicks reaching the game behind a menu.
static func modal(screen: Control, width: int, dim: bool = true) -> VBoxContainer:
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen.mouse_filter = Control.MOUSE_FILTER_STOP
	var backdrop := ColorRect.new()
	backdrop.name = "Backdrop"
	backdrop.color = Color(0.01, 0.03, 0.05, 0.55 if dim else 0.0)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen.add_child(backdrop)
	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen.add_child(centre)
	var made := card(14)
	var panel: PanelContainer = made[0]
	panel.custom_minimum_size = Vector2(width, 0)
	var box := panel.get_theme_stylebox(&"panel", &"PanelContainer")
	if box == null:
		box = theme().get_stylebox(&"panel", &"PanelContainer")
	var padded := box.duplicate() as StyleBoxFlat
	padded.set_content_margin_all(32)
	padded.shadow_color = Color(0, 0, 0, 0.35)
	padded.shadow_size = 18
	panel.add_theme_stylebox_override(&"panel", padded)
	centre.add_child(panel)
	return made[1]


## Returns the first focusable button or field under [param node], depth first.
static func first_focusable(node: Node) -> Control:
	for child in node.get_children():
		var control := child as Control
		if control == null or not control.is_visible_in_tree():
			continue
		if control.focus_mode == Control.FOCUS_ALL and (
			control is Button or control is LineEdit or control is Slider
		):
			return control
		var nested := first_focusable(control)
		if nested != null:
			return nested
	return null


## Returns a horizontal rule for separating groups in a panel.
static func rule() -> HSeparator:
	var line := HSeparator.new()
	var style := StyleBoxLine.new()
	style.color = EDGE
	style.thickness = 1
	line.add_theme_stylebox_override(&"separator", style)
	return line


## Returns a key-cap style label, for naming a control in a prompt: [ F ].
static func key_cap(text: String, size: int = 20) -> PanelContainer:
	var cap := PanelContainer.new()
	var box := _box(Color(0.965, 0.949, 0.906, 0.95), 8, Color(0, 0, 0, 0.4), 2)
	box.border_width_bottom = 4
	box.content_margin_left = 10
	box.content_margin_right = 10
	box.content_margin_top = 2
	box.content_margin_bottom = 2
	cap.add_theme_stylebox_override(&"panel", box)
	var text_label := Label.new()
	text_label.text = text
	text_label.add_theme_font_override(&"font", display_font(700))
	text_label.add_theme_font_size_override(&"font_size", size)
	text_label.add_theme_color_override(&"font_color", Color(0.063, 0.106, 0.149))
	text_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cap.add_child(text_label)
	return cap


## Formats [param seconds] as m:ss.
static func clock(seconds: float) -> String:
	var whole := maxi(0, int(floor(seconds)))
	return "%d:%02d" % [whole / 60, whole % 60]


static func _variation(file: FontFile, weight: int) -> Font:
	var key := "%s/%d" % [file.resource_path, weight]
	if not _fonts.has(key):
		var variation := FontVariation.new()
		variation.base_font = file
		# Keyed by the numeric OpenType tag. The string "wght" is accepted without complaint and
		# silently ignored — measured: the same string width at weights 300, 600 and 700 — so
		# every label rendered in the fonts' hairline default instance.
		var tag := TextServerManager.get_primary_interface().name_to_tag("wght")
		variation.variation_opentype = {tag: weight}
		_fonts[key] = variation
	return _fonts[key]


static func _box(color: Color, radius: int, border: Color, border_width: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(radius)
	box.border_color = border
	box.set_border_width_all(border_width)
	box.anti_aliasing = true
	return box


static func _button_box(state: StringName) -> StyleBoxFlat:
	var box: StyleBoxFlat
	match state:
		&"hover", &"focus":
			box = _box(ACCENT, 14, Color(1.0, 0.86, 0.6), 2)
		&"pressed":
			box = _box(ACCENT.darkened(0.15), 14, Color(1.0, 0.86, 0.6), 2)
		&"disabled":
			box = _box(Color(PANEL_LIGHT, 0.5), 14, Color(EDGE, 0.2), 1)
		_:
			box = _box(PANEL_LIGHT, 14, EDGE, 1)
	box.content_margin_left = 24
	box.content_margin_right = 24
	box.content_margin_top = 8
	box.content_margin_bottom = 10
	box.shadow_color = Color(0, 0, 0, 0.25)
	box.shadow_size = 4
	box.shadow_offset = Vector2(0, 3)
	return box


static func _dot_texture(size: int, color: Color) -> ImageTexture:
	var image := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	var centre := Vector2(size, size) * 0.5
	for y in size:
		for x in size:
			var distance := Vector2(x + 0.5, y + 0.5).distance_to(centre)
			var alpha := clampf(size * 0.5 - distance, 0.0, 1.0)
			image.set_pixel(x, y, Color(color, alpha))
	return ImageTexture.create_from_image(image)
