class_name GameMenu
extends Control

## The player-facing front end of the voyage: title, co-op, settings, pause and arrival screens.
##
## Built in code, like [code]debug_overlay.gd[/code], so the release scene carries it without a
## second scene file to keep in step. Only one screen shows at a time. While any screen is up the
## camera stops reading the mouse and the cursor is freed; closing the last one hands control back.
##
## [b]Presentation and requests only.[/b] Every button asks the same code a key or a launch
## argument already reaches — [method NetworkSession.host], [method VoyageGame.reset_run],
## [method MultiplayerGame._quit_game] — so the menu adds no second path into the game's rules.

## Emitted when a screen opens or the last one closes, so the game can hide HUD text under it.
signal screen_changed(blocking: bool)

## Where settings are kept between launches.
const SETTINGS_PATH: String = "user://settings.cfg"

## Ports a solo game tries in turn. A second copy of the game, or anything else on the machine
## holding the first, must not stop someone playing alone.
const SOLO_PORT_ATTEMPTS: int = 10

## Screens, at most one of which is visible.
enum Screen { NONE, TITLE, COOP, SETTINGS, PAUSE, ARRIVAL }

## The game this menu fronts. Assigned before the menu enters the tree.
var game: VoyageGame

var _screen: Screen = Screen.NONE
## Screen the settings page returns to: the title or the pause menu.
var _settings_return: Screen = Screen.TITLE
var _panels: Dictionary = {}
var _notice: Label
var _coop_notice: Label
var _name_field: LineEdit
var _address_field: LineEdit
var _arrival_time: Label
var _restart_button: Button
var _again_button: Button
var _waiting_label: Label
var _paused_world: bool = false
var _sensitivity: float = 0.25
var _fullscreen: bool = false
var _show_fps: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = _make_theme()
	_build()
	_load_settings()
	_apply_settings()
	NetworkSession.session_started.connect(_on_session_started)
	NetworkSession.session_ended.connect(_on_session_ended)
	NetworkSession.roster_changed.connect(_on_roster_changed)
	# A launch that already names its role — the two-window test, a dedicated host — goes
	# straight into the session it asked for, as it always has.
	if NetworkSession.role_from_command_line() == NetworkSession.Role.NONE:
		show_title()


func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo or key.keycode != KEY_ESCAPE:
		return
	# The debug panel closes itself on Escape; this menu leaves it alone while it is open.
	if game._debug_overlay != null and game._debug_overlay.get("is_open"):
		return
	match _screen:
		Screen.PAUSE, Screen.ARRIVAL:
			close()
		Screen.SETTINGS:
			_open(_settings_return)
		Screen.COOP:
			_open(Screen.TITLE)
		Screen.NONE:
			if NetworkSession.is_active():
				_open(Screen.PAUSE)
		_:
			return
	get_viewport().set_input_as_handled()


## Whether a screen is up, covering the game.
func is_blocking() -> bool:
	return _screen != Screen.NONE


## Shows the title screen, with [param notice] under it when there is something to explain.
func show_title(notice: String = "") -> void:
	_notice.text = notice
	_open(Screen.TITLE)


## Shows the end of a crossing: how long it took, and what can happen next.
##
## [param can_restart] is whether this peer decides the run. Anyone else is told they are waiting
## on the host, rather than offered a button that would do nothing.
func show_arrival(seconds: float, can_restart: bool) -> void:
	var whole := int(round(seconds))
	_arrival_time.text = "Crossing time  %d:%02d" % [whole / 60, whole % 60]
	_again_button.visible = can_restart
	_waiting_label.visible = not can_restart
	_open(Screen.ARRIVAL)


## Closes whatever screen is up and hands control back to the player.
func close() -> void:
	_open(Screen.NONE)


func _open(screen: Screen) -> void:
	_screen = screen
	for key: Screen in _panels:
		(_panels[key] as Control).visible = key == screen
	var blocking := screen != Screen.NONE
	mouse_filter = Control.MOUSE_FILTER_STOP if blocking else Control.MOUSE_FILTER_IGNORE
	var camera := game.get_node("PlayerCamera") as PlayerCamera
	camera.input_blocked = blocking
	camera._set_mouse_captured(not blocking and NetworkSession.is_active())
	if screen == Screen.PAUSE:
		_restart_button.visible = NetworkSession.is_authority()
		(_panels[Screen.PAUSE].find_child("Title", true, false) as Label).text = (
			"Paused" if _can_pause_world() else "Menu")
	_set_world_paused(screen in [Screen.PAUSE, Screen.SETTINGS] and _can_pause_world())
	if blocking:
		var button := _first_button(_panels[screen])
		if button != null:
			button.grab_focus.call_deferred()
	screen_changed.emit(blocking)


## Only a host alone in its session may stop the world: anyone else's sea would carry on without
## them, and a client that froze its own clock would be dragged back the moment it resumed.
func _can_pause_world() -> bool:
	return NetworkSession.is_authority() and NetworkSession.players.size() <= 1


func _set_world_paused(paused: bool) -> void:
	if paused == _paused_world:
		return
	_paused_world = paused
	get_tree().paused = paused


# --- Actions ---------------------------------------------------------------------------------

func _play_solo() -> void:
	var port := NetworkSession.port_from_command_line()
	var error: Error = FAILED
	for attempt in SOLO_PORT_ATTEMPTS:
		error = NetworkSession.host(port + attempt, _player_name(), true)
		if error == OK:
			return
	_notice.text = "Could not start a game: %s." % error_string(error)


func _host_coop() -> void:
	var error := NetworkSession.host(NetworkSession.port_from_command_line(), _player_name())
	if error != OK:
		_coop_notice.text = "Could not host on port %d: %s." % [
			NetworkSession.port_from_command_line(), error_string(error)]


func _join_coop() -> void:
	var address := _address_field.text.strip_edges()
	if address.is_empty():
		_coop_notice.text = "Type the host's address first."
		return
	var error := NetworkSession.join(address, NetworkSession.port_from_command_line(),
		_player_name())
	_coop_notice.text = ("Connecting to %s…" % address) if error == OK else (
		"Could not connect: %s." % error_string(error))


func _restart_run() -> void:
	close()
	game.reset_run()


func _to_title() -> void:
	_set_world_paused(false)
	# Leaving announces itself through session_ended, which is what brings the title back.
	NetworkSession.leave()


func _quit() -> void:
	_set_world_paused(false)
	_save_settings()
	game._quit_game()


func _player_name() -> String:
	var typed := _name_field.text.strip_edges()
	return typed if not typed.is_empty() else "Player"


func _on_session_started(_as_server: bool) -> void:
	_coop_notice.text = ""
	_notice.text = ""
	close()


## A friend arriving at a paused host must not find a frozen world, so the pause lifts at once.
func _on_roster_changed() -> void:
	if _paused_world and not _can_pause_world():
		_set_world_paused(false)
		if _screen == Screen.PAUSE:
			(_panels[Screen.PAUSE].find_child("Title", true, false) as Label).text = "Menu"


func _on_session_ended(reason: String) -> void:
	show_title("" if reason == NetworkSession.REASON_LEFT else reason)


# --- Settings --------------------------------------------------------------------------------

func _load_settings() -> void:
	var camera := game.get_node("PlayerCamera") as PlayerCamera
	_sensitivity = camera.mouse_sensitivity
	var file := ConfigFile.new()
	if file.load(SETTINGS_PATH) != OK:
		return
	_sensitivity = clampf(float(file.get_value("controls", "mouse_sensitivity", _sensitivity)),
		0.05, 1.0)
	_fullscreen = bool(file.get_value("display", "fullscreen", false))
	_show_fps = bool(file.get_value("display", "show_fps", false))


func _save_settings() -> void:
	var file := ConfigFile.new()
	file.set_value("controls", "mouse_sensitivity", _sensitivity)
	file.set_value("display", "fullscreen", _fullscreen)
	file.set_value("display", "show_fps", _show_fps)
	file.save(SETTINGS_PATH)


func _apply_settings() -> void:
	(game.get_node("PlayerCamera") as PlayerCamera).mouse_sensitivity = _sensitivity
	# Only switched when it differs, so a windowed launch under the editor is left alone.
	var fullscreen_now := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
	if DisplayServer.get_name() != "headless" and fullscreen_now != _fullscreen:
		DisplayServer.window_set_mode(
			DisplayServer.WINDOW_MODE_FULLSCREEN if _fullscreen
			else DisplayServer.WINDOW_MODE_WINDOWED)
	if game._debug_overlay != null:
		var badge := game._debug_overlay.get_node_or_null("PerformanceBadge") as Control
		if badge != null:
			badge.visible = _show_fps


# --- Construction ----------------------------------------------------------------------------

func _build() -> void:
	var shade := ColorRect.new()
	shade.name = "Shade"
	shade.color = Color(0.02, 0.05, 0.08, 0.35)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)
	screen_changed.connect(func(blocking: bool) -> void: shade.visible = blocking)

	_build_title()
	_build_coop()
	_build_settings()
	_build_pause()
	_build_arrival()
	_open(Screen.NONE)


func _build_title() -> void:
	var box := _panel(Screen.TITLE, "WaterTitle", 500)
	# Held in the left part of the screen rather than centred: the view behind it opens on the
	# mainland's mountains, which are the one thing the title should not cover.
	var holder := _panels[Screen.TITLE] as Control
	holder.anchor_right = 0.46
	var title := _heading("Water EveryWhere", 46)
	box.add_child(title)
	box.add_child(_text("Paddle a battered raft home to the mainland."))
	box.add_child(_spacer(8))
	_button(box, "Play", "Play", _play_solo)
	_button(box, "Coop", "Play with friends", func() -> void: _open(Screen.COOP))
	_button(box, "Settings", "Settings", func() -> void:
		_settings_return = Screen.TITLE
		_open(Screen.SETTINGS))
	_button(box, "Quit", "Quit", _quit)
	_notice = _text("")
	_notice.add_theme_color_override("font_color", Color("f2b880"))
	box.add_child(_notice)
	var version := str(ProjectSettings.get_setting("application/config/version", ""))
	var footer := _text("Demo%s" % ((" " + version) if not version.is_empty() else ""))
	footer.add_theme_font_size_override("font_size", 13)
	footer.modulate = Color(1, 1, 1, 0.55)
	box.add_child(footer)


func _build_coop() -> void:
	var box := _panel(Screen.COOP, "CoopPanel", 460)
	box.add_child(_heading("Play with friends", 30))
	box.add_child(_text("Your name"))
	_name_field = LineEdit.new()
	_name_field.name = "NameField"
	_name_field.max_length = 24
	_name_field.text = NetworkSession.name_from_command_line()
	_name_field.placeholder_text = "Player"
	box.add_child(_name_field)
	box.add_child(_spacer(6))
	_button(box, "Host", "Host a game", _host_coop)
	box.add_child(_text(
		"Friends join your IP address on UDP port %d. Over the internet the host's router must "
		% NetworkSession.port_from_command_line() + "forward that port."))
	box.add_child(_spacer(6))
	box.add_child(_text("Join a host at"))
	_address_field = LineEdit.new()
	_address_field.name = "AddressField"
	_address_field.text = game._join_address()
	_address_field.placeholder_text = "192.168.1.50"
	box.add_child(_address_field)
	_button(box, "Join", "Join", _join_coop)
	_coop_notice = _text("")
	_coop_notice.add_theme_color_override("font_color", Color("f2b880"))
	box.add_child(_coop_notice)
	_button(box, "Back", "Back", func() -> void: _open(Screen.TITLE))


func _build_settings() -> void:
	var box := _panel(Screen.SETTINGS, "SettingsPanel", 420)
	box.add_child(_heading("Settings", 30))
	var sensitivity_label := _text("")
	box.add_child(sensitivity_label)
	var slider := HSlider.new()
	slider.name = "Sensitivity"
	slider.min_value = 0.05
	slider.max_value = 1.0
	slider.step = 0.01
	slider.custom_minimum_size.y = 24
	box.add_child(slider)
	var fullscreen := CheckButton.new()
	fullscreen.name = "Fullscreen"
	fullscreen.text = "Fullscreen"
	box.add_child(fullscreen)
	var fps := CheckButton.new()
	fps.name = "ShowFps"
	fps.text = "Show frame rate"
	box.add_child(fps)
	# Filled in when the page opens, so it always shows what is actually in force.
	screen_changed.connect(func(_blocking: bool) -> void:
		if _screen != Screen.SETTINGS:
			return
		slider.set_value_no_signal(_sensitivity)
		sensitivity_label.text = "Mouse sensitivity  %.2f" % _sensitivity
		fullscreen.set_pressed_no_signal(_fullscreen)
		fps.set_pressed_no_signal(_show_fps))
	slider.value_changed.connect(func(value: float) -> void:
		_sensitivity = value
		sensitivity_label.text = "Mouse sensitivity  %.2f" % value
		_apply_settings()
		_save_settings())
	fullscreen.toggled.connect(func(on: bool) -> void:
		_fullscreen = on
		_apply_settings()
		_save_settings())
	fps.toggled.connect(func(on: bool) -> void:
		_show_fps = on
		_apply_settings()
		_save_settings())
	_button(box, "Back", "Back", func() -> void: _open(_settings_return))


func _build_pause() -> void:
	var box := _panel(Screen.PAUSE, "PausePanel", 440)
	var title := _heading("Paused", 30)
	title.name = "Title"
	box.add_child(title)
	_button(box, "Resume", "Resume", close)
	_restart_button = _button(box, "Restart", "Restart the crossing", _restart_run)
	_button(box, "Settings", "Settings", func() -> void:
		_settings_return = Screen.PAUSE
		_open(Screen.SETTINGS))
	_button(box, "MainMenu", "Main menu", _to_title)
	_button(box, "Quit", "Quit", _quit)
	box.add_child(_spacer(4))
	var controls := _text(_controls_text())
	controls.name = "Controls"
	controls.add_theme_font_size_override("font_size", 14)
	box.add_child(controls)


func _build_arrival() -> void:
	var box := _panel(Screen.ARRIVAL, "ArrivalPanel", 440)
	box.add_child(_heading("You made it!", 40))
	box.add_child(_text("The crew reached the mainland."))
	_arrival_time = _text("")
	_arrival_time.name = "Time"
	_arrival_time.add_theme_font_size_override("font_size", 22)
	box.add_child(_arrival_time)
	box.add_child(_spacer(6))
	_again_button = _button(box, "Again", "Sail again", _restart_run)
	_waiting_label = _text("Waiting for the host to sail again.")
	box.add_child(_waiting_label)
	_button(box, "Explore", "Keep exploring", close)
	_button(box, "MainMenu", "Main menu", _to_title)


## Returns the controls, with the keys read out of the InputMap wherever an action exists.
func _controls_text() -> String:
	var lines := PackedStringArray([
		"WASD  move    Mouse  look    Shift  sprint",
		"%s  climb aboard    %s  paddle (hold)    %s  push off shore" % [
			game._key_name(&"board"), game._key_name(&"paddle"), game._key_name(&"push")],
		"Paddling turns the raft away from your side: walk across the deck to steer.",
		"V  first / third person    1 2 3  weather    Esc  menu",
	])
	return "\n".join(lines)


func _panel(screen: Screen, panel_name: String, width: float) -> VBoxContainer:
	var holder := CenterContainer.new()
	holder.name = panel_name
	holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(holder)
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = width
	holder.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)
	_panels[screen] = holder
	return box


func _heading(text: String, size: int) -> Label:
	var label := _text(text)
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", Color("f4fbff"))
	label.add_theme_color_override("font_outline_color", Color(0.05, 0.2, 0.3, 0.9))
	label.add_theme_constant_override("outline_size", 8)
	return label


func _text(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


func _spacer(height: float) -> Control:
	var spacer := Control.new()
	spacer.custom_minimum_size.y = height
	return spacer


func _button(parent: Control, button_name: String, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.name = button_name
	button.text = text
	button.custom_minimum_size.y = 42
	button.pressed.connect(action)
	parent.add_child(button)
	return button


func _first_button(node: Node) -> Button:
	for child in node.get_children():
		if child is Button and (child as Button).visible:
			return child
		var found := _first_button(child)
		if found != null:
			return found
	return null


func _make_theme() -> Theme:
	var result := Theme.new()
	result.default_font_size = 18
	for kind in ["Label", "Button", "CheckButton", "LineEdit"]:
		result.set_color("font_color", kind, Color("e6f1f8"))
	result.set_stylebox("panel", "PanelContainer",
		_style(Color(0.04, 0.09, 0.13, 0.9), Color("4a7890"), 22))
	result.set_stylebox("normal", "Button", _style(Color("1d4459"), Color("3f7690"), 8))
	result.set_stylebox("hover", "Button", _style(Color("2a6079"), Color("8fe3d8"), 8))
	result.set_stylebox("focus", "Button", _style(Color(0, 0, 0, 0), Color("8fe3d8"), 8))
	result.set_stylebox("pressed", "Button", _style(Color("17525a"), Color("8fe3d8"), 8))
	result.set_stylebox("normal", "LineEdit", _style(Color("0e2533"), Color("3f7690"), 8))
	result.set_stylebox("focus", "LineEdit", _style(Color("0e2533"), Color("8fe3d8"), 8))
	return result


func _style(color: Color, border: Color, margin: float) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = border
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.content_margin_left = margin
	style.content_margin_right = margin
	style.content_margin_top = margin * 0.6
	style.content_margin_bottom = margin * 0.6
	return style
