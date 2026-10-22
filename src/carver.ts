// Carving: turns pointer strokes into SDF subtractions, with grain-aware behaviour.
//
// All maths here is in GRID space (voxel units). The log axis — and therefore the wood grain —
// runs along +y, so the grain vector is simply (0, 1, 0).
//
// Grain model, per stroke segment (tangent t projected onto the surface, outward normal n):
//   along   = |t·y|           1 = cutting with the fibres, 0 = straight across them
//   endGrain= |n·y|           1 = slicing the end of the log (tough, slow)
//   uphill  = -(t·y)(n·y)     > 0 when the blade travels toward where fibres dive INTO the wood.
//            On a taper, fibres run out of the surface; cutting "downhill" (same direction they
//            exit) lifts them cleanly, cutting "uphill" lets the edge follow fibres inward and
//            pry them out ahead of the blade — tear-out.
// These scale the depth of cut, choose curl vs. chip shavings, and roughen the cut surface.

import { CLAMP, Field } from './field';
import { vnoise } from './noise';
import type { Tool } from './tools';

export type V3 = [number, number, number];
export type Feel = 'with' | 'across' | 'against' | 'end' | 'saw' | 'sand';

export interface Hit {
  g: V3; // grid-space point on the surface
  n: V3; // outward normal (grid space)
}

export interface CutEvent {
  volume: number; // removed volume, in voxels³
  kind: 'curl' | 'chip' | 'dust';
  p: V3; // grid point where material came off
  t: V3; // stroke direction (unit)
  n: V3; // surface normal (unit)
  width: number; // inches
  depth: number; // inches
  segLen: number; // inches
  feel: Feel;
}

export interface Island {
  /** Sub-grid holding just this piece, for meshing it as a falling offcut. */
  data: Float32Array;
  nx: number;
  ny: number;
  nz: number;
  ox: number;
  oy: number;
  oz: number;
  cells: number;
}

export interface UndoEntry {
  x0: number; y0: number; z0: number; x1: number; y1: number; z1: number;
  old: Float32Array;
  strokeId: number;
  pieces: unknown[];
}

const dot = (a: V3, b: V3) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const sub = (a: V3, b: V3): V3 => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const len = (a: V3) => Math.hypot(a[0], a[1], a[2]);
const norm = (a: V3): V3 => { const l = len(a) || 1; return [a[0] / l, a[1] / l, a[2] / l]; };
const cross = (a: V3, b: V3): V3 => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const smooth = (e0: number, e1: number, x: number) => { const t = Math.min(1, Math.max(0, (x - e0) / (e1 - e0))); return t * t * (3 - 2 * t); };

interface Stroke {
  tool: Tool;
  last: Hit;
  id: number;
  // Saw state
  sawPlane?: V3;
  sawCells?: Int32Array;
  sawDepth: number;
  sawOrigin: V3;
  sawNormal: V3;
}

export class Carver {
  /** Snapshot of the field at stroke start: knife strokes ride on the pre-stroke surface so a
   *  single stroke takes an even layer instead of digging into its own groove. Also the undo source. */
  private prev: Float32Array;
  private stroke: Stroke | null = null;
  private box = [0, 0, 0, 0, 0, 0];
  private boxEmpty = true;
  private undoStack: UndoEntry[] = [];
  private strokeCounter = 0;
  private labels: Int32Array;
  private queue: Int32Array;

  /** Called with an inclusive grid box whenever field values change. */
  onChange: (x0: number, y0: number, z0: number, x1: number, y1: number, z1: number) => void = () => {};

  constructor(readonly field: Field) {
    this.prev = new Float32Array(field.data.length);
    this.prev.set(field.data);
    this.labels = new Int32Array(field.data.length);
    this.queue = new Int32Array(field.data.length);
  }

  get active() { return this.stroke !== null; }
  get activeTool() { return this.stroke?.tool ?? null; }
  get strokeId() { return this.stroke?.id ?? -1; }
  get canUndo() { return this.undoStack.length > 0; }

  // ---------------------------------------------------------------- raycast

  /** Sphere-trace a grid-space ray against the field. Uses the frozen snapshot during knife strokes. */
  raycast(o: V3, d: V3, frozen = false): Hit | null {
    const f = this.field;
    const src = frozen ? this.prev : f.data;
    // Clip to the grid's bounding box.
    let t0 = 0, t1 = 1e9;
    const lo = [1, 1, 1], hi = [f.nx - 2, f.ny - 2, f.nz - 2];
    for (let a = 0; a < 3; a++) {
      if (Math.abs(d[a]) < 1e-9) {
        if (o[a] < lo[a] || o[a] > hi[a]) return null;
      } else {
        let ta = (lo[a] - o[a]) / d[a], tb = (hi[a] - o[a]) / d[a];
        if (ta > tb) [ta, tb] = [tb, ta];
        t0 = Math.max(t0, ta); t1 = Math.min(t1, tb);
      }
    }
    if (t0 > t1) return null;
    let t = t0, prevT = t0;
    let v = f.sample(o[0] + d[0] * t, o[1] + d[1] * t, o[2] + d[2] * t, src);
    if (v < 0) return null; // started inside
    while (t < t1) {
      prevT = t;
      t += Math.max(0.3, v * 0.8);
      v = f.sample(o[0] + d[0] * t, o[1] + d[1] * t, o[2] + d[2] * t, src);
      if (v < 0) {
        // Bisect for the zero crossing.
        let a = prevT, b = t;
        for (let i = 0; i < 10; i++) {
          const m = (a + b) / 2;
          if (f.sample(o[0] + d[0] * m, o[1] + d[1] * m, o[2] + d[2] * m, src) < 0) b = m; else a = m;
        }
        const g: V3 = [o[0] + d[0] * a, o[1] + d[1] * a, o[2] + d[2] * a];
        const n: V3 = [0, 0, 0];
        f.gradient(g[0], g[1], g[2], n, src);
        return { g, n };
      }
    }
    return null;
  }

  // ---------------------------------------------------------------- strokes

  begin(tool: Tool, hit: Hit) {
    this.prev.set(this.field.data);
    this.boxEmpty = true;
    this.stroke = {
      tool, last: hit, id: ++this.strokeCounter,
      sawDepth: 0, sawOrigin: [...hit.g] as V3, sawNormal: [...hit.n] as V3,
    };
  }

  /**
   * Continue the stroke. `ray` (grid space) is used to find the new surface point; if the
   * pointer slides off the edge of the wood, the stroke continues on the last tangent plane so
   * the blade runs off the edge naturally (which is how you take off a corner).
   * `dragDir` / `travel` are only used by the saw (grid-space direction, inches of hand travel).
   */
  move(rayO: V3, rayD: V3, dragDir: V3 | null, travel: number): CutEvent[] {
    const s = this.stroke;
    if (!s) return [];
    if (s.tool.kind === 'saw') return this.moveSaw(s, dragDir, travel);
    const frozen = s.tool.kind !== 'sand';
    let hit = this.raycast(rayO, rayD, frozen);
    if (!hit) {
      const n = s.last.n;
      const denom = dot(rayD, n);
      if (Math.abs(denom) < 1e-4) return [];
      const t = dot(sub(s.last.g, rayO), n) / denom;
      if (t <= 0) return [];
      const p: V3 = [rayO[0] + rayD[0] * t, rayO[1] + rayD[1] * t, rayO[2] + rayD[2] * t];
      if (len(sub(p, s.last.g)) > this.field.vpi * 1.5) return [];
      hit = { g: p, n: [...n] as V3 };
    }
    if (s.tool.kind === 'sand') {
      const ev = this.sand(s, hit);
      s.last = hit;
      return ev ? [ev] : [];
    }
    const seg = sub(hit.g, s.last.g);
    const segLen = len(seg);
    if (segLen < 0.6) return [];
    const ev = this.cutSegment(s, s.last, hit, seg, segLen);
    s.last = hit;
    return ev ? [ev] : [];
  }

  private cutSegment(s: Stroke, a: Hit, b: Hit, seg: V3, segLen: number): CutEvent | null {
    const f = this.field;
    const tool = s.tool;
    const n = norm([a.n[0] + b.n[0], a.n[1] + b.n[1], a.n[2] + b.n[2]]);
    // Stroke direction projected onto the surface.
    const sn = dot(seg, n);
    const t = norm([seg[0] - n[0] * sn, seg[1] - n[1] * sn, seg[2] - n[2] * sn]);

    const along = Math.abs(t[1]);
    const endGrain = smooth(0.65, 0.95, Math.abs(n[1]));
    const uphill = Math.min(1, Math.max(0, -t[1] * n[1] * 3));

    let depthIn = tool.depth * f.species.softness * (0.5 + 0.5 * along) * (1 - 0.55 * endGrain);
    if (uphill > 0.3) depthIn *= 1.15; // blade dives in
    const dv = depthIn * f.vpi;
    // Tear-out only once the cut is clearly uphill; it scales with how hard the blade is fighting the fibres.
    const tearAmp = uphill > 0.3 ? (uphill - 0.3) * 1.3 * Math.max(1, dv) : 0;
    const fuzzAmp = (1 - along) * 0.3 * (1 - endGrain);

    let feel: Feel = 'with';
    if (endGrain > 0.6) feel = 'end';
    else if (uphill > 0.3) feel = 'against';
    else if (along < 0.45) feel = 'across';

    let widthIn: number;
    let volume: number;
    if (tool.kind === 'vee') {
      const half = (32 * Math.PI) / 180;
      widthIn = 2 * depthIn * Math.tan(half);
      volume = this.applyVee(a.g, b.g, n, t, dv, half, tearAmp, fuzzAmp);
    } else {
      const R = Math.max(tool.radius * f.vpi, dv * 1.05);
      widthIn = (2 * Math.sqrt(Math.max(0, 2 * R * dv - dv * dv))) / f.vpi;
      const off = R - dv;
      const pa: V3 = [a.g[0] + n[0] * off, a.g[1] + n[1] * off, a.g[2] + n[2] * off];
      const pb: V3 = [b.g[0] + n[0] * off, b.g[1] + n[1] * off, b.g[2] + n[2] * off];
      volume = this.applyCapsule(pa, pb, R, tearAmp, fuzzAmp);
    }
    if (volume <= 0.001) return null;
    const curl = tool.curls && feel === 'with' && along > 0.6;
    return {
      volume, kind: curl ? 'curl' : 'chip', p: [...b.g] as V3, t, n,
      width: widthIn, depth: depthIn, segLen: segLen / f.vpi, feel,
    };
  }

  /** Subtract a capsule (swept sphere) from a to b with radius R, plus grain roughness. */
  private applyCapsule(a: V3, b: V3, R: number, tearAmp: number, fuzzAmp: number): number {
    const f = this.field;
    const pad = R + tearAmp + 1.5;
    const x0 = Math.max(0, Math.floor(Math.min(a[0], b[0]) - pad)), x1 = Math.min(f.nx - 1, Math.ceil(Math.max(a[0], b[0]) + pad));
    const y0 = Math.max(0, Math.floor(Math.min(a[1], b[1]) - pad)), y1 = Math.min(f.ny - 1, Math.ceil(Math.max(a[1], b[1]) + pad));
    const z0 = Math.max(0, Math.floor(Math.min(a[2], b[2]) - pad)), z1 = Math.min(f.nz - 1, Math.ceil(Math.max(a[2], b[2]) + pad));
    const ab = sub(b, a);
    const abLen2 = dot(ab, ab) || 1e-9;
    const data = f.data;
    const nx = f.nx, nxy = f.nx * f.ny;
    let vol = 0;
    let cx0 = Infinity, cy0 = Infinity, cz0 = Infinity, cx1 = -Infinity, cy1 = -Infinity, cz1 = -Infinity;
    for (let z = z0; z <= z1; z++) {
      for (let y = y0; y <= y1; y++) {
        for (let x = x0; x <= x1; x++) {
          const i = x + nx * y + nxy * z;
          const old = data[i];
          if (old >= CLAMP) continue;
          const px = x - a[0], py = y - a[1], pz = z - a[2];
          let h = (px * ab[0] + py * ab[1] + pz * ab[2]) / abLen2;
          h = h < 0 ? 0 : h > 1 ? 1 : h;
          const dx = px - ab[0] * h, dy = py - ab[1] * h, dz = pz - ab[2] * h;
          let d = Math.sqrt(dx * dx + dy * dy + dz * dz) - R;
          if (d > tearAmp + 1.2) continue;
          // Tear-out follows fibres: noise stretched along the grain (y) pulls the cutter deeper in streaks.
          if (tearAmp > 0) d -= tearAmp * vnoise(x * 0.6, y * 0.12, z * 0.6, 17);
          if (fuzzAmp > 0) d -= fuzzAmp * vnoise(x * 1.4, y * 1.4, z * 1.4, 5);
          let nv = -d;
          if (nv <= old) continue;
          if (nv > CLAMP) nv = CLAMP;
          data[i] = nv;
          vol += clampHalf(nv) - clampHalf(old);
          if (x < cx0) cx0 = x; if (x > cx1) cx1 = x;
          if (y < cy0) cy0 = y; if (y > cy1) cy1 = y;
          if (z < cz0) cz0 = z; if (z > cz1) cz1 = z;
        }
      }
    }
    if (cx1 >= cx0) this.changed(cx0, cy0, cz0, cx1, cy1, cz1);
    return vol;
  }

  /** Subtract a V-groove whose bottom runs from a to b, `dv` below the surface. */
  private applyVee(a: V3, b: V3, n: V3, t: V3, dv: number, half: number, tearAmp: number, fuzzAmp: number): number {
    const f = this.field;
    const side = norm(cross(t, n));
    const A: V3 = [a[0] - n[0] * dv, a[1] - n[1] * dv, a[2] - n[2] * dv];
    const B: V3 = [b[0] - n[0] * dv, b[1] - n[1] * dv, b[2] - n[2] * dv];
    const ab = sub(B, A);
    const abLen2 = dot(ab, ab) || 1e-9;
    const cosA = Math.cos(half), sinA = Math.sin(half);
    const pad = dv * 2.5 + tearAmp + 2;
    const x0 = Math.max(0, Math.floor(Math.min(A[0], B[0]) - pad)), x1 = Math.min(f.nx - 1, Math.ceil(Math.max(A[0], B[0]) + pad));
    const y0 = Math.max(0, Math.floor(Math.min(A[1], B[1]) - pad)), y1 = Math.min(f.ny - 1, Math.ceil(Math.max(A[1], B[1]) + pad));
    const z0 = Math.max(0, Math.floor(Math.min(A[2], B[2]) - pad)), z1 = Math.min(f.nz - 1, Math.ceil(Math.max(A[2], B[2]) + pad));
    const data = f.data;
    const nx = f.nx, nxy = f.nx * f.ny;
    let vol = 0;
    let cx0 = Infinity, cy0 = Infinity, cz0 = Infinity, cx1 = -Infinity, cy1 = -Infinity, cz1 = -Infinity;
    for (let z = z0; z <= z1; z++) {
      for (let y = y0; y <= y1; y++) {
        for (let x = x0; x <= x1; x++) {
          const i = x + nx * y + nxy * z;
          const old = data[i];
          if (old >= CLAMP) continue;
          const px = x - A[0], py = y - A[1], pz = z - A[2];
          let h = (px * ab[0] + py * ab[1] + pz * ab[2]) / abLen2;
          const hc = h < 0 ? 0 : h > 1 ? 1 : h;
          const qx = px - ab[0] * hc, qy = py - ab[1] * hc, qz = pz - ab[2] * hc;
          const u = Math.abs(qx * side[0] + qy * side[1] + qz * side[2]);
          const v = qx * n[0] + qy * n[1] + qz * n[2];
          const along = Math.abs(qx * t[0] + qy * t[1] + qz * t[2]);
          // Wedge SDF (open toward +n), capped at the segment ends.
          let d = Math.max(u * cosA - v * sinA, along - 0.2, -v - 0.0);
          if (d > tearAmp + 1.2) continue;
          if (tearAmp > 0) d -= tearAmp * 0.6 * vnoise(x * 0.6, y * 0.12, z * 0.6, 17);
          if (fuzzAmp > 0) d -= fuzzAmp * 0.6 * vnoise(x * 1.4, y * 1.4, z * 1.4, 5);
          let nv = -d;
          if (nv <= old) continue;
          if (nv > CLAMP) nv = CLAMP;
          data[i] = nv;
          vol += clampHalf(nv) - clampHalf(old);
          if (x < cx0) cx0 = x; if (x > cx1) cx1 = x;
          if (y < cy0) cy0 = y; if (y > cy1) cy1 = y;
          if (z < cz0) cz0 = z; if (z > cz1) cz1 = z;
        }
      }
    }
    if (cx1 >= cx0) this.changed(cx0, cy0, cz0, cx1, cy1, cz1);
    return vol;
  }

  /**
   * Saw: the kerf is a thin slab through the start point, containing the surface normal and the
   * drag direction. Each back-and-forth movement deepens it; saw all the way through and the
   * separated part drops off (handled by the island check at stroke end).
   */
  private moveSaw(s: Stroke, dragDir: V3 | null, travel: number): CutEvent[] {
    const f = this.field;
    if (!s.sawPlane) {
      if (!dragDir || len(dragDir) < 1e-6) return [];
      const n = s.sawNormal;
      const dn = dot(dragDir, n);
      const tang = norm([dragDir[0] - n[0] * dn, dragDir[1] - n[1] * dn, dragDir[2] - n[2] * dn]);
      s.sawPlane = norm(cross(tang, n));
      // Collect the grid points inside the kerf slab once.
      const kn = s.sawPlane, o = s.sawOrigin;
      const halfK = Math.max(0.04 * f.vpi, 0.75) + 1.2;
      const list: number[] = [];
      for (let z = 0; z < f.nz; z++)
        for (let y = 0; y < f.ny; y++)
          for (let x = 0; x < f.nx; x++) {
            const dd = (x - o[0]) * kn[0] + (y - o[1]) * kn[1] + (z - o[2]) * kn[2];
            if (dd > -halfK && dd < halfK) list.push(x + f.nx * (y + f.ny * z));
          }
      s.sawCells = Int32Array.from(list);
    }
    const before = s.sawDepth;
    s.sawDepth += travel * 0.22 * f.species.softness; // inches of kerf per inch of hand travel
    const depthV = s.sawDepth * f.vpi;
    const kn = s.sawPlane, o = s.sawOrigin, n = s.sawNormal;
    const halfK = Math.max(0.04 * f.vpi, 0.75);
    const data = f.data;
    const cells = s.sawCells!;
    const nx = f.nx, ny = f.ny;
    let vol = 0;
    let cx0 = Infinity, cy0 = Infinity, cz0 = Infinity, cx1 = -Infinity, cy1 = -Infinity, cz1 = -Infinity;
    let sumX = 0, sumY = 0, sumZ = 0, cnt = 0;
    for (let k = 0; k < cells.length; k++) {
      const i = cells[k];
      const old = data[i];
      if (old >= CLAMP) continue;
      const x = i % nx, y = Math.floor(i / nx) % ny, z = Math.floor(i / (nx * ny));
      const px = x - o[0], py = y - o[1], pz = z - o[2];
      const sd = Math.abs(px * kn[0] + py * kn[1] + pz * kn[2]) - halfK;
      const h = -(px * n[0] + py * n[1] + pz * n[2]) - depthV; // depth below the start surface
      const d = Math.max(sd, h);
      let nv = -d;
      if (nv <= old) continue;
      if (nv > CLAMP) nv = CLAMP;
      data[i] = nv;
      const dv = clampHalf(nv) - clampHalf(old);
      vol += dv;
      if (dv > 0) { sumX += x; sumY += y; sumZ += z; cnt++; }
      if (x < cx0) cx0 = x; if (x > cx1) cx1 = x;
      if (y < cy0) cy0 = y; if (y > cy1) cy1 = y;
      if (z < cz0) cz0 = z; if (z > cz1) cz1 = z;
    }
    if (cx1 >= cx0) this.changed(cx0, cy0, cz0, cx1, cy1, cz1);
    if (vol <= 0.001 || s.sawDepth === before) return [];
    return [{
      volume: vol, kind: 'dust', p: cnt ? [sumX / cnt, sumY / cnt, sumZ / cnt] : [...o] as V3,
      t: dragDir ? norm(dragDir) : [1, 0, 0], n: [...n] as V3,
      width: 0.08, depth: 0, segLen: travel, feel: 'saw',
    }];
  }

  /** Sandpaper: relax the SDF toward the neighbour average — a local Laplacian smooth. */
  private sand(s: Stroke, hit: Hit): CutEvent | null {
    const f = this.field;
    const R = s.tool.radius * f.vpi;
    const c = hit.g;
    const x0 = Math.max(1, Math.floor(c[0] - R)), x1 = Math.min(f.nx - 2, Math.ceil(c[0] + R));
    const y0 = Math.max(1, Math.floor(c[1] - R)), y1 = Math.min(f.ny - 2, Math.ceil(c[1] + R));
    const z0 = Math.max(1, Math.floor(c[2] - R)), z1 = Math.min(f.nz - 2, Math.ceil(c[2] + R));
    const data = f.data;
    const nx = f.nx, nxy = f.nx * f.ny;
    const w = x1 - x0 + 1, hgt = y1 - y0 + 1;
    const tmp = new Float32Array(w * hgt * (z1 - z0 + 1));
    for (let z = z0; z <= z1; z++)
      for (let y = y0; y <= y1; y++)
        for (let x = x0; x <= x1; x++) {
          const i = x + nx * y + nxy * z;
          tmp[(x - x0) + w * ((y - y0) + hgt * (z - z0))] =
            (data[i - 1] + data[i + 1] + data[i - nx] + data[i + nx] + data[i - nxy] + data[i + nxy]) / 6;
        }
    let vol = 0;
    const softness = f.species.softness;
    for (let z = z0; z <= z1; z++)
      for (let y = y0; y <= y1; y++)
        for (let x = x0; x <= x1; x++) {
          const i = x + nx * y + nxy * z;
          const old = data[i];
          if (old > 2.5 || old < -2.5) continue;
          const r = Math.hypot(x - c[0], y - c[1], z - c[2]) / R;
          if (r >= 1) continue;
          const wgt = (1 - r * r) * (0.35 + 0.25 * softness);
          const avg = tmp[(x - x0) + w * ((y - y0) + hgt * (z - z0))];
          // Only ever remove material (sanding never adds wood back).
          const nv = Math.max(old, old + (avg - old) * wgt + 0.012 * wgt);
          data[i] = nv;
          vol += clampHalf(nv) - clampHalf(old);
        }
    this.changed(x0, y0, z0, x1, y1, z1);
    if (vol <= 0.0005) return null;
    return {
      volume: vol, kind: 'dust', p: [...hit.g] as V3, t: [1, 0, 0], n: [...hit.n] as V3,
      width: 0.02, depth: 0, segLen: 0, feel: 'sand',
    };
  }

  private changed(x0: number, y0: number, z0: number, x1: number, y1: number, z1: number) {
    const b = this.box;
    if (this.boxEmpty) {
      b[0] = x0; b[1] = y0; b[2] = z0; b[3] = x1; b[4] = y1; b[5] = z1;
      this.boxEmpty = false;
    } else {
      b[0] = Math.min(b[0], x0); b[1] = Math.min(b[1], y0); b[2] = Math.min(b[2], z0);
      b[3] = Math.max(b[3], x1); b[4] = Math.max(b[4], y1); b[5] = Math.max(b[5], z1);
    }
    this.onChange(x0, y0, z0, x1, y1, z1);
  }

  /** Finish the stroke: detach any pieces no longer connected to the main body, record undo. */
  end(): { entry: UndoEntry | null; islands: Island[] } {
    const s = this.stroke;
    this.stroke = null;
    if (!s || this.boxEmpty) return { entry: null, islands: [] };
    const islands = this.detachIslands();
    const [x0, y0, z0, x1, y1, z1] = this.box;
    const f = this.field;
    const w = x1 - x0 + 1, h = y1 - y0 + 1, d = z1 - z0 + 1;
    const old = new Float32Array(w * h * d);
    let k = 0;
    for (let z = z0; z <= z1; z++)
      for (let y = y0; y <= y1; y++) {
        const row = f.idx(x0, y, z);
        old.set(this.prev.subarray(row, row + w), k);
        k += w;
      }
    const entry: UndoEntry = { x0, y0, z0, x1, y1, z1, old, strokeId: s.id, pieces: [] };
    this.undoStack.push(entry);
    if (this.undoStack.length > 30) this.undoStack.shift();
    return { entry, islands };
  }

  undo(): UndoEntry | null {
    const e = this.undoStack.pop();
    if (!e) return null;
    const f = this.field;
    const w = e.x1 - e.x0 + 1;
    let k = 0;
    for (let z = e.z0; z <= e.z1; z++)
      for (let y = e.y0; y <= e.y1; y++) {
        f.data.set(e.old.subarray(k, k + w), f.idx(e.x0, y, z));
        k += w;
      }
    this.onChange(e.x0, e.y0, e.z0, e.x1, e.y1, e.z1);
    return e;
  }

  clearUndo() {
    this.undoStack.length = 0;
  }

  /**
   * Connected-component labelling of solid cells (6-connectivity). The largest component is the
   * log in your hand; everything else has been cut free and falls away.
   */
  private detachIslands(): Island[] {
    const f = this.field;
    const { nx, ny, nz, data } = f;
    const nxy = nx * ny;
    const labels = this.labels;
    const q = this.queue;
    labels.fill(0);
    const sizes: number[] = [0];
    const boxes: number[][] = [[]];
    let label = 0;
    for (let i = 0; i < data.length; i++) {
      if (data[i] >= 0 || labels[i] !== 0) continue;
      label++;
      let head = 0, tail = 0;
      q[tail++] = i;
      labels[i] = label;
      let bx0 = nx, by0 = ny, bz0 = nz, bx1 = 0, by1 = 0, bz1 = 0;
      while (head < tail) {
        const c = q[head++];
        const x = c % nx, y = Math.floor(c / nx) % ny, z = Math.floor(c / nxy);
        if (x < bx0) bx0 = x; if (x > bx1) bx1 = x;
        if (y < by0) by0 = y; if (y > by1) by1 = y;
        if (z < bz0) bz0 = z; if (z > bz1) bz1 = z;
        if (x > 0) { const j = c - 1; if (labels[j] === 0 && data[j] < 0) { labels[j] = label; q[tail++] = j; } }
        if (x < nx - 1) { const j = c + 1; if (labels[j] === 0 && data[j] < 0) { labels[j] = label; q[tail++] = j; } }
        if (y > 0) { const j = c - nx; if (labels[j] === 0 && data[j] < 0) { labels[j] = label; q[tail++] = j; } }
        if (y < ny - 1) { const j = c + nx; if (labels[j] === 0 && data[j] < 0) { labels[j] = label; q[tail++] = j; } }
        if (z > 0) { const j = c - nxy; if (labels[j] === 0 && data[j] < 0) { labels[j] = label; q[tail++] = j; } }
        if (z < nz - 1) { const j = c + nxy; if (labels[j] === 0 && data[j] < 0) { labels[j] = label; q[tail++] = j; } }
      }
      sizes.push(tail);
      boxes.push([bx0, by0, bz0, bx1, by1, bz1]);
    }
    if (label <= 1) return [];
    let main = 1;
    for (let l = 2; l <= label; l++) if (sizes[l] > sizes[main]) main = l;

    const islands: Island[] = [];
    for (let l = 1; l <= label; l++) {
      if (l === main) continue;
      const [bx0, by0, bz0, bx1, by1, bz1] = boxes[l];
      // Extract a padded sub-grid for meshing the falling piece.
      const pad = 2;
      const ox = bx0 - pad, oy = by0 - pad, oz = bz0 - pad;
      const sx = bx1 - bx0 + 1 + pad * 2, sy = by1 - by0 + 1 + pad * 2, sz = bz1 - bz0 + 1 + pad * 2;
      const sub = sizes[l] >= 4 ? new Float32Array(sx * sy * sz) : null;
      for (let z = 0; z < sz; z++)
        for (let y = 0; y < sy; y++)
          for (let x = 0; x < sx; x++) {
            const gx = x + ox, gy = y + oy, gz = z + oz;
            let v = CLAMP;
            if (gx >= 0 && gy >= 0 && gz >= 0 && gx < nx && gy < ny && gz < nz) {
              const i = gx + nx * gy + nxy * gz;
              const own = labels[i] === l;
              v = own ? data[i] : data[i] < 0 ? 1 : data[i];
              if (own) data[i] = CLAMP; // remove from the log
            }
            if (sub) sub[x + sx * (y + sy * z)] = v;
          }
      this.changed(Math.max(0, bx0), Math.max(0, by0), Math.max(0, bz0), Math.min(nx - 1, bx1), Math.min(ny - 1, by1), Math.min(nz - 1, bz1));
      if (sub) islands.push({ data: sub, nx: sx, ny: sy, nz: sz, ox, oy, oz, cells: sizes[l] });
    }
    return islands;
  }
}

function clampHalf(v: number) {
  return v < -0.5 ? -0.5 : v > 0.5 ? 0.5 : v;
}
