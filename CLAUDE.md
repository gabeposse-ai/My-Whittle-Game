# Notes for Claude

## Two builds
- `game/` is the real game: **Godot 4.7.2, GDScript, Forward+, targeting Windows/Steam.** All new work goes here.
- The repo root (Vite + Three.js) is the original web prototype, deployed to GitHub Pages. Keep it working but don't extend it.

## Workflow
- The owner plays builds on a Windows PC. Every push touching `game/` runs `.github/workflows/windows.yml`, which validates shaders/scripts headlessly, exports `Whittle.exe`, and replaces the `latest-windows` GitHub Release. Keep `main` exportable.
- Before pushing: `godot --headless --path game --import` then `godot --headless --path game -s res://scripts/tools/validate.gd` (compiles every compute shader to SPIR-V and reloads every script; non-zero exit on failure).
- The cloud sandbox has no GPU compute. Visual checks run under Xvfb with `--rendering-method gl_compatibility`, which uses the CPU carving backend in `log_volume.gd` (same cutter maths as `log_carve.glsl`, low resolution). Screenshot/test flags after `--`: `--shot=<png> --play --frames=N --autocarve [--vee] [--saw] --nohands --noshadow --tool=<id>`.

## Architecture (game/)
- The log is a signed distance field in a 3D texture on the GPU (`LogVolume`, R16F, voxels; ±4 clamp). Compute shaders init/carve/sand/pick it; `log.gdshader` sphere-traces it for rendering (no meshing). DEPTH mapping differs between Forward+ and Compatibility (see `CURRENT_RENDERER` branch).
- `wood_math.gdshaderinc` is shared by GLSL compute and Godot shaders, so it must stay in the common subset (plain functions, no uniforms). `WoodMath` (GDScript) mirrors it.
- `Carver` turns strokes into cutter segments in grid space (log axis = grain = +y) and emits shaving events; grain model: along / end-grain / uphill.
- `Shavings`: blade-attached curls (soft-body chain on release), MultiMesh flakes and dust, all coloured by the log-local point they came from.
- Units: world metres; log-local space inches (`log_node` scaled 0.0254).
- GDScript gotcha: Packed*Array values are copied on cast/assignment; build locally then assign back.

## Design
- Story and design doc: Albert (silent, widowed retired physician), Autumn (late wife), Walt (friend, tutorial). Orders judged by hidden target SDF; reactions set by 1–3 leaf marks. Calm: no timers, no fail states.
