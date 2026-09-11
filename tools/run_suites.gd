extends SceneTree

## Runs every verification suite in one command and reports a single verdict.
##
## Each suite already exits non-zero on failure "so it is usable from CI", and nothing ever used
## them that way: they had to be pasted one at a time, and the spray suite needs a different
## invocation from the other six. A suite nobody remembers to run is how a regression ships.
##
## Suites run one at a time, each in its own child process. Sequential is deliberate rather than
## incidental: every suite binds an ENet port, and although today's ports are all distinct, a
## bind clash presents as [code]Couldn't create an ENet host[/code] or as a timeout rather than
## as a clean error. Running them concurrently would trade a few minutes for a class of false
## failure nobody would enjoy diagnosing. For the same reason, do not run a suite by hand
## alongside this one: the ports are fixed per suite, not per process.
##
## Nothing from the project is loaded here — the suites are launched, not imported. That sidesteps
## the [code]--script[/code] parse-order trap that [code]tools/verify_session_identity.gd[/code]
## documents, where statically typing a variable with a [code]class_name[/code] forces that script
## to compile before the autoloads it references exist.
##
## Run with:
## [codeblock lang=text]
## godot --path . --headless --script tools/run_suites.gd
## [/codeblock]
## The whole set takes several minutes. To run a subset, pass a filter after a bare
## [code]--[/code]:
## [codeblock lang=text]
## godot --path . --headless --script tools/run_suites.gd -- --only=raft
## [/codeblock]
## Exits non-zero if any suite fails, so it is usable from CI.

## Column width for the suite name, so results line up in the terminal.
const LABEL_WIDTH: int = 14

## Rendering driver the GPU suite is asked for by name. Its whole point is a real device.
const GPU_DRIVER: String = "d3d12"

## Lower-cased fragments that mark a suite's closing verdict line. See [method _verdict_of].
const VERDICT_MARKERS: Array[String] = ["passed", "failed", "failures", "timed out"]

## Lower-cased fragments that mean a suite never got as far as testing anything.
##
## What these detect is a socket the suite could not open — [method NetworkSession.host]
## returning a non-OK [enum Error], or the engine refusing to create an ENet host. The suite then
## dies before its first assertion, so its exit code says "failed" about nothing it tested.
##
## The [i]cause[/i] is deliberately not asserted anywhere below, only guessed at in prose. A
## competing run holding the port is the obvious suspect and each suite does host on a fixed one,
## but that explanation is not established: ENet sets [code]SO_REUSEADDR[/code], and two ENet
## servers were confirmed here to coexist happily on one UDP port on Windows. Deliberately
## holding a suite's port — with a plain UDP socket, with a real ENet server, and with
## [code]SO_EXCLUSIVEADDRUSE[/code] — produced a timeout every time, never a bind error. So a
## port clash does not reliably present this way, and something else may produce it.
const BIND_FAILURE_MARKERS: Array[String] = [
	"couldn't create an enet host",
	"could not host on port",
	"could not connect",
	"is another run using the port",
]

## Every suite, in the order they run.
##
## [code]gpu[/code] marks one that cannot run headless. [code]tools/verify_spray.gd[/code] renders
## the particles' own copy of the wave spectrum into a texture and reads it back, so it needs a
## real rendering device; it is also the only place a shader compile error can surface at all,
## since those are compile-time and invisible to a headless run. That single exception is why this
## file exists rather than a loop over [code]tools/verify_*.gd[/code].
const SUITES: Array[Dictionary] = [
	{"name": "waves", "script": "tools/verify_waves.gd", "gpu": false},
	{"name": "buoyancy", "script": "tools/verify_buoyancy.gd", "gpu": false},
	{"name": "reactions", "script": "tools/verify_reactions.gd", "gpu": false},
	{"name": "multiplayer", "script": "tools/verify_multiplayer.gd", "gpu": false},
	{"name": "session", "script": "tools/verify_session_identity.gd", "gpu": false},
	{"name": "raft", "script": "tools/verify_raft.gd", "gpu": false},
	{"name": "spray", "script": "tools/verify_spray.gd", "gpu": true},
]

var _failed_suites: int = 0
var _blocked_suites: int = 0
var _unlaunchable_suites: int = 0
var _failed_checks: PackedStringArray = PackedStringArray()


func _initialize() -> void:
	var only := _only_filter()
	var godot := OS.get_executable_path()
	var project := ProjectSettings.globalize_path("res://")

	print("run_suites: %s" % (
		"every verification suite" if only.is_empty() else "suites matching '%s'" % only
	))
	print("  engine  %s" % godot)
	print("  project %s" % project)
	print("")

	var ran := 0
	var started := Time.get_ticks_msec()
	for suite in SUITES:
		if not only.is_empty() and not String(suite["name"]).contains(only):
			continue
		ran += 1
		_run_suite(godot, project, suite)

	if ran == 0:
		printerr("run_suites: no suite name contains '%s'" % only)
		quit(2)
		return

	_report_summary(ran, float(Time.get_ticks_msec() - started) / 1000.0)


## Nothing here needs a frame; the work is done in [method _initialize].
func _process(_delta: float) -> bool:
	return true


## Returns the [code]--only=[/code] filter from the launch arguments, or an empty string.
func _only_filter() -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--only="):
			return argument.trim_prefix("--only=")
	return ""


## Launches one suite in a child engine and records what it said.
func _run_suite(godot: String, project: String, suite: Dictionary) -> void:
	var suite_name: String = suite["name"]
	var arguments := PackedStringArray(["--path", project])
	# The GPU suite is not merely "not headless": the driver is named, because a device that
	# quietly fell back would compare the CPU wave field against nothing in particular.
	if suite["gpu"]:
		arguments.append_array(["--script", suite["script"], "--rendering-driver", GPU_DRIVER])
	else:
		arguments.append_array(["--headless", "--script", suite["script"]])

	var output: Array = []
	var started := Time.get_ticks_msec()
	var code := OS.execute(godot, arguments, output, true, false)
	var seconds := float(Time.get_ticks_msec() - started) / 1000.0

	if code < 0:
		_unlaunchable_suites += 1
		print("%s  %s %6s  the engine could not be launched" % [
			"----", suite_name.rpad(LABEL_WIDTH), "-",
		])
		return

	var lines := _lines_of(output)
	for failure in _failing_checks(lines):
		_failed_checks.append("%s: %s" % [suite_name, failure])

	# A suite that could not open its socket tested nothing, so it is neither a pass nor an honest
	# failure. Still counted against the run — an untested suite is not a green one — but named
	# separately, because "this did not run" is a different instruction from "go and read the
	# assertion that broke". The line says what was observed, not why: see BIND_FAILURE_MARKERS.
	if code != 0 and _is_bind_failure(lines):
		_blocked_suites += 1
		print("BUSY  %s %5.1fs  could not open its socket; nothing was tested" % [
			suite_name.rpad(LABEL_WIDTH), seconds,
		])
		return

	if code != 0:
		_failed_suites += 1

	print("%s  %s %5.1fs  %s" % [
		"PASS" if code == 0 else "FAIL",
		suite_name.rpad(LABEL_WIDTH),
		seconds,
		_verdict_of(lines, code),
	])


## Flattens whatever [method OS.execute] captured into individual lines.
##
## The output array holds a few large strings rather than a line each, and a failing suite will
## have written to stderr as well, so everything is joined before being split.
func _lines_of(output: Array) -> PackedStringArray:
	var joined := ""
	for chunk in output:
		joined += str(chunk)
	return joined.replace("\r", "").split("\n")


## Returns the suite's own closing line, so the summary quotes it rather than paraphrasing it.
##
## Decoration only — the exit code decides pass or fail, and a suite that says nothing
## recognisable is still reported by its code. Matching is case-insensitive and covers several
## wordings because the suites do not agree on one: "All spray checks PASSED", "all session
## identity checks passed", "1 multiplayer check(s) FAILED" and "verify_raft: 0 failures" are all
## in use today, and a matcher tuned to one of them silently degrades to the fallback for the
## rest — which is exactly what it did until a GPU run reported PASS with nothing to show for it.
func _verdict_of(lines: PackedStringArray, code: int) -> String:
	for index in range(lines.size() - 1, -1, -1):
		var line := lines[index].strip_edges()
		var lowered := line.to_lower()
		for marker in VERDICT_MARKERS:
			if lowered.contains(marker):
				return line
	return "no verdict line printed; going by exit code %d" % code


## Returns whether the suite died trying to bind or reach a socket rather than on an assertion.
func _is_bind_failure(lines: PackedStringArray) -> bool:
	for line in lines:
		var lowered := line.to_lower()
		for marker in BIND_FAILURE_MARKERS:
			if lowered.contains(marker):
				return true
	return false


## Returns every individual check the suite reported as failing.
func _failing_checks(lines: PackedStringArray) -> PackedStringArray:
	var failures := PackedStringArray()
	for line in lines:
		var trimmed := line.strip_edges()
		if trimmed.begins_with("FAIL"):
			failures.append(trimmed.trim_prefix("FAIL").strip_edges())
	return failures


## Prints the verdict and exits with a code CI can read.
##
## Failing checks are repeated here on purpose. A suite's own output scrolls past behind several
## minutes of other suites, and the whole value of one command is not having to go looking for
## which assertion actually broke.
##
## Deliberately no allowlist of expected failures. Some checks are known to fail today and are
## documented in the audit, but a runner that swallows a named check cannot tell that check
## failing for the old reason from it failing for a new one — and at least one of them may be
## catching a real defect rather than being merely stale. Reporting every failure and letting the
## docs carry the context keeps this file honest and free of a list that would rot.
func _report_summary(ran: int, seconds: float) -> void:
	print("")
	if not _failed_checks.is_empty():
		print("failing checks:")
		for failure in _failed_checks:
			print("  %s" % failure)
		print("")

	if _unlaunchable_suites > 0:
		printerr("run_suites: %d suite(s) could not be launched" % _unlaunchable_suites)
		quit(2)
		return

	if _blocked_suites > 0:
		print("%d suite(s) never opened a socket, so they tested nothing." % _blocked_suites)
		print("  A competing run is the usual suspect; close any other suite and try again.")

	if _failed_suites > 0 or _blocked_suites > 0:
		print("%d of %d suite(s) did not pass in %.1fs" % [
			_failed_suites + _blocked_suites, ran, seconds,
		])
		quit(1)
	else:
		print("all %d suite(s) passed in %.1fs" % [ran, seconds])
		quit(0)
