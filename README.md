# Whittle

A calm, first-person whittling simulator. Pick a log, pick your tools, and carve. No goals, no timers.

**Play:** https://gabeposse-ai.github.io/my-whittle-game/ (deployed by GitHub Actions on every push to `main`).

## How it works

- **The log is a signed distance field.** Each grid point stores its distance to the wood surface (negative inside). A cut is a CSG subtraction, `f = max(f, -cutter)`, so surfaces stay smooth and sub-voxel accurate.
- **Meshing:** Surface Nets for the smooth look, or classic cube faces for the voxel look (Settings → Look). The grid is split into 16³ chunks and only touched chunks are re-meshed.
- **Wood shader:** colour comes from the 3D position inside the log, so every cut reveals real growth rings, heartwood/sapwood, fibre streaks, knots, and bark.
- **Grain:** fibres run along the log axis. Cuts along the grain lift curls; across the grain gives chips; cutting uphill on a slope tears out; end grain is slow.
- **Offcuts:** after each stroke, a connected-component pass finds pieces that have been cut free; they fall off as real geometry.

## Controls

| | Touch | Mouse / keys |
|---|---|---|
| Carve | drag on the wood | left-drag on the wood |
| Turn log | drag off the wood, or two fingers | right-drag, or shift-drag |
| Closer / further | pinch | scroll |
| Tools | tap the tool roll | 1–7 |
| Undo | ↶ button | Z |
| Switch grip end | ⇅ button | F |
| Hide UI | | H |

## Develop

```
npm install
npm run dev
```

Source map: `src/field.ts` (SDF log), `src/carver.ts` (strokes, grain, saw, sanding, offcuts, undo), `src/mesher.ts`, `src/logMesh.ts`, `src/woodMaterial.ts`, `src/shavings.ts`, `src/hands.ts`, `src/scene.ts`, `src/audio.ts`, `src/ui.ts`, `src/persist.ts`, `src/main.ts`.
