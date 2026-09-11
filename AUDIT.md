# Release Readiness Audit

**Project:** WaterEVERYWHERE
**Date of audit:** 11 September 2026
**Premise:** shipping in 7 days, in the state the project was in. Scope: only what already exists.
**Line numbers** refer to the code as it stands after the fixes recorded below; the
original audit was written against the pre-fix files.
**Method:** all 6 verification suites re-run, plus 11 purpose-written probes against the real
scene (player churn, capacity, 120 s storm stability, rider retention, hot-path timing, GPU
shader compile, session cycling, weather-on-join, surface divergence).

> **Status note.** This file records the audit as it was written, with a status line added to
> each finding. Items fixed since are marked and dated; everything else is still open and the
> reasoning still applies. See [Current status](#current-status) for the short version.

---

## Verdict

**Do not ship in 7 days. Two blockers are not shippable defects — they are the absence of
shipping itself.** There is no version control and no export preset, so there is no build to
ship and no way to roll one back. Both are hours of work, not days.

Underneath that, the *simulation* is genuinely release-grade. 120 s in a 19 m/s gale: zero NaN
frames, peak tilt 46°, no runaway. A player rides the raft for 90 s of storm without falling
off. Every shader compiles and renders across all three presets on d3d12. Buoyancy hot path
costs **0.74 ms for 9 bodies** against a 16.67 ms budget. The physics and rendering are not
what will hurt you.

What will hurt you is the **session layer**: three confirmed defects that a player meets in the
first ten minutes of an 8-person game, none of which the existing suites can see, because every
suite tests a 2-peer loopback that never churns.

---

## P0 — Blocks the release

### P0-1 · No version control

> **RESOLVED — 11 Sep 2026.** `git init` on branch `main`, first commit `79954c3`, pushed to
> <https://github.com/ICY0U/water-everywhere>. Tracks source only (134 files, ~1.5 MB);
> `docs/`, `.godot/` and the unreferenced sky HDRIs are excluded. A fresh clone was verified
> to import cleanly and pass four suites.

```
$ git rev-parse --show-toplevel
fatal: not a git repository (or any of the parent directories): .git
```

68k lines, no history. `.gitignore` and `.gitattributes` are already written and correct —
this was intended and never done. Consequences on a 7-day timeline: no bisect when a hotfix
regresses a shader, no rollback, no way to tell a reviewer what changed since yesterday. Every
fix below becomes materially riskier without it.

The README's "Notes for future work" is a list of nine bugs that were once live and had to be
diagnosed the hard way (winding order, `smoothstep(a,a,x)` NaN, particle `return`). That is
precisely the failure class history protects against.

**Fix:** `git init`, commit. Under an hour.

### P0-2 · No export preset — there is no build

> **OPEN.** Still the largest schedule risk.

No `export_presets.cfg`. `config/features` is `("4.7", "Forward Plus")` only. Nothing has ever
been exported; no export templates verified, no binary produced, no packaged run tested. The
d3d12 driver override (`rendering_device/driver.windows="d3d12"`) and the Jolt physics
dependency are both editor-verified only.

This is the single largest schedule risk: first-export problems (missing templates, import
errors, shader cache cold-start stalls) are *routine*, and you would be discovering them on
day 6. **Export a build on day 1**, not day 6 — everything else in this report is verification
against a thing that exists.

---

## P1 — Player-visible defects, confirmed by probe

### P1-1 · The 9th player becomes a permanent ghost

> **OPEN.**

`MultiplayerSpawner.spawn_limit = 8` (`scenes/multiplayer_demo.tscn:215`) vs
`MAX_PLAYERS = 8` (`scripts/network/network_session.gd:48`). ENet's
`create_server(port, max_clients)` counts **clients**, excluding the host — so the server
admits 8 clients + 1 host = 9 bodies, and the spawner refuses the 9th.

Probe result:

```
ERROR: Spawn limit reached!
GHOST roster=9 bodies=8
GHOST in roster but NO body: [307]
```

The 9th player connects, appears in everyone's roster, and has **no body, no camera target,
and no recovery path**. `_spawner.spawn()`'s return value is discarded at
`scripts/network/multiplayer_game.gd:209`, so nothing notices.

**Fix:** `spawn_limit = 9`, or `MAX_PLAYERS = 7`. Plus check the spawn return and reject the
peer cleanly. Under an hour.

### P1-2 · Two players get the same colour after anyone leaves

> **RESOLVED — 11 Sep 2026.** `_free_color_index()` in `scripts/network/multiplayer_game.gd`
> now allocates the lowest colour not in use. Covered by
> `tools/verify_session_identity.gd`, which reproduces the exact churn below and fails
> against the old code.

`color_index` is `_players.get_child_count()` (`scripts/network/multiplayer_game.gd:214`, since fixed) — a
count, not an allocation. It is reused the moment a player leaves.

Probe result — peers join 101/102/103, 102 leaves, 104 joins:

```
CHURN   name=103 colour=(0.929, 0.741, 0.286, 1.0)
CHURN   name=104 colour=(0.929, 0.741, 0.286, 1.0)   <-- identical
```

The project's entire player-identification design is colour (`PLAYER_COLORS` exists "so the two
windows are told apart instantly"). After one disconnect — the most common event in any session
— two players are visually indistinguishable. There are 8 colours for up to 9 bodies, so
exhaustion is reachable even without churn.

**Fix:** allocate the lowest colour index not currently in use. ~10 lines.

### P1-3 · Late joiners get the wrong ocean — 5.55 m of surface disagreement

> **RESOLVED — 11 Sep 2026.** `_send_current_weather_to()` sends the applied preset to each
> joining peer via the existing `_broadcast_weather` RPC; `WeatherController.current_index()`
> was added to expose it. Verified across a real ENet loopback: the joiner adopts the
> server's preset and both sides derive 19.0 m/s, with worst surface disagreement 0.0000 m.
> The suite's control measures 5.66 m for an uninformed joiner, independently reproducing
> the figure below.

Weather is broadcast only on *change* (`scripts/network/multiplayer_game.gd:280`, since fixed). Nothing
sends current weather on join, and `WeatherController._ready()` applies `starting_index = 0`
locally.

```
WX server after storm index=2 wind=19.0
WX late joiner      index=0 wind=8.5   <-- should be 2 / 19.0
```

This is not cosmetic. `wind_speed` drives the Pierson-Moskowitz spectrum, so the client's
*physics surface* differs from the server's:

```
DIV sig wave height: sunny=1.55m stormy=7.73m
DIV worst surface disagreement = 5.55 m
```

Buoyancy is server-authoritative, so the client receives transforms solved against a sea it is
not drawing. The raft and every player visibly float in mid-air or sunk, by up to 5.55 m. Any
player joining a session where weather was ever changed gets a broken game.

**Fix:** send current weather index in `_on_player_joined`, or fold it into the spawn payload.
~5 lines. **Highest severity-to-effort ratio in this report.**

### P1-4 · Ocean clock has no latency compensation

> **OPEN.** The most player-visible item still outstanding, and one no local test can catch.

`scripts/network/multiplayer_game.gd:92-104`. The server sends `ocean.elapsed_time` raw every
0.5 s; the client adopts and integrates. Nothing subtracts one-way trip time, so **every client
renders a sea permanently one latency behind the server's**, against which buoyancy was solved.

Invisible on loopback — which is why all suites pass. At 80 ms RTT a client is ~40 ms stale;
with 7.73 m storm waves and ~8 m/s phase speed that is a visible vertical offset on every hull.
The clamp (0.012 s/frame ≈ 0.72 s of drift absorbed per second) has ample headroom; it is
simply never given a compensated target.

**Fix:** add half-RTT at send or receive. A handful of lines.

---

## P2 — Ship-blocking UX gaps

### P2-1 · No quit, and no pause

> **OPEN.**

Grepping all of `scripts/` for `quit()`, `NOTIFICATION_WM_CLOSE`, or `paused` returns
**nothing**. ESC is bound to mouse-capture toggle (`scripts/network/player_camera.gd:155`). The
game is windowed (no `window/mode` in `project.godot`), so Alt+F4 works and this is not a trap
— but there is no in-game exit, and a shipped game needs one.

### P2-2 · Multiplayer is localhost-only in practice

> **OPEN.** Either a small feature or a release-notes scoping decision.

`join()` accepts an address (`scripts/network/network_session.gd:112`), but **nothing ever
passes one**. The keybind calls bare `NetworkSession.join()` → `127.0.0.1`
(`scripts/network/multiplayer_game.gd:118`); `role_from_command_line()` parses
`--server`/`--client`/`--name=` but has no `--address=`. There is no text field — the only UI
is a debug `Label`.

So the advertised two-player feature is **same-machine only**. The plumbing is complete and
correct; only the entry point is missing. Either add an address field / `--address=` argument,
or scope the release honestly as local/LAN-with-manual-config.

### P2-3 · Failures are invisible to the player

> **OPEN.**

`_on_connection_failed` and `_on_server_disconnected` call `push_warning`
(`scripts/network/network_session.gd:280-287`) — console only. `_join_with_retries` likewise
ends in `push_warning`. The HUD reverts to `"Offline"` with no reason given. A player whose host
quit, or who typed the wrong port, sees no distinction from never having tried.
`session_ended(reason)` already carries the text; `_refresh_status` just ignores it.

---

## P3 — Maintainability risks that will bite during the 7 days

### P3-1 · The wave spectrum is maintained in three hand-copied places

> **OPEN.** Highest-value maintainability fix.

`shaders/gerstner_waves.gdshaderinc` exists as the shared GPU source of truth and is included
by 4 shaders. The two most important consumers do not use it:

| Location | What it duplicates |
|---|---|
| `shaders/ocean.gdshader:212-260` | `WAVE_COUNT`, both 8-element offset tables, `LONGEST_WAVE_SPREAD`, `octave_direction()`, full summation |
| `shaders/foam_sim.gdshader:79-110` | a third copy of the same |
| `scripts/wave_field.gd:32` | the CPU copy — legitimately separate (different language, documented) |

The CPU/GPU split is well-justified. The GPU/GPU split has **no comment explaining why these
two opt out** of the include written for them. Three copies of eight constants that must agree
bit-for-bit; `wave_field.gd:30` names only *two* of the files needing sync.

Critically: `verify_spray.gd` compares the *include* against the CPU (0.0097–0.0167 agreement).
It never compares `ocean.gdshader`'s private copy against anything. **The one divergence that
would silently desync the rendered surface from the physics is the one divergence the suite
cannot catch** — and it sits in the file most likely to be touched for last-minute art
direction.

### P3-2 · Both demo scenes inline the same 40-parameter material

> **OPEN.** Additional evidence found 11 Sep 2026: both scene instances in a single process
> resolve to *one shared* `WaveField` resource instance (`shared=true` by instance id). Across
> separate processes this is harmless, but any in-process test that tries to make two peers
> disagree will silently measure 0.00 m and pass for the wrong reason.

`multiplayer_demo.tscn` and `ocean_demo.tscn` each carry their own `ShaderMaterial_ocean`
(40 `shader_parameter/` lines), `ShaderMaterial_foam`, and `Resource_wavefield` as inline
`SubResource`s. I diffed them: **byte-identical today** — latent risk, not present breakage.
But `verify_spray.gd` and `verify_reactions.gd` both load `ocean_demo`, so one art tweak to the
multiplayer scene and the suite starts validating a sea the game no longer renders.
`resources/weather/*.tres` proves the extraction pattern is already understood.

### P3-3 · `tools/verify_raft.gd` is below the project's own bar

> **PARTIALLY RESOLVED — 11 Sep 2026.** It is now listed in the README file table and its
> run-commands block. The style items below (no `##` class doc, over-long lines, untyped
> `var failures := 0`, wall-clock `await`) are still open.

Newest file in the project, and the only one breaking documented conventions: no `##` class
doc, no `.uid` (unlike all 11 neighbours), five lines over the 100-col `.editorconfig` limit
(one at 154), untyped `var failures := 0`, a wall-clock `await create_timer(10.0)` where other
suites assert on physics frames, and absent from both the README file table and its
run-commands block. Its 11 checks pass and are useful — but it is the file someone will copy
next.

### P3-4 · Smaller items

- **No test runner / CI.** *(Open.)* Suites must be pasted one at a time, with a different
  invocation for the GPU suite. Every suite is explicitly built to exit non-zero "so it is
  usable from CI" — and nothing uses them that way.
- **`MAX_CONTACTS = 8` declared twice** — *(Open.)* `scripts/ocean.gd:95` and
  `scripts/foam_field.gd:28`. Must agree (ocean fills the arrays foam reads); neither comment
  says so.
- **Orphan `probe_spawn.gd.uid`** pointing at a deleted script.
  *(Resolved — 11 Sep 2026, deleted.)*
- **Stale comment:** *(Open.)* `tools/verify_multiplayer.gd:408` states "a `--script` run has
  no main loop, so autoloads are never created." I probed this — autoloads *are* created under
  `--script` in 4.7.2 (`NetworkSession` is present at `root`). The workaround is harmless and
  the test is arguably better for it, but the stated reason is wrong and would mislead someone
  refactoring it.

---

## What I verified as sound

Worth stating plainly, so effort goes to the right places:

- **Wave physics** — 12/12 checks. Dispersion exact to 1e-6, significant wave height within
  0.1%, no self-intersection at max steepness (min Jacobian 0.4901), deterministic sampling.
- **Buoyancy** — 13/13. Archimedean draught exact to 0.003 m across cube/raft/sphere; hull
  shape genuinely changes draught (0.776 m vs 0.129 m); beamy hull stays upright.
- **GPU/CPU parity** — 12/12 across breeze and gale, worst error 0.0167.
- **Storm stability** — 120 s at 19 m/s: 0 NaN frames, tilt 46.3°, peak speed 8.44 m/s, no
  drift.
- **Core loop** — player rides the raft 90 s of gale, never falls off, settles on deck.
- **Shader compile** — all presets render 45 frames each on d3d12, no errors. (This matters:
  particle `return` restrictions are compile-time-only and invisible headless.)
- **Session cycling** — host → leave → rehost leaks no bodies; camera re-targets correctly.
- **Hot path** — 0.74 ms for 9 bodies. `hull_detail` is effectively inert at current collider
  complexity (32/128/512 all ~30 µs), so the 128 default is harmless.

One correction to the earlier audit pass: it reported p95 physics at 20.7 ms against a 16.67 ms
budget. That was wrong — the figure was `await physics_frame` wall-clock including headless
frame pacing, and it stayed flat at 13.8/20.7 ms from 1 body to 8, which is what exposed it.
Direct instrumentation gives 0.74 ms for 9 bodies. **There is no performance problem.**

---

## Recommended 7-day plan

As written at the time of the audit.

| Day | Work |
|---|---|
| **1** | `git init` + commit (P0-1). **Export a build** and run it (P0-2) — discover export problems now, not on day 6. |
| **2** | P1-3 weather-on-join (~5 lines, worst defect per unit effort). P1-1 spawn off-by-one. P1-2 colour allocation. Re-run all 6 suites. |
| **3** | P1-4 half-RTT clock compensation. Add a churn/capacity case to `verify_multiplayer` so P1-1/P1-2 can never silently return. |
| **4** | P2-1 quit. P2-3 surface `session_ended(reason)` in the HUD. Decide P2-2: ship an address field, or scope the release as local-only and say so. |
| **5** | P3-1 collapse the shader triplication behind the existing include; extend `verify_spray` to compare `ocean.gdshader` itself. Highest-value maintainability fix. |
| **6** | Test runner script. P3-2 extract shared materials to `.tres`. P3-3/P3-4 tidy. |
| **7** | Full suite on an **exported build**, not the editor. Freeze. |

Day 2's three fixes total well under 50 lines and close every confirmed player-facing defect.
If the week compresses, days 1–2 are the irreducible minimum — and P2-2 becomes a release-notes
scoping decision rather than a code change.

---

## Current status

As of 11 September 2026.

| ID | Finding | Status |
|---|---|---|
| P0-1 | No version control | **Resolved** — pushed to GitHub |
| P0-2 | No export preset | Open — largest schedule risk |
| P1-1 | 9th player becomes a ghost | Open |
| P1-2 | Colour reused after churn | **Resolved** — covered by a suite |
| P1-3 | Late joiners get the wrong ocean | **Resolved** — covered by a suite |
| P1-4 | Ocean clock has no RTT compensation | Open |
| P2-1 | No quit or pause | Open |
| P2-2 | Multiplayer is localhost-only | Open |
| P2-3 | Failures invisible to the player | Open |
| P3-1 | Wave spectrum copied three times | Open |
| P3-2 | Demo scenes inline the same material | Open |
| P3-3 | `verify_raft.gd` below the bar | Partially resolved — listed in README |
| P3-4 | Orphan `.uid` | **Resolved** — deleted |
| P3-4 | No test runner / CI, duplicate `MAX_CONTACTS`, stale comment | Open |

### Known failing checks

Two suites have failing checks that **predate** the fixes above; both were confirmed to fail
identically against the pre-fix code, so neither is a regression. Both are wall-clock-timed
physics-settling assertions:

- `tools/verify_multiplayer.gd` — `remote input drives real physics`
- `tools/verify_raft.gd` — `player settles on deck`, `second player supported`

### Suggested next step

**P1-4 (ocean clock RTT)** is the highest-value open item that affects what a player
experiences, and it cannot be caught by any local test — loopback has no latency to compensate
for. **P0-2 (export a build)** remains the biggest unknown on any real timeline.
