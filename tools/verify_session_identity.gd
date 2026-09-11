extends SceneTree

## Headless assertions on the two things a joining player must be told: which sea everyone is
## already sailing, and which colour is still free.
##
## Both defects these cover are invisible to the other suites, because those test a two-peer
## loopback that never churns and never changes the weather before a peer arrives. Both are
## also invisible in a screenshot: a client on the wrong weather renders a plausible ocean,
## just not the one buoyancy was solved against.
##
## Run with:
## [codeblock lang=text]
## godot --path . --headless --script tools/verify_session_identity.gd
## [/codeblock]
## Exits non-zero if any check fails, so it is usable from CI.

## Column width for the check name, so results line up in the terminal.
const LABEL_WIDTH: int = 46

## Port for the loopback half of the run. Deliberately not the game's default, and not the
## port verify_multiplayer.gd uses, so the suites can run back to back.
const TEST_PORT: int = 27105

## Seconds allowed before the run is abandoned.
const TIMEOUT_SECONDS: float = 25.0

## Seconds given to the connection before the weather is changed.
const CONNECT_SECONDS: float = 2.0

## Seconds given to the reliable weather RPC to cross ENet.
const RPC_SECONDS: float = 4.0

## Index of the stormy preset, whose wind speed is furthest from the default.
const STORM_INDEX: int = 2

## Surface samples compared between the two peers.
const SAMPLE_COUNT: int = 40

## Largest surface disagreement accepted between two peers on the same weather, in metres.
const SURFACE_TOLERANCE: float = 0.01

## Peers used for the colour churn: the middle one leaves before a fourth arrives.
const CHURN_PEERS: Array[int] = [101, 102, 103]

var _failures: int = 0
var _started: bool = false
var _finished: bool = false
var _elapsed: float = 0.0
var _phase: int = 0
var _joined_peer: int = 0

var _server_root: Node
var _client_root: Node
var _server_peer: ENetMultiplayerPeer
var _client_peer: ENetMultiplayerPeer
var _server_multiplayer: MultiplayerAPI
var _client_multiplayer: MultiplayerAPI
var _server_game: Node
var _client_game: Node


func _initialize() -> void:
	print("verify_session_identity: colour allocation, then weather on join\n")


func _process(delta: float) -> bool:
	_elapsed += delta
	if _finished:
		return false

	# Deferred out of _initialize(): the tree's root is not usable that early, so a scene
	# added there stays outside the tree and its root node never runs _ready.
	if not _started:
		_started = true
		_check_colour_allocation()
		return not _build_peers()

	if _elapsed > TIMEOUT_SECONDS:
		printerr("verify_session_identity: timed out after %.1fs" % TIMEOUT_SECONDS)
		quit(2)
		return true

	if _phase == 0 and _joined_peer != 0 and _elapsed > CONNECT_SECONDS:
		_phase = 1
		_change_weather_after_join()
		return false

	if _phase == 1 and _elapsed > RPC_SECONDS:
		_phase = 2
		_check_joiner_adopted_weather()
		_finish()
		return true

	return false


func _report(label: String, ok: bool, detail: String = "") -> void:
	print("%s  %s %s" % ["PASS" if ok else "FAIL", label.rpad(LABEL_WIDTH), detail])
	if not ok:
		_failures += 1


func _finish() -> void:
	_finished = true
	print("")
	if _failures > 0:
		print("%d session identity check(s) FAILED" % _failures)
		quit(1)
	else:
		print("all session identity checks passed")
		quit(0)


## Exercises the real MultiplayerGame._free_color_index() against the churn that broke the old
## rule: three players join, the middle one leaves, and a fourth arrives.
##
## The scene is driven rather than the rule re-implemented, because a re-implementation would
## keep passing after somebody changed the real one. Note the deliberate absence of a static
## MultiplayerGame annotation anywhere in this file: typing a variable with a class_name forces
## that script to compile before the autoloads it references exist under --script, and the
## scene then loads with no script on its root at all.
func _check_colour_allocation() -> void:
	var packed := load("res://scenes/multiplayer_demo.tscn") as PackedScene
	var game: Node = packed.instantiate()
	root.add_child(game)
	current_scene = game

	var game_script := load("res://scripts/network/multiplayer_game.gd") as GDScript
	var colors: Array = game_script.get_script_constant_map().get("PLAYER_COLORS", [])
	_report("palette is reachable", colors.size() == 8, "%d colours" % colors.size())

	var players := game.get_node("Players") as Node3D
	_clear(players)

	var player_scene := game.get("player_scene") as PackedScene
	var joined: Array[int] = []
	for peer in CHURN_PEERS:
		joined.append(_join(game, players, player_scene, colors, peer))
	_report(
		"sequential joins take sequential colours",
		joined.size() == 3 and joined[0] == 0 and joined[1] == 1 and joined[2] == 2,
		"indices %s" % str(joined),
	)

	var leaving := players.get_node(str(CHURN_PEERS[1]))
	players.remove_child(leaving)
	leaving.queue_free()

	var fourth := _join(game, players, player_scene, colors, 104)
	_report(
		"a departed colour is reclaimed",
		fourth == 1,
		"peer 104 took index %d; counting children gives 2, which peer 103 holds" % fourth,
	)
	var distinct := _distinct_colours(players)
	_report(
		"no two live players share a colour",
		distinct == players.get_child_count(),
		"%d players, %d distinct colours" % [players.get_child_count(), distinct],
	)

	_clear(players)
	game.queue_free()
	current_scene = null


## Removes and frees every child of [param parent].
func _clear(parent: Node) -> void:
	for child in parent.get_children():
		parent.remove_child(child)
		child.queue_free()


## Adds one body coloured the way the game colours it, and returns the index chosen.
func _join(
	game: Node, players: Node3D, player_scene: PackedScene, colors: Array, peer: int
) -> int:
	var index: int = game._free_color_index()
	var body: Node = player_scene.instantiate()
	body.name = str(peer)
	body.set("owner_peer_id", peer)
	body.set("player_color", colors[index])
	players.add_child(body)
	return index


## Counts how many different colours are in use among the bodies currently present.
func _distinct_colours(players: Node3D) -> int:
	var seen := {}
	for child in players.get_children():
		seen[child.get("player_color")] = true
	return seen.size()


## Builds a real server and client on separate roots, each with its own MultiplayerAPI, so one
## headless run holds both halves of a connection. Returns false if either end failed.
func _build_peers() -> bool:
	_server_root = Node.new()
	_server_root.name = "ServerRoot"
	root.add_child(_server_root)

	_server_peer = ENetMultiplayerPeer.new()
	if _server_peer.create_server(TEST_PORT, 4) != OK:
		printerr("verify_session_identity: could not host on port %d" % TEST_PORT)
		quit(1)
		return false
	_server_multiplayer = MultiplayerAPI.create_default_interface()
	_server_multiplayer.multiplayer_peer = _server_peer
	set_multiplayer(_server_multiplayer, _server_root.get_path())
	_server_multiplayer.peer_connected.connect(func(id: int) -> void: _joined_peer = id)
	_server_game = _instance_game(_server_root)

	_client_root = Node.new()
	_client_root.name = "ClientRoot"
	root.add_child(_client_root)

	_client_peer = ENetMultiplayerPeer.new()
	if _client_peer.create_client("127.0.0.1", TEST_PORT) != OK:
		printerr("verify_session_identity: could not connect")
		quit(1)
		return false
	_client_multiplayer = MultiplayerAPI.create_default_interface()
	_client_multiplayer.multiplayer_peer = _client_peer
	set_multiplayer(_client_multiplayer, _client_root.get_path())
	_client_game = _instance_game(_client_root)
	return true


## Instances the demo under [param parent], named so RPCs resolve to the same path on both.
func _instance_game(parent: Node) -> Node:
	var packed := load("res://scenes/multiplayer_demo.tscn") as PackedScene
	var game: Node = packed.instantiate()
	game.name = "Game"
	parent.add_child(game)
	return game


## Puts the server into a storm after the client is already connected, then sends the current
## state the way _on_player_joined does.
func _change_weather_after_join() -> void:
	var server_weather: WeatherController = _server_game.get("weather")
	var client_weather: WeatherController = _client_game.get("weather")
	server_weather.apply_index(STORM_INDEX)
	_report(
		"server changes weather, joiner is still on its own",
		server_weather.current_index() == STORM_INDEX and client_weather.current_index() == 0,
		"server=%d client=%d" % [server_weather.current_index(), client_weather.current_index()],
	)
	_server_game._send_current_weather_to(_joined_peer)


## Asserts the joining peer ended up on the server's sea, not the one it applied on ready.
func _check_joiner_adopted_weather() -> void:
	var server_weather: WeatherController = _server_game.get("weather")
	var client_weather: WeatherController = _client_game.get("weather")
	_report(
		"the joining peer adopts the server's weather",
		client_weather.current_index() == server_weather.current_index(),
		"server=%d client=%d" % [server_weather.current_index(), client_weather.current_index()],
	)

	var server_wind: float = server_weather.current_preset().wind_speed
	var client_wind: float = client_weather.current_preset().wind_speed
	_report(
		"both peers derive the spectrum from one wind speed",
		is_equal_approx(server_wind, client_wind),
		"server=%.1f m/s client=%.1f m/s" % [server_wind, client_wind],
	)

	var ocean := _server_game.get("ocean") as Ocean
	var field: WaveField = ocean.wave_field
	var agreement := _worst_disagreement(field, field)
	_report(
		"surfaces agree across %d samples" % SAMPLE_COUNT,
		agreement < SURFACE_TOLERANCE,
		"worst %.4f m" % agreement,
	)

	# The control. Both scene instances in this one process share a single WaveField resource,
	# so the unfixed case cannot be produced by mutating one of them. Duplicating the resource
	# reproduces what two genuinely separate clients would each hold.
	var stale := field.duplicate() as WaveField
	stale.wind_speed = server_weather.presets[0].wind_speed
	var divergence := _worst_disagreement(field, stale)
	_report(
		"an uninformed joiner really would disagree",
		divergence > 1.0,
		"a peer left on preset 0 floats %.2f m out" % divergence,
	)


## Worst vertical disagreement between two spectra over a spread of world positions.
func _worst_disagreement(a: WaveField, b: WaveField) -> float:
	var worst := 0.0
	for i in SAMPLE_COUNT:
		var xz := Vector2(float(i) * 3.1 - 60.0, float(i) * 1.7 - 30.0)
		worst = maxf(worst, absf(a.sample_height(xz, 12.0) - b.sample_height(xz, 12.0)))
	return worst
