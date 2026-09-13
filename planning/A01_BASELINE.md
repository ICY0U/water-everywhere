# A01 — Current baseline

**Completed:** 13 September 2026, approximately 22:42 BST.  
**Result:** baseline capture complete; **13/14 existing suites pass** as recorded below. The remaining multiplayer assertion failed reproducibly; it was diagnosed and fixed in A02a, after which the runner reports 14/14. This report is preserved as the as-measured baseline — see [A02a](A02A_REMOTE_INPUT_FIX.md).  
**Scope:** inventory, existing-suite execution, rendered two-process checks and evidence. No gameplay implementation or existing test correction.

## Environment and source identity

| Item | Observed |
|---|---|
| Engine | `4.7.2.stable.steam.ed1daf0bf` |
| Executable | `D:/MainSystems/Steam/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe` |
| Rendering | D3D12 12_0, Forward+, NVIDIA GeForce RTX 2080 Ti |
| GPU driver | `32.0.16.1692` |
| CPU | AMD Ryzen 7 5800X 8-Core Processor |
| RAM reported by Windows | 34,280,230,912 bytes, approximately 31.93 GiB |
| HEAD | `97b2801edb378217221015aae473a6d567569390` plus existing dirty work |
| Main scene | `scenes/archipelago.tscn` |
| Templates | Steam portable `editor_data/export_templates/4.7.2.stable`; `version.txt` = `4.7.2.stable`; Windows x86_64 debug/release templates present |
| Export preset | No root `export_presets.cfg` found; packaged execution remains A03 |

The old missing-template claim is obsolete for this installation. Their presence does not prove export success. No download or engine change was needed.

The working tree already contained modified gameplay/rendering/test scripts, untracked archipelago/character work, and a deleted root `AUDIT.md`. It was preserved. A source/assets SHA-256 manifest covers 190 existing files; HEAD alone is insufficient to identify this baseline. No commit or staging was performed.

Local inventory artifacts: [dirty tree](../docs/a01_baseline/dirty_before.txt), [source manifest](../docs/a01_baseline/source_manifest.json). Generated evidence remains under ignored `docs/a01_baseline/`; this report and the capture harness are outside that ignored directory.

## Existing suite results

The runner completed in **333.8 seconds**. No suite was reported busy, stopped without verdict, or unlaunchable.

| Suite | Result | Seconds |
|---|---|---:|
| waves | PASS | 0.4 |
| buoyancy | PASS | 86.2 |
| reactions | PASS | 0.5 |
| multiplayer | **FAIL — one assertion** | 6.0 |
| session | PASS | 7.6 |
| raft | PASS | 25.8 |
| island | PASS | 37.3 |
| player model | PASS | 1.9 |
| locomotion | PASS | 28.3 |
| island spawn | PASS | 8.4 |
| player state | PASS | 38.7 |
| archipelago | PASS | 81.0 |
| island network | PASS | 9.6 |
| spray — real D3D12 GPU check | PASS | 2.2 |

[Full runner report](../docs/a01_baseline/suites.log).

The first invocation used a Windows GUI-subsystem executable, which detached from the shell. Its initial shell exit code was not the test verdict. The engine process was observed until completion and the final report was read. The runner's own OS exit code was not captured; do not report the waiting shell's success as a passing suite run. The separate failing test below was launched with `Start-Process -PassThru`, waited on, and returned **exit 1**.

The runner summarizes child results rather than preserving every child's complete stdout. Passing rows establish the runner's verdict, not a blanket guarantee of no suppressed child warnings.

## Reproduced failure and next action

`tools/verify_multiplayer.gd` → **remote input drives real physics**.

Both the full run and an isolated rerun reported:

```text
PASS client intent reaches server
FAIL remote input drives real physics   host displacement x=2.570
1 multiplayer check(s) FAILED
isolated_exit=1
```

The assertion expects negative X displacement of more than 0.1 m. Actual movement was positive 2.570 m. The previous design document attributed an older failure to sampling while airborne, but the current cause has **not been established**. Receipt of input, camera-relative mapping, bounded diagonal/slow input, release/focus behavior, boarding counter delivery and raft authority/transform checks passed in the isolated run.

**RESOLVED IN A02a** — see [A02a report](A02A_REMOTE_INPUT_FIX.md). The cause was collision between the authority body and its own frozen remote proxy in the shared physics world, not stance, settling or leaked input; the suite now passes 22/22 without any threshold change. The original requirement stood and was met: Inspect fixture stance, initial pose/velocity, sea configuration and measured interval. Compare actual server motion with the intended input after a defined settled state. Keep a failing-before/passing-after reproduction at the real ENet seam. The passing main-scene test below does not excuse this failure.

[Isolated full log](../docs/a01_baseline/multiplayer_isolated.log), [captured exit](../docs/a01_baseline/isolated_exit.txt).

## Rendered host/client baseline

Used the actual archipelago scene on two independent rendered Godot processes, real ENet loopback port **27231**, names `A01Host` and `A01Client`. [Capture harness](A01_capture_baseline.gd) is evidence tooling only and is not registered in project settings or any gameplay scene.

Both processes returned **exit 0**, with seven successful checks each:

- Camera follows the local owner; each scene contains both players.
- Injected owner movement traverses the normal replicated input/body path; each body moved approximately **+3.090 m in X** over the action/settling interval.
- Third-person capture saved, first-person mode selected and capture saved, third-person restored.

At capture time both peers reported identical positions: host approximately `(21.0898, 5.982843, 18.00028)` and client `(25.0898, 5.982843, 18.00028)`. Both were grounded. The authority bodies were unfrozen; both client proxies were frozen. This is settled local agreement, not a latency/error distribution or prediction benchmark.

The existing main-scene network suite additionally passed remote movement, weather change, late-join clock/weather, terrain agreement, stance/animation, raft state and discrete water-impact checks. Its client is headless; the separate rendered pair supplies visual evidence.

### Visual inspection

Inspected all four new images. Both third-person views render the two differently colored characters, names, ground, shadows and island/ocean surroundings. First-person images hide the local body/name and show the scene without a visible head obstruction. Camera aim differs between windows; these are independent local views, not pixel-parity captures. The host's downward aim makes its first-person shot mostly terrain, so this does not establish navigation visibility or comfort at sea.

| Host | Client |
|---|---|
| [Third person](../docs/a01_baseline/host_third_person.png) | [Third person](../docs/a01_baseline/client_third_person.png) |
| [First person](../docs/a01_baseline/host_first_person.png) | [First person](../docs/a01_baseline/client_first_person.png) |

[Host log](../docs/a01_baseline/rendered_host.log), [client log](../docs/a01_baseline/rendered_client.log), [exit codes](../docs/a01_baseline/rendered_exit.txt). Neither rendered log contained an error/warning marker during inspection. HUD frame-rate readings in still images are not performance qualification.

## Reproduction

Run from the repository root. Use a waiting launcher to obtain the actual process exit code:

```powershell
$godotA01 = 'D:\MainSystems\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe'
New-Item -ItemType Directory -Force docs/a01_baseline | Out-Null
$suiteA01 = Start-Process -FilePath $godotA01 -ArgumentList '--headless','--path','.','--log-file','docs/a01_baseline/suites.log','--script','tools/run_suites.gd' -WindowStyle Hidden -PassThru
$suiteA01.WaitForExit()
$suiteA01.ExitCode
```

Do not run another suite concurrently: existing tests use fixed ENet ports. This runner launches its own visible GPU test even though its parent is headless.

The isolated failure used the same waiting pattern with `--script tools/verify_multiplayer.gd` and log `docs/a01_baseline/multiplayer_isolated.log`.

For rendered evidence, launch these arguments in two processes, then wait for both:

```text
--path . --script planning/A01_capture_baseline.gd --rendering-driver d3d12 --log-file docs/a01_baseline/rendered_host.log -- --server --port=27231 --name=A01Host
--path . --script planning/A01_capture_baseline.gd --rendering-driver d3d12 --log-file docs/a01_baseline/rendered_client.log -- --client --port=27231 --name=A01Client
```

The harness exits automatically with a 60-second timeout. It injects movement intent and calls camera mode methods; it is not a human keyboard/mouse playtest. Normal startup/key paths receive separate coverage from existing suites.

## User test card and limits

**Checkpoint:** A01 baseline report, dirty source at the HEAD above; no exported build yet.  
**Changed:** plan checkboxes, this report and isolated evidence tooling; no shipping scripts/settings/scenes modified.  
**Manual launch:** open this project's `project.godot` with Godot 4.7.2 and run the main scene. Press H to host, then J in the host window to open a second joining instance. WASD moves, Shift sprints, V changes view; click the gameplay window to capture controls, Escape releases them.  
**Expected:** current sheltered-island start, two visible crew, owner camera and local/remote movement. This checkpoint does not add voyage gameplay.

- [x] Current source/environment identified.
- [x] All 14 existing suites executed and actual failures retained.
- [x] Isolated failure repeated with captured nonzero exit.
- [x] Rendered host/client actions, captures and process exits verified.
- [x] Four images visually inspected.
- [ ] Human keyboard/mouse comfort and water-level visibility review.
- [ ] Physical multi-machine/WAN impairment tests.
- [ ] Eight-human voyage qualification, long soak and performance budgets.
- [ ] Exported binary runtime verification — A03.

**Next eligible work: A02a**, diagnosis of the reproducible remote-input assertion. A01 is checked off because the requested baseline has been captured, not because every test passed or a user accepted gameplay feel. Keep A02 unchecked until its actual fix and verification are complete.
