# A03 — Exported playable baseline, and A04 — Voyage scene and phase skeleton

**Completed:** 13 September 2026.
**Result:** a Windows build runs outside the editor and two exported processes host/join each
other; a new voyage scene carries an authoritative run phase, objective and reset. The runner
reports **15/15 suites passed, exit 0**. Three further defects found in the first human play
were fixed; see the final section.
**Scope:** packaging and a bounded gameplay skeleton. No paddling, cargo, damage, rescue or
weather schedule — those are later chunks with their own gates.

## A03 — First exported playable baseline

### What was missing

No `export_presets.cfg` existed. Templates were already installed and match the engine
(`4.7.2.stable`, including `windows_release_x86_64.exe`), so nothing had to be downloaded.

> A01 recorded the templates as present and it was right. An early listing here was truncated by
> `head -20` before the alphabetically-later `windows_*` entries and briefly looked like a missing
> -template blocker. Read the whole listing before reporting one.

### What was added

`export_presets.cfg`, one Windows Desktop x86_64 preset. `docs/`, `planning/` and `tools/` are
excluded from the pack: they are evidence and test scaffolding, not game content.

### Gate evidence

The plan's gate is four clauses, and export success alone satisfies none of them.

| Clause | Evidence |
|---|---|
| Runs without the editor | `WaterEVERYWHERE.exe` (109 MB) + `.pck` (4.7 MB), launched directly |
| Renders correctly | Both processes: `D3D12 12_0 - Forward+ - NVIDIA GeForce RTX 2080 Ti` |
| Hosts and joins another exported process | Host: `hosting on port 27241`; client: `connected as peer 705782754`; host then logged `ExportGuest (peer 705782754) joined` |
| Exits cleanly | Separate probe: `EXITCODE=0`, `NO_LEFTOVER_PROCESSES` |

```powershell
$godot = 'D:\MainSystems\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe'
& $godot --headless --path . --export-release "Windows Desktop" "build/windows/WaterEVERYWHERE.exe"
```

Launch paths, for a human test:

```text
build\windows\WaterEVERYWHERE.exe
build\windows\WaterEVERYWHERE.exe -- --server --port=27241 --name=Host
build\windows\WaterEVERYWHERE.exe -- --client --port=27241 --name=Guest
```

Controls unchanged: H hosts, J opens a second window, WASD moves, Shift sprints, V changes view,
Ctrl+Q quits. The voyage scene adds R to restart.

### Limits

- `--log-file` produced no file from the exported binary in two attempts. Unexplained; stdout
  redirection works and supplied every result above. Recorded rather than papered over.
- The build is **not** signed, has no custom icon, and has never run on another machine.
- Two processes on one machine over loopback is not a WAN test. That is B04.

## A04 — Voyage scene and phase skeleton

### What was added

| File | Role |
|---|---|
| `scripts/network/run_director.gd` | Authoritative phase, revision and epoch |
| `scripts/network/voyage_game.gd` | `MultiplayerGame` subclass: arrival rule, reset, spawn ashore |
| `scenes/voyage.tscn` | Home island, mountainous mainland 300 m west, raft, full presentation stack |
| `tools/verify_voyage.gd` | Gate suite (38 checks after the fixes below), registered in `run_suites.gd` |

`LOBBY -> VOYAGE -> ARRIVAL`, which is the subset a short crossing needs; the plan explicitly
permits entering `VOYAGE` directly. The omitted phases are absent rather than stubbed, so nothing
claims a beat with no behaviour behind it.

**Phase travels by reliable RPC, not a synchronizer.** A synchronizer streams the latest value,
which is right for a pose and wrong for a transition: a joiner would see the current phase without
the revision saying how many it missed. A joiner instead receives a full baseline snapshot.

**Revision and epoch are what make stale packets harmless.** A peer ignores any update not newer
than the one it holds, and any update from a previous run. Both are asserted, not assumed.

**Reset moves bodies rather than freeing and respawning them.** Freeing races the spawner's own
replicated create/destroy messages, which is exactly how a peer ends up with two bodies or none.

### Gate evidence

The plan's gate: two peers agree on objective/phase, late join initializes correctly, three resets
leave one raft and one body per player.

`verify_voyage.gd` — **38/38 PASS, exit 0** (36 at first writing, plus two landmark checks added
after the human play), including:

- Fresh scene starts in LOBBY at revision 0; `begin_voyage()` advances to VOYAGE at revision 1.
- Re-entering the same phase does **not** bump the revision — one result from a duplicate trigger.
- Crew spawns ashore on the home island (r=11.7 < 26.0), 312 m from the mainland, clear of each other.
- Reaching the mainland ends the run; staying ashore does not re-trigger it.
- Three resets each leave **one body per player and exactly one raft**, return the crew home, and
  start a new epoch (3 after 3 resets).
- A command from a previous epoch is ignored; a stale revision cannot rewind the phase.

That suite drives the server methods directly, because the `NetworkSession` autoload name is not
resolvable under `--script` — every `MultiplayerGame` subclass fails to compile that way, including
the shipping ones (verified against `island_game.gd` and `archipelago_game.gd` as a control). So
agreement across the wire was proved separately, with **two real processes over ENet on port 27253**:

```text
PASS  host enters VOYAGE on hosting phase=1 revision=1
PASS  late joiner receives the run phase host=1 client=1
PASS  late joiner receives the run revision host=1 client=1
PASS  late joiner receives the run epoch host=0 client=0
PASS  both peers render the same objective '<objective text>'
PASS  both peers see both crew host=2 client=2
PASS  a later phase change reaches the client client phase=2 revision=2
PASS  the client objective follows the new phase
voyage_network: 0 failures
```

### Visual confirmation

Rendered on a real D3D12 device and inspected, not merely sampled:
[voyage overview](../docs/a04_voyage/voyage_overview.png). The home island sits in the foreground
with surf and the raft moored offshore; the mountainous mainland reads clearly on the horizon as a
destination; the cel-shaded sea, cloud shadows and sky render correctly; the objective line appears
under the roster text. A green suite plus a clean compile would not have caught a vanished
procedural surface — this is why the capture exists.

One fix came out of building the scene: both islands initially claimed shoreline surf, which is
global and single-owner. The mainland now leaves `surf_strength` at 0.

### Limits and honest status

- **The crossing has never been sailed.** Arrival is proved by moving a body to the mainland,
  which tests the arrival *rule*, not handling, propulsion or whether crossing is any fun.
  Propulsion is B01.
- **The A04 gate's "user identifies home within 30 seconds" human test remains open.** The user
  has since run the scene and confirmed it works, which surfaced the fixes in the final section,
  but that specific timed question has not been put to anyone.
- The distance (300 m) and arrival margin are first guesses, to be set from measured raft speed
  once B01 gives the raft a speed.
- `voyage.tscn` **is** now the main scene, set by the user in the editor. The suite that
  hard-coded a single main scene was generalised rather than reverting that choice.

## Reproduction

```powershell
$godot = 'D:\MainSystems\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe'
& $godot --headless --path . --script tools/verify_voyage.gd   # 38/38 PASS, exit 0
& $godot --headless --path . --script tools/run_suites.gd      # 15/15 PASS, exit 0
```

## Phase A fixes after the first human play (13 September 2026)

The user ran the voyage scene in the editor and reported it working. That single session surfaced
three defects no headless suite had caught, plus one non-defect worth recording.

### 1. The objective named a landmark that did not exist

The HUD read "Reach the mainland lighthouse to the west." A project-wide grep found "lighthouse"
in exactly one place: that string. The scene has never contained a lighthouse.

The objective is the only instruction a new player gets, and A04's gate is "user identifies home
within 30 seconds", so this was pointing people at nothing. Now reads **"Sail west to the
mountains on the mainland."**, which is what is actually on screen — the massif rises 86.0 m and
is visible from the start position.

### 2. The suite could not have caught it

36 checks passed while the objective described a fiction, because every one of them tested the
string against another string. `verify_voyage.gd` now asserts the objective against the **world**:
if the text names a lighthouse, beacon, tower or harbour, that thing must exist in the scene, and
the mainland must carry the relief the objective points at.

Proved by reintroducing the bug rather than by assuming:

```text
FAIL  the objective's 'lighthouse' exists in the scene
verify_voyage: 1 failures          (exit 1)
```

Restoring the corrected text returns 38/38, exit 0. A guard that cannot fail is not a guard.

### 3. `verify_archipelago` hard-coded the main scene

Setting the voyage scene as the main scene turned `F5 loads the playable world` red without
anything in the archipelago changing. A control run confirmed the setting was the sole cause:
with `main_scene` pointed back at the archipelago, that suite reported 0 failures.

The assertion encoded "archipelago is the only real scene", which was true when written and became
wrong the moment a second playable scene existed. It now checks membership of
`PLAYABLE_MAIN_SCENES` — the four actual `MultiplayerGame` scenes — so it still catches F5 pointing
at a demo or fixture. Negative control, with `main_scene` set to `ocean_demo.tscn`:

```text
FAIL F5 loads a playable world res://scenes/ocean_demo.tscn     (exit 1)
```

**The main scene was left as the user set it.** `project.godot` was modified at 23:25:53, twelve
minutes after `voyage.tscn` was created and by an editor session, not by any agent edit. The fix
belonged in the stale assertion, not in reverting a deliberate choice.

### Not a defect: the spawn

The player appeared standing on the raft in the screenshot, which looked like a spawn-position bug.
It was not — the user had walked there. Measured independently before concluding: the body settles
at r=11.70 from the home island centre, stance GROUNDED, submersion 0.000, stable across 8 s.
Spawn is correct and was left alone.

### Board after these fixes

**15/15 suites pass, exit 0, 347.2 s**, with `voyage.tscn` as the main scene.

Still open, and unchanged by any of this: the crossing has never been sailed, and no human has
judged whether home is identifiable within 30 seconds.

**Next: B01 — one paddle action**, and the human tests above. The voyage scene is the place for it:
the crew starts ashore with a raft moored nearby and a destination they can see.
