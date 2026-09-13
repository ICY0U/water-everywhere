# A02a — Remote-input assertion diagnosed and fixed

**Completed:** 13 September 2026.
**Result:** `tools/verify_multiplayer.gd` now reports **22/22 checks PASS, exit 0**, and the full
runner reports **14/14 suites passed, exit 0, 333.5 s**.
**Scope:** one test-fixture defect. No gameplay script, scene or threshold was changed.

## The defect

`remote input drives real physics` asserted `server_body.position.x < start.x - 0.1` after 0.7 s
of −X intent and reported **positive** displacement (`x=2.570` in A01, `x=2.631` on re-run).

The cause is **collision between the authority body and its own remote proxy**, not physics and
not the input path.

`_check_live_controls()` runs both peers as two branches of ONE `SceneTree`, so they share ONE
physics world. The authority body and the proxy that mirrors it are spawned at the same position
and overlap. A frozen `RigidBody3D` is still a collider: `freeze_mode` defaults to
`FREEZE_MODE_STATIC` and is never set anywhere in this project (`grep -rn "freeze_mode"` returns
nothing), so the proxy is a solid, immovable obstacle inside the body it represents. Jolt resolves
that overlap by pushing the authority body out along +X.

**The decisive measurement:** position advanced at ~3.67 m/s while the body's own
`linear_velocity.x` read **+0.01**. Position moving without velocity is depenetration, not thrust.

## Evidence

Same intent throughout (`move_direction=(-1,0)`, sprint, down), measured at the real ENet seam:

| Setup | dx | vx | Verdict |
|---|---|---|---|
| Proxy `layer=2 mask=3` — as the fixture was | **+4.531** | +0.01 | FAIL |
| Proxy `layer=0 mask=0` | **−15.141** | −22.8 | PASS |
| Fully isolated: one body, bare Ocean, no networking, no synchronizers | −26.5 | −21 | PASS |

The isolation run is what separates harness from physics: identical code, identical flat Ocean,
identical intent, correct −X motion. The physics was never at fault.

## Two earlier diagnoses were wrong

Both were recorded as probable causes and both are now disproved. Neither should be repeated.

- **Leaked `Input.action_press` from the axis sweep** (old `AUDIT.md`). The sweep releases each
  action inside its own loop, and `client intent reaches server` passes — correct −X intent
  demonstrably crossed ENet.
- **Sampling a body that was still airborne.** Instrumenting the real harness showed
  `stance = 1 (FLOATING)` from t=0 through the entire window; the body never was airborne. The
  endless sinking that made this theory plausible (y falling to −22 with submersion pinned at
  1.000) is a *consequence* of being driven under by the proxy, not a settling transient.

## The fix

In the spawn function, the proxy branch only:

```gdscript
if is_proxy_branch:
    body.collision_layer = 0
    body.collision_mask = 0
```

This is the same workaround `_check_live_raft()` in the same file already applied, with the
comment "Both branches share one physics world in this test; avoid proxy/authority collision."
The player check simply never got it. No threshold was relaxed.

## Reproduction

Failing before / passing after, at the real ENet seam:

```powershell
$godot = 'D:\MainSystems\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe'
& $godot --headless --path . --script tools/verify_multiplayer.gd   # 22/22 PASS, exit 0
& $godot --headless --path . --script tools/run_suites.gd           # 14/14 PASS, exit 0
```

Reverting the four added lines restores the positive-displacement failure.

## Limits

- Fixes a **test fixture**. It changes no shipping behavior, so it needs no human feel review.
- The in-process two-peer harness remains an artificial arrangement: one physics world, two
  branches. It is adequate for authority, RPC direction and intent-delivery assertions, and it is
  **not** a latency, prediction or WAN-quality measurement. That work is B04.
- Green suites are not visual proof. Rendered evidence remains the A01 captures.

**Next: A03**, the first exported playable baseline.
