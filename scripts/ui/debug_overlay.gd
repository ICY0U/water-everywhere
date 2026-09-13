extends Control

## Local diagnostic UI. Shared-world actions go through the existing weather RPC or are
## restricted to the authority; body changes then use normal player replication.
var game: Node3D
var is_open: bool = false
var _session: Node
var _camera: PlayerCamera
var _metrics: Label
var _panel: PanelContainer
var _tabs: TabContainer
var _readouts: Dictionary = {}
var _buttons: Dictionary = {}
var _player_select: OptionButton
var _weather_select: OptionButton
var _destination: OptionButton
var _balance: CheckButton
var _walking: CheckButton
var _restore_capture: bool = false
var _elapsed: float = 0.0
var _frame_ms: float = 16.7
var _worst_ms: float = 0.0
var _collision_nodes: Array[MeshInstance3D] = []
var _show_collisions: bool = false
var _feedback: Label


func _ready() -> void:
	_session = get_tree().root.get_node("NetworkSession")
	_camera = game.get_node("PlayerCamera")
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = _make_theme()
	_build()
	_refresh()


func _process(delta: float) -> void:
	_frame_ms = lerpf(_frame_ms, delta * 1000.0, 1.0 - exp(-delta * 4.0))
	_worst_ms = maxf(_worst_ms, delta * 1000.0)
	_elapsed += delta
	if _elapsed < 0.25:
		return
	_elapsed = 0.0
	_metrics.text = "%d FPS   |   PING %s" % [Engine.get_frames_per_second(), ping_text()]
	if is_open:
		_refresh()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F1 or (is_open and event.keycode == KEY_ESCAPE):
			set_open(not is_open)
			get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_restore_capture = false


## Opens without pausing. Closing restores capture only if this UI originally released it.
func set_open(opened: bool) -> void:
	if is_open == opened:
		return
	is_open = opened
	_panel.visible = opened
	mouse_filter = Control.MOUSE_FILTER_STOP if opened else Control.MOUSE_FILTER_IGNORE
	if opened:
		_restore_capture = _camera._mouse_captured
		_camera.input_blocked = true
		_camera._set_mouse_captured(false)
		_refresh()
	else:
		_camera.input_blocked = false
		_camera._set_mouse_captured(_restore_capture)
		get_viewport().gui_release_focus()


## RTT from the live transport, not the ocean's smoothed/limited latency estimate.
func ping_text() -> String:
	if not _session.is_active():
		return "--"
	if _session.is_authority():
		return "0 ms (host)"
	var peer := _transport_peer(1)
	return "%.0f ms" % peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME) if peer else "connecting"


func _transport_peer(id: int) -> ENetPacketPeer:
	var transport := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if transport == null or transport.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return null
	if id not in multiplayer.get_peers():
		return null
	return transport.get_peer(id)


func _build() -> void:
	var badge := PanelContainer.new()
	badge.name = "PerformanceBadge"
	add_child(badge)
	badge.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	badge.offset_left = -270
	badge.offset_right = -16
	badge.offset_top = 12
	badge.offset_bottom = 48
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_metrics = Label.new()
	_metrics.name = "Metrics"
	_metrics.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_metrics.text = "-- FPS   |   PING --"
	_metrics.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.add_child(_metrics)
	_panel = PanelContainer.new()
	_panel.name = "DebugPanel"
	add_child(_panel)
	_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_panel.offset_left = -448
	_panel.offset_right = -16
	_panel.offset_top = 60
	_panel.offset_bottom = 570
	_panel.hide()
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	_panel.add_child(margin)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 10)
	margin.add_child(stack)
	var header := HBoxContainer.new()
	stack.add_child(header)
	var title := _label("DEBUG  /  WaterEVERYWHERE")
	title.add_theme_color_override("font_color", Color("7edbd0"))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_button(header, "close", "F1  ×", func() -> void: set_open(false))
	_tabs = TabContainer.new()
	_tabs.name = "Tabs"
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stack.add_child(_tabs)
	var monitor := _tab("Monitor")
	_readout(monitor, "performance")
	_button(monitor, "reset_peak", "Reset peak frame time", func() -> void: _worst_ms = 0.0)
	_button(monitor, "copy", "Copy diagnostic snapshot", _copy_snapshot)
	var player := _tab("Player")
	_player_select = OptionButton.new()
	player.add_child(_player_select)
	_player_select.item_selected.connect(func(_index: int) -> void: _refresh())
	_readout(player, "player")
	_balance = CheckButton.new()
	_balance.text = "Upright balance  ·  host"
	player.add_child(_balance)
	_balance.toggled.connect(func(value: bool) -> void: _set_player_flag("balance_enabled", value))
	_walking = CheckButton.new()
	_walking.text = "Ground movement  ·  host"
	player.add_child(_walking)
	_walking.toggled.connect(func(value: bool) -> void: _set_player_flag("deck_movement_enabled", value))
	_destination = OptionButton.new()
	for place in ["Starter spawn", "Exploration beach", "Mountain lookout", "Open water"]:
		_destination.add_item(place)
	player.add_child(_destination)
	_button(player, "teleport", "Move selected player  ·  host", _teleport)
	_button(player, "reset", "Reset velocity / stand upright  ·  host", _reset_player)
	var world := _tab("World")
	_readout(world, "world")
	_weather_select = OptionButton.new()
	var weather: WeatherController = game.get("weather")
	if weather:
		for preset in weather.presets:
			_weather_select.add_item(preset.display_name)
	world.add_child(_weather_select)
	_weather_select.item_selected.connect(func(index: int) -> void: game.call("_request_weather", index))
	_button(world, "view", "Switch first / third person  ·  local", _camera.toggle_view_mode)
	_slider(world, "Camera FOV", 50, 100, _camera.third_person_fov, func(value: float) -> void:
		_camera.third_person_fov = value
		_camera.first_person_fov = value
		_camera._apply_mode())
	_slider(world, "Mouse sensitivity", 0.05, 0.6, _camera.mouse_sensitivity, func(value: float) -> void:
		_camera.mouse_sensitivity = value)
	var render := OptionButton.new()
	for mode in ["Normal rendering", "Unshaded", "Overdraw"]:
		render.add_item(mode)
	world.add_child(render)
	render.item_selected.connect(func(index: int) -> void:
		get_viewport().debug_draw = [Viewport.DEBUG_DRAW_DISABLED,
			Viewport.DEBUG_DRAW_UNSHADED, Viewport.DEBUG_DRAW_OVERDRAW][index])
	var collision := CheckButton.new()
	collision.text = "Player / raft collision shapes  ·  local"
	world.add_child(collision)
	collision.toggled.connect(_toggle_collisions)
	var network := _tab("Network")
	_readout(network, "network")
	_button(network, "host", "Host session", func() -> void:
		game.call("_report_start", _session.host(_session.port_from_command_line())))
	_button(network, "join", "Join configured server", func() -> void:
		game.call("_report_start", _session.join(game.call("_join_address"), _session.port_from_command_line())))
	_button(network, "second", "Open local client window  ·  host", func() -> void: game.call("_launch_second_window"))
	_button(network, "leave", "Leave session", func() -> void: _session.leave())
	var help := _label("WASD move · Shift sprint · Alt slow\nQ/E dive/rise · V camera · F board raft\nH host · J join / local client · 1/2/3 weather\nEsc mouse / close debug · Ctrl+Q quit")
	network.add_child(help)
	_feedback = _label("Local diagnostics · world keeps running")
	_feedback.add_theme_color_override("font_color", Color("8eabbc"))
	stack.add_child(_feedback)


func _refresh() -> void:
	var old_id := _player_select.get_selected_id()
	var ids: Array[int] = []
	for player in game.get_node("Players").get_children():
		ids.append(player.owner_peer_id)
	var existing: Array[int] = []
	for index in _player_select.item_count:
		existing.append(_player_select.get_item_id(index))
	if existing != ids:
		_player_select.clear()
		for player in game.get_node("Players").get_children():
			_player_select.add_item("%s  /  peer %d" % [player.player_name, player.owner_peer_id], player.owner_peer_id)
		var selected := _player_select.get_item_index(old_id)
		if selected >= 0:
			_player_select.select(selected)
	var body := _selected_player()
	var editable: bool = _session.is_authority() and body != null
	_balance.disabled = not editable
	_walking.disabled = not editable
	_buttons.teleport.disabled = not editable
	_buttons.reset.disabled = not editable
	if body:
		_balance.set_pressed_no_signal(body.balance_enabled)
		_walking.set_pressed_no_signal(body.deck_movement_enabled)
		_readouts.player.text = "State  %s\nPosition  %.1f, %.1f, %.1f\nSpeed  %.2f m/s   Ground  %.2f m/s\nTilt  %.1f°   Angular speed  %.2f\nPhysics  %s" % [
			NetworkPlayer.Stance.keys()[body.stance], body.position.x, body.position.y, body.position.z,
			body.linear_velocity.length(), body.ground_velocity.length(),
			rad_to_deg(body.global_basis.y.angle_to(Vector3.UP)), body.angular_velocity.length(),
			"remote proxy" if not body.is_multiplayer_authority() else "authority"]
	else:
		_readouts.player.text = "No player spawned.\nHost or join a session to inspect players."
	_readouts.performance.text = "FRAME\n%d FPS   /   %.2f ms average\n%.2f ms peak since reset\nCPU process  %.2f ms\nPhysics process  %.2f ms\n\nRENDER\n%d draw calls   /   %s primitives\nVideo memory  %.1f MB\n\nSCENE\n%d nodes   /   %d objects\n%d active physics bodies" % [
		Engine.get_frames_per_second(), _frame_ms, _worst_ms,
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000,
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		str(int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))),
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT), Performance.get_monitor(Performance.OBJECT_COUNT),
		Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)]
	var ocean: Ocean = game.get("ocean")
	var weather: WeatherController = game.get("weather")
	if ocean and weather:
		_weather_select.select(weather.current_index())
		_readouts.world.text = "Weather  %s\nOcean clock  %.2f s\nWind  %.1f m/s   /   active contacts %d\nWeather changes apply to every peer." % [
			weather.current_preset().display_name, ocean.elapsed_time, ocean.wave_field.wind_speed,
			ocean.get_active_contacts().size()]
	_buttons.host.disabled = _session.is_active()
	_buttons.join.disabled = _session.is_active()
	_buttons.second.disabled = not _session.is_authority()
	_buttons.leave.disabled = not _session.is_active()
	var lines := PackedStringArray(["Role  %s   /   peer %d" % [
		["Offline", "Host", "Client"][_session.role], _session.local_peer_id()],
		"Server  %s:%d" % [game.call("_join_address"), _session.port_from_command_line()],
		"Ping  %s   /   players %d of 8" % [ping_text(), _session.players.size()], ""])
	for id in multiplayer.get_peers():
		var peer := _transport_peer(id)
		if peer:
			lines.append("Peer %d  ·  %.0f ms  ·  %.2f%% loss" % [id,
				peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME),
				100.0 * peer.get_statistic(ENetPacketPeer.PEER_PACKET_LOSS) / ENetPacketPeer.PACKET_LOSS_SCALE])
	_readouts.network.text = "\n".join(lines)
	if _show_collisions:
		_refresh_collisions()


func _selected_player() -> NetworkPlayer:
	return game.get_node("Players").get_node_or_null(str(_player_select.get_selected_id())) as NetworkPlayer


func _set_player_flag(property: String, enabled: bool) -> void:
	var player := _selected_player()
	if _session.is_authority() and player:
		player.set(property, enabled)


func _reset_player() -> void:
	var player := _selected_player()
	if not _session.is_authority() or player == null:
		return
	player.rotation = Vector3(0, player.rotation.y, 0)
	player.linear_velocity = Vector3.ZERO
	player.angular_velocity = Vector3.ZERO
	player.sleeping = false
	_feedback.text = "Player reset on authority"


func _teleport() -> void:
	var player := _selected_player()
	if not _session.is_authority() or player == null:
		return
	var destination: Vector3 = game.call("_spawn_position", player.owner_peer_id)
	var island := game.get_node_or_null("ExplorationIsland") as Island
	if _destination.selected in [1, 2]:
		if island == null:
			_feedback.text = "This scene has no exploration island"
			return
		var local := Vector2(-90, 215) if _destination.selected == 1 else Vector2(50, -148)
		destination = island.to_global(Vector3(local.x, 0, local.y))
		destination.y = island.height_at_world(Vector2(destination.x, destination.z)) + 0.4
	elif _destination.selected == 3:
		destination = Vector3(240, 1, 200)
	_reset_player()
	player.position = destination
	_feedback.text = "Moved %s · replicated from host" % player.player_name


func _toggle_collisions(enabled: bool) -> void:
	_show_collisions = enabled
	for mesh in _collision_nodes:
		if is_instance_valid(mesh):
			mesh.queue_free()
	_collision_nodes.clear()
	if enabled:
		_refresh_collisions()


func _refresh_collisions() -> void:
	for body in get_tree().get_nodes_in_group("water_subjects"):
		if not (body is NetworkPlayer or body is Raft):
			continue
		for child in body.get_children():
			if not child is CollisionShape3D or child.shape == null or child.has_node("DebugShape"):
				continue
			var mesh := MeshInstance3D.new()
			mesh.name = "DebugShape"
			mesh.mesh = child.shape.get_debug_mesh()
			var material := StandardMaterial3D.new()
			material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			material.albedo_color = Color("65efc4")
			material.no_depth_test = true
			mesh.material_override = material
			mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			child.add_child(mesh)
			_collision_nodes.append(mesh)


func _copy_snapshot() -> void:
	var text := "WaterEVERYWHERE diagnostic snapshot\n"
	for key in _readouts:
		text += "\n%s\n%s\n" % [key, _readouts[key].text]
	DisplayServer.clipboard_set(text)
	_feedback.text = "Diagnostic snapshot copied"


func _tab(title: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tabs.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 8)
	scroll.add_child(box)
	return box


func _readout(parent: Control, key: String) -> void:
	var label := _label("")
	label.name = key.capitalize()
	parent.add_child(label)
	_readouts[key] = label


func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label


func _button(parent: Control, key: String, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.name = key.capitalize()
	button.text = text
	button.custom_minimum_size.y = 30
	button.pressed.connect(action)
	parent.add_child(button)
	_buttons[key] = button
	return button


func _slider(parent: Control, title: String, minimum: float, maximum: float,
		value: float, action: Callable) -> void:
	var label := _label("%s  %.2f" % [title, value])
	parent.add_child(label)
	var slider := HSlider.new()
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = 0.01
	slider.value = value
	slider.value_changed.connect(func(current: float) -> void:
		label.text = "%s  %.2f" % [title, current]
		action.call(current))
	parent.add_child(slider)


func _make_theme() -> Theme:
	var result := Theme.new()
	result.default_font_size = 14
	for kind in ["Label", "Button", "CheckButton", "OptionButton", "TabContainer"]:
		result.set_color("font_color", kind, Color("dce9f3"))
	var panel := _style(Color(0.035, 0.06, 0.09, 0.96), Color("365367"))
	result.set_stylebox("panel", "PanelContainer", panel)
	result.set_stylebox("panel", "TabContainer", _style(Color("101d29"), Color("263c4c")))
	for kind in ["Button", "OptionButton"]:
		result.set_stylebox("normal", kind, _style(Color("203547"), Color("365367")))
		result.set_stylebox("hover", kind, _style(Color("2b4b60"), Color("7edbd0")))
		result.set_stylebox("pressed", kind, _style(Color("164b50"), Color("7edbd0")))
		result.set_stylebox("disabled", kind, _style(Color("17232f"), Color("263440")))
	result.set_stylebox("tab_selected", "TabContainer", _style(Color("264455"), Color("73c7c5")))
	result.set_stylebox("tab_unselected", "TabContainer", _style(Color("142432"), Color("263c4c")))
	return result


func _style(color: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 7
	style.content_margin_bottom = 7
	return style
