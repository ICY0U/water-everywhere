class_name Records
extends RefCounted

## Best crossing times, kept on this machine.
##
## One record per sea state and crew kind — solo or crewed — because a storm crossing and a calm
## one are not the same achievement, and neither is paddling alone against paddling with three
## friends. Local by design: the time comes from the authority's summary, but a record is only a
## note this player keeps, never something sent to or trusted from another peer.

## Name of the file the records are stored in, inside the active profile. See [UserPaths].
const FILE_NAME: String = "records.cfg"

const SECTION: String = "best_times"


## Returns the best time for [param sea_state], or a negative number when there is none yet.
static func best(sea_state: int, crewed: bool) -> float:
	var file := ConfigFile.new()
	if file.load(UserPaths.file(FILE_NAME)) != OK:
		return -1.0
	return float(file.get_value(SECTION, _key(sea_state, crewed), -1.0))


## Records [param seconds] if it beats the stored best. Returns true when it did.
static func submit(sea_state: int, crewed: bool, seconds: float) -> bool:
	if seconds <= 0.0 or not is_finite(seconds):
		return false
	var file := ConfigFile.new()
	var path := UserPaths.file(FILE_NAME)
	file.load(path)
	var key := _key(sea_state, crewed)
	var previous := float(file.get_value(SECTION, key, -1.0))
	if previous > 0.0 and previous <= seconds:
		return false
	file.set_value(SECTION, key, seconds)
	file.save(path)
	return true


static func _key(sea_state: int, crewed: bool) -> String:
	return "%s_%d" % ["crew" if crewed else "solo", sea_state]
