# Fire in the Forest — Godot 4 prototype

A playable 2.5D creekside movement study. Open `project.godot` in Godot 4 (tested with 4.7.1), then press **F6** or **F5**. Uses the Compatibility renderer; no plugins or imported assets are required.

## Project goals — initial direction

This is an **initial get-off-the-ground plan**, not a locked design or production specification. Mechanics, numbers, level structure, art techniques, and architecture may change as we playtest. This README holds the evolving direction; `AGENTS.md` gives coding agents a short guide to working with it.

The player is a squirrel escaping a forest fire through a large, beautiful forest. Running, jumping, climbing, and gliding should feel responsive and expressive. The experience should be **poignant, tense at times, fair, and forgiving**, with moments of quiet beauty between challenges.

### Traversal and scale

- Use 3D assets in a side-view 2.5D game. The prototype uses 3D physics constrained to a plane; the implementation can evolve as needed.
- Let the player control forward progress and backtracking. The camera follows the squirrel rather than automatically scrolling the world.
- Keep the squirrel significant in size on screen during normal play. Pull back selectively to reveal tall trees, flight routes, and larger vistas; preserve readable landing targets.
- Trees can be hundreds of feet tall. Their scale relative to the squirrel should make climbing feel enormous and gliding feel like flight. Tune world scale and movement together rather than preserving the original 100-unit height limit.
- Trunks are explicitly climbable: overlapping a tree does not attach the squirrel automatically. Support directional leaps from trunks and connected branch routes.
- Keep ground traversal possible, but give it streams, gullies, fallen logs, and skill jumps. Ground and canopy should offer meaningful alternate routes.
- Opening a glide during a fast fall should feel like pulling a parachute rip cord: strong downward braking, a clear opening pose, and a brief camera response that conveys the catch. Maintain player control and landing visibility.
- Stamina should make flight choices meaningful. The current three-second drain and seven-second recovery are starting values to tune. Stamina does not recover while glide is held, so an exhausted glide drops into a full fall until the player lets go. Fall damage and health remain open design questions; ordinary jumps should be safe.

### Fair challenges, retries, and fire

- Increase challenge through terrain and varied traversal, with breathing room between demanding sections.
- Place generous checkpoints immediately before difficult sequences. Retries should be quick and painless, restoring resources and relevant hazards together. Keep a challenge consistent on retry so players can learn it.
- The fire advances in world space behind the squirrel. Its baseline speed need not exceed player speed; wind changes can create temporary surges and additional pressure.
- Telegraph pressure changes with wind, smoke, sound, and environmental movement. Any artificial fire advance should preserve a fair reaction margin and a viable escape route.
- The original endless procedural platformer is a starting concept, not a requirement. The current proposed direction is authored challenge sections with procedural variation, supporting intentional pacing and checkpoints. Endless mode can be reconsidered later.
- Validate traversal against actual movement, stamina, climbing time, and fire pressure before expanding procedural generation.

### Art direction

The user's forest-stream reference establishes the target: simple organic forms, soft watercolor-like color variation, warm cream/pink sunlight, mossy greens, muted peach/brown rocks and bark, and distant trees fading into atmospheric haze.

- Combine simple 3D meshes, painted textures, and restrained watercolor/pigment shaders. The current shader is an early material study.
- Favor broad shapes and soft shading with selective crisp accents, such as water foam, flowers, and character features. Heavy ink outlines are not the current visual target.
- Anchor pigment patterns to objects or world surfaces so they remain stable as the camera moves. Keep paper grain subtle.
- Give the squirrel and traversable surfaces enough contrast to read clearly. Foreground foliage should frame movement without hiding landing points.
- Use stylized fire and smoke to contrast with the forest palette while supporting the game's emotional tone.

### Near-term milestones

1. Playtest and tune the creekside scene: running, climbing, branch jumps, fast-fall glide opening, close camera framing, and zoom-out.
2. Improve the squirrel silhouette, animation, painterly surfaces, water, and atmospheric layering in motion.
3. Add a short checkpointed challenge with an advancing fire and a telegraphed wind surge. Verify that failure and retry feel fair.
4. Expand alternate ground/canopy routes and repeatable challenge sections. Add procedural variation only after the movement and pacing work.

Scoring, acorn purpose, exact fall-damage rules, difficulty curves, final export targets, and the amount of procedural generation are still open. The current controls and tuning values are prototype choices.

## Controls

| Input | Action |
|---|---|
| A/D or arrows | Run |
| Space | Jump (hold for full height); leap from a trunk toward the held side |
| E, or W near a trunk | Grip an overlapping trunk (holding W also catches a trunk in midair); E releases |
| W/S or up/down | Climb while gripping; S at the base steps off |
| Hold A/D while climbing | Swing to that side of the trunk; climbing past a branch on that side runs you out onto it |
| Run back toward the trunk on a branch | Hug onto the trunk; keep holding to swing around to the far side |
| S on a branch | Crouch and flex the branch down; release to let it spring up |
| Space on a branch | Jump; near the tip and on the branch's upswing you get a springboard boost |
| S + Space on a branch | Drop through the branch |
| Hold Shift | Open glide while descending; rapidly brakes a fast fall and keeps carrying you forward |
| Hold Q | Pull the camera back to inspect routes |
| H | Hide/show the controls line |
| R | Instantly retry at the last lantern |
| Escape | Quit |

Branch running is a core traversal verb alongside jumping and gliding: climbing to a branch and running out along it is how the squirrel gains launch height and banks glide stamina. Branches (`scripts/branch.gd`) are long, curved, tapered limbs with a stiff spring. Higher branches slope upward out of the trunk and level off toward the tip. Forking twigs with leaf clusters at their tips grow up and back from each branch (more of them on higher branches), and a twig fan carries the line on past the walkable tip. The squirrel runs along the curved top surface directly, without a physics collider: it passes through from below and lands from above. The tip sags under the squirrel and rebounds. Reaching the tip triggers a short detent (keep holding outward to run off). Crouching with S pumps the branch like a diving board, and jumping near the tip or on the upswing adds height (capped). Spring tuning is at the top of `branch.gd`; boost and detent values are in `squirrel.gd`.

The test arena runs about 150 units (x ≈ -20 to 130) with six lanterns. The play strip (|z| ≤ 2.5) is flat ground with collision. Behind it the forest floor rolls up into hills that fade into the haze, and in front it rises gently toward the camera. Water is carved into the land (`scripts/terrain.gd`): brooks wind back into the hills and cross the play line at the stepping-stone gaps, a zig-zagging foreground river is fed by them, and a pond crossing near x ≈ 78–84 has its own feeder brook and a canopy route over it. Hills flatten near water so streams always run downhill. Shorelines get crisp white foam from the water shader, rocks and plants crowd every bank, and small foam rapids mark the brooks in the hills. The far hills are dressed with painted tree, bush and fern cards (MultiMesh, a few draw calls). The ground has meadow and leaf-litter zones, moss-capped stones, tilted slabs, fallen logs, 3D ferns, mushrooms and flowers. These loose floor props are batched after the scene is built (`_batch_props` in `forest.gd`) into one MultiMesh per material and 24-unit strip, and props smaller than about 1.4 units cast no shadows. Every shadow caster within the sun's shadow distance is redrawn each frame, on screen or not.

The camera is a low-FOV perspective camera that starts close, widens during glides, briefly slows its follow when the glide opens, and looks ahead and down during fast falls. Lanterns restore stamina and save a retry point. Touching the creek water returns you to the lantern. The creek has stepping stones and an alternate tree route. Trees are climbable without blocking ordinary ground movement. While climbing, the squirrel clings upright on the trunk's camera-facing edge, belly to the bark, with a bounding gait (paws reach, hind legs push, body stretches and bunches) and its tail hanging down. Switching sides scurries around the front of the trunk. This is visual only; climbing physics are unchanged.

## Current scope

Handmade route, seeded layered forest (play plane, mossy creek banks, mid trees, far hazy trees), procedural flying-squirrel model with glide membrane and squash/stretch, leaf-card canopy clumps, world-anchored pigment shader (soft-banded light, moss caps, lumpy silhouettes, depth haze behind the play plane), sunbeams, animated water with white foam accents, climbing with branch run-out, one-way branches, buffered jumps/coyote time, stamina, glide braking, camera and checkpoints. This is an early movement/art foundation. Fire pressure, wind events, sound, acorns, finished character animation, authored watercolor textures, and full procedural challenges are future work. The shader gives mottled paint-like surfaces, not a finished reproduction of the reference artwork.

## Structure

- `scripts/forest.gd`: scene construction, materials, trunks, HUD, camera and lanterns.
- `scripts/squirrel.gd`: constrained 3D movement, glide, climbing, branch running, stamina and squirrel poses.
- `scripts/branch.gd`: springy walkable branch (shape, bend, surface queries, segment mesh updates).
- `scripts/limbs.gd`: procedural forking limbs (tapered tubes that curve upward and split into smaller limbs, merged into one mesh) for branch twigs and crown limbs.
- `shaders/pigment.gdshader`: world-anchored pigment variation, optionally over authored vertex colours.
- `tools/blender/`: Blender generator scripts for modular art kits.
- `scripts/terrain.gd`: landform (flat play strip, rising hills, front slope), water courses and their signed-distance grid, ground and water meshes, bank and rapid sample points.
- `shaders/sprite.gdshader`: painted distant-scenery cards with depth haze.
- `shaders/leaf.gdshader`: canopy leaf clumps (outward-bent normals, two-sided cards, edge-on fade, organic see-through around the squirrel, dark interiors, cool shade, warm sunlit highlights, gentle sway).
- `shaders/floor.gdshader`: forest floor with meadow/leaf-litter zones, leaf flecks, sun dapples and soil banks.
- `shaders/water.gdshader`: stylized animated ripples, glints and shoreline foam.
- `shaders/sunbeam.gdshader`, `shaders/sky.gdshader`: additive light shafts and camera-attached backdrop.

## Art assets

Modular assets are generated by Blender scripts so they stay reproducible and tweakable. Open the `.blend` to inspect them or sculpt on top; rerun the script to regenerate.

**Trunk kit** (`tools/blender/trunk_kit.py` → `assets/source/trunk_kit.blend`, `assets/trees/trunk_kit.glb`):

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup --python tools/blender/trunk_kit.py
```

- Segments are 4 units tall with radius ≈ 0.52: three root-flare bases (one wide), seven middles (plain ×2, twist, knot, burl, branch stub, moss), two forked tops that disappear into the canopy, three lean/bend pieces and three forks (even split, leader plus side limb, three-way).
- **Sockets:** each piece exports child empties (`<piece>_socket_<n>`) marking where the next piece attaches: position, tilt and uniform scale. Straight pieces have one socket 4 units up, leans tilt it, forks have two or three, and tops have none. A socket only moves, turns and uniformly scales the standard joint, so joints still match.
- Every segment ends in the same joint: a 32-vertex ring with eight bark ridges, whose shape and colour depend only on angle. Features ease out before each end, so any piece stacks on any other. Rotations in 45° steps also match.
- Colour is baked into vertex colours, written as sRGB values because Godot linearises imported vertex colours itself. The pigment shader multiplies them by `paint_color` (`use_vertex_color`) and adds its world-anchored wash.
- **Background trees** grow by following sockets: a base, a run of straight and leaning pieces, up to two levels of forks, then tops. Turns are picked so every limb stays within about 55° of vertical. Trees are scaled 1.0–1.7× for variety, and crown clusters sit at the limb tips.
- **Climbable trees** stay straight (base, middles) up to the crown, because climbing assumes a vertical trunk. Above the climbable part the trunk splits: a fork piece, turned so its limbs spread across the side view, with a top on each limb, procedural twigs spraying from those limbs, and leaf clumps at and around their tips, so the trunk ends in leafy forks rather than a nub. Crown picks use `limb_rng`, so they don't shift the seeded layout. Climbing carries on past the split: each tree records a climb line per side (`_climb_paths` in `forest.gd`) that runs up the trunk, along the fork limb on that side (the front one, where the fork splits in three) and about halfway up its top, where it gets too thin to hold. Above the split the squirrel stays on the limb it took (switching sides goes around that limb), leans with it, and hugs closer as it thins. Leaning trunk pieces are still not climbable.
- `forest.gd` sorts pieces by name prefix (`trunk_base_`, `trunk_mid_`, `trunk_top_`, `trunk_lean_`, `trunk_fork_`). Every tree is merged into one mesh, and choices come from the seeded RNG so the forest is identical each run. Adding a new segment to the script makes it part of the mix automatically.

**Leaf clumps** (after The Witness's trees): tree crowns and branch leaf clusters are clumps of `assets/sprites/leaf_sprig.png` cards built in `forest.gd` (`leaf_crown`, `add_leaf_clump`), merged into one mesh per crown. Each card's normals point away from its clump centre so the clump shades as one soft volume. Back faces render with the same outward normal. Cards erode as they turn edge-on to the camera, because the sprig's alpha is a distance field, so there are no hard slivers. Vertex colour marks depth into the clump for dark interiors, and the shaded side picks up a cool blue tint, while leaves facing the sun warm toward yellow. Per-leaf paint variation is partly flattened (`leaf_detail`) so each clump reads first as one painted mass. The cards cast no shadows of their own; a shrunken ellipsoid proxy per clump (shadows only) still shades the ground. Climbable trees get a rounded crown: a cap and a loose dome of clumps over the split trunk top, plus clumps at the tips of steep, forking limbs that fan out of the upper trunk and show through the crown's gaps, and background crowns get a cap above each limb tip. **See-through:** leaves level with or in front of the squirrel dissolve around it, so it is never hidden in the canopy. The inner half of the opening always clears. Toward the edge, leaves drop out one at a time, each shrinking along its own shape, and world noise roughens the outline so it never reads as a circle. Per-leaf thresholds come from a random value per card (vertex colour G) and `leaf_sprig_id.png`, a flat grey per leaf painted alongside the sprig. `forest.gd` feeds the squirrel's position to the `squirrel_position` shader global (declared in `project.godot`). `reveal_radius` and `reveal_ragged` in `leaf.gdshader` tune the opening. Leaf cards, extra crown clumps, twigs and crown limbs use their own RNGs so they don't shift the seeded layout. Ground bushes are still lumpy ellipsoids.

**Distant sprites** (`tools/blender/sprites.py` → `assets/sprites/*.png`) paint trees, bushes and ferns with numpy inside Blender: scalloped leaf masses lit warm yellow-green, with sage and pink in shade. The same script paints the `leaf_sprig.png` card used by the 3D leaf clumps and its `leaf_sprig_id.png` leaf-ID map. The sprig's leaves are rounded brush dabs: noise frays their edges (more toward the tip, where the brush lifts), a few dry-brush flecks sit just outside the edges, paint streaks run along each stroke, and each leaf shades the ones beneath it so overlaps stay readable. Rerun to repaint:

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup --python tools/blender/sprites.py
```

## Validation

```sh
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --editor --quit
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . -- --smoke-test
```

The smoke mode exercises ground landing, jumping, trunk overlap without attachment, explicit attachment, climbing, climbing up a fork limb, directional leaps, branch run-out, tip detent, landing on branches, trunk hugging, springboard jumps, drop-through, fast-fall glide braking, stamina drain/reset, lantern activation and creek-fall recovery. It exits after those checks pass. Movement tuning is in `squirrel.gd`; camera sizes and smoothing are in `forest.gd`.

For a rendered preview, run Godot with `--path . -- --capture`. This writes `prototype-preview.png` and exits. Optional: `--at=x,y` places the squirrel, `--glide` holds glide, `--overview` holds the wide view, `--freeze` pins the squirrel in place, `--tap=a,b` / `--hold=a,b` press input actions, `--frame=N` picks the captured frame, `--out=path.png` changes the output, and `--perf` waits 300 frames and prints steady-state FPS and draw calls. Inspect the image for framing and materials, then play the scene to assess movement and visual stability.
