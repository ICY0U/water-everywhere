# Releasing the demo

The demo is the voyage (`scenes/voyage.tscn`, the main scene) behind its title menu. Version:
`application/config/version` in `project.godot`, mirrored as the Windows file and product version
in `export_presets.cfg`. Bump all three together.

## Build

1. Open the project in Godot 4.7.2 so it re-imports (a new `class_name` is only registered by an
   import).
2. Run the board and require it green. `-- --only=voyage` alone is not enough:
   ```sh
   godot --path . --headless --script tools/run_suites.gd
   ```
3. Export, from the editor (Project > Export, *Export With Debug* **unticked**) or from the
   command line once the 4.7.2 export templates are installed:
   ```sh
   godot --headless --path . --export-release "Windows Desktop" build/windows/WaterEVERYWHERE.exe
   godot --headless --path . --export-release "Linux" build/linux/WaterEVERYWHERE.x86_64
   ```
   A release export hides the F1 diagnostic panel (`OS.is_debug_build()`); a debug export does
   not, and also opens a console window.
4. Zip each build's binary and `.pck` with `release/README.txt` as
   `WaterEverywhere-demo-<version>-windows.zip` / `-linux.zip`. Never ship an `override.cfg`:
   Godot reads one next to the executable and it can register autoloads.
5. Sounds are generated, not recorded. After changing `tools/generate_audio.py`, run it and
   re-import; the `.wav.import` files carry each loop setting.

## Smoke test the exported zip, not the editor

On a machine (or a clean folder) that has never run the project:

- [ ] Title screen appears; no console window; window title and taskbar icon are the game's.
- [ ] Play: no firewall prompt (solo binds to 127.0.0.1 only). You spawn looking at the raft
      and the mountains.
- [ ] Hints appear: head to the raft, press F, hold Space, steering tip.
- [ ] Esc pauses (the sea stops), Settings changes sensitivity and fullscreen, and both survive
      a restart of the game.
- [ ] Paddle to the mainland, wade ashore: the end screen shows a crossing time; Sail again
      returns you home facing the mainland.
- [ ] Play with friends: host on one PC, join from another on the LAN; both see each other
      paddle. Quitting the host sends the guest back to the title with a reason.
- [ ] F1 does nothing in the release build.
- [ ] Sound: sea on the title and in play, music under the menus only, a splash per stroke, a
      click per button, a sting on arrival. Volume and Music sliders work; Music at 0 is silent.
- [ ] Graphics Low visibly lowers resolution and removes the god-ray fog, and stays Low after
      pressing 3 (stormy).
- [ ] Credits opens and scrolls through Godot's licence.

## Known limits of 0.1.0

Three character animations (the Blender expansion is not exported yet); online play needs a
forwarded UDP port; the build is unsigned; volumetric fog can look wrong under software rendering
(lavapipe), so judge visuals on real hardware. The rights to the raft model and the Kotarou
character must be confirmed before public distribution: no licence or source is recorded for
either in this repository, and Credits does not name their authors.

Verified in the cloud on 30 September 2026 without Windows: the Linux release export launched,
reached the title, played, rendered without shader errors, applied the graphics presets and quit
cleanly. The Windows export completed with no warnings but has not been launched on Windows.
Under the headless dummy audio driver Godot reports finished sounds as leaked at exit; a real
audio driver retires them, which could not be confirmed here.
