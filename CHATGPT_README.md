# ChatGPT Development Handoff — SpaceMinerGame

> **Read this file before making changes to this project.**
>
> This is a development-context handoff for future ChatGPT sessions. It summarizes the important design decisions, implementation history, user requirements, current behavior, known failure modes, and workflow conventions accumulated during the prototype work.
>
> **Repository:** `AkitaAttribute/SpaceMinerGame`  
> **Working branch:** `prototype/ship-builder-first-pass`  
> **Draft PR:** #1 — `Initial modular ship builder prototype`  
> **Snapshot when this handoff was written:** `0cf5292a2212395b10005eb98913970cb8ba4d6e`  
> **Godot:** 4.7.1  
> **Current snapshot CI:** push run #256 and PR run #257 both passed.
>
> This file is a handoff, not a substitute for checking the current branch. Before editing, fetch the branch head, inspect the relevant current source files, and check CI. Later commits may supersede details below.

---

## 1. Product vision

SpaceMinerGame is a low-effort space-mining / logistics game prototype.

The high-level mechanical inspirations are:

- **EVE-style asteroid mining:** ships orbit or maneuver around asteroid fields while mining resources over time.
- **Kingdom Hearts Gummi Ship-style construction:** player ships are assembled from modular pieces on a 3D grid.
- The eventual direction is broader automation/logistics, but the current prototype is focused on:
  1. the modular ship builder,
  2. persistent ship models,
  3. test-flight simulation,
  4. asteroid mining,
  5. a large orbital asteroid-ring scene.

The user strongly prefers getting concrete working behavior into the repository over abstract architectural discussion.

---

## 2. How to work with this user/project

### Make changes directly in GitHub

The normal workflow is to edit the repository directly on:

`prototype/ship-builder-first-pass`

Use the GitHub connector. Do not merely paste theoretical code unless the user explicitly asks for an example.

After a change:

1. commit it to the branch,
2. report the commit SHA,
3. check GitHub Actions before claiming that it passes.

Do not claim CI success while it is queued or in progress.

### Treat user-described behavior literally

A recurring pattern in this project is that a technically plausible interpretation is not necessarily the requested behavior. When the user clarifies a visual or control issue, preserve that exact behavioral requirement.

Examples:

- “A/D reverse steering” means **only while S is physically held**, not while the ship still has reverse momentum.
- “Actual ship hitbox” means collision should follow the rendered modular geometry, **not one box around the ship’s occupied grid extents**.
- “Render the full ring” means the full 360-degree ring should exist persistently, not a local section that is recycled around the player.
- “Near asteroids should not have changed at all” means performance LOD must never alter normal nearby asteroid rendering.

### Avoid regressions from optimization work

Rendering optimization has caused several visible regressions. Do not optimize by replacing nearby real meshes, changing nearby face culling, or allowing visual state to depend on camera direction.

Performance work should first target:

- distant cosmetic updates,
- distant physics,
- draw-call batching that does not alter nearby models,
- update frequency for distant-only behavior.

### Diagnostics matter

If the UI shows a generic `Error`, there should be a useful breadcrumb in `SpaceMinerGame.log`.

The user checks logs and screenshots when something behaves incorrectly.

---

## 3. Important files

### Main builder

- `main.tscn`
- `scripts/main.gd`

Contains:

- ship selector,
- ship builder,
- 20×20×20 editor grid,
- parts drawer,
- placement/removal,
- camera,
- rotation controls,
- color UI,
- thumbnails,
- settings integration.

### Part definitions and procedural meshes

- `scripts/part_factory.gd`

Contains:

- part definitions,
- color-region definitions,
- default colors,
- procedural mesh construction,
- functional thrusters,
- mining laser geometry,
- occupied-cell offsets,
- flat/unshaded materials.

### Simulation

- `simulation.tscn`
- `scripts/simulation.gd`

Contains:

- test flight,
- ship physics,
- camera,
- mobile joystick,
- asteroid population,
- planet/ring,
- mining lasers,
- auto orbit,
- collision recovery,
- debug UI,
- ship collision geometry.

### Asteroids

- `scripts/space_asteroid.gd`

Contains:

- logical voxel asteroid state,
- exposed-face mesh generation,
- exact mined collision partition,
- mining preparation/commit,
- orbital motion,
- random spin,
- asteroid color palettes,
- visibility/culling safeguards.

### Persistence/settings

- `scripts/ship_store.gd`
- `scripts/app_settings.gd`
- `scripts/ui_theme.gd`
- `scripts/app_logger.gd`

### CI/export

- `.github/workflows/windows-build.yml`
- `export_presets.cfg`
- `project.godot`

---

## 4. Builder: established behavior

### Grid and navigation

The editor is a 20×20×20 logical construction grid.

Desktop:

- WASD / arrows move the cursor in the horizontal plane.
- E/Q move vertically.
- Tab toggles the Parts drawer.
- Escape opens/back/resumes menus.
- Mouse drag/orbit behavior is camera-relative.
- Part movement/rotation is camera-relative where appropriate, but **part rotation itself was deliberately decoupled from camera orientation** so a piece’s rotation remains predictable.

Mobile:

- landscape presentation,
- right-side on-screen D-pad,
- separate up/down Z controls,
- touch drag orbits camera,
- touch controls remain visible in builder,
- D-pad scale is configurable in 10% steps with a numeric field,
- no artificial min/max clamp was requested for the percentage setting,
- 100% must reproduce the original geometry exactly.

### Parts drawer

Current expected layout:

- `SHIP PARTS`
- horizontal part cards
- Color section
- only the **color slots for the selected part**
- Place / Remove controls
- help text

The user explicitly rejected embedding the whole color palette directly in the drawer.

### Current color UI

Current behavior as of `0cf5292`:

In the Parts drawer, each color region is a row like:

`[Area Name                         ■]`

The row shows:

- the color-region name,
- a compact square swatch on the right,
- **no hex text in the drawer**.

The compact swatch uses the same visual styling as the popup color squares, scaled down for the drawer.

Clicking a color-region row opens a separate popup.

Popup contains:

- preset color grid,
- custom hex field,
- live color preview box,
- Close button.

Preset colors currently include:

- primary: red, yellow, blue,
- secondary: orange, green, purple,
- tertiary: red-orange, yellow-orange, yellow-green, blue-green, blue-violet, red-violet,
- neutrals: black, white.

Clicking a preset:

- immediately applies it to the region that opened the popup,
- closes the popup.

Custom hex:

- accepts RGB or RGBA hex,
- live-updates the preview box when valid,
- Enter or clicking the preview box applies,
- then closes the popup.

Do **not** restore Godot’s full ColorPicker wheel or shader/value sliders unless explicitly requested.

### Part color regions

Parts use named color slots.

Important current mining-laser change:

- **Housing**
- **Turret**

The turret defaults to the same dark gray used by the thruster cone.

Legacy saved ships may only contain the older one-color mining-laser array. `PartFactory.normalize_colors()` was added so missing new color slots are filled from current defaults instead of breaking or becoming white.

### Flat visual style

Builder parts are deliberately:

- flat,
- unshaded,
- shadow-free or effectively neutral.

Do not reintroduce normal dramatic lighting/shading unless the user requests it.

### Selection/highlight history

Selection highlighting had several native-renderer crash/inconsistency problems earlier.

The project moved toward geometric edge outlines and special handling for curved pieces.

The diagnostic logger includes `HIGHLIGHT ...` breadcrumbs because this was previously crash-prone.

Be cautious when changing highlight mesh traversal or curved-part highlight generation.

### Rotation guide

The rotation guide has a designated **mounting base/reference face** per part.

Do not redefine orientation purely from camera direction.

---

## 5. Ship model selector and persistence

`ShipStore` persists models under `user://ships`.

Models support:

- create,
- list,
- load,
- save,
- thumbnail,
- rename,
- export JSON,
- import JSON,
- copy JSON to clipboard,
- paste JSON,
- delete.

Format wrapper:

- `SpaceMinerShip`
- version 1

Stored model data includes:

- name,
- camera,
- parts,
- part colors,
- part basis/orientation.

### Selector behavior

Startup enters the model selector.

Selector includes:

- Add,
- Import,
- per-model thumbnail/name/gear,
- Rename,
- Export,
- Copy JSON,
- Delete,
- shared settings gear.

### Thumbnail rule: non-negotiable

Ship thumbnails must contain the ship only.

Do not include:

- editor UI,
- grid,
- D-pad,
- labels,
- guides,
- buttons.

Thumbnail capture is intentionally done when returning to the selector rather than constantly while editing.

---

## 6. Test flight / ship physics

### Direction comes from thrusters

Ship forward is derived from the saved thruster bases/orientations.

Do not hard-code a universal construction-grid forward direction for flight.

A possible future validation rule is that all thrusters must point in a coherent direction, but that is not implemented as a builder restriction yet.

### Desktop movement semantics

Important:

- W = forward thrust.
- S = reverse/braking thrust.
- A/D alone = turn and propel forward.
- A/D + S = reverse steering/thrust behavior.
- **The instant S is released, A/D return to normal forward behavior.**
- Residual reverse velocity must not “latch” A/D into reverse mode.

This was fixed in commit `f9fcebe`.

### Boat-like movement

Flight intentionally has:

- longitudinal acceleration/drag,
- lateral slip,
- yaw inertia,
- heel,
- momentum.

Do not turn it into instant arcade translation unless requested.

### Mobile flight

Mobile flight uses Godot’s native `VirtualJoystick`.

Requirements:

- bottom-right,
- visually transparent/subtle,
- any meaningful joystick displacement produces thrust,
- angular deviation controls turning urgency,
- drag outside joystick orbits camera.

### Camera

Third-person camera goals:

- stable,
- no head-bob,
- no FOV pumping,
- motion-sickness-conscious,
- smooth follow/orbit.

Horizontal and vertical inversion are separate settings.

Current defaults:

- horizontal inversion: false,
- vertical inversion: true relative to the original implementation.

### Desktop Tab behavior in flight

Mouse is normally captured.

Holding **Tab**:

- releases mouse capture,
- freezes camera orbit,
- allows clicking HUD elements such as Auto Pilot.

Releasing Tab:

- recaptures mouse unless a menu is open.

Focus changes were also handled to prevent stuck capture state.

---

## 7. Ship collision: current implementation

The user explicitly rejected one large bounding box around the ship’s grid extents.

The current implementation builds moving ship collision from the **actual rendered procedural meshes**:

- traverse ship `MeshInstance3D` nodes,
- create a convex collision shape for each rendered mesh,
- add those shapes to the `CharacterBody3D`,
- synchronize collision transforms to their source visuals.

This means:

- cubes collide as cubes,
- slopes as slopes,
- pyramids as pyramids,
- hemispheres/thrusters/mining-laser pieces follow their rendered geometry much more closely,
- empty grid space inside the overall ship extents is not one giant solid box.

The collision transforms are synchronized around physics/mining updates because some visual children, especially mining turrets, can rotate.

### Debug ship hitbox

The old debug hitbox was one cyan box.

It is now meant to show the real per-piece geometry.

A first attempt used a nonexistent Godot enum:

`BaseMaterial3D.POLYGON_MODE_LINE`

That caused simulation-smoke CI failures in commits `8b2b856` / `afe6023`.

Commit `8e4f916` fixed this by generating line geometry from mesh triangle edges instead.

**Do not reintroduce `POLYGON_MODE_LINE` in Godot 4.7.1.**

### Important remaining distinction

`ship_cell_boxes` still exists for mining-laser obstruction checks.

That is intentionally separate from physics collision:

- physical ship/asteroid collision now follows actual mesh-derived convex geometry,
- mining obstruction is still based on occupied builder cells.

If obstruction accuracy becomes an issue, this distinction is a likely place to investigate.

---

## 8. Collision recovery

Asteroid collision recovery was tuned through several iterations.

Established behavior:

- collision temporarily takes over control,
- normal propulsion/boat physics pauses,
- ship executes one smooth ±90° avoidance turn,
- ship is moved outward until safely separated,
- no retrigger while recovery is active,
- clearance target includes 5 builder cells,
- pre-impact speed magnitude is preserved,
- after recovery, that speed resumes **along the new forward direction**, not the old collision vector.

Current constants historically include approximately:

- recovery duration: 1.35 s,
- clearance: 5 cells,
- turn: 90°.

Do not restore momentum toward the asteroid after recovery.

---

## 9. Planet and asteroid ring

### Planet

Current planet:

- one sphere,
- center approximately `Vector3(0, 0, -2400)`,
- radius `520`,
- procedurally generated heatmap-like land/water texture,
- unshaded material.

Texture concept:

- deep/shallow water,
- green lowland,
- tan highland,
- darker mountains.

It is intentionally a single sphere, not a multi-mesh terrain system.

### Ring

The asteroid belt is a persistent full 360° ring around the planet.

Current key parameters:

- `RING_ASTEROID_COUNT = 420`
- base radius ≈ `2400`
- radial half-width ≈ `105`
- vertical half-thickness ≈ `18`
- common linear orbital speed ≈ `1.20`
- camera far plane ≈ `7000`

Each asteroid:

- follows the same orbital direction,
- uses the same linear ring speed,
- has independent random gentle 3D spin when in detailed range,
- uses one of two color palettes:
  - ice blue / dark blue,
  - dirt brown / tan brown.

### Asteroid sizes

Asteroids are now random **3×3×3 through 9×9×9 logical cells**.

The old prototype initially used 20×20×20; many older comments/commits reference that. Do not assume those comments are current.

### Full-ring population rule

Every angular slot should result in an asteroid.

A bug previously allowed a slot to be skipped if spawn-clearance tests failed, creating large permanent missing arcs.

The full-ring population logic now:

- retries radial/vertical placement,
- falls back to alternate lanes,
- should still instantiate the slot.

The log emits:

`RING populated requested=420 actual=420`

If the ring appears incomplete, check that diagnostic first.

### Visibility rule: extremely important

The user observed asteroids disappearing/reappearing while panning and described an earlier bug as looking like the inside of a thin shell.

Near asteroids must render normally at all camera angles.

Current asteroid mesh safeguards:

- `cull_mode = CULL_DISABLED`
- explicit conservative `custom_aabb`
- extra cull margin
- `ignore_occlusion_culling = true`

Do **not** enable back-face culling on the procedural asteroid surface unless the face winding/mesh architecture is deliberately redesigned and visually verified.

---

## 10. Asteroid rendering / LOD history and lessons

This area has produced the most regressions.

### Bad optimization path

Commits around:

- `394dbd9` — asteroid LOD/back-face culling
- `f9d2043` — obstructed laser retarget + full-ring optimization

introduced visual problems.

Symptoms included:

- nearby asteroid exterior seeming to disappear from some angles,
- appearance that asteroid geometry “followed the camera,”
- seeing what looked like interior faces from outside,
- missing/popping asteroids.

A later attempt using far surrogate/proxy meshes also caused camera-relative visual behavior and was removed.

### Current intended LOD rule

Nearby asteroid behavior must remain equivalent to the original real asteroid:

- real procedural mesh,
- real world transform,
- orbit updated every frame,
- random spin updated every frame.

For distant asteroids:

- still update orbital world position every frame,
- cosmetic random spin can be frozen,
- physics collision can sleep/disable,
- no camera-dependent surrogate geometry.

Current detailed-distance rule is approximately:

`max(250, distance(ship, planet center) - planet radius)`

At the starting ring this is around 1880 world units.

Far asteroid physics currently wakes within roughly 280 units.

### Core rule

**Never optimize by making the visible asteroid representation camera-dependent.**

If performance still needs work, prefer:

- far-only rotation suppression,
- far-only collision sleeping,
- future proper GPU instancing for genuinely distant assets if it can preserve world-space appearance,
- profiling before replacing working near rendering.

---

## 11. SpaceAsteroid architecture

Asteroids are logical voxel volumes, but they are **not** rendered as thousands of cube nodes.

A `SpaceAsteroid` uses:

- logical cell occupancy,
- one mutable exterior `MeshInstance3D`,
- only exposed voxel faces,
- deterministic cell colors,
- exact collision represented as merged AABB boxes,
- one rotating/orbiting asteroid body.

This was originally designed to avoid rendering 8000 individual cube instances for 20³ asteroids. The same principle remains valid for 3–9-cell asteroids.

### Mined geometry preparation

A noticeable frame hitch occurred exactly when a mined voxel detached.

The solution was to move expensive work earlier during the 5-second mining cycle.

`prepare_detach_cell(cell)` builds:

- future surface-cell state,
- future combined mesh,
- future collision-box partition.

`commit_prepared_detach(prepared)` then applies the already prepared result.

This keeps the break-off frame cheap.

Do not casually move mesh/collision reconstruction back to the detach frame.

### Exact asteroid collision after mining

Initial asteroid collision is one full cube.

As voxels are removed, the containing collision cuboid is split into surrounding exact boxes.

This avoids a full occupancy rescan on normal mining operations.

A full rebuild remains a fallback path only.

---

## 12. Mining lasers

### Builder geometry

Mining laser consists of:

- housing,
- rotating turret/pivot,
- cylinder barrel.

Current color regions:

1. Housing
2. Turret

Turret default = thruster-cone dark gray.

### Range

Current mining range is **40 builder cells**.

Range is measured from the edge/support volume of the laser’s builder cell to the asteroid’s current exact occupied collision geometry.

It is not just center-to-center distance.

### Targeting

Each mining laser is independent.

Different lasers on the same ship may target different asteroids.

Target behavior:

- choose in-range asteroid,
- keep target while valid,
- if obstructed, seek another unobstructed in-range target,
- do not require all lasers to share one target.

### Obstruction

Only solid ship-builder occupancy blocks the mining beam.

Specifically, obstruction checks intentionally exclude:

- detached tractor chunks,
- beam particles,
- other visual effects.

Do not add those to obstruction.

### Reservation / multi-laser mining

Multiple lasers can mine the same asteroid.

Each laser reserves a unique surface voxel.

Other lasers targeting that asteroid exclude already reserved cells.

Prepared geometry can become stale after another laser commits first. The stale laser should:

- refresh preparation against the new asteroid version,
- keep its completed mining progress,
- commit on the next frame,
- **not restart the full 5-second mining cycle**.

### Recent generic `Error` bug

A laser previously displayed `Error` when its target had no currently available unreserved surface cell.

That was not a true runtime failure.

Current behavior after `afe6023`:

- before choosing a target, check that the target has an unreserved available surface cell for that specific laser,
- if current target has no free selection, look for another valid target,
- if no replacement exists, wait/retry rather than showing `Error`.

Actual hard-error states now log a specific diagnostic, e.g.:

`MINING LASER ERROR index=... reason=...`

The user specifically reported a case where two lasers showed Error and a third later mined successfully. This reservation/selection behavior was the suspected cause.

### Beam timing

Current behavior:

- mining duration: 5 s,
- starts aimed roughly at asteroid center,
- over the final ~1.5 s smoothly transitions center → reserved surface voxel,
- beam remains continuous once firing,
- turret tracking speed was increased to about 68°/s,
- extracted chunk tractors toward ship.

### Out-of-range turret behavior

When target leaves range:

- beam stops,
- mining resets as appropriate,
- turret **holds its current orientation**.

Do not automatically return it to rest orientation.

### Status panel

Compact bottom-left panel, one row per laser.

Expected statuses:

- green dot, no text = OK,
- red `Out of Range`,
- red `Obstructed`,
- red `Error` only for genuine hard failures.

---

## 13. Auto Pilot / auto orbit

Flight HUD has an Auto Pilot toggle immediately below the settings gear.

Visual style:

- off: red indicator / `Auto Pilot` / gray indicator
- on: gray indicator / `Auto Pilot` / green indicator

When enabled:

- acquire nearest valid asteroid,
- approach if needed,
- orbit it,
- remain comfortably inside mining range,
- avoid collision,
- choose orbit direction based on smaller turn from current heading.

Manual normal flight input is overridden while Auto Pilot is active.

Collision recovery still has higher priority if a collision occurs.

The orbit controller uses both:

- mining-laser distance,
- conservative ship/asteroid clearance.

---

## 14. Debug tools

Simulation debug menu includes:

- Show hitbox outlines
- Show mining laser range

### Asteroid hitboxes

Shown as orange wireframe boxes matching current exact asteroid collision partitions.

Mined notches should be visible in debug collision.

### Ship hitbox

Shown cyan.

Current implementation should visualize per-piece mesh-derived collision rather than a single ship-sized frame box.

### Laser range

Shown green.

Each laser draws range geometry around its builder-cell origin/support volume corresponding to the 40-cell activation boundary.

---

## 15. Logging

`scripts/app_logger.gd` installs a logger that tries to write beside the executable:

`SpaceMinerGame.log`

If that fails, it falls back to `user://SpaceMinerGame.log`.

The logger flushes aggressively so breadcrumbs survive hard crashes.

Historically important diagnostics include:

- PLACE
- HIGHLIGHT
- RING population
- mining hard errors

When adding a generic UI `Error`, add a useful logger event too.

---

## 16. CI and builds

Workflow:

`.github/workflows/windows-build.yml`

Godot version:

`4.7.1`

Java:

`17`

Pipeline includes:

1. checkout,
2. install Godot + export templates,
3. import/compile,
4. runtime smoke test,
5. simulation smoke test using `--simulation-smoke`,
6. Windows export + artifact,
7. Android debug signing,
8. Android ARM64 debug APK export + artifact.

Android uses Godot’s native template export rather than a Gradle project.

Project is configured for Android ETC2/ASTC and landscape/sensor behavior.

### Why simulation smoke matters

A change can import successfully and still fail when the simulation scene loads.

Example:

`BaseMaterial3D.POLYGON_MODE_LINE` parsed only when `simulation.gd` loaded, causing simulation-smoke failure.

Always inspect the failing workflow step/log before assuming the feature logic itself is broken.

---

## 17. Current known-good snapshot and recent hot-zone commits

At handoff creation:

**Head:** `0cf5292a2212395b10005eb98913970cb8ba4d6e`

Recent commits, newest first:

- `0cf5292` — compact color swatches beside part color slots
- `8e4f916` — fix exact ship hitbox debug wireframes
- `afe6023` — recover mining lasers from unavailable reserved targets
- `8b2b856` — actual ship geometry collision hitboxes
- `c2b59bc` — normalize saved part colors for new color regions
- `6762452` — mining laser gets separate dark turret color
- `a16f88c` — color regions open a dedicated popup color picker
- `40a911a` / `10a13d3` — full ring population and visibility stabilization
- `717d05a` / `f98e0e5` — restore original near asteroid rendering behavior
- `cca184f` — persistent 360° asteroid ring
- `7fa916d` — planet + moving asteroid ring
- `bfeb1fa` — asteroid sizes 3–9 cells
- `6e65ab8` — hold Tab to release cursor / lock camera
- `41d4a36` — Auto Pilot
- `f9fcebe` — reverse steering only while S held
- `334eea7` / `8cc5429` — multi-laser reservations and randomized asteroid positions
- `6b4e8ba` — smooth center-to-surface mining beam transition
- `a6ecac5` — precompute mined geometry before break-off
- `408904a` — compact mining-laser status indicator
- `605d45c` — mining range debug visualization
- `ab54e97` — asteroid collision follows mined occupancy
- `75bb53b` / `49bad74` — collision recovery momentum behavior
- `fb01f30` — ship-only thumbnails
- `23ac739` — mutable exposed-surface asteroid mesh
- `8dd5f4d` / `2c1e23c` — mining simulation and test-flight scene
- `87a9d21` — mining-laser builder part
- `7cf5d9e` — flat unshaded builder parts
- `31a3c80` / `cf8be36` — model import/export/rename/clipboard/thumbnails
- `94be0d4` / `4a3a09b` — persistent model selector/storage
- `cafe16c` — first modular builder prototype

### Known bad/intermediate commits worth remembering

These commits are in history but their problematic behaviors were subsequently fixed:

- `394dbd9` / `f9d2043`: full-ring optimization/back-face culling caused nearby asteroid visual artifacts.
- `c1dfd2f` / `34afb01`: camera-dependent far proxy/surrogate approach was removed.
- `8b2b856`: exact ship collision feature was conceptually desired, but its first debug-wireframe implementation broke CI due to unsupported `POLYGON_MODE_LINE`.
- `afe6023`: mining fix was correct in direction but inherited the same debug-wireframe parse failure until `8e4f916`.

Do not use a historical commit message as proof that behavior is still correct; inspect current code.

---

## 18. Fragile / unresolved areas to test carefully

### A. Ship exact collision performance

Per-render-mesh convex collision is much more accurate than the old ship-sized bounding box, and it matches the user’s request.

However, it is newer than most flight code.

Watch for:

- excessive collision-shape count on very large ships,
- transform-sync cost,
- odd behavior from moving turret collision,
- duplicate overlapping convex shapes,
- collision recovery using conservative `model_radius` values even though actual collision is now more precise.

Do not revert to one ship-sized box merely for convenience.

### B. Mining obstruction versus exact ship collision

Physics collision is now mesh-derived.

Laser obstruction is still grid-cell AABB-derived.

If a beam is reported obstructed when it visually should not be, inspect `_ship_blocks_segment()` and `ship_cell_boxes`.

### C. Mining reservation edge cases

With small 3×3 asteroids and several lasers:

- reservations can consume the most attractive surface cells,
- target availability can change after another laser commits,
- prepared geometry can become stale.

The intended behavior is graceful retarget/wait/reprepare, never generic `Error` for normal contention.

### D. Ring performance

The user wants the full belt visible/persistent.

Do not solve performance by deleting sections of the ring.

Current allowed distance optimization:

- far spin can stop,
- far physics can sleep,
- orbital position should stay smooth.

If additional optimization is needed, profile first.

### E. Asteroid visual popping

If any asteroid disappears/reappears while it is visibly in view:

check, in order:

1. ring actually populated 420/420,
2. no slot was dropped,
3. `custom_aabb`,
4. `extra_cull_margin`,
5. `ignore_occlusion_culling`,
6. accidental reintroduction of back-face culling,
7. transform update cadence.

Near asteroids should never use camera-dependent proxies.

### F. Color UI

The latest requested drawer format is specifically:

`[Area Name][color swatch]`

not:

- `Area Name #HEX`,
- full palette inline,
- full color wheel inline.

The popup itself is currently considered acceptable.

---

## 19. Strong user requirements collected across the project

Preserve these unless the user explicitly changes them:

- Flat/unshaded ship parts.
- Ship-only thumbnails: no editor UI or grid.
- Mobile landscape.
- Parts button top-left; no old coordinate readout.
- Mobile builder D-pad scalable.
- Mobile flight native joystick bottom-right and transparent/subtle.
- Desktop captured mouse + WASD.
- Hold Tab to release desktop mouse and freeze camera.
- Mobile drag outside joystick orbits camera.
- Separate horizontal/vertical camera inversion.
- Vertical inversion default remains enabled relative to original behavior.
- Ship flight direction derives from thrusters.
- Mobile joystick displacement always means thrust.
- PC A/D alone turns + moves forward.
- S reverses; reverse steering applies only while S is held.
- Asteroids are logical voxels but rendered as one exposed-surface mesh, never thousands of cube nodes.
- Asteroid sizes 3–9.
- Full persistent ring around the planet.
- Ring asteroids move slowly in one direction at common linear speed.
- Random gentle asteroid rotation only needs full update near enough to matter.
- Near asteroid rendering must remain completely normal.
- Asteroid palettes: ice blue/dark blue and dirt brown/tan.
- Planet: single distant large sphere with land/water heatmap texture.
- Exact asteroid collision follows mined cells.
- Mining geometry is prepared during mining to avoid detach-frame hitch.
- Debug hitbox outlines are actual collision geometry.
- Mining range debug toggle exists.
- Compact per-laser status panel.
- Collision recovery: smooth 90°, 5-cell clearance, physics paused, speed resumes along new heading.
- Laser range: 40 cells from laser cell volume to exact asteroid occupancy.
- Mining laser center→surface beam transition near end of cycle.
- Target persists while valid, but obstructed lasers may independently retarget.
- Out-of-range turret holds orientation.
- Multiple lasers reserve unique cells.
- Stale prepared geometry refreshes without restarting a completed mining cycle.
- Tractor chunks/beam particles do not obstruct lasers.
- 5-second mining cycle.
- Turret tracking ~68°/s.
- Auto Pilot orbits nearest asteroid while maintaining mining range and avoiding collision.
- Ship physics collision follows actual modular part geometry, not one enclosing frame/bounding box.
- Mining laser has two color regions: Housing and dark-gray Turret.
- Color drawer shows region name + swatch; actual color selection happens in popup.

---

## 20. Suggested startup checklist for the next ChatGPT session

When continuing this project:

1. Fetch branch:
   `prototype/ship-builder-first-pass`
2. Check current HEAD.
3. Check latest push and PR CI.
4. Read this file.
5. Fetch the exact source file involved in the new request.
6. Do not assume a historical implementation still matches current behavior.
7. Make the smallest change that preserves established behavior.
8. Run/check CI after committing.
9. If a visual/runtime issue cannot be confirmed by CI, add a focused diagnostic rather than guessing.

If a user screenshot contradicts a previous verbal description, prioritize the screenshot plus the user’s latest clarification.

---

## 21. Current architectural philosophy

This prototype has repeatedly benefited from a simple rule:

**Keep the logical systems precise, but keep the rendered/runtime representation cheap.**

Examples already in the project:

- asteroid occupancy is voxel-precise, but exterior rendering is one combined mesh,
- asteroid mining collision is exact, but represented as merged boxes,
- expensive post-mining geometry is prepared before the break-off frame,
- distant asteroids may skip cosmetic work but still remain real persistent world objects,
- ship collision is assembled from procedural part geometry rather than one giant frame.

When adding features, prefer this style over brute-force node counts or camera-dependent visual tricks.

---

## 22. One-sentence state summary

The project is currently a working Godot 4.7.1 modular ship builder with persistent models, a test-flight scene, actual part-shaped ship collision, independent multi-laser asteroid mining, auto-orbit, a full 420-asteroid moving planetary ring, and a simplified slot-based color UI; the most important regression risks are asteroid rendering/culling, multi-laser reservation edge cases, and preserving exact ship collision without reintroducing a giant bounding box.
