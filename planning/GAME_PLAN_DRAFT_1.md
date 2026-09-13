# WaterEVERYWHERE — Game Design & Production Plan

**Working title:** Lost at Sea
**Document status:** Draft 1 — design agreed in principle, not yet validated by a playable slice
**Date:** 13 September 2026
**Engine:** Godot 4.7.2 (Jolt physics, d3d12)
**Target:** 2–8 player cooperative voyage, 25–40 minute sessions

---

## Table of contents

1. [Premise](#1-premise)
2. [Design pillars](#2-design-pillars)
3. [The core loop](#3-the-core-loop)
4. [Systems design](#4-systems-design)
5. [World and content](#5-world-and-content)
6. [Multiplayer architecture](#6-multiplayer-architecture)
7. [What already exists](#7-what-already-exists)
8. [Production plan](#8-production-plan)
9. [Milestone 0 — the two-day slice](#9-milestone-0--the-two-day-slice)
10. [Risks and open questions](#10-risks-and-open-questions)
11. [Decisions to make before coding](#11-decisions-to-make-before-coding)
12. [Verification strategy](#12-verification-strategy)
13. [Appendix: engine facts that constrain design](#appendix-engine-facts-that-constrain-design)

---

## 1. Premise

Your raft breaks apart in a storm, far from shore. You and your friends are scattered
in open water. The mainland is kilometres away and you cannot swim it. Between you and
home is a chain of small islands with the materials to rebuild.

**The voyage home is the game.**

### Why this premise

It is chosen to fit an unusually strong simulation that already exists. The project has
production-grade deep-water wave physics, real buoyancy with hull clipping, simulated
foam, weather that drives sea state, and verified 8-player server-authoritative
networking — and no gameplay attached to any of it. This premise puts the ocean at the
centre of every decision the player makes, rather than treating it as a floor.

The design test applied to every feature below is: **does the state of the sea change
what the player decides to do?** Features that fail that test are cut or deferred.

### Tone

Chaotic, funny, forgiving. Intended to be played with friends on voice chat. Physical
comedy is a feature: being swept off the raft by a wave should be a story, not a
punishment. Individual failure is cheap and funny; group failure — losing the raft,
losing the weather window — is what carries weight.

This is explicitly **not** a survival-sim. No hunger, no crafting trees, no inventory
management. One resource, one vessel, one direction of travel.

---

## 2. Design pillars

### P1 — The sea is the antagonist

Not an obstacle course, not scenery. Wind speed drives a Pierson–Moskowitz spectrum
that determines wave height, and that single number changes whether a crossing is
routine or desperate. Every other system hangs off it.

### P2 — The raft is the character

The vessel persists, degrades and improves across the voyage. Players are expendable
and recoverable; the raft is not. Attachment to an object the group maintains together
is what makes the losses land.

### P3 — Capacity forces negotiation

The raft cannot carry everyone and everything. Every departure is an argument. This is
the social engine of the game, and it emerges from two numbers (capacity, weather)
rather than from designed content.

### P4 — Readable danger

Players must be able to see danger coming and choose to accept it. A storm that arrives
without warning is unfair. A storm you watched build for two minutes while arguing is
the best moment in the game.

### P5 — Degrade, never halt

A run gets worse rather than ending. Arriving with three of five players on a
half-sunk raft is a valid, memorable ending. Hard failure states that boot everyone to
a menu at minute 30 are forbidden.

---

## 3. The core loop

A **run** is one voyage from the wreck site to the mainland. Target 25–40 minutes.

```
   THE WRECK  ──►  REGROUP  ──►  ┌─────────────────────────────┐  ──►  ARRIVAL
   (scripted)      (~3 min)      │   THE VOYAGE (repeating)    │       (scored)
                                 │                             │
                                 │   CROSSING ──► LANDFALL     │
                                 │      ▲            │         │
                                 │      │            ▼         │
                                 │   DEPART ◄──── GATHER       │
                                 └─────────────────────────────┘
                                      2–4 islands per run
```

### Phase 1 — The wreck (scripted, ~60 s)

Players begin **together, standing on a raft**, mid-ocean, in heavy weather. After a
short grace period the raft breaks apart beneath them.

> **Design note.** An earlier version of this concept started players already scattered
> in the water. Starting them on a doomed raft is strictly better: it gives the scatter
> a cause, it teaches deck movement and the camera before anything is at stake, and it
> establishes the vessel the whole game is about. The wreck is simultaneously the
> tutorial, the inciting incident and the difficulty dial.

### Phase 2 — Regroup (~3 min)

Players are in open water, separated by tens of metres, with debris floating nearby.
Objectives, in the order players will discover them:

- Find something that floats and hold on.
- Find each other.
- Assemble enough debris to make a vessel that can be steered.

This phase is deliberately disorienting. At water level in a 2 m swell you cannot see
far, which is either excellent tension or complete misery — **this is the single
biggest open question in the design** (see §10).

### Phase 3 — The voyage (repeating, ~6–10 min per leg)

Each leg is a crossing followed by a landfall.

**Crossing.** Steer the raft toward the next island. Threats: weather turning, damage
from slams, players washed overboard, cargo lost.

**Landfall.** The approach is itself a hazard — surf, rocks, a beach you can wreck on.

**Gather.** Islands hold materials to repair and improve the raft. Time spent here is
time the weather is changing.

**Depart.** A capacity decision. Who and what comes aboard.

### Phase 4 — Arrival (scored)

Reaching the mainland ends the run. The run is scored on what arrived, not merely that
something did:

| Scored | Notes |
|---|---|
| Players brought home | The headline number |
| Raft condition | Rewards careful sailing |
| Materials carried | Rewards greed, punished by capacity |
| Time taken | Secondary; discourages infinite caution |
| Worst wave survived | Flavour, but it is what people screenshot |

A **run summary** screen names who was lost and where, the roughest sea endured, and
the final condition of the raft. This is the shareable artefact of the session and
deserves real design attention despite being cheap to build.

---

## 4. Systems design

### 4.1 The raft (P2)

The central object. Server-simulated `RigidBody3D` extending the existing
`BuoyantBody`.

**Condition.** A scalar 0.0–1.0. At 1.0 the raft is seaworthy; as it falls, buoyancy
and handling degrade. At 0.0 the raft is lost and the group is back in the water — a
setback, not a run-ending failure (P5).

**Damage sources.** Primarily slam impacts. The engine already emits these: a
`WaterImpact` with `kind == SLAM` carries an `energy` field in joules and an `impulse`
in newton-seconds. Damage should scale from **energy**, which is explicitly documented
as the measure of violence, rather than from raw speed.

A slam is only emitted when a body was nearly still and then struck the water above
`SLAM_SPEED_THRESHOLD` (3.0 m/s), which is exactly the "dropped off a crest" event this
system wants. **This means the damage model is close to free** — the hard part is
already built and verified.

**Repair.** Consumes materials, takes time, must happen ashore.

**Upgrade.** Capacity, durability, speed. Choose one axis per island; do not build a
tree.

**Propulsion.** The raft currently has none, which is also an outstanding audit finding
(the raft is presently dead content in the main scene). Options, cheapest first:

1. **Paddling** — players aboard apply thrust. Trivially fits the existing input model,
   makes crew size matter, and scales naturally with how many people you brought.
2. **A sail** — introduces wind direction as a tactical concern, since wind angle
   already exists in the weather presets.
3. **Full sailing with tacking** — a modelled system, roughly a week, and it turns the
   game into a sailing game. Deferred.

**Recommendation: paddling for the first playable, sail as the first upgrade.**

### 4.2 Capacity (P3)

The raft has a finite number of slots shared between people and cargo. Overloading is
*permitted* and physically punished rather than blocked: more mass sits lower in the
water, which the buoyancy solver models honestly, so an overloaded raft genuinely slams
harder and takes more damage.

This is the design's best example of letting physics carry a rule instead of writing
one. No arbitrary "too heavy" message — the sea enforces it.

### 4.3 Weather and the forecast (P1, P4)

Weather is server-owned and already replicates correctly, including to late joiners.
Three presets exist and are tuned: sunny (8.5 m/s wind), overcast (11.5), stormy (19.0).

A run follows a weather **schedule** the server advances, so the sea gets worse as the
voyage goes on and the last leg is the hardest.

> **Important engine constraint.** `WeatherPreset.apply()` is documented as a *discrete*
> change, not a transition — the codebase deliberately authored each mood as a
> standalone look rather than a point on a blend curve. **There is no cross-fade
> machinery.** Two options:
>
> - **Cheap (recommended for first playable):** keep the snap, but add a *forecast
>   layer* — a server-owned countdown surfaced through in-world cues (darkening on the
>   horizon, rising spray, audio) that tells players a change is coming before it lands.
>   Satisfies P4 without touching the preset system.
> - **Expensive:** build interpolation between presets. Roughly 60 tunable fields, many
>   of them colours, and the art direction was explicitly chosen to avoid compromise
>   states. Do not attempt this before the loop is proven.

### 4.4 Players in the water

Already largely built. The player is a buoyant body with a three-state stance machine —
`GROUNDED`, `FLOATING`, `AIRBORNE` — with hysteresis derived from measurement rather
than guesswork, and the stance is replicated rather than recomputed per-peer.

**What to add:**

- **Exhaustion.** Swimming is currently unlimited, which removes the raft's reason to
  exist. Some cost to open-water swimming is required — not as a survival stat, but as
  the constraint that makes the vessel necessary.
- **Drifting (downed) state.** A player who goes under becomes recoverable rather than
  dead (P5). Finding them costs time; time costs weather. This is mechanically the same
  as chasing lost cargo and should share an implementation.
- **Hauling.** One player can drag another. Reliably the funniest interaction in this
  genre and the clearest visual signal that the group is a group.

### 4.5 Signalling

Players need in-world communication even on voice chat: pointing, a lantern, a flare, a
whistle. Cheap to build, disproportionate effect on feel, and it makes spotting a
drifting player land as a moment rather than an inventory event.

### 4.6 Materials

**One** material type for the first playable. Resist the urge to add a second until the
loop is proven fun. Materials are physical objects in the world that occupy capacity —
not an abstract counter — so that carrying them is a decision with a physical cost.

---

## 5. World and content

### Existing geography

The archipelago is already built and verified deterministic across peers.

| Island | Position (X, Z) | Plateau radius | Notes |
|---|---|---|---|
| HomeIsland | 0, 0 | 78 m | Largest; owns the shoreline surf |
| ExplorationIsland | 430, −550 | 280 m | Mountainous, has a verified climbable route |
| WestCove | −280, −95 | 25.2 m | Small rocky islet |
| SouthShoal | −175, 300 | 19.2 m | Low sandy island |
| PassageRock | 135, −255 | 17.4 m | Landmark |
| EastCay | 365, 165 | 28.8 m | Broad small island |
| FarCay | 900, −80 | 25.2 m | Outlying — the "is it worth it" island |
| 6 backdrop ranges | ~1.7–2.0 km | — | Silhouettes, no collision |

### Repurposing for the voyage

The mainland is new content: a large landmass at one end of the route, with the wreck
site at the other. **Size the voyage at roughly 2.5 km.**

> **Engine constraint.** The ocean is drawn as 8 concentric LOD rings that recentre on
> the camera, reaching **3,072 m from the viewer**. Nothing in the codebase assumes a
> bounded world, so a long voyage is safe — but 2.5 km leaves comfortable margin inside
> the ring extent. Do not design a 4 km route without first testing the surface at that
> range.

### Island identity (P3)

Interchangeable islands make gathering a chore. Each island on the route needs one
distinguishing trait that makes it a *choice*:

- **Plentiful but exposed** — good materials, nowhere to shelter from weather.
- **Sheltered but barren** — safe to wait out a storm, costs time.
- **Good materials, bad approach** — surf and rocks; you can wreck on arrival. (The
  surf system exists and is currently enabled on exactly one island.)
- **Off-route** — a detour that costs a weather window.

The existing islands already differ in size, height and shape. Lean on that before
adding new systems.

---

## 6. Multiplayer architecture

Multiplayer is a standing requirement: every system must be designed for replication
before it is built. The existing architecture is sound and should not be renegotiated.

### The established model

- **Server-authoritative.** The server simulates all shared physics. Clients own only
  their `PlayerInput` node and publish intent.
- **The ocean is not replicated.** Every peer derives identical water from the same wind
  speed and a shared clock. This is why the sea costs nothing on the wire.
- **The ocean clock is corrected, not predicted.** Clients converge toward the server's
  time with latency compensation and a per-frame correction clamp.

### Classification of new systems

Every new system must be classified before implementation:

| System | Classification | Rationale |
|---|---|---|
| Raft transform | **Server-authoritative, replicated** | Already works this way |
| Raft condition | **Server-authoritative, ON_CHANGE** | A state, not a stream; changes rarely |
| Cargo / materials | **Server-authoritative rigid bodies** | Same pattern as the raft |
| Carried/held state | **Server-owned** | Clients request, server decides |
| Player stance | **Server-decided, replicated** | Already correct; do not recompute per-peer |
| Downed/drifting state | **Server-owned, ON_CHANGE** | Reliable delivery matters |
| Run phase / score | **Server-owned, pushed whole** | Mirror the roster pattern |
| Weather schedule | **Server-owned** | Already broadcasts correctly |
| Forecast cues | **Derived from replicated schedule** | Cosmetic; derive, do not send |
| Signalling (flare etc.) | **Server-relayed event** | Like the existing impact RPC |

> **Rule inherited from existing code:** visual systems must never read values that only
> the simulating peer computes. A remote body's submersion reads 0.0 forever on
> non-authority peers. Anything cosmetic must derive from *replicated* state.

### Spawning new object types

> **Engine constraint.** The scene's `MultiplayerSpawner` has `spawn_limit = 8`, and a
> passing test (`verify_session_identity`) asserts that this equals `MAX_PLAYERS`
> because each player consumes exactly one body. **Do not raise that limit to make room
> for crates or debris** — it would break a test that exists for a real reason. Give
> cargo and debris their **own** `MultiplayerSpawner` with its own `spawn_path` and
> `spawn_function`.

### Known accepted limitation

The host is the simulation authority, so **if the host leaves, the run ends for
everyone.** For a game built on 30-minute sessions with friends this is a real cost.
Decide explicitly whether to accept it (see §11).

---

## 7. What already exists

Understanding what is already paid for is what makes this plan cheap.

### Production-grade, verified

| System | State |
|---|---|
| Wave physics (Pierson–Moskowitz, 8 octaves, CPU/GPU parity) | Done |
| Buoyancy, hull clipping by divergence theorem, added mass | Done — 0.74 ms for 9 bodies |
| Impact model (entry / exit / slam with energy and impulse) | Done |
| Foam simulation, spray, spindrift, rain | Done |
| Cel shading: ocean, sky, terrain, outlines | Done |
| Weather presets driving sky, sun, fog, sea state | Done |
| Server-authoritative multiplayer, 8 players | Done |
| Late-join correctness (weather, ocean clock, roster) | Done |
| Locomotion, deck movement, stance machine | Done |
| Character model with animation, stride matching | Done |
| Island terrain, deterministic across peers | Done |
| 14-suite automated verification | 13/14 passing |

### Does not exist

Everything that makes it a game: objectives, run state, scoring, resources, raft
condition, raft propulsion, capacity, exhaustion, signalling, a downed state, a
mainland, persistence, menus, and an exported build.

### Immediate blockers to address first

These are outstanding findings from the project audit and should be cleared before or
alongside Milestone 0:

1. **Uncommitted work.** A large body of work — the entire island/archipelago/character
   milestone — is currently untracked. Commit before building anything new.
2. **No export preset.** Nothing has ever been exported, so first-export problems are
   entirely undiscovered. This is the oldest open blocker.
3. **`docs/` is gitignored** while the README links into it. This document is therefore
   placed at the repository root, not in `docs/`, so that it is actually tracked.
4. **The `water_subjects` group does double duty** — it is used both for water reactions
   and to find rafts for boarding. Adding any second floating object will cause the
   board action to target the wrong thing. **Fix this before adding cargo.**
5. **`playable_islands` group is declared on all seven islands and never read.** It is
   the natural registry for island state in this design.

---

## 8. Production plan

Sequenced so that the riskiest assumption is tested first and each milestone produces
something playable.

### Milestone 0 — Is this fun? (2 days)

See §9. A deliberately incomplete slice that answers one question.

### Milestone 1 — The vessel (4–5 days)

- Raft propulsion (paddling)
- Raft condition and slam damage
- Capacity limits
- Repair ashore
- **Exit criteria:** a group can cross open water, take damage, and repair.

### Milestone 2 — The voyage (5–7 days)

- Multi-leg route with the mainland as destination
- Island identity traits
- One material type, physically carried
- Weather schedule with forecast cues
- **Exit criteria:** a complete run start to finish, with decisions that matter.

### Milestone 3 — The group (4–5 days)

- Exhaustion
- Downed/drifting state and recovery
- Hauling another player
- Signalling
- **Exit criteria:** losing and recovering a player is a memorable event.

### Milestone 4 — The run (3–4 days)

- Run state machine, scoring, summary screen
- Lobby and run restart without relaunching
- **Exit criteria:** a group plays three runs back-to-back without touching a terminal.

### Milestone 5 — Shippable (unknown, ≥1 week)

- Export preset and a real build — **first-export problems are undiscovered**
- Menus, settings, key rebinding
- Join-by-address in the UI rather than a launch argument
- Audio pass
- **Exit criteria:** someone who is not the developer can play it.

**Estimated total to a rough but complete game: 4–6 weeks of focused work.** Milestone 5
is the least predictable; treat its estimate with suspicion until an export exists.

---

## 9. Milestone 0 — the two-day slice

The purpose of this milestone is **not** to build the game. It is to answer one
question before committing weeks to the design:

> **Is being in this ocean with your friends fun for twenty minutes?**

### Scope

Deliberately minimal:

- Players start on a raft that breaks apart after ~60 seconds.
- They are scattered into open water.
- **One** island sits between the wreck site and the mainland.
- Reaching the mainland ends the run with a trivial summary.

**Explicitly excluded:** materials, repair, damage, capacity, exhaustion, upgrades,
scoring, signalling, menus. Adding any of them defeats the purpose.

### What it tests

| Question | Why it matters |
|---|---|
| Is swimming at water level tense or miserable? | Decides whether the genre works at all |
| Can players find each other without frustration? | The regroup phase depends on it entirely |
| Is the wreck moment effective? | It is the hook |
| Does the raft feel worth protecting? | Pillar P2 rests on this |
| Is 20 minutes the right length? | Determines the whole session structure |

### Success criteria

Qualitative and honest. After playing with 2–4 people:

- Players talk to each other unprompted about what to do next.
- Someone laughs at the physics at least once.
- Nobody asks "what am I supposed to be doing?" after the first two minutes.
- At least one moment is retold afterwards.

If swimming is tedious and finding each other is frustrating, **the premise needs
rework and it is far cheaper to learn that now.**

### Predicted first finding

Swim speed and visibility at water level will dominate everything. A player floating in
a 2 m swell cannot see over the crests. Whether that is brilliant tension or complete
misery cannot be determined by reading code — it must be played. Expect to tune swim
speed, wave height at the wreck site, and camera height early.

---

## 10. Risks and open questions

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| R1 | Swimming is boring; the regroup phase is tedious | **High** | Milestone 0 tests exactly this before anything is built on it |
| R2 | Water-level visibility makes the game frustrating | **High** | Tune wave height at wreck site; consider a brief raised camera |
| R3 | Carrying/attaching cargo to a moving raft is a hard physics problem | Medium | The one genuinely new physics work; prototype in isolation |
| R4 | Host departure ends the run | Medium | Accept for now; document it in-game |
| R5 | Weather has no transition machinery | Medium | Use forecast cues rather than building interpolation |
| R6 | Scope creep into survival-sim | Medium | One material, one vessel. Re-read the pillars |
| R7 | First export reveals platform problems | Medium | Export early, in Milestone 1, not at the end |
| R8 | 8-player sessions untested for this loop | Low | Existing suites cover 8-player churn |

---

## 11. Decisions to make before coding

These are expensive to change later and should be settled now.

**D1 — Do runs persist, or is each self-contained?**
*Recommendation: self-contained.* It suits the session length, it suits friends dropping
in and out, and persistence is an entire additional pillar — save format, authority over
saved state, and what happens when the host holding the save leaves.

**D2 — Is host migration in scope?**
*Recommendation: no, not initially.* But decide deliberately, because it becomes far more
expensive to retrofit once run state exists.

**D3 — What is the failure state?**
*Recommendation: there isn't one.* Per P5, a run degrades. Losing the raft is a setback;
losing everyone is a scored ending, not a boot to the menu.

**D4 — Paddling or sailing?**
*Recommendation: paddling first.* Sailing is a genre change and roughly a week of work.

**D5 — How many players is this balanced for?**
*Recommendation: tune for 3–4, support 2–8.* Capacity tension needs at least three.

---

## 12. Verification strategy

The project has a strong existing testing culture — 14 suites run from a single command
with one exit code — and new systems should extend it rather than bypass it.

### Principles carried over from existing work

- **Measure settled behaviour, not a single frame.** Fixed wave phases make one reading
  reproducible but not representative. Let bodies settle before sampling, and assert the
  state at the moment sampling begins.
- **Verify visually as well as numerically.** A green suite and a clean compile still
  miss geometry deleted by NaN.
- **A harness that scores "no verdict" as a pass turns any accident into a green board.**
  The existing runner already guards against this.

### New suites required

| Suite | Asserts |
|---|---|
| `verify_raft_damage` | Slam energy maps to condition loss; no damage from ordinary swell |
| `verify_capacity` | Overloaded raft sits lower and takes more damage; limits enforced server-side |
| `verify_run_state` | Phase transitions replicate; a late joiner receives current phase |
| `verify_downed` | Downed state replicates; recovery works; no per-peer disagreement |
| `verify_cargo` | Cargo replicates like the raft; survives host-side churn |

### Outstanding test debt

One check currently fails — `verify_multiplayer` → `remote input drives real physics` —
and it is a **defect in the test, not in gameplay code.** The harness builds an ocean
with no wave field, so the water is flat and a body spawned at the origin is still
*falling* when the check samples it. During that window the body is `AIRBORNE`, thrust
does not apply at all, and the measured displacement is meaningless.

Reproduced in isolation:

| Settle before sampling | Stance at start | Displacement over 0.7 s |
|---|---|---|
| 0.30 s (what the suite does) | AIRBORNE | **+0.015 → FAIL** |
| 1.50 s | FLOATING | −17.371 → PASS |
| 3.00 s | FLOATING | −21.738 → PASS |

**Fix:** settle the body to `FLOATING` before sampling, and assert the stance at that
moment. Do not widen the threshold. Roughly a three-line change.

---

## Appendix: engine facts that constrain design

Verified against the codebase on 13 September 2026. These are the facts most likely to
invalidate a design assumption.

| Fact | Consequence for design |
|---|---|
| `WeatherPreset.apply()` is discrete by design; no cross-fade exists | Forecast must be a signalling layer, not a preset blend (§4.3) |
| `MultiplayerSpawner.spawn_limit = 8`, asserted equal to `MAX_PLAYERS` by a passing test | Cargo needs its own spawner; do not raise the limit (§6) |
| Ocean LOD rings reach 3,072 m from the viewer | Size the voyage ≈2.5 km (§5) |
| Nothing in the codebase assumes a bounded world | Long voyages are safe |
| `SLAM` impacts carry `energy` (joules) and `impulse` (N·s) | Damage model is nearly free; scale from energy (§4.1) |
| Slams require the body to have been nearly still, then exceed 3.0 m/s | Slams already mean "dropped off a crest" |
| Submersion is only computed on the simulating peer; reads 0.0 elsewhere | Never derive visuals from it on remote peers (§6) |
| Player stance uses measured hysteresis (1.0 s grace vs 0.35 s longest trough) | Do not retune casually; the numbers came from measurement |
| The ocean is derived from wind speed + shared clock, not replicated | Sea state costs nothing on the wire |
| Weather sets the wind speed the wave spectrum derives from | A peer on the wrong preset floats off the surface entirely |
| `water_subjects` group is used for both water reactions and raft-finding | Must be split before adding floating objects (§7) |
| Player: thrust 14.0 N/kg, walk 3.4 m/s, sprint ×2.4 | Baseline for tuning swim speed and exhaustion |
| Weather wind speeds: 8.5 / 11.5 / 19.0 m/s | The three sea states available today |
| Host is simulation authority; departure ends the session | Accepted limitation (§6, D2) |

---

*Companion documents: `docs/AUDIT.md` (release-readiness audit), `docs/island_world.md`
(world layout), `docs/raft_integration.md` (raft physics and validation). Note that
`docs/` is currently excluded from version control.*
