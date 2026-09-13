# Water EveryWhere — replication research

Researched 2026-09-13. Scope: a small Godot cooperative physics game supporting 2–8 players. This is planning evidence, not a claim that the current build meets production networking requirements. Official stable documentation is a moving target; pin implementation checks to the actual editor/export-template version before coding.

## 1. Verified engine facts

Godot's default multiplayer authority is the server. RPC sender identity is available through `multiplayer.get_remote_sender_id()`. Reliable messages retry and preserve order; unreliable ordered messages discard older arrivals. Channels separate streams so an unrelated reliable message need not delay gameplay. Channel 0 is separated by transfer mode. These are transport mechanisms, not automatic gameplay validation. [Godot high-level multiplayer](https://docs.godotengine.org/en/stable/tutorials/networking/high_level_multiplayer.html)

`MultiplayerSpawner` replicates supported scene lifecycles from authority, including custom spawns; `spawn_limit` is unlimited when zero. Custom spawn callbacks return a node outside the tree, which the spawner inserts. Configure bounded entity populations. [MultiplayerSpawner reference](https://docs.godotengine.org/en/stable/classes/class_multiplayerspawner.html)

`MultiplayerSynchronizer` sends configured properties from authority and offers per-peer visibility. Resources, Objects, instance IDs and RIDs cannot serve as synchronized cross-peer values. Use game-owned stable IDs and primitive/packed data. Visibility can also trigger spawning/despawning when combined with a spawner; do not confuse hiding presentation with removing gameplay existence. [MultiplayerSynchronizer reference](https://docs.godotengine.org/en/stable/classes/class_multiplayersynchronizer.html)

`SceneReplicationConfig.ALWAYS` uses unreliable updates. `ON_CHANGE` uses reliable updates. Spawn configuration is separate. An infrequently changing value required by a new arrival must be included in initialization, not represented solely by a past event. [SceneReplicationConfig reference](https://docs.godotengine.org/en/stable/classes/class_scenereplicationconfig.html)

Godot's official scene-replication tutorial describes spawning for mid-game joins and reconnects, and recommends giving input a dedicated client-authority child while retaining server authority over the character. The article is from 2023 and explicitly warns about age; use current class references and project tests for exact behavior. Its simple example is not evidence of robust prediction, persistent identity or physics host migration. [Godot scene replication tutorial](https://godotengine.org/article/multiplayer-in-godot-4-0-scene-replication/)

`SceneMultiplayer` offers an authentication callback before normal connection acceptance. Object decoding defaults to false; enabling it for untrusted objects can execute code. The high-level wire protocol is an engine implementation detail, unsuitable as a promised external service protocol. [SceneMultiplayer reference](https://docs.godotengine.org/en/stable/classes/class_scenemultiplayer.html)

Headless execution is available with `--headless`; dedicated export mode adds a feature tag and supports removing unneeded visual resources. An export-template binary is recommended for serving. This enables deployment but does not supply fleet management, matchmaking, authentication policy or persistence. [Godot dedicated server exports](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_dedicated_servers.html)

## 2. Steam facts and boundaries

Steam lobbies group players and carry lobby metadata/chat. High-volume game traffic belongs on the networking API. Lobby discovery is therefore a separate integration from game transport. [Steam matchmaking and lobbies](https://partner.steamgames.com/doc/features/multiplayer/matchmaking)

Steam's networking APIs support traffic through Valve's network; Steam Datagram Relay is a separate networking capability. The Steamworks SDK/partner requirements and selected Godot binding must be checked in an implementation spike. Adding lobby calls to the current ENet implementation does not by itself route its packets through Steam relay. That last statement is an architectural inference from the separate APIs. [Steam networking](https://partner.steamgames.com/doc/features/multiplayer/networking), [Steam Datagram Relay](https://partner.steamgames.com/doc/features/multiplayer/steamdatagramrelay), [ISteamNetworkingSockets](https://partner.steamgames.com/doc/api/ISteamNetworkingSockets)

Steam automatically chooses another lobby owner if its owner leaves. This transfers lobby administration, not the Godot authority's simulated world, in-flight transactions or persistence. Consequently, advertise host-loss recovery only after implementing and testing it separately. [ISteamMatchmaking — GetLobbyOwner](https://partner.steamgames.com/doc/api/ISteamMatchmaking#GetLobbyOwner)

## 3. Current local evidence

The repository presently contains `GAME_PLAN.md`; the requested `GAME/_PLAN.md` path was absent during inspection. The existing plan targets 2–8 people and records a server-authoritative buoyancy foundation.

Inspection of `scripts/network/player_replication.gd` shows streamed world transforms and velocities, spawn identity, and reliable state changes. `player_input_replication.gd` sends input properties on change. `raft_replication.gd` streams position, Euler rotation and velocities with no explicit interval in that file. `network_player.gd` and `raft.gd` freeze non-authority physics. These are useful foundations, not demonstrated WAN smoothness. No runtime tests were performed for this research.

## 4. Proposed architecture — design recommendations

The following are project proposals, not guarantees made by Godot or Valve.

### Authority and meaningful replication

- One authority owns raft motion, physical cargo, collisions, damage, loot, crafting, rescues, weather schedules and run outcomes. A listen host is suitable for the first friend-group loop; keep simulation independent of rendering so a dedicated process can reuse it.
- Clients submit bounded intentions: movement, paddle direction, grab/release, repair request, rescue request. Validate authenticated sender, controlled character, entity existence, range, cooldown, finite numeric values, allowed state and request frequency. Apply mutations once with request IDs; two people collecting the same object must produce one winner and one clean refusal.
- Replicate the causes and state of shared presentation: ocean seed/parameters, authority time samples, weather schedule and compact impact events. Generate particles, camera effects and decorative foam locally. This is compact network traffic, not a zero-byte ocean claim. Anything that can push, damage, conceal a necessary cue or change rewards needs an authoritative rule and consistent representation.

### Physics responsiveness: a gated prototype first

1. Measure current client input latency, correction distance and raft-relative foot drift on two machines.
2. Add a timestamped snapshot buffer for remote presentation, separate from authoritative collision state. Interpolate rotations as quaternions; cap extrapolation; explicitly reset history for teleports and boarding transitions.
3. Prototype local movement prediction with input sequence numbers, authority acknowledgements and reconciliation. Do not assume Godot physics interpolation supplies this; it addresses rendering between physics ticks, a different concern. [Godot physics interpolation introduction](https://docs.godotengine.org/en/stable/tutorials/physics/interpolation/physics_interpolation_introduction.html)
4. Exercise standing, walking, jumping, boarding and falling from a pitching raft. Sample rider and raft at the same presentation time. Test a raft-relative representation while attached; preserve authority-approved attachment transitions and world-space airborne motion.
5. Keep the prototype only if it improves responsiveness without divergent collisions or impossible pushes. General rollback of all coupled rigid bodies is a separate high-cost project; do not promise it as an automatic consequence of client prediction.

Initial tuning hypotheses: 60 Hz authority simulation; 20–30 Hz snapshots for active nearby bodies; interpolation sized from measured jitter; lower rates/sleep handling for quiet distant props. These numbers require profiling and are not engine defaults or acceptance evidence.

### Messages and bandwidth

Use recurring sequenced input samples and a server input-expiry timeout if replacing reliable on-change movement. Release-state robustness must survive loss; one lost release must not create endless thrust. Carry nonrepeatable actions through reliable, deduplicated requests or explicitly acknowledged sequences.

Keep frequent snapshots, reliable gameplay transactions and bulky join/checkpoint payloads in separate traffic classes. Custom RPC channels do not automatically reconfigure scene synchronizer internals; inspect actual packet behavior before claiming isolation. Bound snapshot and baseline payloads, chunk large transfers, acknowledge completion, and measure bytes per second on both host and client.

### Late join, reconnect and recovery

Late join needs an application baseline: protocol/content version, run ID and epoch, authority tick, seed, current weather and next transition, consumed island resources, raft/upgrades/damage, cargo IDs and holders, players/rescue state, timers and run phase. Gate control until the baseline and required spawns agree. Reconcile events produced during transfer using a baseline tick plus ordered revision; reject old-epoch packets after restart.

Reconnect uses a stable authenticated player identity distinct from the temporary transport peer ID, a bounded grace reservation and a clear rule for held cargo and downed bodies. Test replacement of the connection without duplicate characters or inventory. A spawner rebuilding objects does not establish these product rules.

First recovery milestone: atomic, versioned safe-island checkpoint with a tested restore path. If only the host has it, another player cannot recover after that machine vanishes. Replicate an acknowledged checkpoint copy to an eligible friend if peer recovery is intended; clearly show possible progress loss. A new host can start a new session from that checkpoint. This is checkpoint recovery. Seamless live migration additionally needs authority election, split-brain prevention, state handoff, transport reconnection and treatment of in-flight physics/actions; defer until justified by playtests.

### Frontend and backend scope

Frontend: create/join/invite, visible connection progress, actionable failure reason, version mismatch, reconnect status, host-loss recovery choice, mute/report controls if shipped voice requires them, and clean return to lobby. Never hide a failed connection behind an endless spinner.

Backend first: authoritative Godot session, versioned save/checkpoint service within that process, transport/platform adapter, structured diagnostics and exported headless verification. Avoid building account services or server orchestration before their need is proven. A Steam release needs a separate binding/license/version check and a two-account, two-network test of invitations and selected transport. A dedicated offering later adds allocation, health checks, restart policy, storage, access controls and operating-cost measurement.

## 5. Proposed verification gates

| Gate | Required evidence before advancing |
|---|---|
| Two-peer truth | Host and client agree on cargo ownership, repair spend, raft damage, downed/revived state; remote player actually drives authority physics. |
| Moving deck | Both players walk, paddle, collide, jump and reboard while the raft pitches; record correction and deck-slip distributions alongside video. |
| Impaired network | Repeat at 0/60/120/200 ms RTT with explicit latency direction, jitter and 0/1/3/5% packet loss; distinguish supported target conditions from severe degradation tests. |
| Concurrent requests | Repeated same-object pickup, duplicate repair, forged actor ID, out-of-range rescue, NaN input and request spam produce no duplicated state or uncontrolled simulation. |
| Join/rejoin | Join during cargo carry, storm, downed state and ending; reconnect to same identity; verify no duplicate entity, replayed resource or permanently disabled input. |
| Host loss | Kill authority mid-leg and during save; verify truthful failure UI and last valid checkpoint recovery. Do not label this seamless migration. |
| Capacity | 2, 4 and 8 actual peers, with per-peer bandwidth, server physics frame time, correction metrics and a full-voyage soak; local bots alone do not prove WAN quality. |
| Export/platform | Fresh client export plus headless server; separate machines and real Internet path; Steam invitations and relay verified independently when integrated. |

Choose numerical pass thresholds after the baseline experiment, record them in the plan before accepting later mechanics, and retain the test configuration with results. Professional replication means measurable consistency, responsiveness and recovery across these cases, not simply successful connection or a node named Synchronizer.
