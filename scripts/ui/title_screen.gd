class_name TitleScreen
extends Control

## The title: the game's name over the live sea, and the ways into a voyage.
##
## One column on the left, over a darkening gradient so the text reads against bright water; the
## raft and the lighthouse stay visible to the right, which is the pitch of the game in one
## picture. The main buttons and the three setup panels (Set Sail, Host, Join) take turns in
## the same column, so the eye never has to hunt for where the menu went.

## What each sea state is, in the words a first-time player needs: what it looks like and how
## hard it is. Indices match the voyage's weather presets.
const SEA_STATES: Array[Dictionary] = [
	{"name": "Calm", "blurb": "Sunshine and a gentle swell. The best first crossing."},
	{"name": "Choppy", "blurb": "Grey skies, a rising sea and the odd shower."},
	{"name": "Stormy", "blurb": "A full gale. Big waves, driving rain. Hold on."},
]

## Tips shown along the bottom, one at a time.
const TIPS: PackedStringArray = [
	"Stand in the middle of the raft to paddle straight.",
	"Paddle from the right side to turn left, and from the left side to turn right.",
	"Fell in? Swim back to the raft and climb aboard.",
	"Raft stuck on a beach? Stand on the sand beside it and shove it off.",
	"The lighthouse marks the mainland. Keep it ahead of the bow.",
	"Two paddlers on opposite sides go straight twice as surely.",
]

var ui: GameUI

var _column: VBoxContainer
var _main: VBoxContainer
var _solo: VBoxContainer
var _host: VBoxContainer
var _join: VBoxContainer
var _connecting: VBoxContainer
var _notice: Label
var _tip: Label
var _tip_index: int = 0
var _tip_elapsed: float = 0.0
var _sea_choice: int = 0
var _solo_best: Label
var _sea_blurbs: Array[Label] = []
var _sea_groups: Array[ButtonGroup] = []
var _host_port: LineEdit
var _host_error: Label
var _join_address: LineEdit
var _join_port: LineEdit
var _join_error: Label
var _connecting_label: Label
var _name_fields: Array[LineEdit] = []


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sea_choice = clampi(int(Settings.get_value(&"sea_state")), 0, SEA_STATES.size() - 1)

	var shade := TextureRect.new()
	shade.name = "Shade"
	var gradient := Gradient.new()
	gradient.set_color(0, Color(0.02, 0.07, 0.11, 0.86))
	gradient.set_color(1, Color(0.02, 0.07, 0.11, 0.0))
	gradient.set_offset(1, 1.0)
	gradient.add_point(0.55, Color(0.02, 0.07, 0.11, 0.55))
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill_to = Vector2(1, 0)
	texture.width = 256
	texture.height = 4
	shade.texture = texture
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shade.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	shade.anchor_right = 0.62
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)

	_column = VBoxContainer.new()
	_column.name = "Column"
	_column.add_theme_constant_override(&"separation", 18)
	_column.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	_column.offset_left = 96
	_column.offset_right = 96 + 540
	_column.offset_top = 70
	_column.offset_bottom = -60
	_column.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(_column)

	var logo := VBoxContainer.new()
	logo.add_theme_constant_override(&"separation", -28)
	var top := UiStyle.heading("Water", 112, UiStyle.TEXT)
	var bottom := UiStyle.heading("EveryWhere", 112, UiStyle.ACCENT)
	logo.add_child(top)
	logo.add_child(bottom)
	_column.add_child(logo)
	var tagline := UiStyle.label("Paddle together. Get home.", 26, UiStyle.MUTED, 700)
	_column.add_child(tagline)

	_notice = UiStyle.label("", 19, UiStyle.DANGER, 800)
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notice.hide()
	_column.add_child(_notice)

	_main = _build_main()
	_solo = _build_solo()
	_host = _build_host()
	_join = _build_join()
	_connecting = _build_connecting()
	for panel in [_main, _solo, _host, _join, _connecting]:
		_column.add_child(panel)

	var footer := HBoxContainer.new()
	footer.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	footer.offset_left = 96
	footer.offset_right = -40
	footer.offset_top = -52
	footer.offset_bottom = -20
	footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(footer)
	var version := UiStyle.label(
		"v%s  ·  demo" % ProjectSettings.get_setting("application/config/version", "0"), 15,
		Color(UiStyle.MUTED, 0.8), 700,
	)
	footer.add_child(version)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)
	_tip = UiStyle.label("", 18, UiStyle.TEXT, 700)
	_tip.add_theme_color_override(&"font_outline_color", UiStyle.OUTLINE)
	_tip.add_theme_constant_override(&"outline_size", 4)
	footer.add_child(_tip)
	_tip_index = randi() % TIPS.size()
	_tip.text = "Tip: " + TIPS[_tip_index]
	show_main()


func _process(delta: float) -> void:
	if not visible:
		return
	_tip_elapsed += delta
	if _tip_elapsed > 7.0:
		_tip_elapsed = 0.0
		_tip_index = (_tip_index + 1) % TIPS.size()
		_tip.text = "Tip: " + TIPS[_tip_index]


## Shows the main buttons.
func show_main() -> void:
	_show_only(_main)
	focus_first()


## Shows the connecting panel for a join in flight.
func show_connecting() -> void:
	_connecting_label.text = "Connecting to %s:%s..." % [_join_address.text, _join_port.text]
	_show_only(_connecting)
	(_connecting.get_child(_connecting.get_child_count() - 1) as Control).grab_focus()


## Shows a message above the menu: why the last session ended.
func show_notice(message: String) -> void:
	_notice.text = message
	_notice.visible = not message.is_empty()


## Backs out of a setup panel to the main buttons.
func back() -> void:
	if not _main.visible:
		UiStyle.play(&"back")
		show_main()


## Gives keyboard and gamepad focus to the first button of whatever is showing.
func focus_first() -> void:
	for panel: VBoxContainer in [_main, _solo, _host, _join, _connecting]:
		if panel.visible:
			var first := _first_focusable(panel)
			if first != null:
				first.grab_focus()
			return


func _show_only(panel: Control) -> void:
	for other in [_main, _solo, _host, _join, _connecting]:
		other.visible = other == panel
	for field in _name_fields:
		field.text = String(Settings.get_value(&"player_name"))
	_refresh_sea()


func _build_main() -> VBoxContainer:
	var stack := _stack()
	stack.add_child(UiStyle.button("Set Sail", func() -> void:
		_notice.hide()
		_show_only(_solo)
		focus_first(), true))
	stack.add_child(UiStyle.button("Host a Crew", func() -> void:
		_notice.hide()
		_show_only(_host)
		focus_first()))
	stack.add_child(UiStyle.button("Join a Crew", func() -> void:
		_notice.hide()
		_show_only(_join)
		focus_first()))
	stack.add_child(UiStyle.button("How to Play", func() -> void: ui.open_overlay(&"help")))
	stack.add_child(UiStyle.button("Settings", func() -> void: ui.open_overlay(&"settings")))
	stack.add_child(UiStyle.button("Credits", func() -> void: ui.open_overlay(&"credits")))
	stack.add_child(UiStyle.button("Quit", func() -> void: ui.quit_game()))
	return stack


func _build_solo() -> VBoxContainer:
	var stack := _stack()
	stack.add_child(UiStyle.heading("Set Sail", 40))
	stack.add_child(_name_row())
	stack.add_child(_sea_picker())
	_solo_best = UiStyle.label("", 18, UiStyle.SEA, 800)
	stack.add_child(_solo_best)
	var row := _button_row()
	row.add_child(UiStyle.button("Cast Off", func() -> void: ui.start_solo(_sea_choice), true))
	row.add_child(UiStyle.button("Back", back))
	stack.add_child(row)
	return stack


func _build_host() -> VBoxContainer:
	var stack := _stack()
	stack.add_child(UiStyle.heading("Host a Crew", 40))
	stack.add_child(_name_row())
	_host_port = _field(str(Settings.get_value(&"port")), "27015")
	stack.add_child(_labelled("Port", _host_port))
	stack.add_child(_sea_picker())
	var info := UiStyle.label(_host_help(), 16, UiStyle.MUTED, 600)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(info)
	_host_error = UiStyle.label("", 17, UiStyle.DANGER, 800)
	_host_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(_host_error)
	var row := _button_row()
	row.add_child(UiStyle.button("Host Voyage", _on_host_pressed, true))
	row.add_child(UiStyle.button("Back", back))
	stack.add_child(row)
	return stack


func _build_join() -> VBoxContainer:
	var stack := _stack()
	stack.add_child(UiStyle.heading("Join a Crew", 40))
	stack.add_child(_name_row())
	_join_address = _field(String(Settings.get_value(&"join_address")), "127.0.0.1")
	stack.add_child(_labelled("Host address", _join_address))
	_join_port = _field(str(Settings.get_value(&"port")), "27015")
	stack.add_child(_labelled("Port", _join_port))
	var info := UiStyle.label(
		"Ask the host for their address. On the same network it looks like 192.168.x.x.", 16,
		UiStyle.MUTED, 600,
	)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(info)
	_join_error = UiStyle.label("", 17, UiStyle.DANGER, 800)
	_join_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(_join_error)
	var row := _button_row()
	row.add_child(UiStyle.button("Join Voyage", _on_join_pressed, true))
	row.add_child(UiStyle.button("Back", back))
	stack.add_child(row)
	return stack


func _build_connecting() -> VBoxContainer:
	var stack := _stack()
	stack.add_child(UiStyle.heading("Joining...", 40))
	_connecting_label = UiStyle.label("", 20, UiStyle.TEXT, 700)
	_connecting_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(_connecting_label)
	stack.add_child(UiStyle.button("Cancel", func() -> void: ui.cancel_join()))
	return stack


func _on_host_pressed() -> void:
	var port := _parse_port(_host_port.text)
	if port < 0:
		_host_error.text = "The port must be a number from 1 to 65535."
		return
	_host_error.text = ""
	var error := ui.start_host(port, _sea_choice)
	if error != OK:
		_host_error.text = "Could not host on port %d (%s). Is another game using it?" % [
			port, error_string(error),
		]


func _on_join_pressed() -> void:
	var port := _parse_port(_join_port.text)
	var address := _join_address.text.strip_edges()
	if address.is_empty():
		_join_error.text = "Enter the host's address."
		return
	if port < 0:
		_join_error.text = "The port must be a number from 1 to 65535."
		return
	_join_error.text = ""
	var error := ui.start_join(address, port)
	if error != OK:
		_join_error.text = "Could not reach %s:%d (%s)." % [address, port, error_string(error)]


func _host_help() -> String:
	var local := PackedStringArray()
	for address in IP.get_local_addresses():
		if address.begins_with("192.168.") or address.begins_with("10.") or (
			address.begins_with("172.") and address.split(".").size() == 4
			and int(address.split(".")[1]) >= 16 and int(address.split(".")[1]) <= 31
		):
			local.append(address)
	var text := "Friends on your network join with your address"
	text += (": %s." % ", ".join(local)) if not local.is_empty() else "."
	text += " Over the internet, forward this UDP port on your router."
	return text


func _name_row() -> HBoxContainer:
	var field := _field(String(Settings.get_value(&"player_name")), "Your name")
	field.max_length = 20
	field.text_changed.connect(func(text: String) -> void:
		Settings.set_value(&"player_name", text.strip_edges())
		for other in _name_fields:
			if other != field:
				other.text = text)
	_name_fields.append(field)
	return _labelled("Name", field)


## A row of three toggle buttons choosing the sea, with a line describing the choice.
func _sea_picker() -> VBoxContainer:
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override(&"separation", 8)
	stack.add_child(UiStyle.label("Sea conditions", 17, UiStyle.MUTED, 800))
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 10)
	var group := ButtonGroup.new()
	_sea_groups.append(group)
	for index in SEA_STATES.size():
		var choice := Button.new()
		choice.text = SEA_STATES[index]["name"]
		choice.toggle_mode = true
		choice.button_group = group
		choice.custom_minimum_size = Vector2(140, 46)
		choice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		choice.add_theme_font_size_override(&"font_size", 20)
		choice.button_pressed = index == _sea_choice
		choice.mouse_entered.connect(func() -> void: UiStyle.play(&"hover"))
		choice.focus_entered.connect(func() -> void: UiStyle.play(&"hover"))
		choice.pressed.connect(func() -> void:
			UiStyle.play(&"toggle")
			_sea_choice = index
			_refresh_sea())
		row.add_child(choice)
	stack.add_child(row)
	var blurb := UiStyle.label("", 17, UiStyle.TEXT, 600)
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_sea_blurbs.append(blurb)
	stack.add_child(blurb)
	return stack


func _refresh_sea() -> void:
	for blurb in _sea_blurbs:
		blurb.text = SEA_STATES[_sea_choice]["blurb"]
	for group in _sea_groups:
		var buttons := group.get_buttons()
		if _sea_choice < buttons.size():
			buttons[_sea_choice].set_pressed_no_signal(true)
	if _solo_best != null:
		var best := Records.best(_sea_choice, false)
		_solo_best.text = (
			"Your best crossing: %s" % UiStyle.clock(best) if best > 0.0
			else "No crossing made in this sea yet."
		)


func _stack() -> VBoxContainer:
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override(&"separation", 12)
	stack.custom_minimum_size = Vector2(420, 0)
	stack.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	return stack


func _button_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 12)
	return row


func _field(text: String, placeholder: String) -> LineEdit:
	var field := LineEdit.new()
	field.text = text
	field.placeholder_text = placeholder
	field.custom_minimum_size = Vector2(300, 44)
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return field


func _labelled(caption: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 14)
	var label := UiStyle.label(caption, 19, UiStyle.MUTED, 800)
	label.custom_minimum_size = Vector2(130, 0)
	row.add_child(label)
	row.add_child(control)
	return row


func _first_focusable(node: Node) -> Control:
	for child in node.get_children():
		var control := child as Control
		if control == null or not control.visible:
			continue
		if control.focus_mode == Control.FOCUS_ALL and (control is Button or control is LineEdit):
			return control
		var nested := _first_focusable(control)
		if nested != null:
			return nested
	return null


static func _parse_port(text: String) -> int:
	var trimmed := text.strip_edges()
	if not trimmed.is_valid_int():
		return -1
	var port := int(trimmed)
	return port if port > 0 and port <= 65535 else -1
