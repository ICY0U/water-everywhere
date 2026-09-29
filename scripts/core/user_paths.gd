class_name UserPaths
extends RefCounted

## Where this machine's saved files live: settings and best times.
##
## Everything goes under [code]user://[/code], in a sub-folder when the game is launched with
## [code]-- --profile=NAME[/code]. Two reasons for the switch. The verification suites start
## voyages and finish them, and must not write a two-second "best time" into the records of the
## person running them. And the two-window local test runs two copies of the game on one machine:
## without a profile, the guest window would save its settings over the host's.

## Returns the path to [param file_name] in the active profile.
static func file(file_name: String) -> String:
	var profile := profile_name()
	if profile.is_empty():
		return "user://%s" % file_name
	var folder := "user://profiles/%s" % profile
	DirAccess.make_dir_recursive_absolute(folder)
	return "%s/%s" % [folder, file_name]


## Returns the profile named on the command line, or an empty string for the default one.
##
## Only letters, digits, dashes and underscores are kept, so a profile name can never climb out
## of the profiles folder.
static func profile_name() -> String:
	for argument in OS.get_cmdline_user_args():
		if not argument.begins_with("--profile="):
			continue
		var clean := ""
		for character in argument.trim_prefix("--profile="):
			if character.is_valid_identifier() or character.is_valid_int() or character == "-":
				clean += character
		return clean
	return ""
