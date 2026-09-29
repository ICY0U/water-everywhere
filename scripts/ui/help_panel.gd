class_name HelpPanel
extends Control

## How to play: the controls for both devices, and the handful of things the raft does that
## nobody guesses — above all, that where you stand on the deck is how you steer.
##
## The key names are read from the input map, so a rebinding cannot leave this page naming a key
## that does nothing — the same discipline the HUD legend follows.

## Actions listed, with what each does.
const ACTIONS: Array = [
	[&"move_forward", "Walk / swim (with the other movement keys)"],
	[&"move_sprint", "Sprint"],
	[&"board", "Climb aboard the raft"],
	[&"paddle", "Paddle (hold)"],
	[&"push", "Push the raft off a beach"],
	[&"move_up", "Swim up"],
	[&"move_down", "Dive"],
	[&"toggle_view", "First / third person"],
	[&"pause", "Menu"],
]

var ui: GameUI

var _keys: GridContainer

func _ready() -> void:
	var stack := UiStyle.modal(self, 900)
	var heading := UiStyle.heading("How to Play", 44)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stack.add_child(heading)
	var goal := UiStyle.label(
		"Get the raft across to the lighthouse on the mainland. Walk down the jetty, climb "
		+ "aboard, and paddle. Nothing sinks and nobody is left behind: fall in, and you can "
		+ "always swim back.", 19, UiStyle.TEXT, 600,
	)
	goal.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	goal.custom_minimum_size = Vector2(836, 0)
	stack.add_child(goal)
	stack.add_child(UiStyle.rule())

	var columns := HBoxContainer.new()
	columns.add_theme_constant_override(&"separation", 40)
	stack.add_child(columns)

	var controls := VBoxContainer.new()
	controls.add_theme_constant_override(&"separation", 8)
	controls.custom_minimum_size = Vector2(430, 0)
	controls.add_child(UiStyle.label("CONTROLS", 15, UiStyle.ACCENT, 800))
	var header := HBoxContainer.new()
	var keyboard_title := UiStyle.label("Keyboard", 16, UiStyle.MUTED, 800)
	keyboard_title.custom_minimum_size = Vector2(110, 0)
	header.add_child(keyboard_title)
	header.add_child(UiStyle.label("Gamepad", 16, UiStyle.MUTED, 800))
	controls.add_child(header)
	_keys = GridContainer.new()
	_keys.columns = 3
	_keys.add_theme_constant_override(&"h_separation", 14)
	_keys.add_theme_constant_override(&"v_separation", 6)
	controls.add_child(_keys)
	columns.add_child(controls)

	var tips := VBoxContainer.new()
	tips.add_theme_constant_override(&"separation", 10)
	tips.custom_minimum_size = Vector2(380, 0)
	tips.add_child(UiStyle.label("SAILING THE RAFT", 15, UiStyle.ACCENT, 800))
	for tip in [
		"Where you stand is how you steer. Paddle from the middle to go straight.",
		"Paddle from the RIGHT side to turn left, and from the LEFT side to turn right.",
		"The raft panel shows where the lighthouse lies and where to stand.",
		"The first stroke casts off from the jetty.",
		"Run aground? Step onto the shore beside the raft and push it off.",
		"With a crew, paddle from opposite sides to go straight together.",
		"Look around with the mouse or right stick. Walk off the raft at the far shore.",
	]:
		var line := UiStyle.label("•  " + tip, 18, UiStyle.TEXT, 600)
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		line.custom_minimum_size = Vector2(380, 0)
		tips.add_child(line)
	columns.add_child(tips)

	var back := UiStyle.button("Back", func() -> void: ui.close_overlay(), true)
	stack.add_child(back)
	visibility_changed.connect(func() -> void:
		if visible:
			_fill())


func focus_first() -> void:
	var first := UiStyle.first_focusable(self)
	if first != null:
		first.grab_focus()


func _fill() -> void:
	for child in _keys.get_children():
		child.queue_free()
	for entry: Array in ACTIONS:
		var action: StringName = entry[0]
		_keys.add_child(_cap(_first(action, false)))
		_keys.add_child(_cap(_first(action, true)))
		var what := UiStyle.label(entry[1], 17, UiStyle.TEXT, 600)
		_keys.add_child(what)


func _cap(text: String) -> Control:
	if text.is_empty():
		return UiStyle.label("—", 17, UiStyle.MUTED, 600)
	var holder := HBoxContainer.new()
	holder.custom_minimum_size = Vector2(96, 0)
	holder.add_child(UiStyle.key_cap(text, 16))
	return holder


## The first binding of [param action] on one device, named the way the HUD names it.
func _first(action: StringName, pad: bool) -> String:
	if action == &"move_forward":
		return "Left stick" if pad else "WASD"
	if not InputMap.has_action(action):
		return ""
	for event: InputEvent in InputMap.action_get_events(action):
		if pad and event is InputEventJoypadButton:
			return GameUI.PAD_BUTTONS.get((event as InputEventJoypadButton).button_index, "")
		if pad and event is InputEventJoypadMotion:
			return GameUI.PAD_AXES.get((event as InputEventJoypadMotion).axis, "")
		if not pad and event is InputEventKey:
			var key := event as InputEventKey
			var code := key.physical_keycode if key.physical_keycode != KEY_NONE else key.keycode
			return OS.get_keycode_string(code)
	return ""
