class_name SummaryPanel
extends Control

## The end of a crossing: the time, what it took, who made it, and what to do next.
##
## Every number here comes from [member RunDirector.facts], which the authority recorded at the
## moment of arrival and sent with the transition, so every member of a crew sees the same
## summary. The record line is the one local thing on it: best times are kept per machine.

var ui: GameUI

## Whether the crossing just finished beat this machine's best for that sea. Set by [GameUI].
var new_record: bool = false

var _subtitle: Label
var _time: Label
var _record: Label
var _stats: GridContainer
var _sail_again: Button
var _waiting: Label


func _ready() -> void:
	var stack := UiStyle.modal(self, 560, false)
	var heading := UiStyle.heading("Landfall!", 64, UiStyle.ACCENT)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stack.add_child(heading)
	_subtitle = UiStyle.label("", 21, UiStyle.TEXT, 700)
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stack.add_child(_subtitle)
	stack.add_child(UiStyle.rule())

	var time_caption := UiStyle.label("CROSSING TIME", 15, UiStyle.MUTED, 800)
	time_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stack.add_child(time_caption)
	_time = UiStyle.heading("0:00", 72)
	_time.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stack.add_child(_time)
	_record = UiStyle.label("", 19, UiStyle.SEA, 800)
	_record.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stack.add_child(_record)

	_stats = GridContainer.new()
	_stats.columns = 2
	_stats.add_theme_constant_override(&"h_separation", 28)
	_stats.add_theme_constant_override(&"v_separation", 6)
	var holder := CenterContainer.new()
	holder.add_child(_stats)
	stack.add_child(holder)
	stack.add_child(UiStyle.rule())

	_sail_again = UiStyle.button("Sail Again", func() -> void: ui.sail_again(), true)
	stack.add_child(_sail_again)
	_waiting = UiStyle.label("The host can start another crossing.", 17, UiStyle.MUTED, 700)
	_waiting.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stack.add_child(_waiting)
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 12)
	var explore := UiStyle.button("Keep Exploring", func() -> void: ui.resume())
	explore.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(explore)
	var menu := UiStyle.button("Main Menu", func() -> void: ui.leave_to_title())
	menu.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(menu)
	stack.add_child(row)


## Fills the panel from the run's recorded facts.
func refresh() -> void:
	var facts := ui.game.director().facts
	var crew: Array = facts.get("crew", [])
	var seconds := float(facts.get("seconds", ui.game.director().voyage_seconds))
	var sea := int(facts.get("weather", 0))
	_subtitle.text = (
		"You made it to the mainland." if crew.size() <= 1
		else "The crew made it to the mainland."
	)
	_time.text = UiStyle.clock(seconds)
	var best := Records.best(sea, crew.size() > 1)
	if new_record:
		_record.text = "New best time for this sea!"
		_record.add_theme_color_override(&"font_color", UiStyle.SEA)
	elif best > 0.0:
		_record.text = "Your best: %s" % UiStyle.clock(best)
		_record.add_theme_color_override(&"font_color", UiStyle.MUTED)
	else:
		_record.text = ""

	for child in _stats.get_children():
		child.queue_free()
	var seas := TitleScreen.SEA_STATES
	_add_stat("Sea", String(seas[sea]["name"]) if sea >= 0 and sea < seas.size() else "Unknown")
	_add_stat("Paddle strokes", str(int(facts.get("strokes", 0))))
	if crew.size() > 1:
		_add_stat("First ashore", String(facts.get("first", "")))
		_add_stat("Crew", ", ".join(PackedStringArray(crew)))

	var authority := NetworkSession.is_authority()
	_sail_again.visible = authority
	_waiting.visible = not authority


func focus_first() -> void:
	var first := UiStyle.first_focusable(self)
	if first != null:
		first.grab_focus()


func _add_stat(caption: String, value: String) -> void:
	var name_label := UiStyle.label(caption, 19, UiStyle.MUTED, 700)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_stats.add_child(name_label)
	var value_label := UiStyle.label(value, 19, UiStyle.TEXT, 800)
	_stats.add_child(value_label)
