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
- Stamina should make flight choices meaningful. The current three-second drain and seven-second recovery are starting values to tune. Fall damage and health remain open design questions; ordinary jumps should be safe.

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
| Space | Jump; leap from a trunk (hold a direction) |
| E | Grip / release an overlapping tree trunk |
| W/S or up/down | Climb while gripping |
| Hold Shift | Open glide while descending; rapidly brakes a fast fall |
| Hold Q | Pull the camera back to inspect routes |
| R | Instantly retry at the last lantern |
| Escape | Quit |

The camera starts close, widens slightly during glides, and briefly slows its follow when the glide opens. Lanterns restore stamina and save a retry point. Falling into the creek returns you to the lantern. The creek has stepping stones and an alternate tree route. Trees are climbable without blocking ordinary ground movement. Branch platforms currently have flat collision tops beneath organic tapered meshes.

## Current scope

Handmade route, seeded decorative forest, procedural simple squirrel model with movement poses, object-anchored pigment shader, animated water, haze, climbing, buffered jumps/coyote time, stamina, glide braking, camera and checkpoints. This is an early movement/art foundation. Fire pressure, wind events, sound, acorns, finished character animation, authored watercolor textures, and full procedural challenges are future work. The shader gives mottled paint-like surfaces, not a finished reproduction of the reference artwork.

## Structure

- `scripts/forest.gd`: scene construction, materials, trunks, HUD, camera and lanterns.
- `scripts/squirrel.gd`: constrained 3D movement, glide, climbing, stamina and squirrel poses.
- `shaders/pigment.gdshader`: world-anchored pigment variation.
- `shaders/water.gdshader`: stylized animated ripples.

## Validation

```sh
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --editor --quit
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . -- --smoke-test
```

The smoke mode exercises ground landing, jumping, trunk overlap without attachment, explicit attachment, climbing, directional leaps, fast-fall glide braking, stamina drain/reset, lantern activation and creek-fall recovery. It exits after those checks pass. Movement tuning is in `squirrel.gd`; camera sizes and smoothing are in `forest.gd`.

For a rendered preview, run Godot with `--path . -- --capture`. This writes `prototype-preview.png` and exits. Inspect the image for framing and materials, then play the scene to assess movement and visual stability.
