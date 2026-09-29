class_name GameUI
extends CanvasLayer

## The voyage's front end: title screen, play, pause, summary, and the panels they share.
##
## [b]The title screen is the world.[/b] There is no separate menu scene: the voyage loads once,
## and while the title is up the camera drifts round the raft waiting at its jetty. Choosing to
## sail starts a session in the scene that is already running, so there is no second load, the
## shaders are already compiled, and the first thing a player sees on pressing Set Sail is the
## place they were just looking at, from their own eyes.
##
## [b]States.[/b] TITLE, CONNECTING (a join in flight), PLAYING, PAUSED and SUMMARY. Settings,
## How to Play and Credits are overlays opened from the title or the pause menu, which return to
## whichever opened them.
##
## [b]Pausing is honest about multiplayer.[/b] A solo pause stops the tree — the sea included,
## since its clock runs in [method Node._process]. In a crewed voyage the menu opens and the
## world carries on, and the menu says so, because one player cannot stop everyone else's sea.
##
## Everything here is local: which screen is up, which way the camera drifts. The only thing it
## asks of the network is to start or leave a session, through [VoyageGame].

enum Screen { TITLE, CONNECTING, PLAYING, PAUSED, SUMMARY }

## Seconds after landfall before the summary appears, so the arrival itself is seen first.
const SUMMARY_DELAY: float = 2.8

## Seconds a fade to or from black takes.
const FADE_SECONDS: float = 0.45

## Where the title camera circles, how far out and how high: the raft at the end of its jetty.
const SHOWCASE_CENTRE: Vector3 = Vector3(-53.0, 2.0, 0.0)
const SHOWCASE_RADIUS: float = 23.0
const SHOWCASE_HEIGHT: float = 7.5

## Radians per second the title camera travels round its circle.
const SHOWCASE_SPEED: float = 0.045

## Names for gamepad buttons and axes, Xbox layout, for prompts and the legend.
const PAD_BUTTONS: Dictionary = {
	JOY_BUTTON_A: "A", JOY_BUTTON_B: "B", JOY_BUTTON_X: "X", JOY_BUTTON_Y: "Y",
	JOY_BUTTON_BACK: "View", JOY_BUTTON_START: "Menu", JOY_BUTTON_LEFT_STICK: "L3",
	JOY_BUTTON_RIGHT_STICK: "R3", JOY_BUTTON_LEFT_SHOULDER: "LB",
	JOY_BUTTON_RIGHT_SHOULDER: "RB", JOY_BUTTON_DPAD_UP: "D-pad Up",
	JOY_BUTTON_DPAD_DOWN: "D-pad Down", JOY_BUTTON_DPAD_LEFT: "D-pad Left",
	JOY_BUTTON_DPAD_RIGHT: "D-pad Right",
}
const PAD_AXES: Dictionary = {
	JOY_AXIS_TRIGGER_LEFT: "LT", JOY_AXIS_TRIGGER_RIGHT: "RT",
	JOY_AXIS_LEFT_X: "Left stick", JOY_AXIS_LEFT_Y: "Left stick",
	JOY_AXIS_RIGHT_X: "Right stick", JOY_AXIS_RIGHT_Y: "Right stick",
}

## Emitted when the screen changes, for anything that follows the front end's state.
signal screen_changed(screen: Screen)

## Emitted when the player switches between keyboard and gamepad.
signal device_changed(using_pad: bool)

var game: VoyageGame
var camera: PlayerCamera

var hud: VoyageHud
var _title: TitleScreen
var _pause: PauseMenu
var _summary: SummaryPanel
var _settings: SettingsPanel
var _help: HelpPanel
var _credits: CreditsPanel
var _fader: ColorRect
var _screen: Screen = Screen.TITLE
var _overlay: Control = null
var _overlay_return: Control = null
var _using_pad: bool = false
var _showcase_angle: float = 0.6
var _summary_timer: SceneTreeTimer
var _summary_dismissed: bool = false

## Exit code for a --smoke-test run; see _smoke_test().
var _smoke_code: int = 0


func _ready() -> void:
	layer = 5
	process_mode = Node.PROCESS_MODE_ALWAYS
	var root := Control.new()
	root.name = "Root"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = UiStyle.theme()
	add_child(root)

	hud = VoyageHud.new()
	hud.name = "Hud"
	hud.game = game
	hud.camera = camera
	hud.key_name = key_name
	root.add_child(hud)

	_title = TitleScreen.new()
	_title.name = "Title"
	_title.ui = self
	root.add_child(_title)

	_pause = PauseMenu.new()
	_pause.name = "Pause"
	_pause.ui = self
	root.add_child(_pause)

	_summary = SummaryPanel.new()
	_summary.name = "Summary"
	_summary.ui = self
	root.add_child(_summary)

	_settings = SettingsPanel.new()
	_settings.name = "Settings"
	_settings.ui = self
	root.add_child(_settings)

	_help = HelpPanel.new()
	_help.name = "Help"
	_help.ui = self
	root.add_child(_help)

	_credits = CreditsPanel.new()
	_credits.name = "Credits"
	_credits.ui = self
	root.add_child(_credits)

	_fader = ColorRect.new()
	_fader.name = "Fader"
	# The boot splash's own background, so the splash hands over to the fade without a flash.
	_fader.color = Color(0.043, 0.122, 0.180, 1.0)
	_fader.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fader.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_fader)

	for panel: Control in [_pause, _summary, _settings, _help, _credits]:
		panel.hide()

	NetworkSession.session_started.connect(_on_session_started)
	NetworkSession.session_ended.connect(_on_session_ended)
	NetworkSession.player_joined.connect(_on_player_joined)
	NetworkSession.player_left.connect(_on_player_left)
	game.director().phase_changed.connect(_on_phase_changed)
	if game.weather != null:
		game.weather.weather_changed.connect(_on_weather_changed)
	Settings.changed.connect(_on_setting_changed)
	_apply_camera_settings()
	_apply_performance_badge()

	# Closing the window takes the same road out as the menu's Quit: leave the session so the
	# crew is told why, stop the audio, then exit. See quit_game().
	get_tree().set_auto_accept_quit(false)

	# A launch with --server or --client is the two-window development test, and goes straight
	# to play exactly as it always has. Everyone else starts at the title.
	if NetworkSession.is_active() or NetworkSession.role_from_command_line() != NetworkSession.Role.NONE:
		_enter(Screen.PLAYING)
	else:
		_enter(Screen.TITLE)
	fade_in(1.2)
	if OS.get_cmdline_user_args().has("--smoke-test"):
		_smoke_test.call_deferred()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		quit_game()


## A packaged-build check: from the title, set sail alone, confirm the voyage is running, and quit
## by the normal road. Prints one verdict line and exits 0 on success, 1 on failure.
##
## Launched as [code]WaterEVERYWHERE -- --smoke-test[/code]. It exists because an exported build
## cannot load the verification suites — they are excluded from the pack — and "the export command
## succeeded" says nothing about whether the game inside it starts.
##
## With [code]--server[/code] as well it checks a hosted session instead, which the development
## launch arguments start before the title would appear.
func _smoke_test() -> void:
	var problems := PackedStringArray()
	var hosting := NetworkSession.role_from_command_line() == NetworkSession.Role.SERVER
	if not hosting:
		if _screen != Screen.TITLE:
			problems.append("did not open on the title")
		start_solo(0)
	var deadline := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline and game.get_node("Players").get_child_count() == 0:
		await get_tree().process_frame
	for _frame in 60:
		await get_tree().process_frame
	if game.get_node("Players").get_child_count() < 1:
		problems.append("no player body after setting sail")
	if hosting and not NetworkSession.is_networked():
		problems.append("not hosting a networked session")
	if not hosting and not NetworkSession.is_solo():
		problems.append("not in a solo session")
	if game.director().phase != RunDirector.Phase.VOYAGE:
		problems.append("the voyage did not start")
	if _screen != Screen.PLAYING:
		problems.append("not playing")
	print("smoke test: %s" % ("PASSED" if problems.is_empty() else "FAILED — " + "; ".join(problems)))
	_smoke_code = 0 if problems.is_empty() else 1
	quit_game()


func _process(delta: float) -> void:
	if _screen == Screen.TITLE or _screen == Screen.CONNECTING:
		_showcase_angle += delta * SHOWCASE_SPEED
		var eye := SHOWCASE_CENTRE + Vector3(
			cos(_showcase_angle) * SHOWCASE_RADIUS,
			SHOWCASE_HEIGHT + sin(_showcase_angle * 1.7) * 0.8,
			sin(_showcase_angle) * SHOWCASE_RADIUS,
		)
		camera.showcase(eye, SHOWCASE_CENTRE + Vector3(0, 1.5, 0))


func _input(event: InputEvent) -> void:
	_track_device(event)
	# The F1 debug panel closes on Escape itself; the menu must not open underneath it.
	var debug := game.get_node_or_null("HUD/DebugOverlay")
	if debug != null and debug.get("is_open"):
		return
	if event.is_action_pressed(&"pause"):
		_on_pause_pressed()
		get_viewport().set_input_as_handled()
		return
	# The gamepad's B backs out of menus. In play it is the push key, so it is only taken here
	# while a menu is actually up.
	if event is InputEventJoypadButton and event.is_action_pressed(&"ui_cancel"):
		if _screen != Screen.PLAYING:
			_on_pause_pressed()
			get_viewport().set_input_as_handled()


## Returns the screen currently shown.
func screen() -> Screen:
	return _screen


## Returns whether the player last used a gamepad.
func using_pad() -> bool:
	return _using_pad


## Returns the name of the control bound to [param action] for the device in use.
func key_name(action: StringName) -> String:
	if not InputMap.has_action(action):
		return String(action)
	var fallback := ""
	for event: InputEvent in InputMap.action_get_events(action):
		if _using_pad:
			if event is InputEventJoypadButton:
				return PAD_BUTTONS.get((event as InputEventJoypadButton).button_index, "Pad")
			if event is InputEventJoypadMotion:
				return PAD_AXES.get((event as InputEventJoypadMotion).axis, "Stick")
		else:
			var key := event as InputEventKey
			if key != null:
				var code := key.physical_keycode if key.physical_keycode != KEY_NONE else key.keycode
				if code != KEY_NONE:
					return OS.get_keycode_string(code)
		if fallback.is_empty() and event is InputEventKey:
			fallback = OS.get_keycode_string((event as InputEventKey).physical_keycode)
	return fallback if not fallback.is_empty() else String(action)


# ---------------------------------------------------------------------------------------------
# Actions the screens call
# ---------------------------------------------------------------------------------------------


## Sets sail alone in [param sea_state].
func start_solo(sea_state: int) -> void:
	Settings.set_value(&"sea_state", sea_state)
	UiStyle.play(&"start")
	await fade_out()
	game.start_solo(Settings.player_name(), sea_state)


## Hosts a crewed voyage. Returns the error that stopped it, or OK.
func start_host(port: int, sea_state: int) -> Error:
	Settings.set_value(&"sea_state", sea_state)
	Settings.set_value(&"port", port)
	var error := game.host_session(Settings.player_name("Host"), port, sea_state)
	if error == OK:
		UiStyle.play(&"start")
	return error


## Joins a crew at [param address]. The outcome arrives through the session's signals.
func start_join(address: String, port: int) -> Error:
	Settings.set_value(&"join_address", address)
	Settings.set_value(&"port", port)
	var error := game.join_session(address, port, Settings.player_name("Guest"))
	if error == OK:
		_enter(Screen.CONNECTING)
	return error


## Abandons a join that is still connecting.
func cancel_join() -> void:
	NetworkSession.leave()
	_enter(Screen.TITLE)


## Closes the pause menu or summary and returns to play.
func resume() -> void:
	if _screen == Screen.SUMMARY:
		_summary_dismissed = true
	_enter(Screen.PLAYING)


## Opens the pause menu.
func open_pause() -> void:
	if _screen == Screen.PLAYING or _screen == Screen.SUMMARY:
		_enter(Screen.PAUSED)


## Shows the summary again, from the pause menu, after it has been dismissed.
func show_summary() -> void:
	if game.director().phase == RunDirector.Phase.ARRIVAL:
		_enter(Screen.SUMMARY)


## Starts the crossing over. Authority only; clients see the reset arrive.
func sail_again() -> void:
	if not NetworkSession.is_authority():
		return
	get_tree().paused = false
	await fade_out(0.3)
	game.reset_run()
	_enter(Screen.PLAYING)
	fade_in()


## Leaves the voyage for the title screen.
func leave_to_title() -> void:
	get_tree().paused = false
	await fade_out()
	NetworkSession.leave()
	# session_ended brings the title up; if there was no session, bring it up here.
	if _screen != Screen.TITLE:
		_enter(Screen.TITLE)
	fade_in()


## Closes the game, leaving any session first so the other side is told why.
func quit_game() -> void:
	get_tree().paused = false
	await fade_out(0.3)
	if NetworkSession.is_active():
		NetworkSession.leave()
	# Stop the sea and the music first: see Audio.silence() for why quitting mid-song leaks.
	await Audio.silence()
	get_tree().quit(_smoke_code)


## Opens Settings, How to Play or Credits over whichever panel is up.
func open_overlay(which: StringName) -> void:
	var panel: Control = {&"settings": _settings, &"help": _help, &"credits": _credits}.get(which)
	if panel == null:
		return
	_overlay_return = _title if _screen == Screen.TITLE else _pause
	_overlay_return.hide()
	_overlay = panel
	panel.show()
	if panel.has_method(&"focus_first"):
		panel.call(&"focus_first")


## Closes the open overlay and returns to the panel that opened it.
func close_overlay() -> void:
	if _overlay == null:
		return
	UiStyle.play(&"back")
	_overlay.hide()
	_overlay = null
	if _overlay_return != null:
		_overlay_return.show()
		if _overlay_return.has_method(&"focus_first"):
			_overlay_return.call(&"focus_first")
	_overlay_return = null


## Fades the screen to black. Awaitable.
func fade_out(seconds: float = FADE_SECONDS) -> void:
	_fader.show()
	var tween := create_tween()
	tween.tween_property(_fader, "color:a", 1.0, seconds)
	await tween.finished


## Fades the screen in from black.
func fade_in(seconds: float = FADE_SECONDS) -> void:
	_fader.show()
	var tween := create_tween()
	tween.tween_property(_fader, "color:a", 0.0, seconds)
	tween.tween_callback(_fader.hide)


# ---------------------------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------------------------


func _enter(next: Screen) -> void:
	if _overlay != null:
		_overlay.hide()
		_overlay = null
		_overlay_return = null
	_screen = next
	var playing := next == Screen.PLAYING
	var in_session := next in [Screen.PLAYING, Screen.PAUSED, Screen.SUMMARY]
	hud.visible = in_session
	_title.visible = next == Screen.TITLE or next == Screen.CONNECTING
	_pause.visible = next == Screen.PAUSED
	_summary.visible = next == Screen.SUMMARY
	_set_legend_visible(in_session)
	game.session_keys_enabled = false
	get_tree().paused = next == Screen.PAUSED and NetworkSession.is_solo()

	camera.input_blocked = not playing
	camera.set_mouse_captured(playing)

	match next:
		Screen.TITLE:
			_title.show_main()
			Audio.play_music(&"title")
		Screen.CONNECTING:
			_title.show_connecting()
		Screen.PLAYING:
			Audio.play_music(&"voyage", 2.5, -7.0)
		Screen.PAUSED:
			_pause.refresh()
			_pause.focus_first()
		Screen.SUMMARY:
			_summary.refresh()
			_summary.focus_first()
	screen_changed.emit(next)


func _on_pause_pressed() -> void:
	if _overlay != null:
		close_overlay()
		return
	match _screen:
		Screen.PLAYING:
			UiStyle.play(&"toggle")
			_enter(Screen.PAUSED)
		Screen.PAUSED, Screen.SUMMARY:
			UiStyle.play(&"back")
			resume()
		Screen.CONNECTING:
			cancel_join()
		Screen.TITLE:
			_title.back()


func _on_session_started(_as_server: bool) -> void:
	_summary_dismissed = false
	_enter(Screen.PLAYING)
	fade_in(0.8)


func _on_session_ended(reason: String) -> void:
	get_tree().paused = false
	_enter(Screen.TITLE)
	if reason != NetworkSession.REASON_LEFT:
		_title.show_notice(reason)


func _on_player_joined(peer_id: int, player_name: String) -> void:
	if _screen != Screen.TITLE and peer_id != NetworkSession.local_peer_id():
		hud.toast("%s joined the crew" % player_name, UiStyle.SEA)


func _on_player_left(peer_id: int, player_name: String) -> void:
	if _screen != Screen.TITLE and peer_id != NetworkSession.local_peer_id():
		hud.toast("%s left the voyage" % player_name, UiStyle.MUTED)


func _on_phase_changed(phase: RunDirector.Phase, _revision: int) -> void:
	if _screen == Screen.TITLE or _screen == Screen.CONNECTING:
		return
	match phase:
		RunDirector.Phase.ARRIVAL:
			hud.toast("Landfall!", UiStyle.ACCENT, 3.5)
			Audio.play_sting(&"arrival")
			Audio.play_music(&"title", 3.0, -6.0)
			_record_result()
			_summary_timer = get_tree().create_timer(SUMMARY_DELAY, true)
			_summary_timer.timeout.connect(func() -> void:
				if _screen == Screen.PLAYING and not _summary_dismissed \
						and game.director().phase == RunDirector.Phase.ARRIVAL:
					_enter(Screen.SUMMARY))
		RunDirector.Phase.VOYAGE:
			_summary_dismissed = false
			if _screen == Screen.SUMMARY:
				_enter(Screen.PLAYING)
			Audio.play_music(&"voyage", 2.5, -7.0)


func _on_weather_changed(preset: WeatherPreset, _index: int) -> void:
	if _screen != Screen.TITLE and preset != null:
		hud.toast("The weather turns: %s" % preset.display_name, UiStyle.TEXT)


## Keeps this machine's best time for the sea just crossed.
func _record_result() -> void:
	var facts := game.director().facts
	var seconds := float(facts.get("seconds", -1.0))
	var crew: Array = facts.get("crew", [])
	var sea := int(facts.get("weather", 0))
	_summary.new_record = Records.submit(sea, crew.size() > 1, seconds)


func _track_device(event: InputEvent) -> void:
	var pad := event is InputEventJoypadButton or (
		event is InputEventJoypadMotion and absf((event as InputEventJoypadMotion).axis_value) > 0.5
	)
	var keyboard := event is InputEventKey or event is InputEventMouseButton
	if (pad and not _using_pad) or (keyboard and _using_pad):
		_using_pad = pad
		game.refresh_legend()
		device_changed.emit(_using_pad)


func _on_setting_changed(key: StringName) -> void:
	match key:
		&"mouse_sensitivity", &"invert_y", &"pad_sensitivity", &"field_of_view":
			_apply_camera_settings()
		&"show_fps":
			_apply_performance_badge()
		&"quality":
			game.apply_graphics_quality()


func _apply_camera_settings() -> void:
	camera.mouse_sensitivity = float(Settings.get_value(&"mouse_sensitivity"))
	camera.invert_y = bool(Settings.get_value(&"invert_y"))
	camera.pad_look_speed = 170.0 * float(Settings.get_value(&"pad_sensitivity"))
	camera.set_field_of_view(float(Settings.get_value(&"field_of_view")))


func _apply_performance_badge() -> void:
	var badge := game.get_node_or_null("HUD/DebugOverlay/PerformanceBadge") as Control
	if badge != null:
		badge.visible = bool(Settings.get_value(&"show_fps"))


func _set_legend_visible(shown: bool) -> void:
	var legend := game.get_node_or_null("HUD/Status") as Label
	if legend == null:
		return
	legend.visible = shown and bool(Settings.get_value(&"show_hints"))
