# DEMO01 — Demo readiness

**Date:** 29 September 2026.
**Asked for:** "make this a fully demo ready game — add and improve to get it to that point."
**Status:** `READY FOR USER TEST`. Every automated check passes; nobody has played it yet, so
nothing here is `ACCEPTED`. The open human tests are listed at the end.

This is not one of the plan's chunks. It was asked for directly, it cuts across several phases —
a front end from §7, a mainland landmark from §5, recovery of a grounded start from §3 — and it
deliberately stops short of the plan's gameplay chunks: there is still no cargo, damage, rescue
line or weather schedule. What it delivers is the existing crossing, made into something a stranger
can launch, understand, finish and replay.

## What a demo needed that the build did not have

Found by playing the build the way a newcomer would, and by writing a bot that does.

| Gap | Evidence |
|---|---|
| **The crossing could not be sailed.** Arrival had only ever been proved by moving a body. | A bot using only player controls: raft grounded in the shallows and facing north; six shoves moved it 1.5 m; a lone paddler boarded at the far edge and turned it back into the beach. |
| **Paddling crawled.** | 0.3 m/s averaged over 36 s of continuous strokes in open water: ten minutes for the crossing. |
| **A lone paddler could not go straight.** | 53° of yaw in 36 s from the "centre" of the deck — the lever was `signf(x)`, with no middle. |
| **No way into the game.** | It opened on "Offline" and a key list; playing alone meant hosting an ENet server for one. |
| **No end.** | Arrival changed one line of text. No time, no summary, no replay beyond R. |
| **No sound at all.** | No audio assets or buses existed. |
| **A debug HUD.** | One label: peer id, roster, key names, objective. |
| **No pause, settings or gamepad.** | P froze the tree silently; nothing persisted; no joypad bindings. |
| **Not packaged as a product.** | Godot's default icon, no boot splash, one export preset. |

## What changed

### The crossing (commit `b61314c`)

- **Horizontal damping.** The raft's linear damping rate of 1.1 was set to settle its heave, and
  applied horizontally too: 85 kN per m/s on a 77.8 t hull against a 30 kN stroke. `BuoyantBody`
  gained `horizontal_damping_scale`; the raft uses 0.1. Heave damping is untouched (idle swing
  2.72 m before, 2.51 m after); the raft still coasts to a stop in about 4 s.
- **Steering lever.** Zero within 0.75 m of the centreline, full at 3 m, linear between. The deck's
  edge slots (2.7 m) still turn hard; the paddle suite's edge check is unaffected.
- **Boarding** no longer counts the boarder when choosing a deck slot, so a lone swimmer lands on
  the centre rather than the far edge.
- **A jetty and a mooring.** The raft starts in deep water off a new jetty, facing the mainland,
  held by a spring on position and heading until the first stroke or shove casts it off.
- **A following sea.** The voyage's presets blow toward 190° (a per-scene override on copies of
  the presets), where every preset blew toward 45° — a head sea for a westward crossing.
- **A lighthouse** on the mainland's near shore. The objective names it, and the suite check that
  asserts named landmarks exist now matches case-insensitively; it could never have matched a
  PascalCase node before, and it is shown failing with the lighthouse renamed.
- **Resets** restore the raft's heading and give each player their own slot.

### The front end

- **The title screen is the world.** No menu scene: the voyage loads once and the camera circles
  the moored raft behind the title. Set Sail, Host a Crew, Join a Crew, How to Play, Settings,
  Credits, Quit. Pressing Set Sail starts the session in the running scene — no second load.
- **Solo has no socket.** `NetworkSession.start_solo()` runs the authoritative game on an
  `OfflineMultiplayerPeer`, which is a server with no peers, so there is no firewall prompt.
- **Pause** stops a solo game, sea clock included; in a crew the menu opens over a running world
  and says so. Restart is offered only to the authority.
- **Arrival** carries facts — time, strokes, who landed first, crew, sea — recorded by the
  authority and sent with the ARRIVAL transition, and in the join baseline, so every peer's
  summary is the same one. Best times are kept per machine, per sea, solo and crewed apart.
- **The HUD** is an objective card with the next step and a clock, a compass with the lighthouse,
  the raft and crewmates, context prompts naming the key or button for the device in use, a
  top-down raft panel showing where the lighthouse lies and where to stand to steer, a crew list,
  and toasts. Everything on it is derived from replicated state.
- **Settings** persist to `user://settings.cfg`; `--profile=NAME` isolates them (and records),
  which the verification suites and the local two-window test both use.
- **Gamepad**: bindings for every action, right-stick look, menu focus throughout.

### Presentation

- **Audio**, all synthesised by `tools/generate_audio.py`: a title theme, a sea theme, arrival and
  cast-off stings, sea, wind, rain and surf beds, and effects for strokes, shoves, splashes,
  footsteps on sand and on wood, swimming, creaking timbers, gulls and the lighthouse bell. Every
  cue is derived from replicated state, so nothing about sound crosses the network.
- **A paddle** appears in a paddler's hands, on the side they stand, pulled into place by
  `TwoBoneIK3D` — which needed pole targets: the rig's arms rest nearly straight, a degenerate
  two-bone chain, and without a pole the hand did not move at all.
- **Stroke splashes** travel the existing server-authoritative impact channel.
- **Icon, boot splash, version 0.9.0, a Linux export preset** beside the Windows one.

## Evidence

| Check | Result |
|---|---|
| `tools/run_suites.gd` | **20/20 passed**, 515 s — the 18 existing suites plus `crossing` and `frontend` |
| `verify_crossing` — spawn to landfall, player controls only | sunny 124.3 s, overcast 130.9 s, stormy 146.4 s |
| `verify_frontend` | 44 checks: title, solo without a socket, pause stops the sea clock, summary facts, sail again, leave restores the world, host on ENet, settings, device glyphs |
| Two processes, host and join through the menu | client reached play, saw both bodies, the host's sea and the replicated mooring; leaving returned it to the title |
| Linux export | exported with the 4.7.2 template (73.5 MB binary, 8.0 MB pack); `-- --smoke-test` passed in the packaged build both solo and with `--server`, exit 0 and a clean log; two packaged processes hosted and joined over ENet |
| Rendered captures, inspected | title, Set Sail, settings, How to Play, HUD ashore and aboard, pause, summary, jetty, lighthouse near and far, the paddle in hand |

The GPU suite and every capture ran on Mesa's software Vulkan driver under Xvfb, because the
machine that did this work has no GPU. That proves the shaders compile and the pictures are
composed right; it says nothing about frame rate.

**One engine message is known and left alone.** A packaged *host* killed mid-session by
`--quit-after` prints `Attempt to disconnect a nonexistent connection ... 'tree_exiting'` at exit:
the spawner tears down before the bodies it tracks. Every real way out — the menu's Quit, closing
the window, `--smoke-test` — leaves the session first, and those exits are clean.

## Open — needs a person

1. **Feel.** B01 was accepted at the old lever and speed. The raft is now about three times
   faster in open water and steers from a centre band; that is a change to accepted behaviour and
   needs the user's say-so.
2. **A newcomer's first crossing.** Can someone who has never seen the game find the jetty, board,
   cast off and steer from the HUD alone? The plan's "identifies home within 30 seconds" test.
3. **The sound mix.** Every sound was checked by level, loop seam and spectrogram, and none has
   been heard by a person.
4. **Gamepad on hardware.** Bindings and glyphs are tested through synthetic events only.
5. **Performance on real GPUs**, and whether the auto-detected preset is the right one.
6. **The Windows export**, which could not be built here, and **play across two machines**.
7. **The raft model's licence**, which is not recorded anywhere in the project.
