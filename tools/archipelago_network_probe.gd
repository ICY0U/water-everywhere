extends Node

## Test-only RPC endpoint. Not referenced by any gameplay scene.
var _game: Node3D
var _session: Node
var _client: bool
var _failures: int = 0
var _client_pid: int = -1
var _guest: int = 0
var _reports: Dictionary = {}
var _impact_received: bool = false


func _ready() -> void:
	_game = get_parent()
	_session = get_tree().root.get_node("NetworkSession")
	_client = "--probe-client" in OS.get_cmdline_user_args()
	_game.get_node("Ocean").water_impacted.connect(func(impact: WaterImpact) -> void:
		if impact.seed == 918273:
			_impact_received = true)
	get_tree().create_timer(40.0).timeout.connect(func() -> void:
		_check("network test completes before timeout", false)
		_finish())
	_run.call_deferred()


func _run() -> void:
	await get_tree().create_timer(0.2).timeout
	var hud: String = _game.get_node("HUD/Status").text
	_check("starts offline with H/J instructions", not _session.is_active()
		and _game.get_node("Players").get_child_count() == 0
		and hud.contains("H  host") and hud.contains("J  join"))
	_press(KEY_J if _client else KEY_H)
	if _client:
		while _game.get_node("Players").get_child_count() < 2:
			await get_tree().process_frame
		await get_tree().create_timer(0.6).timeout
		_submit.rpc_id(1, "joined", _snapshot())
		return
	await get_tree().create_timer(0.3).timeout
	_check("H creates host and player", _session.is_authority()
		and _game.get_node("Players").get_child_count() == 1)
	_game.call("_request_weather", 2)
	_game.get_node("Ocean").elapsed_time = 40.0
	_client_pid = OS.create_process(OS.get_executable_path(), PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"--log-file", ProjectSettings.globalize_path("res://docs/archipelago_network_client.log"),
		"--script", "res://tools/verify_archipelago_network.gd", "--", "--probe-client",
		"--port=%d" % _session.port_from_command_line(), "--name=Guest",
	]))
	_check("client process launches", _client_pid > 0)
	await _wait_report("joined")
	var joined: Dictionary = _reports["joined"]
	_check("J joins and receives both spawned players", joined.players.size() == 2)
	_check("late join receives current weather", joined.weather == 2)
	_check("late join synchronizes ocean clock", absf(joined.clock - _game.get_node("Ocean").elapsed_time) < 0.15)
	_check("all island meshes match across processes", joined.terrain == _snapshot().terrain)
	_check("client player camera follows its owner", joined.camera_owner == _guest)
	var player := _game.get_node("Players/%d" % _guest) as NetworkPlayer
	var start := player.position
	_drive.rpc_id(_guest, true)
	await get_tree().create_timer(1.1).timeout
	_check("client sprint intent reaches server", player.input_node().wants_sprint
		and player.input_node().move_direction == Vector2.RIGHT)
	_check("client input moves server player", player.position.x - start.x > 4.0,
		"%.2f m" % (player.position.x - start.x))
	_drive.rpc_id(_guest, false)
	await get_tree().create_timer(0.8).timeout
	_check("release and client weather change reach host", player.input_node().move_direction == Vector2.ZERO
		and _game.get_node("Weather").current_index() == 1)
	_freeze_bodies(true)
	await get_tree().create_timer(0.4).timeout
	_sample.rpc_id(_guest, "ground")
	await _wait_report("ground")
	_compare(_reports["ground"])
	# A supported rider has world velocity but no motion relative to the deck. Deliver that
	# authoritative state through the real synchronizer and check the remote host's animation.
	var host := _game.get_node("Players/1") as NetworkPlayer
	host.linear_velocity = Vector3(5, 0, 0)
	host.ground_velocity = Vector3.ZERO
	await get_tree().create_timer(0.3).timeout
	_sample.rpc_id(_guest, "rider")
	await _wait_report("rider")
	_check("remote supported rider idles instead of walking with the raft",
		_reports["rider"].players["1"].clip == "Idle")
	# Place the guest in open water on the authority, then verify the stance and swim clip.
	player.freeze = false
	player.set_physics_process(true)
	player.position = Vector3(240, -1, 200)
	await get_tree().create_timer(2.0).timeout
	player.freeze = true
	player.set_physics_process(false)
	var impact := WaterImpact.new()
	impact.position = Vector3(240, 0, 200)
	impact.normal = Vector3.UP
	impact.seed = 918273
	impact.volume = 1.0
	impact.impact_speed = 4.0
	_game.get_node("Ocean").report_impact(impact)
	await get_tree().create_timer(0.5).timeout
	_sample.rpc_id(_guest, "water")
	await _wait_report("water")
	var water: Dictionary = _reports["water"]
	_check("swimming stance and clip reach client", water.players[str(_guest)].stance == NetworkPlayer.Stance.FLOATING
		and water.players[str(_guest)].clip == "Swim_Idle")
	_check("discrete water impact reaches client", water.impact)
	_check("client assertions passed", water.failures == 0)
	_finish()


func _press(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	Input.parse_input_event(event)


@rpc("authority", "call_remote", "reliable")
func _drive(moving: bool) -> void:
	var player := _game.get_node("Players/%d" % multiplayer.get_unique_id()) as NetworkPlayer
	var input := player.input_node()
	input.set_process(false)
	input.move_direction = Vector2.RIGHT if moving else Vector2.ZERO
	input.wants_sprint = moving
	if not moving:
		_press(KEY_2)


@rpc("authority", "call_remote", "reliable")
func _sample(label: String) -> void:
	_submit.rpc_id(1, label, _snapshot())


@rpc("any_peer", "call_remote", "reliable")
func _submit(label: String, report: Dictionary) -> void:
	_guest = multiplayer.get_remote_sender_id()
	_reports[label] = report


func _snapshot() -> Dictionary:
	var players := {}
	for child in _game.get_node("Players").get_children():
		var player := child as NetworkPlayer
		var animation := player.find_child("AnimationPlayer", true, false) as AnimationPlayer
		players[str(player.name)] = {"position": player.position, "rotation": player.rotation,
			"velocity": player.linear_velocity, "ground_velocity": player.ground_velocity,
			"stance": player.stance, "name": player.player_name, "color": player.player_color,
			"frozen": player.freeze, "clip": animation.current_animation}
	var terrain := {}
	for mesh_node in _game.find_children("Mesh", "MeshInstance3D", true, false):
		if mesh_node.get_parent() is Island:
			terrain[str(_game.get_path_to(mesh_node))] = hash(mesh_node.mesh.get_faces())
	var camera := _game.get_node("PlayerCamera") as PlayerCamera
	var owner := camera.target() as NetworkPlayer
	var raft := _game.get_node("Raft") as Raft
	return {"players": players, "terrain": terrain, "weather": _game.get_node("Weather").current_index(),
		"clock": _game.get_node("Ocean").elapsed_time, "camera_owner": owner.owner_peer_id if owner else 0,
		"raft_position": raft.position, "raft_frozen": raft.freeze,
		"impact": _impact_received, "failures": _failures}


func _freeze_bodies(frozen: bool) -> void:
	for player in _game.get_node("Players").get_children():
		player.freeze = frozen
		player.set_physics_process(not frozen)
	_game.get_node("Raft").freeze = frozen
	_game.get_node("Raft").set_physics_process(not frozen)


func _compare(remote: Dictionary) -> void:
	var local := _snapshot()
	for id in local.players:
		var a: Dictionary = local.players[id]
		var b: Dictionary = remote.players[id]
		_check("player %s transform, velocity, stance and identity replicate" % id,
			a.position.distance_to(b.position) < 0.03 and a.rotation.distance_to(b.rotation) < 0.03
			and a.velocity.distance_to(b.velocity) < 0.03
			and a.ground_velocity.distance_to(b.ground_velocity) < 0.03
			and a.stance == b.stance and a.name == b.name and a.color == b.color and b.frozen)
	_check("raft transform replicates with client physics disabled",
		local.raft_position.distance_to(remote.raft_position) < 0.03 and remote.raft_frozen)
	_check("client weather request reaches both peers", local.weather == 1 and remote.weather == 1)


func _wait_report(label: String) -> void:
	while not _reports.has(label):
		await get_tree().process_frame


func _check(label: String, passed: bool, detail: String = "") -> void:
	print("%s %s %s" % ["PASS" if passed else "FAIL", label, detail])
	if not passed:
		_failures += 1


func _finish() -> void:
	if _client_pid > 0 and OS.is_process_running(_client_pid):
		OS.kill(_client_pid)
	print("verify_archipelago_network: %d failures" % _failures)
	_session.leave()
	get_tree().quit(1 if _failures else 0)
