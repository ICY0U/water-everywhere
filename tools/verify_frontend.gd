extends SceneTree

## Checks the voyage's front end end to end: title, solo, pause, arrival and summary, sailing
## again, leaving, hosting, and the settings and records it keeps.
##
## Every screen is driven through the same methods its buttons call, and every assertion is about
## the game rather than about the UI's own bookkeeping: that a solo voyage opens no socket, that a
## solo pause stops the sea while a crewed one does not, that the summary reports what the
## authority measured, that leaving puts the raft back at its jetty.
##
## [b]Isolated files.[/b] Run with [code]-- --profile=verify[/code] (the runner does), so the best
## times and settings written here land in their own profile and never in the player's.
##
## Classes that name autoloads — [GameUI], [VoyageGame] — are reached through [code]call()[/code]
## rather than typed, for the parse-order reason [code]tools/verify_voyage.gd[/code] documents.
##
## Run with:
## [codeblock lang=text]
## godot --path . --headless --script tools/verify_frontend.gd -- --profile=verify
## [/codeblock]
## Exits non-zero if any check fails.

const SCENE := "res://scenes/voyage.tscn"

## Port for the hosting check: clear of the game's default and of every other suite's.
const HOST_PORT: int = 27131

## GameUI.Screen values, mirrored because the enum cannot be named from here.
const TITLE: int = 0
const PLAYING: int = 2
const PAUSED: int = 3
const SUMMARY: int = 4

var _failures: int = 0
var _game: Node3D
var _ui: CanvasLayer
var _session: Node
var _settings: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	create_timer(180.0).timeout.connect(func() -> void:
		_expect(false, "the front end suite finished before its timeout")
		_finish())

	_session = root.get_node("NetworkSession")
	_settings = root.get_node("Settings")
	_expect(
		String(root.get_node("Settings").get("FILE_NAME")) == "settings.cfg"
		and _profile_is_isolated(),
		"the suite writes to its own profile, not the player's"
	)
	_clear_profile()

	_game = load(SCENE).instantiate()
	root.add_child(_game)
	current_scene = _game
	await _frames(5)
	_ui = _game.call("ui")
	var director: Node = _game.call("director")
	var raft: RigidBody3D = _game.get("raft")
	var players: Node = _game.get_node("Players")

	# --- Title ----------------------------------------------------------------------------
	_expect(_ui != null, "the voyage builds its front end")
	_expect(int(_ui.call("screen")) == TITLE, "the game opens on the title screen")
	_expect(not _session.call("is_active"), "the title runs with no session")
	_expect(players.get_child_count() == 0, "nobody is in the water behind the title")
	_expect(raft.get("moored"), "the raft waits at its jetty behind the title")
	_expect(not _game.get("session_keys_enabled"), "H and J do nothing while the menu is in charge")
	var camera: Node3D = _game.get_node("PlayerCamera")
	_expect(camera.get("input_blocked"), "the camera ignores play input behind the title")

	# --- Solo -----------------------------------------------------------------------------
	_ui.call("start_solo", 0)
	await _until(func() -> bool: return players.get_child_count() == 1 and int(_ui.call("screen")) == PLAYING)
	_expect(_session.call("is_solo"), "Set Sail starts a solo session")
	_expect(
		root.multiplayer.multiplayer_peer is OfflineMultiplayerPeer,
		"a solo voyage opens no network socket"
	)
	_expect(int(_ui.call("screen")) == PLAYING, "a solo voyage goes straight to play")
	_expect(players.get_child_count() == 1, "a solo voyage has exactly one body")
	_expect(int(director.get("phase")) == RunDirector.Phase.VOYAGE, "the crossing is under way")
	var hud: Control = _ui.get_node("Root/Hud")
	_expect(hud.visible, "the HUD shows during play")
	var legend := _game.get_node("HUD/Status") as Label
	_expect(
		legend.visible and legend.text.contains("Paddle") and legend.text.contains("Push"),
		"the key legend names paddling and pushing ('%s')" % legend.text.replace("\n", " / ")
	)

	# --- Pause ----------------------------------------------------------------------------
	var ocean: Node = _game.get("ocean")
	_ui.call("open_pause")
	await process_frame
	_expect(int(_ui.call("screen")) == PAUSED, "the menu opens over a solo voyage")
	_expect(paused, "a solo pause stops the world")
	var clock_before: float = ocean.get("elapsed_time")
	await _frames(20)
	_expect(
		is_equal_approx(float(ocean.get("elapsed_time")), clock_before),
		"the sea's clock stops while paused (%.3f -> %.3f)" % [clock_before, ocean.get("elapsed_time")]
	)
	_ui.call("resume")
	await process_frame
	_expect(not paused and int(_ui.call("screen")) == PLAYING, "resuming restarts the world")

	# --- Arrival --------------------------------------------------------------------------
	var body: RigidBody3D = players.get_child(0)
	var mainland: Node3D = _game.get("mainland")
	await physics_frame
	body.global_position = mainland.global_position + Vector3(0, 20, 0)
	await _until(func() -> bool: return int(director.get("phase")) == RunDirector.Phase.ARRIVAL)
	_expect(int(director.get("phase")) == RunDirector.Phase.ARRIVAL, "reaching the mainland lands the crew")
	var facts: Dictionary = director.get("facts")
	_expect(
		float(facts.get("seconds", 0.0)) > 0.0 and String(facts.get("first", "")) == body.get("player_name")
		and (facts.get("crew", []) as Array).size() == 1 and facts.has("strokes"),
		"the authority records the crossing's facts (%s)" % str(facts)
	)
	await _until(func() -> bool: return int(_ui.call("screen")) == SUMMARY, 6.0)
	_expect(int(_ui.call("screen")) == SUMMARY, "the summary follows landfall")
	_expect(
		Records.best(0, false) > 0.0,
		"the crossing time is kept as this machine's best (%.1f s)" % Records.best(0, false)
	)

	# --- Sail again -----------------------------------------------------------------------
	_ui.call("sail_again")
	await _until(func() -> bool: return int(director.get("phase")) == RunDirector.Phase.VOYAGE and int(_ui.call("screen")) == PLAYING)
	await _frames(5)
	_expect(int(director.get("phase")) == RunDirector.Phase.VOYAGE, "Sail Again starts a new crossing")
	_expect(int(_ui.call("screen")) == PLAYING, "Sail Again returns to play")
	_expect(raft.get("moored"), "the raft is tied up at the jetty again")
	var home: Node3D = _game.get("home")
	var back := Vector2(body.global_position.x - home.global_position.x,
		body.global_position.z - home.global_position.z).length()
	_expect(back < float(home.get("plateau_radius")), "the crew is back on the home island (r=%.1f)" % back)

	# --- Leave ----------------------------------------------------------------------------
	raft.set("moored", false)
	raft.global_position += Vector3(-30, 0, 0)
	_ui.call("leave_to_title")
	await _until(func() -> bool: return not _session.call("is_active") and players.get_child_count() == 0)
	_expect(int(_ui.call("screen")) == TITLE, "leaving returns to the title")
	_expect(not _session.call("is_active"), "leaving ends the session")
	_expect(players.get_child_count() == 0, "leaving removes the crew from the water")
	_expect(
		raft.get("moored") and raft.global_position.distance_to(_raft_berth()) < 3.0,
		"leaving puts the raft back at its jetty (%.1f m off)" % raft.global_position.distance_to(_raft_berth())
	)
	_expect(int(director.get("phase")) == RunDirector.Phase.LOBBY, "leaving resets the run")

	# --- Host -----------------------------------------------------------------------------
	var error: int = _ui.call("start_host", HOST_PORT, 1)
	await _until(func() -> bool: return players.get_child_count() == 1)
	_expect(error == OK and _session.call("is_networked"), "Host a Crew opens a real session")
	_expect(
		root.multiplayer.multiplayer_peer is ENetMultiplayerPeer,
		"a hosted voyage is listening on ENet"
	)
	var weather: Node = _game.get("weather")
	_expect(int(weather.call("current_index")) == 1, "the host's chosen sea is the one sailed")
	_ui.call("open_pause")
	await process_frame
	_expect(not paused, "a crewed voyage keeps running under the menu")
	_ui.call("resume")
	_ui.call("leave_to_title")
	await _until(func() -> bool: return not _session.call("is_active"))
	_expect(not _session.call("is_active"), "the host can leave again")

	# --- Settings ---------------------------------------------------------------------------
	_settings.call("set_value", &"mouse_sensitivity", 0.4)
	await process_frame
	_expect(is_equal_approx(float(camera.get("mouse_sensitivity")), 0.4), "sensitivity reaches the camera")
	var stored := ConfigFile.new()
	stored.load(UserPaths.file("settings.cfg"))
	_expect(
		is_equal_approx(float(stored.get_value("settings", "mouse_sensitivity", 0.0)), 0.4),
		"settings are saved to disk as they change"
	)
	_settings.call("set_value", &"no_such_setting", 1)
	_expect(_settings.call("get_value", &"no_such_setting") == null, "an unknown setting is refused")
	_settings.call("set_value", &"quality", 0)
	_expect(
		not ((_game.get_node("WorldEnvironment") as WorldEnvironment).environment.volumetric_fog_enabled),
		"the Low preset turns volumetric fog off"
	)
	weather.call("apply_index", 2)
	_expect(
		not ((_game.get_node("WorldEnvironment") as WorldEnvironment).environment.volumetric_fog_enabled),
		"a weather change cannot switch fog back on under Low"
	)
	_settings.call("reset_to_defaults")

	# --- Device names ---------------------------------------------------------------------
	_expect(String(_ui.call("key_name", &"paddle")) == "Space", "prompts name keys on a keyboard")
	# Y rather than A: A is also ui_accept, and would press whichever title button has focus.
	var press := InputEventJoypadButton.new()
	press.button_index = JOY_BUTTON_Y
	press.pressed = true
	Input.parse_input_event(press)
	await _frames(2)
	_expect(String(_ui.call("key_name", &"board")) == "A", "prompts name buttons on a gamepad")

	_clear_profile()
	_finish()


func _raft_berth() -> Vector3:
	return (_game.get("_raft_start") as Transform3D).origin


func _profile_is_isolated() -> bool:
	return UserPaths.profile_name() == "verify" and UserPaths.file("x").contains("profiles/verify")


func _clear_profile() -> void:
	for file_name in ["settings.cfg", "records.cfg"]:
		var path := UserPaths.file(file_name)
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


## Waits until [param condition] holds, or [param seconds] of real time pass. The front end's
## fades run on real time, and headless frames are nearly instant, so counting frames would check
## before a fade had finished.
func _until(condition: Callable, seconds: float = 5.0) -> void:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while not condition.call() and Time.get_ticks_msec() < deadline:
		await process_frame


func _frames(count: int) -> void:
	for _frame in count:
		await process_frame


func _expect(condition: bool, message: String) -> void:
	print("%s %s" % ["PASS " if condition else "FAIL ", message])
	if not condition:
		_failures += 1


func _finish() -> void:
	print("verify_frontend: %d failures" % _failures)
	quit(1 if _failures else 0)
