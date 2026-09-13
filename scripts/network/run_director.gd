class_name RunDirector
extends Node

## Authoritative run phase and objective for one voyage.
##
## The plan's state contract puts "run, roster, route" under reliable versioned server state, and
## this is the smallest honest piece of that: which phase the run is in, and what the crew is
## being asked to do. It is deliberately NOT derived on each peer from world geometry — a client
## that decided its own phase by measuring its distance to the mainland would disagree with the
## server the moment a correction arrived, which is the failure [[replicated-state-not-derived-state]]
## describes.
##
## The phase is replicated by explicit reliable RPC rather than by a [MultiplayerSynchronizer],
## because a phase change is a discrete transaction that a joiner must receive exactly once and
## in full. A synchronizer streams the latest value, which is right for a pose and wrong for a
## transition: a late joiner would see the current phase without the revision that tells it how
## many transitions it missed.
##
## [b]Revision[/b] is what makes a stale packet harmless. Every change increments it, and a peer
## ignores any update whose revision is not newer than the one it holds, so an out-of-order or
## replayed phase message cannot walk the run backwards.

## Phases of one voyage, in the order they occur.
##
## The plan's full chain is LOBBY -> PREPARING -> INTRO -> REGROUP -> VOYAGE -> FINAL_APPROACH ->
## ARRIVAL -> SUMMARY. A04 implements the subset a short crossing actually needs and the plan
## explicitly permits ("the slice can enter VOYAGE directly"); the omitted phases are not stubs
## here, so nothing claims to implement a beat that has no behaviour behind it.
enum Phase {
	## No session, or a session with no run started.
	LOBBY,
	## Crossing to the mainland. The playable phase.
	VOYAGE,
	## The mainland has been reached and the run is over.
	ARRIVAL,
}

## Emitted on every peer when the phase changes, including on the authority.
signal phase_changed(phase: Phase, revision: int)

## Emitted on every peer when a run is reset, after the phase returns to LOBBY.
signal run_reset(epoch: int)

## Objective text shown for each phase.
##
## Held here rather than in the HUD so that every peer renders the same sentence from the same
## authoritative phase, instead of each writing its own wording for a state it inferred.
const OBJECTIVE_TEXT: Dictionary = {
	Phase.LOBBY: "Press H to host, then J to open a second window.",
	# Names the mountains because the mountains are what is on screen. An earlier version of this
	# line promised a lighthouse, which the scene has never contained: the objective is the only
	# instruction a new player gets, so it must describe a landmark they can actually see. A
	# suite check now asserts that, because 36 green checks did not catch the invented one.
	Phase.VOYAGE: "Sail west to the mountains on the mainland.",
	Phase.ARRIVAL: "You reached the mainland. Press R to sail again.",
}

## Current phase. Authoritative on the server; a replicated copy everywhere else.
var phase: Phase = Phase.LOBBY

## Number of phase changes this run has seen. See the class description.
var revision: int = 0

## Which run this is. Incremented by [method reset_run] so that a command issued against the
## previous run can be recognised and discarded rather than applied to the new one.
##
## The plan requires that "delayed old-epoch commands after restart cannot affect new run", and
## an epoch is what makes that checkable rather than merely hoped for.
var epoch: int = 0


## Returns the objective sentence for the current phase.
func objective() -> String:
	return OBJECTIVE_TEXT.get(phase, "")


## Moves the run to [param next] and tells every peer. Server only.
##
## Ignored when the phase is unchanged, so a repeated arrival trigger cannot emit a second
## completion or bump the revision for nothing — the plan asks for exactly one result from a
## duplicate trigger.
func advance_to(next: Phase) -> void:
	if not _is_authority():
		return
	if next == phase:
		return
	revision += 1
	_receive_phase.rpc(next, revision, epoch)
	# Applied locally too: rpc() alone does not call the local peer, and the server must not be
	# the one peer that never learns its own phase.
	_apply_phase(next, revision)


## Returns the whole run state, for a joiner that needs a baseline rather than a delta.
func snapshot() -> Dictionary:
	return {"phase": phase, "revision": revision, "epoch": epoch}


## Sends the current run state to one peer. Server only.
##
## A late joiner cannot be caught up by the phase RPCs it was not connected for, so it is handed
## the current baseline instead. This is the "full current snapshot and run epoch" the plan's
## join/recovery column requires for run state.
func send_baseline_to(peer_id: int) -> void:
	if not _is_authority():
		return
	_receive_baseline.rpc_id(peer_id, snapshot())


## Starts a fresh run: new epoch, revision zeroed, phase back to LOBBY. Server only.
##
## Returns the new epoch so a caller can assert it changed.
func reset_run() -> int:
	if not _is_authority():
		return epoch
	epoch += 1
	revision = 0
	_receive_reset.rpc(epoch)
	_apply_reset(epoch)
	return epoch


@rpc("authority", "call_remote", "reliable")
func _receive_phase(next: Phase, sent_revision: int, sent_epoch: int) -> void:
	# A message from a run that no longer exists must not move this one. Checked before the
	# revision, because a stale epoch's revision numbers are not comparable with this run's.
	if sent_epoch != epoch:
		return
	if sent_revision <= revision:
		return
	_apply_phase(next, sent_revision)


@rpc("authority", "call_remote", "reliable")
func _receive_baseline(state: Dictionary) -> void:
	epoch = int(state.get("epoch", 0))
	_apply_phase(int(state.get("phase", Phase.LOBBY)) as Phase, int(state.get("revision", 0)))


@rpc("authority", "call_remote", "reliable")
func _receive_reset(sent_epoch: int) -> void:
	_apply_reset(sent_epoch)


func _apply_phase(next: Phase, sent_revision: int) -> void:
	phase = next
	revision = sent_revision
	phase_changed.emit(phase, revision)


func _apply_reset(sent_epoch: int) -> void:
	epoch = sent_epoch
	revision = 0
	phase = Phase.LOBBY
	phase_changed.emit(phase, revision)
	run_reset.emit(epoch)


## True when this peer decides the run.
##
## An offline single-player launch has no multiplayer peer at all, and must still be able to run
## the phases rather than sitting in LOBBY forever, so that case counts as authority too.
func _is_authority() -> bool:
	if not multiplayer.has_multiplayer_peer():
		return true
	return multiplayer.is_server()
