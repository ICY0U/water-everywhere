class_name PauseMenu
extends Control

## The in-voyage menu: resume, the shared panels, restart, leave, quit.
##
## Says plainly whether the world has stopped. Solo, it has; in a crew it has not, and a player
## who opens this mid-crossing needs to know their raft is still drifting.

var ui: GameUI

var _heading: Label
var _note: Label
var _summary_button: Button
var _restart_button: Button


func _ready() -> void:
	var stack := UiStyle.modal(self, 460)
	_heading = UiStyle.heading("Paused", 44)
	_heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stack.add_child(_heading)
	_note = UiStyle.label("", 17, UiStyle.MUTED, 700)
	_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(_note)
	stack.add_child(UiStyle.rule())
	stack.add_child(UiStyle.button("Resume", func() -> void: ui.resume(), true))
	_summary_button = UiStyle.button("Voyage Summary", func() -> void: ui.show_summary())
	stack.add_child(_summary_button)
	stack.add_child(UiStyle.button("How to Play", func() -> void: ui.open_overlay(&"help")))
	stack.add_child(UiStyle.button("Settings", func() -> void: ui.open_overlay(&"settings")))
	_restart_button = UiStyle.button("Restart Voyage", func() -> void: ui.sail_again())
	stack.add_child(_restart_button)
	stack.add_child(UiStyle.button("Leave Voyage", func() -> void: ui.leave_to_title()))
	stack.add_child(UiStyle.button("Quit to Desktop", func() -> void: ui.quit_game()))


## Updates the wording and buttons for the session and phase this menu is opening over.
func refresh() -> void:
	var solo := NetworkSession.is_solo()
	_heading.text = "Paused" if solo else "Voyage Menu"
	if solo:
		_note.text = "The sea waits for you."
	elif NetworkSession.is_authority():
		_note.text = "Your crew is still sailing. Leaving ends the voyage for everyone."
	else:
		_note.text = "The voyage carries on while this menu is open."
	_summary_button.visible = ui.game.director().phase == RunDirector.Phase.ARRIVAL
	# Only the authority can restart a run; a client asking would be refused anyway, so the
	# button is not offered rather than offered and ignored.
	_restart_button.visible = NetworkSession.is_authority()


func focus_first() -> void:
	var first := UiStyle.first_focusable(self)
	if first != null:
		first.grab_focus()
