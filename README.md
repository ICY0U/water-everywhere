# WaterEVERYWHERE

A cel-shaded ocean for Godot 4.7 with physically-modelled waves.

The design goal is "real physics, toon surface": the water *moves* like real deep-water
ocean, but it is *drawn* like a painted illustration — flat colour bands, hard-edged
foam, and crisp specular blobs instead of smooth PBR gradients.



The production plan, its chunk-by-chunk gates and the evidence behind each completed chunk are in
[GAME_PLAN.md](GAME_PLAN.md) and [planning/](planning/).

![sea level](docs/sea_level.png)

## Running it

Open the project in Godot 4.7 and press **F5** to play `scenes/archipelago.tscn`.
Press **H** to host or **J** to join. You then spawn on the larger starter island, with a mountainous exploration island, five small
islands and six low-poly background ranges. Terrain has basic cel-shaded sand/earth/rock
textures and no vegetation. See [island world notes and previews](docs/island_world.md).

Or launch directly:

```sh
"D:/MainSystems/Steam/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe" \
    --path . --rendering-driver d3d12
```

| Key | Action |
| --- | --- |
| `WASD` | move horizontally |
| `Q` / `E` | down / up |
| `Shift` / `Alt` | sprint / slow |
| Mouse | look |
| `1` / `2` / `3` | sunny / overcast / stormy |
| `C` | cycle weather |
| `V` | toggle first / third person |
| `F` | climb onto a nearby raft |
| `Esc` | release the mouse |

## Multiplayer

The main archipelago starts offline. Press **H** to host or **J** to join an existing host.
Players arrive on the starter island. Press **J** while already hosting to open a second
client window for a local test.
Explicit `--server` and `--client` arguments remain available.

The separate `scenes/multiplayer_demo.tscn` still starts players on the floating barrel raft.
Its deck movement, buoyancy and boarding behavior are described in
[raft integration and validation](docs/raft_integration.md).

To play across two machines rather than one, pass the server's address to the client. Both
sides accept `--port=` as well, so a session can avoid the default port entirely:

```sh
# on the host
godot --path . --rendering-driver d3d12 -- --server --name=Host --port=27015
# on the other machine
godot --path . --rendering-driver d3d12 -- --client --name=Guest --address=192.168.1.50 --port=27015
```

`J` uses the same address, and the offline panel names the machine it would reach, so there is
no guessing about where the key points. Without `--address=` it is `127.0.0.1` and the game is
same-machine only — which is what it silently was before these arguments existed. An unusable
`--port=` is refused with a warning rather than clamped, because a typo that quietly became a
different valid port presents as "the other machine cannot see me".

| Key | Action |
| --- | --- |
| `WASD` | steer relative to the camera, independent of hull roll |
| `Shift` / `Alt` | sprint / slow (Alt takes priority) |
| `Q` / `E` | dive / rise |
| `V` | toggle third / first person |
| `Esc` / left click | release mouse and stop thrust / resume control |
| `1` `2` `3` / `C` | weather (applies to **everyone**) |

| `P` | pause (single player only) |

| `Ctrl` + `Q` | quit |
| `H` / `J` | host / join when offline; J opens a second client when hosting |

Movement uses camera yaw in both views, with equal cardinal and diagonal thrust. Looking up or
down and rolling in waves do not rotate the steering axes. Releasing the mouse or switching
windows clears movement, sprint and vertical thrust; the cube continues to drift with the sea.

Input has its own client-owned synchronizer, configured before spawn. Body transforms remain
server-owned and remote bodies are frozen against local physics integration. This follows
[Godot's synchronizer authority model](https://docs.godotengine.org/en/stable/classes/class_multiplayersynchronizer.html).
The multiplayer verifier now spawns real players over ENet and checks camera headings, slow mode,
client input delivery, resulting host displacement, and capture/focus release.

### The camera

One rig, two arm lengths. `PlayerCamera` is a pivot at the player's eye point carrying the
mouse's yaw and pitch; a `SpringArm3D` hangs off it and the `Camera3D` hangs off *that*. The
nesting is required rather than tidy — a spring arm casts along its own Z and moves its
**direct children** to whatever it hits, so a camera it is meant to protect has to be its child.
Third person extends the arm to 12 m and it pulls in automatically when something comes between
the camera and the player; first person collapses it to zero, putting the camera at the pivot.
Two arm lengths of one rig, so switching cannot move where you are looking.

**The horizon stays level in both.** The camera takes the hull's *position* and never its
rotation. Bolted to a body floating on waves it would inherit every bob and roll, and on a two
metre swell the horizon pitches hard enough to make the sea unreadable — the motion belongs to
the boat, not to the viewer watching it. Rising and falling still conveys the swell; tumbling
only conveys nausea.

**Only the name tag is hidden in first person**, not the body — seeing the hull you are standing
on is most of what makes the view feel located. It is hidden with the camera's `cull_mask`
rather than by hiding the node, because `visible` belongs to the tag and would remove it from
*every* screen; a cull mask belongs to this viewer's camera, so one player declines to draw
something that stays perfectly normal for everyone else. That is also why none of this is
replicated: where a player looks, and what their own camera skips, is local by construction.

The first-person eye offset was set from screenshots, not geometry, and both components fix a
specific failure. Derived from the hull's half-height the eye sat barely above the waterline and
the view filled with sea; moved to the centre it stared into the far half of its own hull, which
filled the bottom of the screen. It now sits at the bow, where looking down shows the deck and
looking level shows the ocean.

### What is replicated, and what is not

Almost nothing needs to cross the network, because **the ocean is deterministic**. Every client
derives the same spectrum from the same wind speed and drives it from the same clock, so the
waves, the foam and the whitecaps are identical on both screens without a single packet. What
*is* replicated is only what two clients could otherwise disagree about:

| | |
| --- | --- |
| **Replicated** | player transforms and velocities, names, colours, input intent, weather changes, authority clock samples, discrete water impacts |
| **Derived locally** | waves, cloud animation and shadows, foam, wakes, spray, rain, splash particles and ripple crowns |

The distinction is bandwidth, not visibility. Every peer now runs the complete atmosphere and
water-effects stack. The server sends a half-second ocean-clock sample and clients converge on it
gently, so waves, animated clouds, cloud shadows, particle landings and foam share one timeline.
Continuous wakes are reconstructed from the replicated body transform and velocity; an entry or
slam is too brief to reconstruct, so its compact physical payload is sent reliably instead.

### Authority is split down the middle

The pattern that matters, and the one most tutorials get wrong: **the server owns the body, the
client owns only its input.** [scripts/network/player_input.gd](scripts/network/player_input.gd)
is a separate node whose authority is handed to the owning peer, while
[NetworkPlayer](scripts/network/network_player.gd) itself stays with the server.

If a client owned its whole character it would run its own buoyancy, the server would run it
too, and every wave would be a small argument between them — the body juddering between two
answers that are each locally correct. Here the client publishes what it *wants*, the server
decides what the sea does about it, and the result is replicated back. Non-authority peers do
not simulate at all: `NetworkPlayer._physics_process` returns immediately unless it is the
authority.

Players are `BuoyantBody` cubes, so they ride the swell, roll into wave faces, drift downwind
and carve a Kelvin wake when they move — the same water everything else in the project floats in.

### Things that bit

- **A `class_name` cannot match an autoload name.** `NetworkSession` is the singleton, so the
  script deliberately carries no `class_name` — with one, the parser reports only
  "hides an autoload singleton" and the autoload silently fails to create.
- **A replication config must exist before the node enters the tree.** Replication starts on
  tree entry, which is *before* any child's `_ready()`. Setting the config from a child node was
  always too late; the engine says only `ERR_UNCONFIGURED` in a log while the visible symptom is
  a player who never moves on the other screen. It is now built in `_init()` of a
  `MultiplayerSynchronizer` subclass, which is early by construction, and
  [tools/verify_multiplayer.gd](tools/verify_multiplayer.gd) asserts it on an instance that has
  not yet entered the tree.
- **Both windows start at once, so the client can beat the server to the socket.** A client
  launched from arguments retries for twelve seconds rather than giving up on its first attempt,
  which otherwise presents as a client stuck on "Offline" beside a perfectly healthy server.
- **`Label3D.fixed_size` is not what a name tag wants.** With it the text is screen-sized
  regardless of distance, and a name fills a third of the viewport. Plain billboarding with a
  small `pixel_size` is the setting that reads as a tag floating over a head.

## How the water works

### Waves are real

The surface is a spectrum of eight **Gerstner (trochoidal) waves** — the standard analytic
solution for deep-water gravity waves — and the spectrum itself is derived from **one number:
wind speed.**

- **Sea state follows the wind.** The **Pierson–Moskowitz** model of a fully developed sea
  gives significant wave height as `0.21·U²/g` and peak wavelength as `8.17·U²/g`. A 10 m/s
  breeze produces a 2.1 m sea on a 42 m swell; a 19 m/s gale produces a 7.7 m one — with
  height, length and period scaling together the way a real ocean's do, instead of three
  dials that have to be kept plausible by hand.
- **Amplitude is solved, not chosen.** Surface elevation from a sum of sinusoids has standard
  deviation `sqrt(Σa²/2)`, and significant wave height is four times that, so the dominant
  octave's amplitude is whatever reproduces the requested height once the rest of the
  spectrum is accounted for. Measuring the rendered surface back gives its stated wave height
  to within 0.1%.
- **Dispersion is obeyed.** `c = sqrt(g/k)`: wave speed is *derived* from wavelength, never
  set, so the 42 m swell runs at 8.1 m/s while the 5 m chop riding on it crawls at 2.8 — and
  the pattern never resolves into one rigidly translating shape.
- **Horizontal displacement is capped** across the spectrum, so the summed surface cannot
  fold through itself even at maximum steepness. That is the condition for the analytic
  normals meaning anything.
- **The octaves are irregular.** Fixed per-octave phase and direction offsets replace the
  symmetric fan. Without them every wave crests together at the world origin at `t = 0`,
  producing one implausible spike that then travels outward as a visible ring.

All of it is asserted in [tools/verify_waves.gd](tools/verify_waves.gd).

### …but the shading is cel

Physical accuracy stops at the geometry. The surface colour is quantised into hard bands:

- **Height bands** — the dominant cue. Colour steps from trough to crest in discrete
  jumps, and the bands shift *hue* (toward the shallow colour) as well as brightness, so
  each band reads as a separate painted region rather than as soft shading.
- **Depth bands** — Beer's-law absorption, quantised into steps.
- **Hard specular** — a `step()` cut-off rather than a GGX lobe, giving solid sparkle
  shapes with crisp edges. Godot's built-in specular is disabled entirely
  (`specular_disabled`), because its sky reflection greys the colour bands out.
- **Subsurface scattering** — sunlight through a thin crest, thresholded into two hard
  steps rather than a smooth glow, so a backlit wave gets a painted green rim.
- **Sun glitter** — the hard specular cut-off is lowered locally by a noise mask, so the
  sun's reflected path breaks into individual winking sparks instead of one white sheet.

### Foam is simulated, not thresholded

![whitecaps](docs/whitecaps.png)

Foam is the part of water that most obviously **has a memory**. A crest breaks, throws white
water, and leaves a streak that drifts downwind and dissolves over several seconds. Nothing
that reads only the current wave state can draw that, which is why stylised water so often
gives itself away with foam that appears and vanishes with the crest.

**Where foam comes from.** Not a height threshold — a height threshold marks a contour line
of constant elevation, which reads as a stroke painted across the water. The source is the
**determinant of the Jacobian of the horizontal displacement field**: 1 on undisturbed
water, above 1 where a trough is stretching apart, and below 1 where water is piling up
against itself on the steep face of a crest. That collapse is where a real wave breaks, and
it falls out of the same tangent/binormal accumulation the normals already need, so it costs
nothing to compute.

**How it persists.** [shaders/foam_sim.gdshader](shaders/foam_sim.gdshader) runs over a
world-space texture that follows the viewer, in a ping-pong pair of `SubViewport`s managed by
[scripts/foam_field.gd](scripts/foam_field.gd). Each frame the previous state is re-projected
onto the new window, drifted downwind at Stokes drift (~2.5% of wind speed), blurred outward
and decayed — then new foam is added from breaking waves and from objects. Two channels: **R**
is actively breaking foam, bright and short-lived; **G** is the residue it leaves behind, lacy
and slow to fade, which is what draws the streak behind a crest and the wake behind an object.

**How it is drawn.** The simulation only resolves foam down to its texel size, so the shape of
the *edge* — the thing the eye actually uses to identify foam — is added in the ocean shader:
three octaves of noise sampled in **wind space with the along-wind axis squashed**, so clumps
tear into streaks rather than isotropic blobs. The mask is contrast-stretched before use,
because summed value noise sits too narrowly around 0.5 to ever cross the cut and actually
remove foam; without that it only shades the patch instead of eating holes in it. Two hard
levels then paint a bright core inside a lacy fringe, speckled with bubbles.

Beyond the simulated area the analytic whitecap takes over, blended by distance — no memory,
but no cost either, and it keeps the horizon from looking suspiciously clean.

### Things float in it

![floating cube](docs/floating_cube.png)

[scripts/buoyant_body.gd](scripts/buoyant_body.gd) is a `RigidBody3D` that floats on the wave
field using the **Morison** formulation used for real offshore structures. The demo scene puts
a 6 m cube on the water to exercise it.

- **The hull is clipped, not approximated.** [scripts/hull_geometry.gd](scripts/hull_geometry.gd)
  takes the actual collision shape, clips it against the water plane every physics frame
  (Sutherland–Hodgman), caps the hole the cut leaves, and integrates the resulting closed
  polyhedron with the divergence theorem. Volume *and* centroid fall out of the same
  accumulation — exactly the pair Archimedes needs.
- **So shape drives draught.** A cube, a flat raft and a sphere at the same 380 kg/m³ settle at
  three different, individually correct heights: 0.776 m, 0.129 m and 0.520 m above the
  waterline. The sphere is checked against a bisected spherical-cap solution, because its
  submerged volume is a *cubic* in depth — the case no linear "submersion ramp" can get right.
- **And shape drives stability.** Because the upthrust acts at the centroid of the submerged
  volume, heeling a hull shifts that centroid to the low side and produces a real righting
  couple. A beamy raft is stiff and stays within 25° in a 2 m sea; a cube rolls to a
  corner-down attitude, which is genuinely its stable one; a tall spar capsizes, as a
  uniform-density spar must.
- **Added mass is why water feels heavy.** A body accelerating in water must accelerate the
  water around it too — half the displaced mass again in heave, by potential flow. Drag opposes
  *velocity* and vanishes at the top of a bob; added mass opposes *acceleration* and is
  strongest exactly there. Without it a hull springs like a cork on a spring, and no amount of
  drag tuning fixes it.
- **Drag is quadratic**, `½ρCdAv²`, against a reference area taken from the hull's real
  silhouette facing the flow — so a long hull is draggier broadside than head-on. That is what
  gives a falling body a terminal velocity instead of punching through the surface.
- **Wave forcing decays with depth.** Dynamic pressure under a deep-water wave falls as
  `e^(-kz)`, about 5% of its surface value half a wavelength down, so a deeply submerged body
  is not shoved around like a raft.
- **Drag is measured against the water, not against stillness.** `WaveField.sample_velocity()`
  is the exact time derivative of the displacement, including the circular orbital motion
  inside a wave — so the cube is carried forward under a crest and back in the trough, and
  drifts downwind over time.

### It reacts back

Objects in the water talk to the ocean over two deliberately separate channels.

**Continuous presence** goes through `Ocean.report_contact()` each physics frame and is read
back with `Ocean.get_active_contacts()`. The ocean forwards it to the surface shader and to the
foam simulation. Contacts expire on a timer rather than being cleared every frame, because they
arrive on the physics clock and are consumed on the render clock; clearing would strobe the wake.

**Discrete moments** — entering, leaving, or slamming into the surface — are raised as a
[WaterImpact](scripts/water_impact.gd) through the `water_impacted` signal, carrying the impact
point, surface normal, closing speed, full relative velocity, waterline radius and displaced
volume, plus derived impulse and energy. [WaterReactionSystem](scripts/water_reaction_system.gd)
turns those values into a preallocated spray burst and expanding foam/ripple crown: momentum sets
the breadth of the displacement, energy sets atomisation and launch speed, and the authority's
seed keeps the cel silhouette stable across peers. Entry, exit and slam therefore remain visually
distinct without networking individual droplets or letting presentation apply physics forces.

**A moving hull leaves a Kelvin wake.** A stationary object gets a symmetric hollow with a
raised rim. Once it is moving relative to the water, that becomes the V that trails every ship
on deep water, at the true **19.47° Kelvin half-angle** — which is *independent of speed*,
falling out of deep-water dispersion where group velocity is half phase velocity. The wake has
divergent arms along the edges of the V, transverse waves trapped inside it, and a bow wave
heaped up in front. The foam simulation mirrors the same geometry, so white water lands on the
crests the surface shader is actually raising rather than beside them.

> **Shader gotcha worth remembering:** `pow(x, 2.0)` is undefined for negative `x` in GLSL and
> returns NaN on real drivers. Both wake shaders originally squared a signed offset that way.
> NaN survives multiplication by zero, so no mask could contain it — it reached the vertex
> position and erased every triangle it touched, deleting half the ocean. Square by
> multiplication.

![cube at the waterline](docs/cube_waterline.png)

Floating props must use an **opaque** material. Godot queues any spatial shader that assigns
`ALPHA` as transparent, and a transparent surface neither writes depth under
`depth_draw_opaque` nor appears in the depth texture the water reads to work out how deep it
is — so the ocean, whose rings are re-centred on the camera and therefore always sort as the
nearest transparent object, paints straight over it.

### Spray, spindrift and rain

![spray off a breaking crest](docs/storm_spray.png)

Weather that can be seen *in the air*, not only on the water. Both effects are GPU particles
that know where the sea is: their process shaders include the same Gerstner spectrum the
surface is drawn from ([shaders/gerstner_waves.gdshaderinc](shaders/gerstner_waves.gdshaderinc)),
fed by the same `WaveField.apply_to_material()` and the same wave clock. So a droplet lands on
the wave that is actually drawn, rather than on a flat plane at sea level.

**How much spray there is follows from the wind, not from a dial.** The Beaufort scale
describes what a sea does at each wind speed, and [OceanSpray](scripts/ocean_spray.gd) uses
those descriptions directly: force 5 (8 m/s) brings a "chance of some spray" and force 6
"probably some spray", so spray ramps in across that range; force 7 (13.9 m/s) is where
"spindrift begins to be seen"; by the top of force 8 (20.7 m/s) "edges of crests break into
spindrift". The sunny preset's 8.5 m/s breeze therefore throws about one burst a second, and
the stormy gale throws some three thousand, streaming downwind. Neither number was chosen.

**Spray leaves the crests that are breaking** — not the tallest ones, but the same collapse of
the horizontal Jacobian that sources the foam. Particles are not emitted from a shape at all:
each one, on restart, examines eight random points of sea around the viewer and launches from
whichever is breaking hardest, with a probability equal to how hard. That is what makes the
budget usable. Scattering particles evenly and culling the ones that miss — the usual
approach — wastes most of them, so raising the count barely raises the density.

**Then it is ballistic.** Gravity, plus drag toward the wind that grows as the droplet
shrinks, so fine spindrift streams downwind while heavy spray arcs and falls back. Every
droplet tests itself against the analytic surface each frame and, where it lands, hands a
ripple ring to a sub-emitter.

**Rain is authored, not derived** ([RainShower](scripts/rain_shower.gd)). A squall can arrive
over any sea, so `rain_intensity` belongs to the weather preset. Everything else about it is
physical: drops fall at a raindrop's terminal velocity, lean with the same wind the waves are
built from, and are spawned upwind of where they will land by exactly the distance the wind
will carry them during the fall — so the rained-on patch stays centred on the viewer however
hard it blows.

![rain on the water](docs/rain_on_water.png)

**Rings ride the water they landed on.** A ripple is pinned to the *rest position* of the
water beneath it and re-placed from the spectrum every frame, so it travels round the wave's
orbit and up and down the swell instead of sitting still while the sea moves underneath it.
That is the difference between a disturbance in the surface and a decal on top of one.

**Everything is drawn with alpha scissor, which is both the style and the only correct
choice.** The ocean is transparent-queued and writes no depth, so an alpha-*blended* droplet
behind a swell would be painted over that swell instead of being hidden by it. A scissored
droplet is opaque: it writes depth, sorts correctly against the waves, and gets the hard
cut-out silhouette cel spray wants for free.

### The CPU knows where the water is

The GPU displaces the mesh, but nothing on the CPU can read that back cheaply. So
[scripts/wave_field.gd](scripts/wave_field.gd) evaluates *the same* spectrum on the CPU
for anything that needs to know where the surface actually is — buoyancy, spawning at
water level, or the camera's wave-riding mode.

`WaveField.apply_to_material()` pushes the *derived* spectrum to the shader — and to the foam
simulation, which takes the same uniform names. The Pierson–Moskowitz maths exists in exactly
one place and the GPU is told the answer, so the two cannot disagree.

Gerstner waves also move water *horizontally*, which means the surface directly above a
given XZ was generated somewhere else. `sample_surface_point()` inverts that with a
short fixed-point iteration when the offset matters.

### The sky is procedural too

[shaders/cel_sky.gdshader](shaders/cel_sky.gdshader) replaces the HDRI panorama the project
started with. A photographic sky over cel-shaded water reads as two different renderers in
one frame, and an atmospheric scattering model would produce exactly the smooth gradients
the look has to avoid — so the whole dome is quantised:

- the gradient from horizon to zenith **steps** rather than blends;
- clouds are FBM noise **hard-thresholded** into flat shapes, lit in three tones from
  `LIGHT0` so they turn with the scene's sun;
- the sun is a **solid disc** inside a banded halo.

Clouds are projected onto a flat plane rather than the dome, so they foreshorten toward the
horizon like real cloud cover. That projection runs away as it approaches the skyline, so
the high-frequency octaves are faded out with view height — band-limiting the noise where it
would otherwise alias into streaks.

### Weather

Three discrete presets — **sunny**, **overcast**, **stormy** — in
[resources/weather/](resources/weather/). Each is a [WeatherPreset](scripts/weather_preset.gd)
holding *everything that has to move together*: sky colours, cloud coverage, sun angle and
energy, ambient, the ocean's own palette, and the sea state.

That grouping is the point. Changing the sky without changing the sun and the water's tint
produces a scene lit by two different days at once, so one `apply()` writes all of them.
Stormy raises the **wind speed** to 19 m/s and the wave steepness with it, and a steeper sea
breaks more, so the whitecaps thicken and hold for longer along with the sky — and, since
spray follows the wind too, the crests begin to blow downwind as spindrift.

Rain is the one part of the weather that is *not* derived from the sea state. A squall can
come with any sea, so `rain_intensity` is authored on the preset.

Presets are deliberately discrete rather than points on a blend curve, so each mood can be
tuned to its best without compromising the others.

### Endless surface

[scripts/ocean.gd](scripts/ocean.gd) builds concentric mesh rings centred on the camera.
The inner ring is a dense grid; each ring outward doubles its quad size and is hollow,
so triangle density falls off with distance while screen-space density stays roughly
constant — 8 rings cover ±3072 m, with half-metre quads in the innermost one so an object's
wake has something to be carved into.

Each ring is re-centred on the viewer every frame and **snapped to its own quad size**.
The snapping is what prevents shimmer: a continuously-sliding mesh would have every
vertex sampling a different point of the wave field each frame, and the surface would
boil.

## Files

| Path | Role |
| --- | --- |
| [shaders/ocean.gdshader](shaders/ocean.gdshader) | The ocean: Gerstner waves + cel surface |
| [shaders/cel.gdshader](shaders/cel.gdshader) | General cel shader for props, matching the water's banding |
| [shaders/cel_outline.gdshader](shaders/cel_outline.gdshader) | Inverse-hull ink outline (use as a `next_pass`) |
| [shaders/cel_sky.gdshader](shaders/cel_sky.gdshader) | Procedural cel sky: banded gradient, hard-edged clouds, solid sun |
| [shaders/foam_sim.gdshader](shaders/foam_sim.gdshader) | Persistent foam: whitecaps, object wakes, drift and decay |
| [scripts/weather_preset.gd](scripts/weather_preset.gd) | One complete weather look, applied atomically |
| [scripts/weather_controller.gd](scripts/weather_controller.gd) | Owns the presets and the switching |
| [scripts/wave_field.gd](scripts/wave_field.gd) | CPU mirror of the wave spectrum |
| [scripts/ocean.gd](scripts/ocean.gd) | Endless LOD ring surface; the front door to the water |
| [scripts/foam_field.gd](scripts/foam_field.gd) | Ping-pong buffers driving the foam simulation |
| [scripts/buoyant_body.gd](scripts/buoyant_body.gd) | A rigid body that floats, rolls and makes foam |
| [scripts/hull_geometry.gd](scripts/hull_geometry.gd) | Clips a hull against the water and integrates what is under it |
| [scripts/water_impact.gd](scripts/water_impact.gd) | One discrete entry, exit or slam |
| [scripts/water_contact.gd](scripts/water_contact.gd) | A snapshot of something continuously in the water |
| [scripts/water_reaction_system.gd](scripts/water_reaction_system.gd) | Pooled, energy-driven impact spray and foam crowns |
| [scripts/free_camera.gd](scripts/free_camera.gd) | Fly camera with wave-riding mode |
| [scripts/network/network_session.gd](scripts/network/network_session.gd) | The `NetworkSession` autoload: hosting, joining, the roster |
| [scripts/network/multiplayer_game.gd](scripts/network/multiplayer_game.gd) | Runs the networked demo: spawning, weather RPCs, the HUD |
| [scripts/network/network_player.gd](scripts/network/network_player.gd) | A player: a `BuoyantBody` cube the server simulates |
| [scripts/network/player_input.gd](scripts/network/player_input.gd) | The one node a client owns; publishes intent, nothing else |
| [scripts/network/player_replication.gd](scripts/network/player_replication.gd) | The player's synchronizer, configured in code |
| [scripts/network/player_camera.gd](scripts/network/player_camera.gd) | Third/first person rig: pivot, spring arm, level horizon |
| [scripts/network/test_window_layout.gd](scripts/network/test_window_layout.gd) | Puts the two debug instances side by side |
| [shaders/gerstner_waves.gdshaderinc](shaders/gerstner_waves.gdshaderinc) | The wave spectrum, for shaders that are not the surface |
| [shaders/spray_particles.gdshader](shaders/spray_particles.gdshader) | Spray and spindrift: finds a breaking crest, launches, flies, lands |
| [shaders/rain_particles.gdshader](shaders/rain_particles.gdshader) | Rain: fills a column around the viewer and falls onto the swell |
| [shaders/ripple_particles.gdshader](shaders/ripple_particles.gdshader) | Ripple rings, pinned to the water they landed on |
| [shaders/spray_droplet.gdshader](shaders/spray_droplet.gdshader) | Draws a droplet: velocity-stretched, hard-edged, eroding |
| [shaders/ripple_ring.gdshader](shaders/ripple_ring.gdshader) | Draws a ripple: hard rings that race out, thin and break up |
| [shaders/impact_foam_ring.gdshader](shaders/impact_foam_ring.gdshader) | Draws the seeded cel foam crown from a discrete impact |
| [scripts/ocean_particles.gd](scripts/ocean_particles.gd) | Base for particle effects that live on the ocean |
| [scripts/ocean_spray.gd](scripts/ocean_spray.gd) | Spray and spindrift, in Beaufort proportion to the wind |
| [scripts/rain_shower.gd](scripts/rain_shower.gd) | Rain, for the weathers that bring it |
| [tools/run_suites.gd](tools/run_suites.gd) | Runs every suite below in turn; one command, one exit code |
| [tools/verify_waves.gd](tools/verify_waves.gd) | Headless wave-physics assertions |
| [tools/verify_buoyancy.gd](tools/verify_buoyancy.gd) | Headless assertions on floating bodies |
| [tools/verify_spray.gd](tools/verify_spray.gd) | Spray and rain assertions, including GPU-vs-CPU wave parity |
| [tools/verify_multiplayer.gd](tools/verify_multiplayer.gd) | Networking assertions over a real loopback connection |
| [tools/verify_reactions.gd](tools/verify_reactions.gd) | Live impact-pool and multiplayer VFX parity checks |
| [tools/verify_session_identity.gd](tools/verify_session_identity.gd) | Colour allocation across churn, and weather sent to a joining peer |
| [tools/verify_raft.gd](tools/verify_raft.gd) | Raft buoyancy, deck movement and late spawns |
| [tools/capture_multiplayer.gd](tools/capture_multiplayer.gd) | Photographs both windows of a running session |
| [tools/capture_camera.gd](tools/capture_camera.gd) | Photographs both view modes at several pitches |
| [tools/wave_probe.gdshader](tools/wave_probe.gdshader) | Renders the wave include into a float texture for that comparison |
| [tools/capture_spray.gd](tools/capture_spray.gd) | Photographs spray and rain; `-- --spray-debug`, `--no-rain`, `--no-cube`, `--no-particles` |
| [tools/generate_water_normals.py](tools/generate_water_normals.py) | Generates the tiling detail normal map |
| [tools/capture_screenshot.gd](tools/capture_screenshot.gd) | Renders the demo to PNGs |
| [tools/capture_weather.gd](tools/capture_weather.gd) | Renders every weather preset from two framings |
| [tools/capture_water.gd](tools/capture_water.gd) | Renders the water and the floating cube; `-- --no-fog` to drop the atmosphere |
| [tools/capture_wake.gd](tools/capture_wake.gd) | Drives a hull through the sea and photographs its Kelvin wake |

## Tuning

Everything is exposed on the ocean material. The parameters that most change the
character:

| Parameter | Effect |
| --- | --- |
| `wind_speed` (on the `WaveField`) | **The sea-state dial.** Everything else follows: height, wavelength, period. |
| `steepness` (on the `WaveField`) | Wave age. Sharp crests, broad troughs, and more whitecaps. Capped, so 1.0 is safe. |
| `wavelength_scale` | Art direction. Below 1 pulls the swell in close enough to read as waves. |
| `wind_angle` / `wind_spread` | Direction, and how much the spectrum fans out from it. |
| `whitecap_threshold` | How compressed water has to be before it foams. **Higher = more foam.** |
| `foam_persistence` (per weather) | How long a foam streak survives. The difference between foam and paint. |
| `foam_noise_scale` / `foam_streak_stretch` | Size of the torn clumps, and how far they streak downwind. |
| `contact_depth` | How deep an object dents the surface it is floating in. |
| `wake_full_speed` | Speed at which a moving object's wake reaches full strength. |
| `wake_length` | How far astern the wake persists, in object radii. |
| `wake_arm_height` / `wake_bow_height` | Height of the V's arms, and of the bow wave in front. |
| `body_density` (on the `BuoyantBody`) | **The draught dial.** 1025 is neutral; below it floats. |
| `drag_coefficient` | ~0.9 for a bluff box, 0.1–0.3 for a faired hull. |
| `hull_detail` | Triangles the clipped hull carries. The main buoyancy performance dial. |
| `amount` (on `OceanSpray` / `RainShower`) | Particle budget. A spray slot that finds no crest dies at once and costs nothing more. |
| `amount_scale` (on `OceanSpray`) | Art multiplier on the Beaufort-derived amount of spray. 1 is as the scale describes. |
| `threshold_offset` (on `OceanSpray`) | How much harder than a whitecap a crest must break before it throws spray. |
| `rain_intensity` (per weather) | How hard it rains, 0 to 1. Authored per preset rather than derived from the sea. |
| `near_fade` | Distance within which drops are not drawn, so none is ever a streak across the lens. |
| `height_bands` | **The main cel dial.** Fewer bands = more graphic. |
| `wave_band_tint` | How far lit bands shift toward the shallow colour. Drives hue separation. |
| `wave_shade_strength` | Contrast between bands. |
| `band_softness` | 0 = razor-hard edges. Raise slightly to fight distant aliasing. |
| `specular_threshold` | Near 1.0 keeps the glint tight; lower floods the sun's path with white. |
| `detail_fade_start` / `_end` | Distance over which fine ripples fade out. |

If waves and buoyancy ever disagree, check that the `WaveField` resource and the shader
parameters match — `apply_to_material()` is the intended single source of truth, and it feeds
the foam simulation as well as the surface.

All seven suites should be green before believing anything visual. The spray one renders the
particles' own copy of the wave spectrum into a texture and compares it against the CPU field
point by point, so it needs a real renderer rather than `--headless`:

```sh
godot --path . --headless --script tools/run_suites.gd
```

That runs all seven in turn, handles the spray suite's different invocation, and exits non-zero
if any of them fails, so it is usable from CI. Add `-- --only=raft` to run just the suites whose
name matches. Every suite binds a fixed port, so do not run one by hand while the runner is
going: a clash presents as `Couldn't create an ENet host` rather than as a clear error.

The runner names every failing check in its summary, so read that rather than a list
here — an earlier version of this paragraph named three checks and was out of date
within hours. When a check does fail, [planning/](planning/) records what was behind it.

What is worth stating permanently is why none of them is suppressed. A list of expected
failures cannot tell a check failing for the old reason from the same check failing for a
new one. Every failure investigated so far has turned out to be a real defect — in the
game or in the test — rather than a threshold that wanted loosening: a held input action
leaking between checks because `Input.action_press` is process-global, a player pose sampled
during a wave transient rather than at rest, and a movement check that passed only because
the raft was heaving hard enough to fling the player along it. Each had to stay visible to
be found.

To run them individually:

```sh
godot --path . --headless --script tools/verify_waves.gd
godot --path . --headless --script tools/verify_buoyancy.gd
godot --path . --headless --script tools/verify_reactions.gd
godot --path . --headless --script tools/verify_multiplayer.gd
godot --path . --headless --script tools/verify_session_identity.gd
godot --path . --headless --script tools/verify_raft.gd
godot --path . --script tools/verify_spray.gd --rendering-driver d3d12
```

## Weather looks

| | |
| --- | --- |
| ![sunny](docs/weather_sunny.png) | ![overcast](docs/weather_overcast.png) |
| **Sunny** — high sun, scattered cloud, warm glints | **Overcast** — heavy grey lid, cold steel water |
| ![stormy](docs/weather_stormy.png) | |
| **Stormy** — ragged dark cover, slate sea, big whitecaps | |

## Assets

- **Skies** — procedural; see [shaders/cel_sky.gdshader](shaders/cel_sky.gdshader). The
  [Poly Haven](https://polyhaven.com) HDRIs (CC0) remain in `assets/hdri/` as a photoreal
  reference to compare against, but the scene no longer uses them.
- **Water detail normals** — generated by
  [tools/generate_water_normals.py](tools/generate_water_normals.py). Neither Poly Haven
  nor ambientCG carries a true water-surface normal map (their water-tagged assets are
  ice, wet ground and puddle overlays), so it is synthesised from periodic value noise
  instead. Periodicity is what makes it tile seamlessly; measured edge deltas are 4–5/255.

## Conventions

Code follows the [official GDScript style guide](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_styleguide.html):
tabs, LF endings, 100-column lines, Godot's prescribed member order, `snake_case` files
named after their `class_name`, past-tense signals, and full static typing. Public API
carries `##` documentation comments that render in the editor's help; `#` comments explain
why a piece of code is the way it is.

The `.editorconfig` enforces the mechanical parts.

## Notes for future work

These bit hard during development and are worth knowing:

- **Triangle winding.** Godot treats *clockwise* faces as front-facing. The ring meshes
  originally wound counter-clockwise, so with `cull_back` every near-flat part of the
  ocean was culled and the sky showed through — which looked exactly like a shading bug
  and sent the investigation down several wrong paths. If the water ever goes
  "transparent" in patches, check winding first.
- **One clock, not two.** The CPU and the shader both evaluate the wave spectrum, so
  `ocean.gd` accumulates time in `_process` and pushes it to the shader as `wave_time`
  rather than letting the shader read its own `TIME`. Two independent clocks drift apart
  under `Engine.time_scale` or pausing, and floating objects then sit at the wrong height.
- **`cel_quantize` remaps, it does not attenuate.** It snaps its input onto band centres,
  so an input of 0.05 comes back as `1/bands` — *larger* than it went in. It is right for
  lighting terms, and wrong for blend weights like fresnel, where it turns a faint
  grazing reflection into a full band of sky tint.
- **Writing `ALPHA` makes a material transparent, with consequences.** A transparent surface
  does not write depth under `depth_draw_opaque`, never appears in the depth texture, and is
  sorted against other transparent surfaces by *object origin*. The ocean's rings are
  re-centred on the camera, so they always sort as the nearest object and are drawn last —
  which made every prop in the water vanish under the water it was floating on. Props stay
  opaque; the ocean sits at a negative `render_priority` to cover the rest.
- **Noise multiplied into a mask only shades it.** Summed value noise clusters narrowly
  around 0.5, so multiplying foam by it darkens the patch without ever crossing the cut-off
  that would remove any. Contrast-stretch the mask first, or the foam stays a smooth white
  puddle no matter how many octaves are layered on.
- **`set_process(false)` from an autoload does not stick.** A node that implements `_process`
  has processing switched back on when it enters the tree, and autoloads are readied before
  the main scene. The screenshot tool silenced the free camera once on ready, the camera
  re-enabled itself, and every shot came out taken from the right place pointing the wrong
  way — with nothing in the log to say so. `tools/capture_water.gd` re-asserts it per frame.
- **`await` inside `_process` runs a coroutine per frame.** `_process` keeps being called
  while an earlier call is suspended on `frame_post_draw`, and they all resume on the same
  emission. A screenshot tool built that way burns through its shot list in two frames and
  saves each image under a framing a later coroutine has already replaced. Drive a capture
  sequence from a single coroutine instead.
- **Particle processor functions may not `return`.** Godot inlines `start()` and `process()`
  into its own particle shader and rejects an early return in either, so every early exit has
  to be written as a nested condition. It is a compile error, which means `--headless` never
  sees it: the shader is only built when a running scene first uses it.
- **A particle that dies only on an event outlives the effect.** Rain drops died when they
  landed, which is right until the rain stops — the emitter stops restarting slots, and
  anything still in the air hangs there, leaving streaks of rain falling through a scene that
  has been sunny for ten seconds. Every particle needs a life of its own as well.
- **`smoothstep(a, a, x)` divides by zero.** Switching an effect off by setting both edges
  equal is the obvious way to say "none of this", and it produces NaN across the whole
  fragment rather than nothing. Hold the far edge clear: `smoothstep(a, max(a + 0.001, b), x)`.
- **State that is only sent on change never reaches a late joiner.** Weather was broadcast
  from the change handler alone, so anyone arriving afterwards kept the preset their own
  `WeatherController` applied on ready. That is not a cosmetic mismatch: the preset carries the
  wind speed the Pierson-Moskowitz spectrum is derived from, so the client drew a different sea
  from the one the server solved buoyancy against — measured at 5.66 m of surface disagreement
  between a sunny client and a stormy server, which is every hull floating in mid-air or sunk.
  Anything replicated on an event needs a matching "here is the current value" on join.
- **A child count is not an allocation.** Player colours were handed out as
  `_players.get_child_count()`, which is only correct while nobody ever leaves. Join three,
  lose the second, and the fourth player is dealt the colour the third is already wearing —
  and colour is the only thing telling players apart. Count the slots that are *taken*, not
  the ones that exist.
- **A particle budget is not a particle count.** Spray rejects most restarts by design, so
  the visible density is `amount / lifetime × P(launch)`, and the emitter's *cycle* is the
  other half of it: rain with an 8.9 s cycle but a 1.6 s fall left four fifths of its slots
  idle, and looked thin no matter how high the count went.
