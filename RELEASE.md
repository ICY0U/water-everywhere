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
3. Project > Export > **Windows Desktop** > **Export Project**, with *Export With Debug*
   **unticked**. A release export hides the F1 diagnostic panel (`OS.is_debug_build()`); a
   debug export does not, and also opens a console window.
4. Output lands in `build/windows/`. Zip `WaterEVERYWHERE.exe`, `WaterEVERYWHERE.pck` and
   `release/README.txt` as `WaterEverywhere-demo-<version>-windows.zip`.

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

## Known limits of 0.1.0

No audio; three character animations (the Blender expansion is not exported yet); online play
needs a forwarded UDP port; the build is unsigned; volumetric fog looks wrong under software
rendering (lavapipe), so judge visuals on real hardware.
