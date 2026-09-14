# Water EveryWhere — Game Design and Testable Production Plan

**Revision:** 2 • 13 September 2026  
**Status:** production plan in progress. A01-A04 complete: baseline captured, the one failing suite fixed, a Windows build exported and verified, and a voyage scene with an authoritative run phase added. B01 propulsion is implemented and verified headlessly but its human gate is open, so it is `READY FOR USER TEST` rather than complete. **17/17 suites now pass.** See [A01](planning/A01_BASELINE.md), [A02a](planning/A02A_REMOTE_INPUT_FIX.md) and [A03/A04](planning/A03_A04_EXPORT_AND_VOYAGE.md).  
**Name:** Water EveryWhere. Retire the old working title “Lost at Sea” in future product-facing work.  
**Platform:** Windows PC first; existing Godot/Jolt/cel-shaded foundation.  
**Players:** tune for 3–4; support and qualify 2–8. Solo is initially a development mode, not a launch promise.  
**Length:** first complete slice 8–12 minutes; full voyage 25–40 minutes, subject to playtest evidence.

This is the working plan. Implement one bounded chunk, test it, deliver a runnable checkpoint, and stop for that checkpoint's human playtest before starting another gameplay chunk. Research precedes risky implementation. A passing headless check is not proof of good gameplay.

The requested `GAME/_PLAN.md` path was absent. The actual source was root `GAME_PLAN.md`; its exact previous contents are preserved in [Draft 1](planning/GAME_PLAN_DRAFT_1.md). Supporting technical evidence is in [Replication research](planning/REPLICATION_RESEARCH.md). These authored documents use `planning/` because the existing `docs/` directory is gitignored.

## Index

1. [Vision and improvements](#1-vision-and-improvements)
2. [Scope and design rules](#2-scope-and-design-rules)
3. [Voyage pacing and recovery](#3-voyage-pacing-and-recovery)
4. [Mechanics and player experience](#4-mechanics-and-player-experience)
5. [Islands and replayability](#5-islands-and-replayability)
6. [Professional replication](#6-professional-replication)
7. [Frontend, backend and production software](#7-frontend-backend-and-production-software)
8. [Current project baseline](#8-current-project-baseline)
9. [Delivery workflow](#9-delivery-workflow)
10. [Workable chunks](#10-workable-chunks)
11. [Verification and quality targets](#11-verification-and-quality-targets)
12. [Human playtest gates](#12-human-playtest-gates)
13. [Risks and scope cuts](#13-risks-and-scope-cuts)
14. [Research register](#14-research-register)
15. [Decisions and next step](#15-decisions-and-next-step)

## 1. Vision and improvements

**You and your friends must get a battered raft back to the mainland, island by island, while the ocean turns every rescue, overloaded departure and questionable shortcut into a story.**

One friend paddles the wrong side, another is pulling someone aboard, and a third refuses to throw away a ridiculously heavy souvenir. The mainland lighthouse is still visible through the rain. Everyone understands the problem without an explanation.

Preserve the original themes: a wreck, regrouping, small resource islands, an ocean crossing, a fragile shared raft, escalating danger and home as the destination. Keep the cel-shaded style. Add depth through interactions between a small number of mechanics.

| Original idea or gap | Revised direction | Benefit |
|---|---|---|
| Wreck/swim slice without propulsion or rescue | First prove paddling, boarding, rescue, one supply stop and arrival | Tests the actual game rather than a long swim |
| People compete with cargo for permission to travel | Baseline raft accommodates everyone; optional cargo creates weight/space pressure | Negotiation without routinely excluding friends |
| No failure, but incomplete recovery rules | Explicit player rescue, fallback raft and assisted arrival | No unwinnable run or long spectator wait |
| Single condition value | Start scalar; consider three readable damage zones later | Cooperative repair without simulating every plank |
| Networking described as solved | Qualify responsiveness, moving platforms, WAN faults and state recovery | Local replication becomes a tested production system |
| Menus/export near the end | Package and connect early; improve frontend progressively | Every milestone can be tested outside the editor |
| Islands mainly supply containers | Short cooperative tasks and safe/greedy route choices | Stops produce decisions and stories |
| Trend potential assumed | Readable incidents, an honest recap and voluntary replay tests | Shareability becomes a hypothesis we can evaluate |

### Design evidence and interpretation

PEAK's official description foregrounds helping friends, a clear destination and repeatable route variation. The transferable idea is mutual assistance around a legible physical task. This supports inspiration, not a prediction of popularity for this game. [PEAK official page](https://store.steampowered.com/app/3527290/PEAK/)

Content Warning includes returning from danger and watching the group's experience. Our proposed illustrated voyage recap gives an incident a second social moment without first building video capture. [Landfall's Content Warning page](https://landfall.se/content-warning)

Water EveryWhere's identity is **rescue comedy on a shared raft**. Sea conditions, cargo placement and teamwork create the trouble. Hunger systems, monsters, quotas and daily chores do not automatically improve that identity.

## 2. Scope and design rules

### Six pillars

1. **Get home together.** The objective stays visible; the best ending brings everyone home.
2. **Readable physical consequences.** Paddle position, cargo mass, waves and repair effort matter. Mistakes must look like mistakes, not packet loss.
3. **The raft is the shared character.** Repairs, load, attachments and condition tell the voyage's story.
4. **Pressure followed by relief.** Forecasts create choices; island stops let the crew regroup. Constant storms flatten the experience.
5. **Failure creates another playable problem.** Rescue and recovery replace early elimination, with costs in time, optional cargo and ending quality.
6. **Shared outcomes are authoritative.** Gameplay-changing state is server-decided and reconstructible by joining clients. Presentation can be locally derived.

### Scope tiers

| Tier | Included |
|---|---|
| First complete slice | 2–4 humans, controllable raft, stable boarding, one-item carrying, one island, repair, rescue assist, one forecast event, arrival and restart |
| Full voyage alpha | 2–8 qualification, 2–4 island stops, load handling, exhaustion, bounded wreck, route choice, damage/recovery, recap and per-feature join correctness |
| Friend beta | Reliable join/reconnect, checkpoint recovery, invitation/transport integration, settings/accessibility, polished audio/animation, optional voice after validation |
| Launch candidate | Small tested route/content set, reproducible build pipeline, support diagnostics, asset provenance and external playtest evidence |
| Later if justified | Simple sail, two-person bulky cargo, three repair zones, challenge seeds, additional island tasks, cosmetics |

Baseline excludes hunger/thirst, deep crafting trees, persistent survival bases, competitive economies, public matchmaking, plank-by-plank destruction, full ocean fluid replication, seamless host migration, video replay and console promises. These create independent engineering and support obligations.

“AAA level” here means responsive controls, clear interactions, stable shared physics, graceful failure/recovery, accessible presentation, useful diagnostics and repeatable release quality. It is a quality target, not a statement about current readiness, budget or delivery date.

## 3. Voyage pacing and recovery

### Full session target

| Beat | Initial duration | Purpose |
|---|---|---|
| Lobby/readiness | Outside run timer | Join friends, appearance, controls |
| On-raft introduction and wreck | 45–75 seconds | Teach deck movement and establish the vessel |
| Regroup and restore steerable raft | 60–120 seconds | Find friends and make first rescue |
| Cross, land, gather, choose departure | Three legs at roughly 6–8 minutes | Teamwork, mishaps and short relief |
| Mainland approach | 2–4 minutes | Use what survived and finish together |
| Recap/replay | 1–2 minutes | Retell incidents and launch again |

These are tuning hypotheses. The slice skips the scripted wreck until the crossing works. Scale distances from measured raft speed and desired crossing time. A larger map is not a substitute for decisions; the ocean render horizon does not determine total route length.

### Authoritative run states

`LOBBY -> PREPARING -> INTRO -> REGROUP -> VOYAGE -> FINAL_APPROACH -> ARRIVAL -> SUMMARY -> LOBBY`

The slice can enter `VOYAGE` directly. Replicate phase revision/start tick, route seed/version, current leg, objective, crew roster, rescue count and ending type. `RECOVERY` is a controlled substate of regroup/voyage; it cannot create duplicate rafts or consume supplies twice. Connection/loading state is separate from run phase.

First server-validated arrival starts a visible 60-second gathering window. Other crew can continue ashore. At expiry, unresolved crew receive an assisted-rescue ending; disconnected crew are labeled disconnected rather than dead. Emit completion once and show the same summary revision to everyone.

### Recovery contract

| Situation | Immediate play | Guaranteed way forward |
|---|---|---|
| Fall overboard | Swim, signal, grab edge or accept assistance | Reachable boarding points and baseline rescue |
| Exhausted swimmer | Slow drift, whistle/ping, accept help | Stable flotation and optional rescue assist |
| Separated too far | Direction cue and rescue marker | Offer regroup assist after 45 seconds; useful play by 60 seconds in standard mode |
| Raft at zero condition | Select cargo releases; emergency flotation remains | Exactly one fallback raft near a safe recovery point |
| No repair supplies | Emergency low-speed propulsion remains | Minimum salvage at recovery point; no resource softlock |
| Everyone drifting | Brief recovery with look/signal controls | Regroup at latest safe stop within 60 seconds |
| Repeated total recoveries | Third recovery presents a shared choice | Continue assisted or finish with rescue-boat ending |
| Host disappears | Clear session-lost screen | Later checkpoint resume; never claim seamless continuation |

Thresholds are starting targets. Assistance loses optional cargo/score and is recorded, but cannot strand a teammate or remove essential controls. Victims can release unwanted rescue attempts. A transient network error is not a gameplay defeat. Deliberate restart is a visible group-facing action.

## 4. Mechanics and player experience

### 4.1 Movement, camera and physical comedy

Preserve the existing instant `V` first/third-person toggle, stable first-person horizon, water clearance and obstacle avoidance unless testing justifies a specific change. Camera shake, local body visibility and viewing mode stay local. Replicate avatar stance and visible action state.

Build on existing walking/swimming/airborne behavior. Add coherent gameplay states for drifting and assistance rather than contradictory Boolean flags. Separate server gameplay state from animation state. Start with additive stumbles and impact reactions; full active ragdoll locomotion would multiply prediction and recovery risks and is deferred.

### 4.2 Shared paddling

First interaction: hold or tap paddle from a reachable side position. A bounded stroke request causes authority to apply force at the paddle point; left/right position creates yaw. Water contact gates thrust. Cooldowns and crew scaling prevent eight players producing runaway speed.

The owner sees immediate anticipation; confirmed action phase drives remote animation and splash timing. Clients never submit final force, velocity or damage. Immediate animation is not a substitute for movement prediction.

Test acceleration, stopping, turning, reversing, counter-steering and rough-water control. Begin with forgiving continuous hold. Optional stroke timing may provide a small efficiency bonus only if humans enjoy it. No mandatory rhythm game or captain class.

One active paddler must still make useful progress while others repair/rescue. More crew provides flexibility rather than linear speed. Two-player runs cannot require four simultaneous stations.

### 4.3 Boarding and rescue — the signature interaction

Readable edge grab points, a short boarding transition and an emergency assist prompt come first. Server validates reach, relative velocity, raft ID, occupancy and player state. Preserve platform motion through transfer and test rotation, not just translation.

Basic rescue is short-range assistance before rope physics. The richer version is a **rescue ring with a bounded line**: throw, connect, reel, release. A line is server-owned endpoint/tension state rendered locally as a curve. Begin with one line per rescuer, bounded length/force, explicit cancel and no arbitrary geometry wrapping.

Pulling affects both participants within force limits; bracing aboard helps. Prevent cyclic constraint chains, duplicate target ownership and disconnect traps. Keep a simple rescue fallback available. Comedy should come from recoverable shared actions, not an unreliable interaction prompt.

### 4.4 Cargo and resources

One resource: **salvage bundles**, consumed by repair and limited upgrades. One carried object per player initially; no inventory grid. Supplies are physical while loose, with secured totals visible on the raft.

Cargo lifecycle: `LOOSE -> HELD -> SECURED -> CONSUMED`, plus explicit releases to `LOOSE`. Each object has stable ID, revision, holder/socket and immutable value. Simultaneous pickup has exactly one winner. Disconnect follows one documented drop/secure rule.

Secured cargo becomes raft-relative state and contributes mass/center of mass once. It must not also collide as a second independent load. Loose cargo uses authority physics. Avoid arbitrary scene reparenting until replication paths and late-join ordering are proven.

Baseline raft holds all active crew. Optional cargo changes freeboard, handling and balance. Show consequences through lean, waterline marks, creaks and optional load indicator. Measure existing player contact weight before adding proxy loads; never count player mass twice.

Start with left/center/right attachment zones. Heavy objects communicate weight through silhouette, carrying speed and sound. More mass does not guarantee more damaging slams: verify freeboard, stability and damage independently.

### 4.5 Condition, damage, repair and upgrades

Start with scalar condition and authored damage bands. Authority combines validated contact/impact data, energy thresholds, per-contact cooldowns and clamps. Existing slam events are candidate inputs, not a complete damage model: arming logic may miss relevant hits, and spawn settling must never count as damage.

Replicate lasting condition separately from feedback events. Unique event IDs prevent duplicate effects or transactions. Players must be able to explain a damaging impact.

Initial repair: hold at a marked point while safely moored; consume secured salvage on successful completion. Cancel consumes nothing. Two repairs competing for the last bundle consume it once. Show progress and requirements.

Later emergency patches at sea trade paddle time for limited recovery. Consider three damage zones only after scalar repair is fun: hull, steering and optional sail. Avoid dozens of hidden maintenance stats.

One upgrade choice per island: reinforcement, stability/outrigger or later simple sail. Same resource, visible model change, measurable benefit and tradeoff. Basic rescue and minimum propulsion are never unlocks.

### 4.6 Weather and readable danger

Authority owns weather epoch, parameters/preset, schedule and forecast. Clients derive sky, water and effects from compatible content and synchronized time; gameplay buoyancy stays authoritative.

Keep discrete presets for early tests with an explicit warning. Test the physical switch for force spikes and surface mismatch. If unsafe or unpleasant, do a bounded transition experiment before raising severity. Warning players does not make a discontinuity acceptable.

Use authored pressure and relief rather than endlessly rising wind. Near-term warnings are dependable; longer outlook may be uncertain. Cues: distant dark band, pennants/audio, readable forecast icon, then event. Captions/icons carry essential audio information.

Shelter must be honest. If a cove only reduces spray visually, do not call it mechanically safe. A sheltered mooring needs actual protected conditions or an explicit validated docking rule. Spatial wave/wind attenuation is new physics work, not assumed existing behavior.

### 4.7 Exhaustion and signals

Exhaustion makes long unsupported swims unattractive while preserving short rescue swims. Resting on raft/flotation restores it. Test swim time and visibility before enabling it; avoid a punitive drowning timer disguised as stamina.

Start with contextual ping and whistle for friend, island, raft and danger. Rate-limit requests and expire markers. Later flare use is server-validated with lasting position/expiry state for joiners. Identify crew by name, icon and color together.

Proximity voice is a beta candidate, not required for first tests. Pings must support the complete loop; external voice chat remains usable. Integrated voice needs separate transport/capture, mute/device controls and performance testing.

### 4.8 Ending and sharing

Prioritize crew brought home, then rescue effort and raft survival. Time and souvenirs are secondary; abandoning friends must not be optimal scoring. Distinguish assisted arrival without shaming the assisted player.

Recap: route sketch, final raft portrait, names, rescues, supplies spent, roughest measured incident and one or two factual highlights. A server event log can say “rescued Sam near WestCove”; it cannot infer who caused a fall without recorded attribution evidence.

Provide a screenshot-friendly local card and replay with same/new seed. Facts come from authority, screenshot output stays local, and nothing posts automatically. Cosmetic badges can celebrate teamwork later; no power progression or daily obligation is needed.

## 5. Islands and replayability

Reuse the archipelago assets/generator in a separate voyage scene so existing development scenes remain useful. The full route need not preserve current coordinates. Begin with one resource island and mainland within a few minutes of the raft.

Initial full content target: four stop archetypes, two route arrangements and three authored weather schedules. Each run visits 2–4 stops. Validate reachable route edges, minimum supplies, recovery locations and travel times. Seeded selection of authored content comes before unrestricted procedural terrain.

| Stop | Decision/task | Recovery | Dependency |
|---|---|---|---|
| Sheltered cove | Moor, repair, choose wait/depart | Recovery berth, modest salvage | Slice |
| Exposed salvage beach | Move bundles before weather turns | Dropped bundles remain nearby | Cargo/forecast |
| Rocky passage | Short route with narrow approach | Grounded raft can be pushed/refloated | Handling/damage |
| Off-route wreck islet | Optional bulky souvenir/upgrade salvage | Reward can be abandoned | Full voyage |

Later tasks: carry a long plank together, hold a mooring during loading, or operate a winch to free cargo. Add one family at a time and count replication/recovery work in its scope.

Mainland needs a distinctive lighthouse, harbor silhouette, protected final channel and obvious landing. Decorative distant ranges remain scenery until collision/navigation is deliberately added.

Variation changes decisions through resource placement, detours, forecast timing and a small optional cargo pool. Do not randomize essential controls or permit unwinnable layouts. Seeds include generator/content versions; the same seed alone cannot guarantee compatibility after code changes.

## 6. Professional replication

The server owns simulation, initially inside the host's game process. Clients send intent. Input ownership is not body, raft or cargo authority. Godot provides RPC, spawning and property synchronization; reconciliation, transaction integrity and recovery are project responsibilities. Official facts and proposals are separated in [Replication research](planning/REPLICATION_RESEARCH.md).

### 6.1 State contract

| Domain | Authority/transport intent | Join/recovery representation |
|---|---|---|
| Run, roster, route | Reliable versioned server state | Full current snapshot and run epoch |
| Player motion | Sequenced input upstream; authority snapshots downstream | Pose, velocity, stance, support ID, acknowledged sequence |
| Raft motion | Server rigid body; timestamped unreliable snapshots | Pose, velocities, condition/load/attachments |
| Cargo | Server lifecycle; loose poses streamed, secured offsets/state | Stable ID, revision, holder/socket, consumed state |
| Rescue | Validated endpoint relationship and force limits | Active endpoints, length, state |
| Salvage/condition/upgrades | Server transaction then reliable state | Current values, never only past events |
| Weather/ocean | Parameters, epoch, schedule and time samples | Full configuration and effective tick |
| Impact/paddle splash | Expiring event or locally derived effect | Do not replay old bursts |
| Active flare | Server active state plus effect event | Owner, position, seed, expiry |
| Animation/audio | Derived from shared action/state; owner anticipation allowed | Current loops/stance; no historical sound flood |
| Camera/particles/menus | Local presentation | Read shared state where needed |

“Everything replicated” means agreement on shared causes and gameplay outcomes. Do not send each ocean vertex, particle or UI pixel. Shared wave parameters and clock samples cost traffic and produce numerical tolerances, not guaranteed bit-identical CPU/GPU results. Clients do not decide gameplay from their visual water.

### 6.2 Input and request validation

Preserve existing transport until a focused replacement passes comparison tests. Proposed movement stream includes input sequence, bounded axes/buttons, sample time and server acknowledgments, with redundant recent inputs on an unreliable ordered channel. Reject stale/replayed/invalid-future samples and non-finite numbers. Clear movement after a bounded timeout.

Reliable requests handle discrete pickup, repair, attach, ready and phase actions. Separate frequent input/state traffic, transactions and bulky join snapshots into traffic classes so transfers do not stall movement. Custom RPC channels do not automatically reconfigure synchronizer traffic; inspect actual packets before claiming separation.

Validate sender identity, controlled entity, epoch, allowed phase, reach, target lifecycle, resource availability, cooldown, request sequence and interaction line where relevant. Duplicate requests return their original result or no-op. Bound payloads, names, entity counts, rates and outstanding actions. Clients submit actions, never final balances or winning scores.

Player-hosted authority does not make the host trustworthy for global competitive rankings. The baseline has no such economy.

### 6.3 Moving raft and responsiveness

This is the highest technical risk. Current scripts synchronize position, rotation and velocities; that is not evidence of WAN interpolation/prediction quality.

Prototype timestamped snapshot buffers for remote poses using a common presentation time for raft and riders. Use quaternion interpolation in the proposed visual layer. A supported rider needs support raft ID, relative pose/velocity and transition tick so platform motion is neither delayed differently nor applied twice.

Prototype bounded owner prediction and reconciliation using acknowledged inputs. Authority resolves contacts and transfers. Do not assume Jolt replays identically on every machine. Compare a constrained predicted locomotion layer with current rigid-body behavior in isolation before selecting the controller seam.

Predict local walking/swimming and action anticipation first; do not promise rollback of the entire ocean's coupled rigid bodies. If moving-deck quality fails, revise support/controller architecture before adding cargo and rope complexity. Record measured errors and side-by-side captures.

Extrapolation has a short cap, followed by a poor-connection cue rather than runaway simulation. Apply smoothing to presentation with limits while collision state follows authority. Reset interpolation history explicitly for teleports/boarding/recovery.

### 6.4 Lifecycle

Separate player and world-object spawners with independent caps. Count eight total players correctly: listen host occupies a slot; a non-playing dedicated server does not. Stable entity IDs must be separate from local instance IDs and temporary peer IDs.

Reliable spawn/despawn plus revisioned attachment state prevents ghosts. Referenced entities can arrive in different order; queue unresolved relationships with bounds/timeouts or request a new baseline. Do not assume ordering across separate channels.

Clean up on disconnect, raft destruction, restart, relevance loss and load failure. IDs include epoch or cannot be reused while stale messages exist. Remote proxies do not independently apply buoyancy or decide ownership.

### 6.5 Late join and reconnect

Join sequence: validate protocol/content/build compatibility; load scene; receive baseline revision S; spawn entities; resolve relationships; apply deltas newer than S; acknowledge ready; enable controls and safe spawn. Chunk/bound baseline traffic. Resnapshot if backlog overflows. Spawner synchronization helps create nodes but does not supply this whole transaction.

Test joins during carrying, repairing, rescuing, weather changes and ending. Past transient splashes need not replay; active flares, damaged raft and depleted islands must be correct.

Reconnect uses authenticated session identity/token, never display name or recycled peer ID. Proposed reservation: 120 seconds. On disconnect neutralize input, release unsafe lines and safely drop held cargo; explicitly define body retention/safe-state behavior. Returning identity gets one authoritative body without duplicated items/score. After expiry use normal late join.

### 6.6 Host loss, saves and dedicated mode

Listen-server alpha loses live simulation when host leaves; UI states this clearly. Beta adds atomic completed-island checkpoints and resume. Persist schema version, run epoch, route/content version, roster identities, raft/load/condition, depleted resources, weather/schedule, phase and summary facts.

A host-only save works when that host returns. Recovery when the host is unavailable requires a tested acknowledged copy elsewhere. A later option distributes checkpoints to peers and resumes in a new session/authority epoch. That is checkpoint recovery, not seamless host migration. Validate restored data as untrusted input and prevent split authority.

Keep simulation independent of rendering and qualify a headless server before evaluating hosted-server operations. Godot supports dedicated export; it does not supply allocation, health monitoring or persistence policy. [Godot dedicated exports](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_dedicated_servers.html)

### 6.7 Bandwidth and relevance

Instrument before optimizing. Starting hypotheses: physics 60 Hz, motion snapshots 20 Hz, inputs 30 Hz, clock correction 1–2 Hz. These are proposals, not current defaults.

Prioritize nearby raft, crew, rescue participants and loose cargo. Secured cargo sends offsets/state changes; quiet props reduce updates; distant island supplies are event-driven. Rescue targets remain relevant across ordinary distance cutoffs.

Illustrative payload: 40 moving entities × 64 bytes × 20 updates/s = 51,200 bytes/s per recipient before framing, retransmission and other state. Seven recipients multiply host outbound cost. Measure actual encoding and wire traffic; this arithmetic is not a benchmark.

## 7. Frontend, backend and production software

### Proposed module boundaries

These are responsibilities to introduce incrementally, not claims that the modules exist. Prefer narrow Godot components/resources over one expanding game-controller script.

| Module | Owns | Boundary |
|---|---|---|
| SessionService | Host/join, identity, compatibility, disconnect | Transport adapter, no raft rules |
| RunDirector | Phase, leg, recovery, arrival, epoch | Validated domain actions and objective state |
| InteractionService | Reach, requests, conflicts | Stable IDs and transaction results |
| RaftController / RaftState | Thrust, load, condition, supported riders | Physics input and snapshots |
| CargoService | Pickup, drop, sockets, consumption | Single ownership/lifecycle contract |
| RescueService | Lines, drifting recovery, assist | Bounded validated relationships |
| VoyageWorld | Route graph, stops, depletion, spawns | Seed/version and authored definitions |
| WeatherDirector | Schedule, cues, effective ticks | Ocean parameters and forecast |
| Presentation | Animation, particles, sound, camera, HUD | Reads state; submits intent |
| CheckpointService | Schema, validation, atomic save/load | Domain data, not node pointers |
| Diagnostics | Tick, traffic, corrections, errors/events | Local redacted export with build ID |

### Frontend

Early flow: title -> host/join -> roster/ready -> loading -> voyage -> summary -> replay/lobby. Add clear timeout, full-room, version mismatch and host-loss messages. Debug keys alone are insufficient for external testing.

Beta settings: audio categories, display/resolution, graphics presets, rebindable gameplay controls, sensitivity/inversion, hold/toggle interaction, reduced motion, text scale, captions and redundant color/icons. Controller support is a separately validated option. Opening local settings cannot pause the network world; explain that behavior.

HUD priorities: where home is, crew activity, raft danger, rescue target and current interaction. Keep technical metrics in debug UI. Loading distinguishes preparing assets, connecting and synchronizing state; no endless unexplained spinner.

### Backend scope

The authoritative Godot process is the initial gameplay backend. No separate web service is required for the first slice. Add platform identity/invite/lobby and transport adapters when the loop passes.

Steam is the proposed initial friend-invite/distribution route, subject to access and maintained integration. Lobbies provide discovery/metadata, not gameplay packet transport. ENet alone does not guarantee connectivity through NAT; lobby calls do not automatically add relay support. Prove the selected transport on two internet connections. [Steam matchmaking](https://partner.steamgames.com/doc/features/multiplayer/matchmaking), [Steam Datagram Relay](https://partner.steamgames.com/doc/features/multiplayer/steamdatagramrelay)

Before choosing a paid service, compare region coverage, pricing model, maintenance, engine compatibility and offline development. Private sessions need join permission, kick/mute controls and clear ownership. Public discovery is deferred.

Settings/cosmetics may persist independently of runs. Cloud saves, accounts, economy, global rankings and live operations are later decisions. If diagnostics are uploaded, use consent and limited events, redact tokens, avoid unnecessary personal data and do not record voice by default.

### Tooling and release

Retain Godot/GDScript/Jolt. Pin engine and export templates. Extend existing suites with contract checks, rendered captures, packaged host/client smoke tests and a repeatable impairment harness. Research a Windows impairment tool before installation; isolate rules to test traffic and restore them afterwards.

After first export, provide simple **Build + Run** and **Build only** entry points plus an isolated multiplayer test launcher. Artifacts record build ID, source revision/dirty marker, engine/content/protocol versions and evidence. Authored plans/research are tracked; generated captures/logs remain separate.

CI progression: import/parse -> deterministic checks -> ENet integration -> Windows export -> packaged smoke -> test artifact. GPU checks need a suitable runner or explicit manual gate. No release credentials in client/source. Signing and store upload come after a reviewable candidate exists.

## 8. Current project baseline

Read-only inspection on 13 September 2026 established the following. No runtime suites were executed for this planning revision; historical pass counts and timings remain unverified against the current tree.

| Observed now | Consequence |
|---|---|
| `project.godot` launches `scenes/archipelago.tscn`; Godot 4.7 feature level, Jolt, D3D12 | Continue foundation; A01 verifies exact executable/templates (Draft 1 says 4.7.2) |
| `archipelago_game.gd` uses sheltered island spawning; main scene has a raft | Introduce explicit voyage scene; do not assume current start is afloat |
| Raft replication streams position/rotation/velocities | Useful plumbing, not proven WAN smoothing |
| Player replication includes stance, ground velocity and spawn identity | Reuse contracts before replacing systems |
| Listen-session policy is eight total players | Recheck dedicated player counting |
| Runner lists 14 suites, including GPU | Distinguish fail, missing GPU, port conflict and absent verdict |
| Significant modified/untracked user work; original plan untracked | Preserve/inventory before coding; no wholesale reset or blind staging |
| `/docs/` ignored; no root export preset found | Track authored work elsewhere; export early |

### Corrections to Draft 1

- `_nearest_raft()` iterates `water_subjects` but casts to `Raft` and skips other bodies. The claimed automatic cargo boarding bug is not supported by current code. A dedicated registry is an optional clarity refactor, not a confirmed blocker.
- Camera-centered LOD extent is view coverage, not maximum total voyage length. Larger routes require precision, navigation, content and camera tests.
- Existing impact energy helps, but thresholds, coverage and cooldowns need validation. Damage is not “nearly free.”
- Additional mass can lower freeboard without necessarily increasing slam damage. Verify those separately.
- Shared ocean parameters/clock cost traffic and have numerical tolerances. Avoid zero-wire-cost and universal-determinism claims.
- Old audit numbers such as 0.74 ms for nine bodies, 13/14 suites passing and the reported input-test settling defect are historical evidence. Reproduce before changing tests or declaring production readiness.
- Eight-player admission/churn is not proof of an eight-person playable voyage over the internet.
- Remove the unsupported 4–6 week schedule promise. Estimate from completed chunks after the slice, including research, art, human tests and release work.

Prior project guidance preserves server-owned buoyancy, replicated input/outcomes and locally reconstructed water effects. Representative scripts were inspected here; historical runtime validation was not repeated.

## 9. Delivery workflow

### One chunk, one reviewable behavior

Before each chunk: read dependencies, inspect dirty tree, record behavior being changed, research uncertain details, state the human test. Keep exploratory work isolated and preserve the last playable build.

After each chunk: run meaningful focused checks, exercise actual scene/build, inspect host/client views, publish the updated test build and test card. Mark `READY FOR USER TEST`, not `ACCEPTED`, until the human gate passes. Do not silently continue into another gameplay chunk while feel is untested.

If a chunk is not one reviewable behavior or its test takes more than roughly 5–15 minutes, split into suffix IDs before coding. Research spikes and soak tests can take longer but still end in a concrete decision/evidence artifact. Multiple independent defects are separate fixes.

```text
Chunk / build ID:
Question answered:
What changed:
Launch path and controls:
Host/client arrangement:
Steps and expected visible results:
Automated/network checks actually run:
Known issues and checks not run:
User observations — accept, revise or block:
Next eligible chunk:
```

Every shared feature specifies sender validation, agreement, initialization for joiners, disconnect and restart cleanup. Apply meaningful cases, not tests that merely mirror private implementation.

Statuses: `PLANNED`, `RESEARCHING`, `IMPLEMENTING`, `VERIFYING`, `READY FOR USER TEST`, `ACCEPTED`, `BLOCKED`, `DEFERRED`. Unchecked chunks are not complete. A01-A04 are complete; B01 is `READY FOR USER TEST` with its automated clauses passing and its human clause open, and every later chunk remains `PLANNED`. See [A01 report](planning/A01_BASELINE.md) for the reproducible failure and outstanding human tests. Checkboxes record completed work, while each checkpoint report separately lists human tests and limitations. No source commit or exported build is implied by a checked baseline report.

## 10. Workable chunks

Each card includes dependency, bounded work and a visible/network gate. Phase letters organize work; they do not authorize implementing the whole phase without checkpoints.

### Phase A — Reproducible starting point

- [x] **A01 — Capture current baseline**  
Depends: this plan. Inventory source changes, exact engine/templates and old logs; run existing 14-suite runner and rendered host/client scene. Record discrepancies without gameplay edits.  
Gate: report actual commands/exits, hardware/build identity, control checks and untested items. User sees the baseline. Unexplained failures affecting the next feature block it.

**Completed 13 September 2026:** [A01 report](planning/A01_BASELINE.md). 13/14 suites passed; the failing remote-input assertion repeated in isolation (exit 1). Both rendered peers passed (exit 0) and four captures were inspected. Completion means baseline recorded, not a green release or human feel approval.

- [x] **A02a — Fix the demonstrated remote-input blocker**  
Depends: A01. Reproduce each actual defect before changing it; split A02a/A02b as needed. If settling is the test issue, wait for the required stance with a bounded timeout and assert it before sampling, rather than relaxing thresholds. Preserve unrelated work and make a deliberate source checkpoint.  
Gate: same reproduction fails before/passes after; visible behavior unchanged except intended fix. Never blindly include all untracked files.

**Completed 13 September 2026:** [A02a report](planning/A02A_REMOTE_INPUT_FIX.md). The failing assertion was a test-fixture defect: the authority body and its own frozen remote proxy share one physics world in the in-process harness and collide, pushing the body +X at 3.67 m/s while its linear_velocity read +0.01. Fixed by removing the proxy from the physics world, as the raft check in the same file already did. Suite 22/22 exit 0; runner 14/14 exit 0. No threshold relaxed and no gameplay script touched. The earlier leaked-input and airborne-body diagnoses are both disproved. No further A02 blocker is currently demonstrated; open one only when a real defect is reproduced.

- [x] **A03 — First exported playable baseline**  
Depends: A02. Verify matching templates and export Windows build using current scene/controls. Add launch instructions.  
Gate: binary runs without editor, renders correctly, hosts/joins another exported process and exits cleanly. Deliver exact launch path. Export command success alone is insufficient.

**Completed 13 September 2026:** [A03/A04 report](planning/A03_A04_EXPORT_AND_VOYAGE.md). Added an export preset (none existed; templates were already correct). All four gate clauses were evidenced separately: the exported pair hosted and joined over real ENet on port 27241, both rendered on D3D12, and a quit probe returned EXITCODE=0 with no leftover processes. Launch path: the exported .exe under build/windows/. Not signed, no custom icon, never run on another machine.

- [x] **A04 — Voyage scene and phase skeleton**  
Depends: A03. Separate short raft/island/mainland scene with safe spawn, objective and reset; reuse presentation.  
Gate: two peers agree on objective/phase, late join initializes correctly, three resets leave one raft and one body per player. User identifies home within 30 seconds.

**Completed 13 September 2026:** [A03/A04 report](planning/A03_A04_EXPORT_AND_VOYAGE.md). Added a run director (phase, revision and epoch by reliable RPC plus a join baseline), a voyage game subclass, scenes/voyage.tscn and tools/verify_voyage.gd (registered; 38/38 pass). Two real processes agreed on phase, revision, epoch and objective, and a post-join phase change reached the client. Three resets each left one raft and one body per player. Rendered and visually inspected. The user then played the scene, which surfaced three defects no headless suite had caught: the objective named a lighthouse that was never built, the suite could only compare strings so it could not have caught that, and verify_archipelago hard-coded a single main scene. All three fixed, each with a proven failing-before/passing-after guard; 15/15 pass with voyage.tscn as the main scene. **The crossing has never been sailed** - arrival is proved by moving a body, not by propulsion - and the "user identifies home within 30 seconds" human test remains open.

### Phase B — Reliable raft feel

- [x] **B01 — One paddle action** — `ACCEPTED`  
Depends: A04. Validated propulsion and basic feedback; measure force/drag rather than guess units.  
Gate: host/client see start/stop; off-raft strokes rejected; missing input stops thrust. User starts, turns and stops in test bay.

**Accepted 14 September 2026.** The human clause is met: the user played the raft and reported it feels fine. That is the whole of what was outstanding — the automated clauses had passed since implementation.

**Implemented and verified headlessly 14 September 2026; the human clause is open.** `tools/verify_b01_paddle.gd` proves the automated half over a real loopback session: host and client both see a stroke start and stop, holding repeats one stroke per stroke duration, each request is served exactly once, a burst of five collapses to one, missing input stops thrust with the key still held, a client cannot start a stroke itself, a stroke from the water is refused as `NOT_ABOARD` and does not fire on reboarding, paddling moves the raft further than drift, and strokes from opposite edges turn it opposite ways. `scenes/test_bay.tscn` and `tools/verify_test_bay.gd` add the calm measuring scene the gate names, with its own weather preset because a preset is the only lever on wind.

**Still required to check this box:** a human starting, turning and stopping the raft in the test bay. No one has played it, so the gate's last sentence is unmet and the chunk is not complete. A force measured headlessly is not a raft that feels like anything.

- [x] **B0P — Push the raft off from shore** — `ACCEPTED`  
Depends: B01. Requested by the user during B01's play test, and scoped by them to the case that
matters: a raft grounded in the shallows, shoved off by someone standing on the shore. Not in the
original plan; it belongs to the rocky-passage stop's "grounded raft can be pushed/refloated"
line in §5, arriving early because a player wanted it.  
Gate: a shove is server-decided, refused from aboard, refused without footing or reach, refused
during its own cooldown, and reaches a raft from a client as well as from the host. User pushes
the raft off.

**Accepted 14 September 2026.** The user played it: "I can push it now." `tools/verify_b06_push.gd`
holds 13 checks; `verify_multiplayer` drives the client-to-server path over a real session.

Two things this chunk is deliberately honest about, both recorded in the code rather than here:

- **`push_force` is set from play, not measured.** Three observables were tried against a hull
  grounded in the shallows — distance, distance against a control, peak speed — and none could
  tell the feature switched on from switched off, because a grounded raft is still afloat and
  90 kN on 77,760 kg moves it about as much as the swell does. The suite therefore asserts the
  contract it can prove and prints the motion figures as an informational line asserted by nobody.
- **A raft fully up on land cannot be shoved at all**, by any force: measured at exactly
  0.0000 m/s under 500 kN applied sideways and straight up, with the hull embedded in the terrain
  mesh. That is a collision problem rather than a strength one, and it is out of scope here.

A review by another session caught the defect that mattered: `push_requests` was missing from the
replicated input list, so a client's key press never reached the server and only the host could
shove — with the suite green throughout, because every check called the raft directly and none
travelled the path a player's press takes. Both halves are now guarded.

- [ ] **B02 — Shared paddling**  
Depends: B01. Two-sided force points, aggregate thrust cap and a few tuning controls.  
Gate: two people travel straight, deliberately spin and recover. Concurrent requests do not duplicate strokes. Compare 2/4/8 simulated inputs then two humans; no runaway speed.

- [ ] **B03 — Boarding moving/rotating raft**  
Depends: B02. Audit support velocity and validate reach/transfers.  
Gate: 20 transfers per peer across both sides in calm/rough sea, including rotation; no hull teleport, duplicate occupancy or client-only success. Inspect first-person comfort.

- [ ] **B04 — WAN measurement and remote presentation**  
Depends: B03. Controlled impairment fixture, timestamped remote-pose buffer experiment, error/traffic metrics.  
Gate: host/client captures under section 11 profiles; raft/rider share presentation time, extrapolation bounded. Verify actual measured impairment, not just tool settings.

- [ ] **B05 — Owner responsiveness decision**  
Depends: B04. Isolated bounded prediction/reconciliation experiment for walking/swimming/support motion. Compare current body/controller behavior and document chosen seam.  
Gate: feedback/consistency targets met with captures. If moving-platform quality fails, revise/split this chunk before cargo/rope complexity. The experiment must end in an implemented, testable choice, not an unproven architecture claim.

### Phase C — Complete short slice

- [ ] **C01 — Basic rescue without rope physics**  
Depends: B05. Signal, reachable assist, cancel/release and safe reboarding; no exhaustion.  
Gate: recover friend from moving raft; reject duplicate/out-of-range requests; disconnect/join preserve valid state. User judges helpfulness and comedy.

- [ ] **C02 — One physical salvage bundle**  
Depends: C01. World spawner, stable ID and pickup/drop lifecycle.  
Gate: contested pickup yields one winner; water/shore drop, disconnect, join and restart never duplicate it. User understands carrying without inventory tutorial.

- [ ] **C03 — Secure cargo to raft**  
Depends: C02. One socket, attachment transaction and mass applied once.  
Gate: moving attach/detach and late join agree; no collision explosion/stale relationship. Compare settled loaded/unloaded freeboard.

- [ ] **C04 — Condition and repair**  
Depends: C03. Controlled damage proves condition, repair progress and resource consumption; natural wave damage stays disabled here.  
Gate: last-bundle contention consumes once, cancel consumes none, join sees condition. User repairs at island and understands cost.

- [ ] **C05 — One forecasted weather change**  
Depends: C04. Warning/schedule plus discontinuity evaluation.  
Gate: shared deadline, correct join countdown, no force spike or surface disagreement. User makes a leave/wait choice. Split transition work if required.

- [ ] **C06 — Arrival and replay**  
Depends: C05. Mainland trigger, gathering window, basic result and replay/lobby buttons.  
Gate: late arrival/duplicate trigger/join during summary produce one result. Three restarts clean up. Deliver full 8–12 minute exported loop.

- [ ] **C07 — First fun gate**  
Depends: C06. Two voyages with 2–4 humans; collect section 12 evidence, not new features.  
Gate: understand goal, cooperate, complete rescue, want another run. If travel/rescue disappoints, tune in separate subchunks. Automated success does not unlock content expansion by itself.

### Phase D — Consequence and recovery

- [ ] **D01 — Calibrated natural damage**  
Depends: C07. Research actual slam/contact coverage, add thresholds/cooldowns and debug visualization.  
Gate: no spawn/ordinary-swell damage; controlled severe impacts cause bounded loss. Clients agree. User explains why hit hurt.

- [ ] **D02 — Load placement and warning**  
Depends: D01. Left/center/right sockets, bounded loads and readable warnings.  
Gate: all active players can board; cargo alters handling without double mass; 2/4/8 crew remain navigable. User voluntarily unloads because of visible pressure.

- [ ] **D03 — Exhaustion and drifting**  
Depends: D02. Swim exhaustion, flotation recovery and server drifting state.  
Gate: normal rescue swims work, drifting still permits signalling, timers independent of client frame rate. Test loss during transitions and inactivity target.

- [ ] **D04 — Rescue ring and line**  
Depends: D03. Research then prototype one non-wrapping, force-capped reel/release relationship.  
Gate: release/contested target/disconnect/despawn clean up; no cycles or remote simulation. User rescues without precision frustration; C01 remains fallback.

- [ ] **D05 — Raft-loss recovery**  
Depends: D04. Exactly-once fallback raft, cargo-loss rules and assistance timer.  
Gate: sink raft with all crew aboard; everyone resumes useful play within target. No duplicated supplies, zero-resource dead end or repeated immediate sinking. Repeat during join.

- [ ] **D06 — Playable wreck opening**  
Depends: D05. Bounded intro wreck with few gameplay debris bodies and cosmetic fragments; guarantee nearby flotation/regroup point.  
Gate: newcomers learn controls, find crew within two minutes and cannot lose required salvage. Bounded traffic. Compare with starting on damaged raft; retain the more enjoyable opening.

### Phase E — Full voyage

- [ ] **E01 — Second distinct island**  
Depends: D06. Sheltered versus exposed stop, depletion and mooring rules using current terrain.  
Gate: revisit/join preserve resource state; approaches navigable. Humans explain different reasons to stop.

- [ ] **E02 — Route choice and mainland**  
Depends: E01. Safe route plus optional detour, measured travel times, recovery sites and recognizable lighthouse/landing.  
Gate: branches completable with minimum supplies; authoritative route/content versions agree. Users navigate from landmarks/minimal guidance.

- [ ] **E03 — Full weather pacing**  
Depends: E02. Three bounded pressure/relief schedules; truthful forecast/shelter.  
Gate: record 25–40 minute runs without forced idle waits/permanent storm traps; clock correction/join remain correct.

- [ ] **E04 — One cooperative island task**  
Depends: E03. Choose either bulky two-person cargo or mooring/winch, not both. Guarantee two-player path.  
Gate: disconnect/contested use/interruption cannot strand task. User gets a distinct social interaction, not simply longer gathering.

- [ ] **E05 — One optional upgrade**  
Depends: E04. Reinforcement or outrigger with same salvage. Sail is a separate later experiment.  
Gate: consume once, join model/state agree, benefit/tradeoff measurable. Users sometimes choose repair instead.

- [ ] **E06 — Recap and seeded replay**  
Depends: E05. Bounded authority event log, factual highlights, route card and same/new seed replay.  
Gate: shared facts, safe name rendering, correct disconnected labels, no false blame. Local screenshot works. Three full runs remain valid; different seed changes a decision.

### Phase F — Dependable sessions

- [ ] **F01 — Complete join bootstrap**  
Depends: E06; per-feature join tests already exist. Version handshake, baseline barrier/revisions, relationship resolution, catch-up overflow recovery.  
Gate: join during carrying/rescue/wreck/repair/weather/summary under loss; controls never enable on partial state. Loading/timeout UI truthful.

- [ ] **F02 — Reconnect identity**  
Depends: F01. Session identity/token and bounded reservation; no new external account service.  
Gate: correct body/state returns; wrong token, stale peer ID, duplicate connection and expired reservation handled. Reconnect cannot mint resources.

- [ ] **F03 — Checkpoint and same-host resume**  
Depends: F02. Atomic versioned island checkpoint, validation and previous-good fallback.  
Gate: terminate after save, resume exported build, peers agree. Truncated/corrupt/incompatible data yields useful error without destroying valid prior save.

- [ ] **F04 — Host-loss recovery decision**  
Depends: F03. Prototype acknowledged peer checkpoint resume or choose explicit same-host-only first-release recovery. Qualify separate headless server mode as F04a before any hosted-server commitment.  
Gate: demonstrate authority termination and truthful limits. Peer resume starts new epoch and prevents split authority; headless mode runs a full loop without render dependencies. No “live migration” claim.

- [ ] **F05 — Internet/platform transport spike**  
Depends: C07 for early research; integration after F02. Verify Steam access, maintained Godot binding, lobby identity and transport/relay separately.  
Gate: two exported clients on different internet connections join; record direct/relay behavior and dependency versions. Unavailable access leaves friend-beta connectivity explicitly blocked, with direct-IP development retained.

- [ ] **F06 — Friendly invitation and lobby flow**  
Depends: F04 and F05. Host/invite/join/ready/loading using chosen adapter, with full-room/mismatch/denial/host-exit handling.  
Gate: non-developer joins without terminal/router configuration/editor; reconnect/replay work. Correct eight-player count in both server modes.

### Phase G — Polish and release qualification

- [ ] **G01 — Settings and accessibility**  
Depends: F06. Separate subchunks for controls, display/performance, then readability/motion.  
Gate: bindings persist, conflicts explained, exported menus usable, essential cues understandable without audio/color. Human comfort in both cameras.

- [ ] **G02 — Animation and audio feedback**  
Depends: G01. Separate passes for paddling, rescue, damage, repair and arrival. Optional voice is G02v after provider/capture research.  
Gate: remote feedback matches action, host sounds do not double, loops stop on disconnect, important sounds captioned. Voice if shipped passes mute/device-change/bandwidth checks.

- [ ] **G03 — Performance and final content**  
Depends: G02. Profile 2/4/8 players and entity caps in busiest weather; optimize measured bottlenecks, then author small final route/task set.  
Gate: section 11 targets on named hardware, correct relevance, usable quality settings and preserved water readability. Split content work by island/task.

- [ ] **G04 — Reproducible release build pipeline**  
Depends: A03 for early automation; finalize after G03. Versioned exports/reports and meaningful regressions from observed faults.  
Gate: fresh checkout/import/export, packaged host/client smoke, no credentials/dev-only content in candidate. Failed/absent test verdict blocks candidate.

- [ ] **G05 — External beta and candidate**  
Depends: G04. Real WAN tests, churn/soak, host-loss drills, tutorial-free onboarding, asset rights/provenance and packaging review.  
Gate: zero open crash/duplication/softlock/unexplained-session-loss blockers; representative crews complete and voluntarily replay. Candidate includes build ID, limitations, support guide and tested rollback artifact. Publishing is a separate action after this concrete result is reviewable.

### Phase gates

| Gate | Ends at | Required evidence |
|---|---|---|
| Baseline | A04 | Reproducible build and shared objective |
| Feel | B05 | Steering/boarding usable under latency |
| Short slice | C07 | Humans complete and want to repeat |
| Recovery | D06 | Wreck/rescue/raft loss cannot strand group |
| Voyage alpha | E06 | Full route with meaningful island decisions |
| Friend beta | F06 | Join/reconnect/host-loss behavior dependable |
| Candidate | G05 | External, performance and release evidence |

These are dependency gates, not calendar promises. After C07, estimate ranges from actual chunk durations and remaining risks. Research, multiplayer integration, human availability and art each need explicit allowance.

## 11. Verification and quality targets

Numbers below are **initial acceptance targets**, not measured current results or engine guarantees. A01/B04/G03 establish hardware and may revise targets with recorded justification. Never loosen a threshold merely to make a failed test green.

### Network profiles

| Profile | RTT | Jitter | Loss | Required behavior |
|---|---|---|---|---|
| Local | Measured LAN/loopback | Measured | 0% | Reference behavior/traffic |
| Typical WAN | 80 ms | ±10 ms | 1% | Normal responsive co-op |
| Challenging WAN | 150 ms | ±30 ms | 3% | Playable; corrections do not eject riders |
| Degraded | 250 ms | ±50 ms | 5% | Clear connection cue; no corrupt state |
| Interruption | 2-second outage, then 10-second outage | Recorded | Burst | Bounded recovery/reconnect; no runaway input |

Apply delay both ways to achieve RTT and label one-way delay separately. Record tool/version, measured RTT/loss, bandwidth cap and reordering/duplication settings. Test capped host upload. Local processes do not replace physical machines and real internet paths. These are the canonical profiles; research-note examples are illustrative.

### Provisional budgets

| Area | Starting target | Evidence |
|---|---|---|
| Local action feedback | Anticipation within 50 ms | Input-to-frame capture; confirmation latency separate |
| Stable deck presentation | p95 relative visual error <0.20 m typical, <0.40 m challenging | Time-aligned pose logs after settling; labeled teleports excluded |
| Large corrections | No unexplained ejection; >0.75 m correction investigated | Capture plus correction log |
| Server work | 60 Hz; p95 simulation <12 ms at supported load | Release profile on named minimum-host candidate |
| Client render | 1080p medium, 60 fps target; p95 frame <20 ms | Named hardware, warm/cold runs separate |
| Traffic | Initial 150 KB/s authority outbound per client; seven recipients ≈1.05 MB/s before voice | Wire capture including retransmits; bootstrap separate |
| Join | <10 seconds after local asset loading, typical WAN | Request to control-ready acknowledgment |
| Reconnect | <15 seconds after transport restoration within reservation | Identity/entity/state timing |
| Input silence | Neutralize within 500 ms without fresh input | Drop upstream while holding movement/paddle |
| Inactive player | Useful play within 60 seconds via standard assist | Human timing including prompt discovery |
| Stability | 90-minute soak and three full runs without restart | Crash/NaN logs, object counts, memory trend |

Initial authoring cap: eight players, one primary raft, up to 24 nearby loose gameplay objects and bounded rescue links. Extra wreck fragments are cosmetic. Profile before increasing caps; do not simply raise player spawner limits.

Required cross-cutting scenarios:

- Contested pickup, repair, rescue and upgrade; duplicate/stale/forged requests, non-finite inputs and spam.
- Join with held/secured cargo, depleted islands, damaged raft and active flare.
- Disconnect holder, rescuer, passenger and host at transitions; lose release packets.
- Delayed old-epoch commands after restart cannot affect new run.
- Throttle upload during baseline transfer while current players keep controlling raft.
- Board rotating raft, carry while boarding, fall during rescue, sink while client joins.
- Restart three times and churn eight peers; object counts return to baseline.
- Corrupt/incompatible saves and protocol/content mismatch yield useful recovery messages.
- Both cameras and reduced-motion mode work in rendered storms.

Add contract suites for propulsion, boarding, cargo transactions, rescue cleanup, repair, run transitions, bootstrap, reconnect, checkpoint restore and soak. Retain existing water CPU/GPU parity checks. Runtime errors, timeout, unresolved references and absent verdict fail; occupied ports explicitly block a run rather than pass it.

## 12. Human playtest gates

Correctness and fun are separate. Observe behavior before asking feedback; do not tell participants what should be funny.

| Question | Observe | Initial decision rule |
|---|---|---|
| Is home clear? | Time to identify destination | Aim under 30 seconds with landmark/marker |
| Is raft valuable? | Return, repair, rescue around it | If everyone swims instead, revise travel balance |
| Is teamwork natural? | Unprompted steering/rescue/load discussion | If one person does everything, improve availability/tradeoffs |
| Is failure playable? | Inactive time and help discovery | Repeated minute-long helpless waits are defects |
| Are islands distinct? | Why crew stops/skips | If only resource count matters, change task/approach/forecast |
| Are mistakes fair? | Can player explain damage/fall? | Fix control/network blame before adding chaos |
| Is replay attractive? | Voluntary request for another run | Seek repeat play in two of three independent crews before expanding content |
| Are stories emerging? | Incident retold without prompting | Rescue/load/weather stories support the hook |

C07: at least two 2–4-person sessions. E06: two-person and larger crews. G05: newcomers who did not watch development and an eight-person session. These small samples guide iteration, not sales forecasts.

Record build, crew, experience, seed, weather, latency, completion/idle time, rescues, recoveries, cargo loss and confusion. Ask: “Best moment?”, “What felt unfair?”, “Where did you stop knowing what to do?”, “Would you play again now?” Link concise observations to chunk IDs.

## 13. Risks and scope cuts

| Risk | Priority | Resolving chunk | Fallback |
|---|---|---|---|
| Platform motion/prediction disagreement | Critical | B03–B05 | Revise support/controller before expansion |
| Export/template blocker | Critical | A03 | Resolve packaging immediately |
| Long swimming/regrouping tedious | High | C01/C07/D06 | Shorter scatter, better assist, damaged-raft start |
| Cargo/line instability | High | C03/D04 | Socketed cargo/simple rescue; drop freeform constraints |
| Weather impulse discontinuity | High | C05 | Bounded transition or different event staging |
| Host loss wastes voyage | High | F03/F04 | Tested checkpoint recovery and truthful UI |
| NAT/binding prevents friend joining | High | F05 | Early transport proof; no online-ready claim from loopback |
| Eight-player load/traffic/chaos | High | D02/G03 | Improve scaling/caps; no eight-player promise before qualification |
| Missing human testers | High | C07 | Keep gate open; agents cannot certify social fun |
| Content outgrows mechanic | Medium | E01 onward | Four archetypes/two routes; defer task families |
| Old audit drives wrong fixes | Medium | A01/A02 | Reproduce current behavior |
| Unknown trend appeal | Product uncertainty | Human gates | Improve observed loop; no virality guarantee |

Cut optional sail, bulky cargo, extra tasks, challenge seeds/cosmetics, integrated voice and distributed checkpoint resume first if scope grows. Preserve basic rescue, home objective, stable deck motion, join correctness, packaged tests and duplication prevention.

## 14. Research register

Before risky code, record question, pinned engine/integration version, primary sources, current local evidence, proposal, tradeoffs and a falsifying test. Save durable notes in `planning/`, not ignored logs.

| Topic | When | Deliverable |
|---|---|---|
| Godot RPC/spawn/sync/channels | Initial, refresh F01 | [Replication research](planning/REPLICATION_RESEARCH.md) and tested bootstrap contract |
| Support/platform velocity | B03 | Code trace and translation/rotation probe |
| Predicted movement with Jolt authority | B04/B05 | Comparison, correction traces, controller decision |
| Cargo mass/contact transfer | C03/D02 | Settled-body experiment preventing double load |
| Slam coverage/damage | D01 | Contact events versus visible incidents |
| Weather transition | C05 | Force/surface continuity and rendered comparison |
| Rescue constraints | D04 | Force-capped prototype and fault tests |
| Steam/transport/relay | Begin after C07; resolve F05 | Maintainer/version/access/cost notes and two-network exported proof |
| Identity/persistence | F02/F03 | Schema plus interruption/reconnect tests |
| Voice | Before G02v | Capture/device/mute/bandwidth proof |
| Co-op pacing/sharing | Human gates | First-party inspiration plus observed player evidence |

Initial design references: [PEAK](https://store.steampowered.com/app/3527290/PEAK/) and [Content Warning](https://landfall.se/content-warning). They support inspiration, not claims about this audience. Technical sources/limitations are in the companion research. Recheck moving documentation against the pinned shipping version at implementation.

## 15. Decisions and next step

| ID | Baseline decision | Revisit |
|---|---|---|
| DEC01 | Water EveryWhere; voyage back to mainland | User direction |
| DEC02 | Current Godot/Jolt/cel-shaded foundation | Demonstrated unsolved constraint |
| DEC03 | Tune 3–4, qualify 2–8 | D02/G03 evidence |
| DEC04 | Paddles before sail; rescue before punishment | C07 |
| DEC05 | One salvage resource, physical cargo, limited sockets | E04 |
| DEC06 | Everyone boards; optional cargo drives load tension | D02 |
| DEC07 | Server outcomes; local reconstructed presentation | B05 selects implementation within authority model |
| DEC08 | Self-contained runs, later checkpoint recovery | F03/F04 |
| DEC09 | No seamless host migration promise | Separate justified scope |
| DEC10 | Early export/frontend; Steam-oriented beta proposed | F05 access/transport proof |
| DEC11 | Short slice before full voyage | C07 pacing |
| DEC12 | One chunk then human test; implementation still planned | Each accepted checkpoint |

**Next: play the raft.** Three human tests are open and none of them needs another line of code. B01's own gate — starting, turning and stopping the raft in the test bay — plus the two A04 tests: whether a player identifies home within 30 seconds, and keyboard/mouse comfort in the exported build. B01's propulsion is implemented and every automated clause of its gate passes, so what is unknown now is feel, and no suite can answer that. **B02 should not start until B01's human test passes**, because shared paddling tunes a stroke that has never been judged by a person; if the single stroke is wrong, two of them are wrong together.

Fixed alongside, outside the chunk list, from a human play report and a bug the suites could not see:

- **The character floated face down.** The swim clip was playing correctly the whole time; the body was a tall uniform-density box, which floats on its side like a log, at a measured mean of 94 degrees from upright. A submersion-scaled upright servo holds a swimmer at 2.9 degrees in a calm sea and 13.4 in a storm, and `verify_player_state.gd` now guards it.
- **Impacts painted a white slab on the sea.** One term in the impact-ring shader was a shape scaled by a fade rather than a signed distance, so it landed every fragment exactly on `ALPHA_SCISSOR_THRESHOLD`, which draws opaque. Measured at a raft-sized impact: 21.07% of frame near-white before, 3.13% after. `verify_reactions.gd` now guards the shader source, because the ring kept its `visible` flag throughout the bug and every live check passed on the broken version.
