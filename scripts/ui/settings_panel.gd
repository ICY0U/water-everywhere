class_name SettingsPanel
extends Control

## Sound, controls and display, in three tabs. Every change applies at once and is saved.
##
## Built from a table of rows rather than by hand, so adding a setting is one line here and one
## default in [code]scripts/core/settings.gd[/code]; the row reads and writes the same key the
## rest of the game listens for.

var ui: GameUI

var _tabs: TabContainer
var _rows: Array[Dictionary] = []


func _ready() -> void:
	var stack := UiStyle.modal(self, 700)
	var heading := UiStyle.heading("Settings", 44)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stack.add_child(heading)
	_tabs = TabContainer.new()
	_tabs.custom_minimum_size = Vector2(636, 400)
	stack.add_child(_tabs)

	var sound := _tab("Sound")
	_slider(sound, "Master volume", &"master_volume", 0.0, 1.0, 0.05, true)
	_slider(sound, "Music", &"music_volume", 0.0, 1.0, 0.05, true)
	_slider(sound, "Effects", &"sfx_volume", 0.0, 1.0, 0.05, true)
	_slider(sound, "Sea and weather", &"ambience_volume", 0.0, 1.0, 0.05, true)

	var controls := _tab("Controls")
	_slider(controls, "Mouse sensitivity", &"mouse_sensitivity", 0.05, 1.0, 0.01, false)
	_slider(controls, "Stick look speed", &"pad_sensitivity", 0.3, 3.0, 0.05, false)
	_toggle(controls, "Invert look up and down", &"invert_y")
	_toggle(controls, "Show control hints", &"show_hints")

	var display := _tab("Display")
	_choice(display, "Graphics quality", &"quality", Settings.QUALITY_NAMES)
	_slider(display, "Render scale", &"render_scale", 0.5, 1.0, 0.05, true)
	_slider(display, "Field of view", &"field_of_view", 55.0, 100.0, 1.0, false)
	_toggle(display, "Fullscreen", &"fullscreen")
	_toggle(display, "Vertical sync", &"vsync")
	_toggle(display, "Show frame rate", &"show_fps")

	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 12)
	var reset := UiStyle.button("Restore Defaults", func() -> void:
		Settings.reset_to_defaults()
		_sync())
	reset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(reset)
	var back := UiStyle.button("Back", func() -> void: ui.close_overlay(), true)
	back.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(back)
	stack.add_child(row)
	visibility_changed.connect(func() -> void:
		if visible:
			_sync())


func focus_first() -> void:
	_tabs.get_tab_bar().grab_focus()


func _tab(title: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var list := VBoxContainer.new()
	list.add_theme_constant_override(&"separation", 14)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var margin := MarginContainer.new()
	margin.add_theme_constant_override(&"margin_top", 16)
	margin.add_theme_constant_override(&"margin_left", 8)
	margin.add_theme_constant_override(&"margin_right", 16)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(list)
	scroll.add_child(margin)
	_tabs.add_child(scroll)
	return list


func _row(parent: VBoxContainer, caption: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 16)
	var label := UiStyle.label(caption, 20, UiStyle.TEXT, 700)
	label.custom_minimum_size = Vector2(250, 0)
	row.add_child(label)
	parent.add_child(row)
	return row


func _slider(
	parent: VBoxContainer, caption: String, key: StringName, low: float, high: float,
	step: float, percent: bool,
) -> void:
	var row := _row(parent, caption)
	var slider := HSlider.new()
	slider.min_value = low
	slider.max_value = high
	slider.step = step
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.custom_minimum_size = Vector2(220, 28)
	slider.focus_mode = Control.FOCUS_ALL
	row.add_child(slider)
	var readout := UiStyle.label("", 18, UiStyle.MUTED, 800)
	readout.custom_minimum_size = Vector2(64, 0)
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(readout)
	var show := func(value: float) -> void:
		readout.text = "%d%%" % roundi(value * 100.0) if percent else (
			"%.2f" % value if high <= 5.0 else "%d" % roundi(value)
		)
	slider.value_changed.connect(func(value: float) -> void:
		show.call(value)
		Settings.set_value(key, value))
	slider.drag_ended.connect(func(_changed: bool) -> void: UiStyle.play(&"toggle"))
	_rows.append({"key": key, "control": slider, "show": show})


func _toggle(parent: VBoxContainer, caption: String, key: StringName) -> void:
	var row := _row(parent, caption)
	var toggle := CheckButton.new()
	toggle.focus_mode = Control.FOCUS_ALL
	toggle.toggled.connect(func(on: bool) -> void:
		UiStyle.play(&"toggle")
		Settings.set_value(key, on))
	row.add_child(toggle)
	_rows.append({"key": key, "control": toggle})


func _choice(parent: VBoxContainer, caption: String, key: StringName, options: PackedStringArray) -> void:
	var row := _row(parent, caption)
	var picker := OptionButton.new()
	for option in options:
		picker.add_item(option)
	picker.custom_minimum_size = Vector2(220, 44)
	picker.focus_mode = Control.FOCUS_ALL
	picker.item_selected.connect(func(index: int) -> void:
		UiStyle.play(&"toggle")
		Settings.set_value(key, index))
	row.add_child(picker)
	_rows.append({"key": key, "control": picker})


## Pulls every control back into line with the stored settings, without firing their handlers.
func _sync() -> void:
	for entry: Dictionary in _rows:
		var value: Variant = Settings.get_value(entry["key"])
		var control: Control = entry["control"]
		if control is HSlider:
			(control as HSlider).set_value_no_signal(float(value))
			(entry["show"] as Callable).call(float(value))
		elif control is CheckButton:
			(control as CheckButton).set_pressed_no_signal(bool(value))
		elif control is OptionButton:
			(control as OptionButton).select(int(value))
