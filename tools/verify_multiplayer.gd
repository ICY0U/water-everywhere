extends SceneTree

## Headless assertions on the multiplayer layer.
##
## Networking fails in ways that a running game hides: a body that replicates its position but
## not its name, a client that can move somebody else's player, a roster that drifts after
## someone leaves. None of that is visible in a screenshot, and all of it is cheap to assert
## against a real loopback connection.
##
## A genuine server and client are started on the loopback interface rather than being mocked,
## because the things worth testing here — authority, spawn state, RPC direction — are
## behaviours of the engine's multiplayer API rather than of this project's code, and a mock
## would only assert that the mock works.
##
## Run with:
## [codeblock lang=text]
## godot --path . --headless --script tools/verify_multiplayer.gd
## [/codeblock]
## Exits non-zero if any check fails, so it is usable from CI.

## Column width for the check name, so results line up in the terminal.
const LABEL_WIDTH: int = 40

## Port used for the loopback test. Deliberately not the game's default, so a running game
## does not collide with a test run.
const TEST_PORT: int = 27099

## Seconds to wait for the connection and the first replication to settle.
const SETTLE_SECONDS: float = 2.5

## Seconds the whole run is allowed before it is abandoned.
const TIMEOUT_SECONDS: float = 25.0

var _server_tree: SceneTree
var _elapsed: float = 0.0
var _failures: int = 0
var _finished: bool = false

var _server_peer: ENetMultiplayerPeer
var _client_peer: ENetMultiplayerPeer
var _server_multiplayer: MultiplayerAPI
var _client_multiplayer: MultiplayerAPI

var _server_root: Node
var _client_root: Node
var _connected: bool = false

## Names of the checks that actually reported, so a crashed one can be told from a silent pass.
var _reported_checks: PackedStringArray = PackedStringArray()


var _started: bool = false


func _initialize() -> void:
	print("verify_multiplayer: starting loopback session on port %d\n" % TEST_PORT)


## Builds the server half: its own MultiplayerAPI on a separate root.
##
## Two MultiplayerAPI instances in one process is what makes a single headless run able to test
## both sides. Each is bound to its own subtree, so RPCs resolve against the right node paths.
func _build_server() -> void:
	_server_root = Node.new()
	_server_root.name = "ServerRoot"
	root.add_child(_server_root)

	_server_peer = ENetMultiplayerPeer.new()
	var error := _server_peer.create_server(TEST_PORT, 4)
	if error != OK:
		printerr("verify_multiplayer: could not host (error %d)" % error)
		quit(1)
		return

	_server_multiplayer = MultiplayerAPI.create_default_interface()
	_server_multiplayer.multiplayer_peer = _server_peer
	set_multiplayer(_server_multiplayer, _server_root.get_path())


## Builds the client half on its own root and MultiplayerAPI.
func _build_client() -> void:
	_client_root = Node.new()
	_client_root.name = "ClientRoot"
	root.add_child(_client_root)

	_client_peer = ENetMultiplayerPeer.new()
	var error := _client_peer.create_client("127.0.0.1", TEST_PORT)
	if error != OK:
		printerr("verify_multiplayer: could not connect (error %d)" % error)
		quit(1)
		return

	_client_multiplayer = MultiplayerAPI.create_default_interface()
	_client_multiplayer.multiplayer_peer = _client_peer
	set_multiplayer(_client_multiplayer, _client_root.get_path())

	_client_multiplayer.connected_to_server.connect(_on_client_connected)


func _process(delta: float) -> bool:
	_elapsed += delta

	if _finished:
		return false

	# Built here rather than in _initialize(): the tree's root is not usable that early, so
	# add_child() leaves nodes outside the tree and set_multiplayer() has no path to bind to.
	if not _started:
		_started = true
		_build_server()
		_build_client()
		return false

	if _elapsed > TIMEOUT_SECONDS:
		printerr("verify_multiplayer: timed out after %.1fs" % TIMEOUT_SECONDS)
		quit(1)
		return true

	if _connected and _elapsed > SETTLE_SECONDS:
		_run_checks()
		return false

	return false


func _on_client_connected() -> void:
	_connected = true
	print("verify_multiplayer: client connected as peer %d\n" % _client_multiplayer.get_unique_id())


func _run_checks() -> void:
	_finished = true

	_check_connection_established()
	_check_server_is_authority()
	_check_client_is_not_authority()
	_check_peer_ids_differ()
	_check_scenes_load()
	_check_player_scene_shape()
	_check_replication_config()
	_check_config_exists_before_tree_entry()
	_check_camera_rig_shape()
	_check_camera_modes()
	_check_name_sanitising()
	_check_command_line_roles()
	await _check_live_controls()
	await _check_live_raft()

	# A check that threw partway through never reached its _report, so it is absent rather than
	# failed. Counting the rows is what stops a crash being read as a pass.
	#
	# The count is compared in BOTH directions, and that matters more than it looks. Adding
	# two checks without updating this number once made the difference negative, which
	# subtracted from the failure tally, cancelled a genuinely failing check and exited 0 —
	# turning a red suite green. That is the one outcome worse than a crash reading as a pass.
	var expected := 23
	if _reported_checks.size() != expected:
		printerr(
			"\n%d of %d checks reported — one did not run to completion."
			% [_reported_checks.size(), expected]
		)
		_failures += absi(expected - _reported_checks.size())

	if _failures == 0:
		print("\nAll multiplayer checks PASSED")
	else:
		printerr("\n%d multiplayer check(s) FAILED" % _failures)

	quit(1 if _failures > 0 else 0)


## Prints one result row and counts it.
##
## A check that never reaches its own [method _report] — because it threw partway through —
## would otherwise vanish from the output and leave the run reporting success. Each check
## registers its name up front in [member _expected_checks] and is struck off here, so a
## missing row is a failure rather than a silence.
func _report(label: String, passed: bool, detail: String) -> void:
	print("%s  %s  %s" % ["PASS" if passed else "FAIL", label.rpad(LABEL_WIDTH), detail])
	_reported_checks.append(label)
	if not passed:
		_failures += 1


## A real ENet connection must have been established over loopback.
func _check_connection_established() -> void:
	_report(
		"loopback connection established",
		_connected and _client_multiplayer.get_unique_id() != 0,
		"client peer id=%d" % _client_multiplayer.get_unique_id(),
	)


## The server must hold authority; this is what lets it own shared physics.
func _check_server_is_authority() -> void:
	_report(
		"server is the authority",
		_server_multiplayer.is_server(),
		"server unique id=%d (must be 1)" % _server_multiplayer.get_unique_id(),
	)


## A client must NOT believe it is the server, or it would simulate shared bodies too.
func _check_client_is_not_authority() -> void:
	_report(
		"client is not the authority",
		not _client_multiplayer.is_server(),
		"client is_server=%s" % _client_multiplayer.is_server(),
	)


## Peers must have distinct ids, since players are keyed by them.
func _check_peer_ids_differ() -> void:
	var server_id := _server_multiplayer.get_unique_id()
	var client_id := _client_multiplayer.get_unique_id()
	_report(
		"peer ids are distinct",
		server_id != client_id and client_id > 1,
		"server=%d client=%d" % [server_id, client_id],
	)


## Both scenes must actually load. A broken NodePath in a .tscn is invisible until it is run.
func _check_scenes_load() -> void:
	var player_scene := load("res://scenes/player.tscn") as PackedScene
	var demo_scene := load("res://scenes/multiplayer_demo.tscn") as PackedScene
	_report(
		"scenes load",
		player_scene != null and demo_scene != null,
		"player=%s demo=%s" % [player_scene != null, demo_scene != null],
	)


## The player scene must have the pieces the networking depends on.
##
## Each of these is load-bearing: without the synchronizer nothing replicates, without the
## input node a client cannot steer, and without the tag nobody can tell the cubes apart.
func _check_player_scene_shape() -> void:
	var scene := load("res://scenes/player.tscn") as PackedScene
	if scene == null:
		_report("player scene has its parts", false, "scene failed to load")
		return

	var instance := scene.instantiate()
	var has_input := instance.get_node_or_null("PlayerInput") != null
	var has_sync := instance.get_node_or_null("Synchronizer") is MultiplayerSynchronizer
	var has_tag := instance.get_node_or_null("NameTag") is Label3D
	var has_collision := instance.get_node_or_null("Collision") is CollisionShape3D
	var is_buoyant := instance is BuoyantBody
	instance.free()

	_report(
		"player scene has its parts",
		has_input and has_sync and has_tag and has_collision and is_buoyant,
		"input=%s sync=%s tag=%s collision=%s buoyant=%s" % [
			has_input, has_sync, has_tag, has_collision, is_buoyant,
		],
	)


## The replication config must cover transform, identity and input.
##
## Asserted against the built config rather than against a scene file, because this is exactly
## the list that silently rots: a renamed property leaves a NodePath pointing at nothing and
## the only symptom is a body that stops moving on the other screen.
func _check_replication_config() -> void:
	var config := PlayerReplication.build_config()
	var properties := config.get_properties()

	var wanted := PackedStringArray([
		".:position", ".:rotation", ".:player_name", ".:owner_peer_id",
	])
	var missing := PackedStringArray()
	for path in wanted:
		if not config.has_property(NodePath(path)):
			missing.append(path)

	# Identity must ride the spawn, or a late joiner sees unnamed grey cubes.
	var name_spawns := config.property_get_spawn(NodePath(".:player_name"))
	var position_streams := (
		config.property_get_replication_mode(NodePath(".:position"))
		== SceneReplicationConfig.REPLICATION_MODE_ALWAYS
	)
	var input_sync := PlayerInputReplication.new()
	var input_config := input_sync.replication_config
	var split_input := (
		input_config.has_property(NodePath(".:move_direction"))
		and not config.has_property(NodePath("PlayerInput:move_direction"))
	)
	input_sync.free()

	_report(
		"replication config is complete",
		missing.is_empty() and name_spawns and position_streams and split_input,
		"%d properties, missing=%s name_on_spawn=%s position_streams=%s" % [
			properties.size(), missing, name_spawns, position_streams,
		],
	)


## The replication config must exist the moment a player is instanced, not merely eventually.
##
## Replication starts as a node enters the tree, which is before any child's _ready() has run.
## A config assigned from a child node was therefore always too late, and the engine reported
## it only as ERR_UNCONFIGURED from on_replication_start — a message that appears in a log and
## nowhere else, while the visible symptom is a player who never moves on the other screen.
## Asserting on a freshly instanced scene is what pins the timing.
func _check_config_exists_before_tree_entry() -> void:
	var scene := load("res://scenes/player.tscn") as PackedScene
	if scene == null:
		_report("replication config is ready on spawn", false, "player scene failed to load")
		return

	var instance := scene.instantiate()
	var synchronizer := instance.get_node_or_null("Synchronizer") as MultiplayerSynchronizer
	var config: SceneReplicationConfig = (
		synchronizer.replication_config if synchronizer != null else null
	)
	var property_count := config.get_properties().size() if config != null else 0
	var in_tree := instance.is_inside_tree()
	instance.free()

	_report(
		"replication config is ready on spawn",
		config != null and property_count > 0,
		"config=%s properties=%d (checked outside the tree: in_tree=%s)" % [
			config != null, property_count, in_tree,
		],
	)


## The camera rig must be nested the way SpringArm3D requires.
##
## SpringArm3D moves its DIRECT CHILDREN to whatever its cast hits. A camera that is merely a
## sibling, or positioned by hand alongside the arm, is never moved and the obstacle avoidance
## silently does nothing — the arm dutifully computes a hit length that nothing reads.
func _check_camera_rig_shape() -> void:
	var scene := load("res://scenes/multiplayer_demo.tscn") as PackedScene
	if scene == null:
		_report("camera rig is nested correctly", false, "demo scene failed to load")
		return

	var instance := scene.instantiate()
	var pivot := instance.get_node_or_null("PlayerCamera")
	var arm := instance.get_node_or_null("PlayerCamera/SpringArm") as SpringArm3D
	var camera := instance.get_node_or_null("PlayerCamera/SpringArm/Camera") as Camera3D
	# Every answer is taken BEFORE the instance is freed. Reading a node afterwards — even just
	# to ask what type it is — is an error on a freed instance rather than a false result.
	var pivot_is_camera := pivot is PlayerCamera
	var camera_is_child_of_arm := camera != null and camera.get_parent() == arm
	var arm_exists := arm != null
	instance.free()

	_report(
		"camera rig is nested correctly",
		pivot_is_camera and arm_exists and camera_is_child_of_arm,
		"pivot=%s arm=%s camera_under_arm=%s" % [
			pivot_is_camera, arm_exists, camera_is_child_of_arm,
		],
	)


## Switching to first person must collapse the arm AND hide the local name tag, and switching back
## must restore both.
##
## The cull-mask half is the part worth asserting: hiding the local tag is a property of
## THIS viewer's camera, so getting it wrong does not throw — it either leaves the player
## staring at a floating label, or hides a tag that should have stayed visible in third person.
func _check_camera_modes() -> void:
	var scene := load("res://scenes/multiplayer_demo.tscn") as PackedScene
	if scene == null:
		_report("view modes switch cleanly", false, "demo scene failed to load")
		return

	var instance := scene.instantiate()
	var pivot := instance.get_node_or_null("PlayerCamera") as PlayerCamera
	var arm := instance.get_node_or_null("PlayerCamera/SpringArm") as SpringArm3D
	var camera := instance.get_node_or_null("PlayerCamera/SpringArm/Camera") as Camera3D
	if pivot == null or arm == null or camera == null:
		instance.free()
		_report("view modes switch cleanly", false, "camera rig missing")
		return

	# _ready() has not run outside the tree, so the @onready references are resolved by hand.
	pivot._arm = arm
	pivot._camera = camera

	pivot.set_view_mode(PlayerCamera.ViewMode.FIRST_PERSON)
	var fp_arm := arm.spring_length
	var fp_hides_tag := not camera.get_cull_mask_value(PlayerCamera.LOCAL_BODY_LAYER)
	var fp_fov := camera.fov

	pivot.set_view_mode(PlayerCamera.ViewMode.THIRD_PERSON)
	var tp_arm := arm.spring_length
	var tp_shows_tag := camera.get_cull_mask_value(PlayerCamera.LOCAL_BODY_LAYER)
	var tp_fov := camera.fov
	instance.free()

	_report(
		"view modes switch cleanly",
		(
			is_zero_approx(fp_arm) and fp_hides_tag
			and tp_arm > 0.0 and tp_shows_tag
			and not is_equal_approx(fp_fov, tp_fov)
		),
		"first: arm=%.1f hides_tag=%s fov=%.0f | third: arm=%.1f shows_tag=%s fov=%.0f" % [
			fp_arm, fp_hides_tag, fp_fov, tp_arm, tp_shows_tag, tp_fov,
		],
	)


## Names arrive from the network, so they must be cleaned before anything renders them.
##
## The session script is loaded and instanced directly rather than reached through its autoload.
## Not because the autoload is absent: it [i]is[/i] created under [code]--script[/code] in 4.7.2,
## and can be pulled off [code]root[/code] and made to host a real server — measured, after an
## earlier comment here asserted the opposite. The reason to instance it is that testing the file
## is the honest check, and that a singleton cannot hand two peers in one process the two
## separate instances they need.
func _check_name_sanitising() -> void:
	var session := _make_session()
	var cleaned: String = session._sanitise_name("  Bob\nDrop  ", 7)
	var empty: String = session._sanitise_name("   ", 9)
	var long_name: String = session._sanitise_name("x".repeat(200), 3)
	session.free()

	_report(
		"player names are sanitised",
		not cleaned.contains("\n") and empty == "Player 9" and long_name.length() <= 20,
		"cleaned='%s' empty='%s' long=%d chars" % [cleaned, empty, long_name.length()],
	)


## The launch-argument parsing must not claim a role when none was asked for.
##
## This runs with no role arguments, so it must report NONE — the case that matters, because a
## false positive would have a normal launch silently trying to host.
func _check_command_line_roles() -> void:
	var script: GDScript = load("res://scripts/network/network_session.gd")
	var role: int = script.role_from_command_line()
	var chosen_name: String = script.name_from_command_line()

	_report(
		"no role claimed without arguments",
		role == 0 and chosen_name.is_empty(),
		"role=%d (NONE=0) name='%s'" % [role, chosen_name],
	)


## Returns a bare NetworkSession instance, outside the tree.
func _make_session() -> Node:
	var script: GDScript = load("res://scripts/network/network_session.gd")
	var session := Node.new()
	session.set_script(script)
	return session


## Exercises spawned production players across ENet, not just config inspection.
func _check_live_controls() -> void:
	var watchdog := create_timer(15.0)
	watchdog.timeout.connect(func() -> void:
		printerr("Live controls timed out")
		quit(1))
	var packed := load("res://scenes/player.tscn") as PackedScene
	var owner_id := _client_multiplayer.get_unique_id()
	for branch in [_server_root, _client_root]:
		var ocean := Ocean.new()
		ocean.name = "TestOcean"
		branch.add_child(ocean)
		var players := Node3D.new()
		players.name = "Players"
		branch.add_child(players)
		var spawner := MultiplayerSpawner.new()
		spawner.name = "Spawner"
		spawner.spawn_path = NodePath("../Players")
		# Both branches share ONE physics world in this test, so the authority body and its
		# remote proxy spawn at the same point and overlap. A frozen RigidBody3D still collides:
		# freeze_mode defaults to FREEZE_MODE_STATIC and is never set anywhere in this project,
		# so the proxy is a solid immovable collider sitting inside the body it mirrors. Jolt
		# resolves that overlap by pushing the authority body out — measured at +3.67 m/s along
		# +X while its own linear_velocity read +0.01, which is the tell: position advancing
		# without velocity is depenetration, not thrust. That is what made "remote input drives
		# real physics" report positive displacement against correctly received -X intent.
		# The raft check below already avoids this the same way.
		var is_proxy_branch: bool = branch == _client_root
		spawner.spawn_function = func(data: Variant) -> Node:
			var body := packed.instantiate() as NetworkPlayer
			body.name = str(data)
			body.owner_peer_id = int(data)
			body.ocean = ocean
			if is_proxy_branch:
				body.collision_layer = 0
				body.collision_mask = 0
			return body
		branch.add_child(spawner)
	(_server_root.get_node("Spawner") as MultiplayerSpawner).spawn(owner_id)
	await create_timer(0.5).timeout
	var path := "Players/%d" % owner_id
	var server_body := _server_root.get_node(path) as NetworkPlayer
	var client_body := _client_root.get_node(path) as NetworkPlayer
	var server_input := server_body.input_node()
	var client_input := client_body.input_node()
	client_input.set_process(false)
	var camera := PlayerCamera.new()
	client_input.movement_camera = camera
	client_input.controls_enabled = true
	_report("spawned input has client authority",
		client_input.is_multiplayer_authority()
		and client_input.get_node("Synchronizer").is_multiplayer_authority()
		and server_body.is_multiplayer_authority() and client_body.freeze,
		"client owns intent; server owns physics")

	var axes_ok := true
	for yaw in [0.0, PI / 2.0, PI, -PI / 2.0]:
		camera._yaw = yaw
		for mode in [PlayerCamera.ViewMode.THIRD_PERSON, PlayerCamera.ViewMode.FIRST_PERSON]:
			camera.set_view_mode(mode)
			camera._pitch = -1.2
			var directions := {
				&"move_forward": Vector3.FORWARD, &"move_back": Vector3.BACK,
				&"move_left": Vector3.LEFT, &"move_right": Vector3.RIGHT,
			}
			for action: StringName in directions:
				Input.action_press(action)
				client_input._process(0.0)
				axes_ok = axes_ok and client_input.world_direction().is_equal_approx(
					Basis(Vector3.UP, yaw) * directions[action])
				Input.action_release(action)
	_report("WASD follows camera in both views", axes_ok, "four headings, steep pitch")

	camera._yaw = 0.0
	Input.action_press(&"move_forward")
	Input.action_press(&"move_right")
	client_input._process(0.0)
	var diagonal_ok := is_equal_approx(client_input.move_direction.length(), 1.0)
	Input.action_press(&"move_slow")
	Input.action_press(&"move_sprint")
	client_input._process(0.0)
	var slow_ok := is_equal_approx(client_input.move_direction.length(), 0.35)
	slow_ok = slow_ok and not client_input.wants_sprint
	for action in [&"move_forward", &"move_right", &"move_slow", &"move_sprint"]:
		Input.action_release(action)
	_report("diagonal and slow intent bounded", diagonal_ok and slow_ok,
		"unit diagonal; Alt overrides sprint")

	camera._yaw = PI / 2.0
	Input.action_press(&"move_forward")
	Input.action_press(&"move_sprint")
	Input.action_press(&"move_down")
	client_input._process(0.0)
	await create_timer(0.3).timeout
	_report("client intent reaches server", server_input.move_direction.is_equal_approx(Vector2.LEFT)
		and server_input.wants_sprint and server_input.wants_down,
		"camera-relative direction, sprint and dive crossed ENet")
	var start := server_body.position
	await create_timer(0.7).timeout
	_report("remote input drives real physics", server_body.position.x < start.x - 0.1,
		"host displacement x=%.3f" % (server_body.position.x - start.x))

	# Boarding crosses as a running count rather than a held flag, and only a real connection
	# can show that works. It is a momentary action: a bool true for one frame can fall between
	# two synchroniser samples and never be transmitted, so a press would be silently dropped.
	# The count is raised directly rather than through Input.action_press, because the action
	# path is already covered by verify_raft and because pressing actions here is process-global
	# and leaks into later checks.
	var board_before: int = server_input.board_requests
	client_input.board_requests += 2
	await create_timer(0.3).timeout
	_report("board requests cross as a count, not a pulse",
		server_input.board_requests == client_input.board_requests
		and server_input.board_requests == board_before + 2,
		"client=%d server=%d (was %d)" % [
			client_input.board_requests, server_input.board_requests, board_before,
		])

	# Shoving crosses the same way, and is checked here for a reason worth recording: when the
	# push action was written, push_requests was left out of PlayerInputReplication entirely. The
	# host could shove, a client pressing the key did nothing at all, and there was no error —
	# the push suite was green throughout, because every check in it calls Raft.request_push()
	# directly and none of them travels the path a player's press actually takes. A config
	# assertion catches the property going missing; only a live session catches it never arriving.
	var push_before: int = server_input.push_requests
	client_input.push_requests += 2
	await create_timer(0.3).timeout
	_report("push requests cross as a count, not a pulse",
		server_input.push_requests == client_input.push_requests
		and server_input.push_requests == push_before + 2,
		"client=%d server=%d (was %d)" % [
			client_input.push_requests, server_input.push_requests, push_before,
		])

	# Capture release clears held actions immediately, then the reliable update reaches host.
	camera._target = client_body
	camera._set_mouse_captured(false)
	await create_timer(0.3).timeout
	var released := server_input.move_direction == Vector2.ZERO
	released = released and not server_input.wants_sprint and not server_input.wants_down
	camera._set_mouse_captured(true)
	client_input._process(0.0)
	camera._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	await create_timer(0.3).timeout
	_report("capture and focus release intent", released
		and server_input.move_direction == Vector2.ZERO and not client_input.controls_enabled,
		"held keys clear locally and on host")

	# The release above ran clear_intent(), which deliberately leaves the count alone. Were it
	# ever zeroed, the server would read the value going backwards and ignore every later
	# request until the client climbed back to the count it had already served — presenting as
	# boarding that works, then silently stops, after one release of the mouse.
	_report("clearing intent never rewinds the board count",
		client_input.board_requests >= board_before + 2
		and server_input.board_requests >= board_before + 2,
		"client=%d server=%d after clear_intent()" % [
			client_input.board_requests, server_input.board_requests,
		])
	for action in [&"move_forward", &"move_sprint", &"move_down"]:
		Input.action_release(action)
	camera.free()


## A level-placed raft must stream to a remote frozen proxy without a player spawner.
func _check_live_raft() -> void:
	var packed := load("res://scenes/raft.tscn") as PackedScene
	var rafts: Array[Raft] = []
	for branch in [_server_root, _client_root]:
		var ocean := Ocean.new()
		ocean.name = "RaftOcean"
		ocean.wave_field = WaveField.new()
		ocean.wave_field.wind_speed = 0.0
		branch.add_child(ocean)
		var raft := packed.instantiate() as Raft
		raft.name = "Raft"
		raft.ocean = ocean
		# Both branches share one physics world in this test; avoid proxy/authority collision.
		raft.collision_layer = 0
		raft.collision_mask = 0
		raft.position = Vector3(100, 0, 0)
		branch.add_child(raft)
		rafts.append(raft)
	await create_timer(0.3).timeout
	_report("raft physics is server owned", not rafts[0].freeze and rafts[1].freeze,
		"remote raft does not integrate gravity or buoyancy")
	rafts[0].apply_central_impulse(Vector3(rafts[0].mass * 2.0, 0, 0))
	await create_timer(0.5).timeout
	var error := rafts[0].position.distance_to(rafts[1].position)
	_report("raft movement crosses ENet", rafts[0].position.x > 100.1 and error < 0.2,
		"server x=%.3f, remote transform error=%.3fm" % [rafts[0].position.x, error])
