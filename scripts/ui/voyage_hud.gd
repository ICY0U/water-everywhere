class_name VoyageHud
extends Control

## Everything on screen during play: what to do next, which way to go, and what the raft is doing.
##
## The plan's HUD priorities, in its order: where home is, crew activity, raft danger, rescue
## target and current interaction. So the compass across the top always carries the lighthouse
## and its distance, the objective card says what the crew is for and what to do next, the
## prompt at the bottom names the one key that does something right now, and while aboard a
## top-down raft shows where to stand to steer — the single thing a new paddler cannot guess.
##
## [b]Read-only.[/b] It reads the run phase, bodies, raft and weather that every peer already
## has, and decides nothing: a prompt saying "climb aboard" is a hint, and the server still
## decides whether the climb happens. Everything here is derived from replicated state, so a
## client's HUD says the same things as the host's.

## Heading error, in degrees, inside which the raft counts as on course. Matches the band the
## crossing suite's bot steers within, so the advice here is advice that has been proved to work.
const ON_COURSE_DEGREES: float = 4.0

## Distance from the mainland's centre inside which a slowed raft is taken to have landed.
const LANDING_RADIUS: float = 112.0

## Raft speed below which, away from its mooring, it is treated as stopped or aground.
const STOPPED_SPEED: float = 0.3

## Seconds between refreshes of the text. The compass redraws every frame.
const TEXT_INTERVAL: float = 0.1

## The game this HUD reports on. Set before the HUD enters the tree.
var game: VoyageGame

## The local camera, whose yaw the compass is drawn from.
var camera: PlayerCamera

## Returns a display name for the control bound to an action. Set by [GameUI], so prompts name
## a gamepad button when a gamepad is in use.
var key_name: Callable = func(action: StringName) -> String: return String(action)

var _objective: Label
var _step: Label
var _clock: Label
var _conditions: Label
var _compass: CompassBar
var _prompt_row: HBoxContainer
var _raft_panel: PanelContainer
var _diagram: RaftDiagram
var _raft_speed: Label
var _raft_advice: Label
var _crew_panel: PanelContainer
var _crew_list: VBoxContainer
var _toasts: VBoxContainer
var _text_elapsed: float = 0.0
var _last_prompt: String = ""


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = UiStyle.theme()
	_build_objective()
	_build_compass()
	_build_prompt()
	_build_raft_panel()
	_build_crew_panel()
	_build_toasts()


func _process(delta: float) -> void:
	if game == null or not visible:
		return
	_compass.queue_redraw()
	_diagram.queue_redraw()
	_text_elapsed += delta
	if _text_elapsed < TEXT_INTERVAL:
		return
	_text_elapsed = 0.0
	_refresh()


## Shows a short message under the compass, fading after [param seconds].
func toast(text: String, color: Color = UiStyle.TEXT, seconds: float = 3.2) -> void:
	if _toasts == null:
		return
	var line := UiStyle.heading(text, 26, color)
	line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	line.modulate.a = 0.0
	_toasts.add_child(line)
	while _toasts.get_child_count() > 3:
		_toasts.get_child(0).free()
	var tween := line.create_tween()
	tween.tween_property(line, "modulate:a", 1.0, 0.25)
	tween.tween_interval(seconds)
	tween.tween_property(line, "modulate:a", 0.0, 0.6)
	tween.tween_callback(line.queue_free)


## Returns the local player's body, or null before it exists.
func local_body() -> NetworkPlayer:
	return camera.target() as NetworkPlayer if camera != null else null


# ---------------------------------------------------------------------------------------------
# Building
# ---------------------------------------------------------------------------------------------


func _build_objective() -> void:
	var made := UiStyle.card(4)
	var panel: PanelContainer = made[0]
	var stack: VBoxContainer = made[1]
	panel.name = "Objective"
	panel.position = Vector2(20, 18)
	panel.custom_minimum_size = Vector2(430, 0)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := panel.get_theme_stylebox(&"panel").duplicate() as StyleBoxFlat
	box.set_content_margin_all(16)
	box.content_margin_left = 20
	panel.add_theme_stylebox_override(&"panel", box)
	add_child(panel)

	stack.add_child(UiStyle.label("OBJECTIVE", 14, UiStyle.ACCENT, 800))
	_objective = UiStyle.heading("", 25)
	_objective.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_objective.custom_minimum_size = Vector2(390, 0)
	stack.add_child(_objective)
	_step = UiStyle.label("", 18, UiStyle.SEA, 700)
	_step.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_step.custom_minimum_size = Vector2(390, 0)
	stack.add_child(_step)
	var footer := HBoxContainer.new()
	footer.add_theme_constant_override(&"separation", 18)
	_clock = UiStyle.label("", 16, UiStyle.MUTED, 700)
	_conditions = UiStyle.label("", 16, UiStyle.MUTED, 700)
	footer.add_child(_clock)
	footer.add_child(_conditions)
	stack.add_child(footer)


func _build_compass() -> void:
	_compass = CompassBar.new()
	_compass.name = "Compass"
	_compass.hud = self
	_compass.custom_minimum_size = Vector2(640, 90)
	_compass.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_compass.offset_left = -320
	_compass.offset_right = 320
	_compass.offset_top = 16
	_compass.offset_bottom = 106
	_compass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_compass)


func _build_prompt() -> void:
	_prompt_row = HBoxContainer.new()
	_prompt_row.name = "Prompts"
	_prompt_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_prompt_row.add_theme_constant_override(&"separation", 26)
	_prompt_row.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_prompt_row.offset_left = -400
	_prompt_row.offset_right = 400
	_prompt_row.offset_top = -120
	_prompt_row.offset_bottom = -70
	_prompt_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_prompt_row)


func _build_raft_panel() -> void:
	var made := UiStyle.card(6)
	_raft_panel = made[0]
	var stack: VBoxContainer = made[1]
	_raft_panel.name = "RaftPanel"
	_raft_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_raft_panel.offset_left = -300
	_raft_panel.offset_right = -20
	_raft_panel.offset_top = -392
	_raft_panel.offset_bottom = -20
	_raft_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_raft_panel)
	var header := HBoxContainer.new()
	header.add_child(UiStyle.label("THE RAFT", 14, UiStyle.ACCENT, 800))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	_raft_speed = UiStyle.label("", 16, UiStyle.MUTED, 700)
	header.add_child(_raft_speed)
	stack.add_child(header)
	_diagram = RaftDiagram.new()
	_diagram.hud = self
	_diagram.custom_minimum_size = Vector2(240, 220)
	_diagram.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(_diagram)
	_raft_advice = UiStyle.label("", 17, UiStyle.TEXT, 700)
	_raft_advice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_raft_advice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_raft_advice.custom_minimum_size = Vector2(240, 0)
	stack.add_child(_raft_advice)


func _build_crew_panel() -> void:
	var made := UiStyle.card(4)
	_crew_panel = made[0]
	var stack: VBoxContainer = made[1]
	_crew_panel.name = "Crew"
	_crew_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_crew_panel.offset_left = -270
	_crew_panel.offset_right = -20
	_crew_panel.offset_top = 64
	_crew_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := _crew_panel.get_theme_stylebox(&"panel").duplicate() as StyleBoxFlat
	box.set_content_margin_all(14)
	_crew_panel.add_theme_stylebox_override(&"panel", box)
	add_child(_crew_panel)
	stack.add_child(UiStyle.label("CREW", 14, UiStyle.ACCENT, 800))
	_crew_list = VBoxContainer.new()
	_crew_list.add_theme_constant_override(&"separation", 2)
	stack.add_child(_crew_list)


func _build_toasts() -> void:
	_toasts = VBoxContainer.new()
	_toasts.name = "Toasts"
	_toasts.alignment = BoxContainer.ALIGNMENT_BEGIN
	_toasts.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_toasts.offset_left = -400
	_toasts.offset_right = 400
	_toasts.offset_top = 120
	_toasts.offset_bottom = 280
	_toasts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_toasts)


# ---------------------------------------------------------------------------------------------
# Refreshing
# ---------------------------------------------------------------------------------------------


func _refresh() -> void:
	var director := game.director()
	var body := local_body()
	var raft := game.raft
	_objective.text = director.objective()
	_clock.text = "TIME  %s" % UiStyle.clock(director.voyage_seconds)
	# Named as the title's sea picker names it, so "Calm" on the menu is "CALM SEA" here.
	var sea := game.weather.current_index() if game.weather != null else -1
	_conditions.text = (
		"%s SEA" % String(TitleScreen.SEA_STATES[sea]["name"]).to_upper()
		if sea >= 0 and sea < TitleScreen.SEA_STATES.size() else ""
	)

	var aboard := raft != null and body != null and raft.carries(body)
	_step.text = _step_hint(body, aboard)
	_refresh_prompts(body, aboard)
	_raft_panel.visible = aboard
	if aboard:
		_refresh_raft(body)
	_refresh_crew()


## What to do next, in plain words: the objective's next step for this player right now.
func _step_hint(body: NetworkPlayer, aboard: bool) -> String:
	var director := game.director()
	var raft := game.raft
	if director.phase == RunDirector.Phase.ARRIVAL:
		return "Explore the mainland, or open the menu to sail again."
	if director.phase != RunDirector.Phase.VOYAGE or body == null or raft == null:
		return ""
	if aboard:
		if raft.moored:
			return "Hold %s to paddle. The first stroke casts off." % key_name.call(&"paddle")
		if _raft_landed():
			return "Land ho! Walk off the raft and up the beach to the lighthouse."
		return "Keep the lighthouse ahead. Where you stand on the deck steers the raft."
	if _near_mainland(body):
		return "Head up the beach to the lighthouse."
	if body.stance == NetworkPlayer.Stance.FLOATING:
		return "Swim back to the raft and climb aboard."
	if raft.moored:
		return "Walk down the jetty to the raft."
	if _raft_stuck():
		return "The raft is aground. Stand beside it on the shore and shove it off."
	return "Get back to the raft."


func _refresh_prompts(body: NetworkPlayer, aboard: bool) -> void:
	var prompts: Array = []
	var raft := game.raft
	if body != null and raft != null and game.director().phase == RunDirector.Phase.VOYAGE:
		var reach := _flat_distance(raft.global_position, body.global_position)
		if aboard:
			prompts.append([&"paddle", "Paddle" + (" to cast off" if raft.moored else " (hold)")])
		elif reach <= NetworkPlayer.BOARD_RANGE:
			prompts.append([&"board", "Climb aboard"])
		if (
			not aboard and body.stance == NetworkPlayer.Stance.GROUNDED
			and reach <= Raft.PUSH_RANGE and not raft.moored and _raft_stuck()
		):
			prompts.append([&"push", "Push off"])
	var signature := str(prompts) + str(key_name.call(&"paddle"))
	if signature == _last_prompt:
		return
	_last_prompt = signature
	for child in _prompt_row.get_children():
		child.queue_free()
	for prompt: Array in prompts:
		var group := HBoxContainer.new()
		group.add_theme_constant_override(&"separation", 10)
		group.add_child(UiStyle.key_cap(key_name.call(prompt[0]), 22))
		group.add_child(UiStyle.heading(prompt[1], 26))
		_prompt_row.add_child(group)


func _refresh_raft(body: NetworkPlayer) -> void:
	var raft := game.raft
	var speed := Vector2(raft.linear_velocity.x, raft.linear_velocity.z).length()
	_raft_speed.text = "%.1f m/s" % speed
	if raft.moored:
		_raft_advice.text = "Tied to the jetty. Paddle to cast off."
		_raft_advice.add_theme_color_override(&"font_color", UiStyle.TEXT)
		return
	if _raft_landed():
		_raft_advice.text = "Aground on the mainland. Step off and wade ashore."
		_raft_advice.add_theme_color_override(&"font_color", UiStyle.SEA)
		return
	var error := heading_error()
	var lateral := raft.to_local(body.global_position).x
	if absf(error) <= ON_COURSE_DEGREES:
		_raft_advice.text = "On course. Paddle from the middle."
		_raft_advice.add_theme_color_override(&"font_color", UiStyle.SEA)
	elif error > 0.0:
		_raft_advice.text = (
			"Turning left. Keep paddling." if raft.lever_at(lateral) > 0.0
			else "Lighthouse to the left. Paddle from the RIGHT side."
		)
		_raft_advice.add_theme_color_override(&"font_color", UiStyle.ACCENT)
	else:
		_raft_advice.text = (
			"Turning right. Keep paddling." if raft.lever_at(lateral) < 0.0
			else "Lighthouse to the right. Paddle from the LEFT side."
		)
		_raft_advice.add_theme_color_override(&"font_color", UiStyle.ACCENT)


func _refresh_crew() -> void:
	var players := game.get_node_or_null("Players")
	var bodies: Array = players.get_children() if players != null else []
	_crew_panel.visible = bodies.size() > 1
	if not _crew_panel.visible:
		return
	while _crew_list.get_child_count() < bodies.size():
		var row := HBoxContainer.new()
		row.add_theme_constant_override(&"separation", 8)
		var swatch := ColorRect.new()
		swatch.custom_minimum_size = Vector2(12, 12)
		swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(swatch)
		row.add_child(UiStyle.label("", 17, UiStyle.TEXT, 700))
		var state := UiStyle.label("", 14, UiStyle.MUTED, 700)
		state.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		state.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(state)
		_crew_list.add_child(row)
	while _crew_list.get_child_count() > bodies.size():
		_crew_list.get_child(_crew_list.get_child_count() - 1).free()
	var mine := local_body()
	for index in bodies.size():
		var player := bodies[index] as NetworkPlayer
		var row := _crew_list.get_child(index) as HBoxContainer
		if player == null:
			continue
		(row.get_child(0) as ColorRect).color = player.player_color
		(row.get_child(1) as Label).text = player.player_name + ("  (you)" if player == mine else "")
		(row.get_child(2) as Label).text = _crew_state(player)


func _crew_state(player: NetworkPlayer) -> String:
	if game.raft != null and game.raft.carries(player):
		return "ABOARD"
	match player.stance:
		NetworkPlayer.Stance.FLOATING:
			return "SWIMMING"
		NetworkPlayer.Stance.AIRBORNE:
			return "FALLING"
	return "ASHORE"


# ---------------------------------------------------------------------------------------------
# Derived state
# ---------------------------------------------------------------------------------------------


## Signed degrees from the raft's bow to the destination; positive means it lies to the left.
func heading_error() -> float:
	var raft := game.raft
	if raft == null:
		return 0.0
	var forward := -raft.global_basis.z
	var toward := game.destination() - raft.global_position
	forward.y = 0.0
	toward.y = 0.0
	if forward.length_squared() < 0.0001 or toward.length_squared() < 0.0001:
		return 0.0
	return rad_to_deg(forward.signed_angle_to(toward, Vector3.UP))


func _raft_landed() -> bool:
	var raft := game.raft
	if raft == null or game.mainland == null:
		return false
	var speed := Vector2(raft.linear_velocity.x, raft.linear_velocity.z).length()
	return (
		_flat_distance(raft.global_position, game.mainland.global_position) < LANDING_RADIUS
		and speed < STOPPED_SPEED
	)


## True when the raft is stopped in water too shallow to float free, away from its mooring.
func _raft_stuck() -> bool:
	var raft := game.raft
	if raft == null or raft.moored:
		return false
	var speed := Vector2(raft.linear_velocity.x, raft.linear_velocity.z).length()
	if speed > STOPPED_SPEED:
		return false
	for island: Node in get_tree().get_nodes_in_group(&"playable_islands"):
		var ground := island as Island
		if ground == null:
			continue
		var floor_height := ground.height_at_world(
			Vector2(raft.global_position.x, raft.global_position.z)
		)
		if floor_height > -2.6:
			return true
	return false


func _near_mainland(body: Node3D) -> bool:
	var mainland := game.mainland
	return mainland != null and _flat_distance(body.global_position, mainland.global_position) < (
		mainland.beach_radius
	)


static func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


# ---------------------------------------------------------------------------------------------
# Drawn widgets
# ---------------------------------------------------------------------------------------------


## A strip compass: the bearings ahead of the camera, with the lighthouse, the raft and the crew
## marked where they lie.
class CompassBar:
	extends Control

	## Half the arc the strip shows, in degrees either side of straight ahead.
	const HALF_ARC: float = 80.0

	## Height of the bearing strip; markers and distances hang beneath it.
	const STRIP_HEIGHT: float = 34.0

	const LETTERS: Dictionary = {
		0: "N", 45: "NE", 90: "E", 135: "SE", 180: "S", 225: "SW", 270: "W", 315: "NW",
	}

	var hud: VoyageHud

	func _draw() -> void:
		if hud == null or hud.camera == null:
			return
		var box := StyleBoxFlat.new()
		box.bg_color = Color(UiStyle.PANEL, 0.72)
		box.set_corner_radius_all(14)
		box.border_color = UiStyle.EDGE
		box.set_border_width_all(1)
		draw_style_box(box, Rect2(Vector2.ZERO, Vector2(size.x, STRIP_HEIGHT)))
		var font := UiStyle.display_font(600)
		var small := UiStyle.body_font(800)
		# The camera looks along -Z rotated by its yaw, so its bearing clockwise from north
		# (-Z) is the negated yaw.
		var facing := -hud.camera.yaw()
		for degrees in range(0, 360, 15):
			var x := _x_for(deg_to_rad(float(degrees)), facing)
			if x < 0.0:
				continue
			if LETTERS.has(degrees):
				var letter: String = LETTERS[degrees]
				var major := degrees % 90 == 0
				var font_size := 22 if major else 16
				var width := font.get_string_size(letter, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
				draw_string(font, Vector2(x - width * 0.5, 25), letter, HORIZONTAL_ALIGNMENT_LEFT,
					-1, font_size, UiStyle.TEXT if major else UiStyle.MUTED)
			else:
				draw_line(Vector2(x, 11), Vector2(x, 23), Color(UiStyle.MUTED, 0.6), 2.0)
		# Straight ahead.
		draw_colored_polygon(PackedVector2Array([
			Vector2(size.x * 0.5 - 7, 0), Vector2(size.x * 0.5 + 7, 0), Vector2(size.x * 0.5, 8),
		]), UiStyle.ACCENT)

		var body := hud.local_body()
		var origin := body.global_position if body != null else hud.camera.global_position
		var game := hud.game
		# Markers hang below the strip so they never hide a bearing letter. The crew first, so the
		# landmarks draw over them; each landmark's distance gets its own row, so a raft lying
		# straight toward the lighthouse cannot print its distance over the lighthouse's.
		var players := game.get_node_or_null("Players")
		if players != null:
			for child in players.get_children():
				var mate := child as NetworkPlayer
				if mate == null or mate == body:
					continue
				_marker(origin, mate.global_position, facing, mate.player_color, "dot", "", 0, small)
		if game.raft != null and (body == null or not game.raft.carries(body)):
			_marker(origin, game.raft.global_position, facing, Color(0.69, 0.47, 0.29), "square",
				"Raft", 1, small)
		_marker(origin, game.destination(), facing, UiStyle.DANGER, "diamond", "Lighthouse", 0,
			small)

	func _x_for(bearing: float, facing: float) -> float:
		var relative := rad_to_deg(wrapf(bearing - facing, -PI, PI))
		if absf(relative) > HALF_ARC:
			return -1.0
		return size.x * 0.5 + relative / HALF_ARC * (size.x * 0.5 - 18.0)

	func _marker(
		origin: Vector3, point: Vector3, facing: float, color: Color, shape: String,
		caption: String, row: int, font: Font,
	) -> void:
		var offset := point - origin
		var distance := Vector2(offset.x, offset.z).length()
		var bearing := atan2(offset.x, -offset.z)
		var x := _x_for(bearing, facing)
		if x < 0.0:
			# Off the strip: pinned to the edge it would come in from, so it is never lost.
			var relative := wrapf(bearing - facing, -PI, PI)
			x = 10.0 if relative < 0.0 else size.x - 10.0
		var centre := Vector2(x, STRIP_HEIGHT)
		match shape:
			"diamond":
				var r := 10.0
				var points := PackedVector2Array([
					centre + Vector2(0, -r), centre + Vector2(r, 0), centre + Vector2(0, r),
					centre + Vector2(-r, 0),
				])
				draw_colored_polygon(points, color)
				points.append(points[0])
				draw_polyline(points, UiStyle.TEXT, 2.0)
			"square":
				draw_rect(Rect2(centre - Vector2(7, 7), Vector2(14, 14)), color)
				draw_rect(Rect2(centre - Vector2(7, 7), Vector2(14, 14)), UiStyle.TEXT, false, 2.0)
			_:
				draw_circle(centre, 6.0, color)
				draw_arc(centre, 6.0, 0.0, TAU, 16, UiStyle.TEXT, 1.5)
		if caption.is_empty():
			return
		var label := "%s  %d m" % [caption, roundi(distance)]
		var width := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x
		var left := clampf(centre.x - width * 0.5, 0.0, size.x - width)
		var baseline := Vector2(left, STRIP_HEIGHT + 30.0 + 18.0 * row)
		draw_string_outline(font, baseline, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, 4,
			UiStyle.OUTLINE)
		draw_string(font, baseline, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, color.lightened(0.4))


## The raft from above, bow up: where the crew stands, where to stand to steer, and where the
## lighthouse lies relative to the bow.
class RaftDiagram:
	extends Control

	## The deck's half-extents in the raft's own space: 9 m across, 9.6 m long.
	const HALF_WIDTH: float = 4.5
	const HALF_LENGTH: float = 4.8

	var hud: VoyageHud

	func _draw() -> void:
		if hud == null or hud.game == null or hud.game.raft == null:
			return
		var raft := hud.game.raft
		var centre := size * 0.5 + Vector2(0, 6)
		var scale := minf(size.x, size.y - 30.0) / (HALF_LENGTH * 2.0 + 5.0)
		var deck := Rect2(
			centre - Vector2(HALF_WIDTH, HALF_LENGTH) * scale,
			Vector2(HALF_WIDTH, HALF_LENGTH) * 2.0 * scale,
		)

		# Where to stand: the side that turns the bow toward the lighthouse, or the middle.
		var error := hud.heading_error()
		var band := Raft.STRAIGHT_BAND * scale
		var zone := Rect2(Vector2(centre.x - band, deck.position.y), Vector2(band * 2.0, deck.size.y))
		if not raft.moored:
			if error > VoyageHud.ON_COURSE_DEGREES:
				zone = Rect2(Vector2(centre.x + band, deck.position.y),
					Vector2(deck.end.x - centre.x - band, deck.size.y))
			elif error < -VoyageHud.ON_COURSE_DEGREES:
				zone = Rect2(deck.position, Vector2(centre.x - band - deck.position.x, deck.size.y))

		# Planks, running fore and aft.
		draw_rect(deck, Color(0.46, 0.30, 0.19))
		var planks := 7
		for index in range(1, planks):
			var x := deck.position.x + deck.size.x * float(index) / planks
			draw_line(Vector2(x, deck.position.y), Vector2(x, deck.end.y), Color(0.33, 0.21, 0.13), 2.0)
		draw_rect(zone, Color(UiStyle.SEA, 0.35))
		draw_rect(deck, Color(0.20, 0.13, 0.08), false, 3.0)
		# The bow, so "forward" is never in doubt.
		draw_colored_polygon(PackedVector2Array([
			Vector2(centre.x - 14, deck.position.y - 4), Vector2(centre.x + 14, deck.position.y - 4),
			Vector2(centre.x, deck.position.y - 18),
		]), UiStyle.ACCENT)

		# The lighthouse's bearing from the bow, on a ring round the deck.
		var ring := HALF_LENGTH * scale + 22.0
		var angle := deg_to_rad(-error)
		var marker := centre + Vector2(sin(angle), -cos(angle)) * ring
		draw_circle(marker, 8.0, UiStyle.DANGER)
		draw_arc(marker, 8.0, 0.0, TAU, 16, UiStyle.TEXT, 2.0)

		var players := hud.game.get_node_or_null("Players")
		if players == null:
			return
		var mine := hud.local_body()
		for child in players.get_children():
			var mate := child as NetworkPlayer
			if mate == null or not raft.carries(mate):
				continue
			var local := raft.to_local(mate.global_position)
			var spot := centre + Vector2(
				clampf(local.x, -HALF_WIDTH, HALF_WIDTH), clampf(local.z, -HALF_LENGTH, HALF_LENGTH)
			) * scale
			var radius := 9.0 if mate == mine else 7.0
			draw_circle(spot, radius, mate.player_color)
			draw_arc(spot, radius, 0.0, TAU, 20, UiStyle.TEXT if mate == mine else UiStyle.OUTLINE, 2.5)
