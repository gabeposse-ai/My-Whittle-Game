# Notes for Claude

- Owner plays and tests on an iPhone via GitHub Pages; there is no local dev machine. Every push to `main` deploys. Keep `main` deployable.
- Stack: Vite + TypeScript + Three.js (`three` pinned to ~0.185). No other runtime deps; generate textures/sounds procedurally unless a real asset is added under `public/`.
- Units are inches in world/log-local space; carving maths in `carver.ts` is in grid (voxel) space with the log axis = grain = +y.
- Performance budget: must stay smooth on iPhone Safari. Avoid per-frame allocations in hot loops; re-mesh only dirty chunks.
- `window.__whittle` is a debug hook (begin/move/endStroke, selectTool, stats) used for headless tests; keep it working.
- Run `npm run typecheck` before pushing.
- Design intent: cozy and calm. No fail states or timers in free carve. Planned next: commissions board with shape-match scoring, gallery shelf, tool sharpening/strop, oil finish, photo mode, recorded audio.
