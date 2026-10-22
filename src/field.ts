// The log as a signed distance field (SDF) on a regular grid.
//
// Every grid point stores the approximate distance (in voxels) to the wood surface:
// negative = inside wood, positive = air. Values are clamped to ±CLAMP because only the
// band near the surface matters for meshing and carving. Carving is a CSG subtraction:
// f = max(f, -cutter(p)), where cutter(p) is the cutter's own SDF (negative inside the blade's
// swept volume). This keeps the surface smooth and sub-voxel accurate.
//
// Coordinate frames:
//   grid  : integer sample indices (x, y, z), log axis along +y
//   local : inches, origin at log centre, y = log axis (this is the frame the meshes live in)

import { fbm } from './noise';
import type { LogSize, Species } from './species';

export const CLAMP = 4;

export interface Knot {
  y: number; // inches along the axis
  angle: number; // radians around the axis
  rise: number; // upward slope of the branch
}

export class Field {
  readonly nx: number;
  readonly ny: number;
  readonly nz: number;
  readonly vpi: number;
  readonly data: Float32Array;
  readonly cx: number;
  readonly cy: number;
  readonly cz: number;
  readonly knots: Knot[] = [];

  constructor(
    readonly size: LogSize,
    readonly species: Species,
    vpi: number,
    readonly seed: number,
  ) {
    this.vpi = vpi;
    const pad = 3;
    this.nx = this.nz = Math.ceil(size.radius * 2 * 1.08 * vpi) + pad * 2;
    this.ny = Math.ceil(size.length * vpi) + pad * 2;
    this.cx = (this.nx - 1) / 2;
    this.cy = (this.ny - 1) / 2;
    this.cz = (this.nz - 1) / 2;
    this.data = new Float32Array(this.nx * this.ny * this.nz);

    // Deterministic knots from the seed.
    let s = seed;
    const rnd = () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296);
    for (let i = 0; i < species.knots; i++) {
      this.knots.push({
        y: (rnd() - 0.5) * size.length * 0.7,
        angle: rnd() * Math.PI * 2,
        rise: 0.25 + rnd() * 0.25,
      });
    }
  }

  idx(x: number, y: number, z: number): number {
    return x + this.nx * (y + this.ny * z);
  }

  inBounds(x: number, y: number, z: number): boolean {
    return x >= 0 && y >= 0 && z >= 0 && x < this.nx && y < this.ny && z < this.nz;
  }

  get(x: number, y: number, z: number): number {
    if (x < 0 || y < 0 || z < 0 || x >= this.nx || y >= this.ny || z >= this.nz) return CLAMP;
    return this.data[x + this.nx * (y + this.ny * z)];
  }

  /** Trilinear sample at fractional grid coordinates. */
  sample(x: number, y: number, z: number, src: Float32Array = this.data): number {
    const x0 = Math.floor(x), y0 = Math.floor(y), z0 = Math.floor(z);
    if (x0 < 0 || y0 < 0 || z0 < 0 || x0 >= this.nx - 1 || y0 >= this.ny - 1 || z0 >= this.nz - 1) return CLAMP;
    const fx = x - x0, fy = y - y0, fz = z - z0;
    const nx = this.nx, nxy = this.nx * this.ny;
    const i = x0 + nx * y0 + nxy * z0;
    const c00 = src[i] + (src[i + 1] - src[i]) * fx;
    const c10 = src[i + nx] + (src[i + nx + 1] - src[i + nx]) * fx;
    const c01 = src[i + nxy] + (src[i + nxy + 1] - src[i + nxy]) * fx;
    const c11 = src[i + nxy + nx] + (src[i + nxy + nx + 1] - src[i + nxy + nx]) * fx;
    const c0 = c00 + (c10 - c00) * fy;
    const c1 = c01 + (c11 - c01) * fy;
    return c0 + (c1 - c0) * fz;
  }

  /** Normalised gradient (outward surface normal) at fractional grid coords. */
  gradient(x: number, y: number, z: number, out: [number, number, number], src: Float32Array = this.data) {
    const h = 0.75;
    let gx = this.sample(x + h, y, z, src) - this.sample(x - h, y, z, src);
    let gy = this.sample(x, y + h, z, src) - this.sample(x, y - h, z, src);
    let gz = this.sample(x, y, z + h, src) - this.sample(x, y, z - h, src);
    const l = Math.hypot(gx, gy, gz) || 1;
    gx /= l; gy /= l; gz /= l;
    out[0] = gx; out[1] = gy; out[2] = gz;
    return out;
  }

  gridToLocal(gx: number, gy: number, gz: number, out: [number, number, number]) {
    out[0] = (gx - this.cx) / this.vpi;
    out[1] = (gy - this.cy) / this.vpi;
    out[2] = (gz - this.cz) / this.vpi;
    return out;
  }

  localToGrid(lx: number, ly: number, lz: number, out: [number, number, number]) {
    out[0] = lx * this.vpi + this.cx;
    out[1] = ly * this.vpi + this.cy;
    out[2] = lz * this.vpi + this.cz;
    return out;
  }

  /** The uncarved log's radius (inches) at height y and angle theta — natural wobble and taper. */
  originalRadius(y: number, theta: number): number {
    const { radius, length } = this.size;
    const c = Math.cos(theta), s = Math.sin(theta);
    const wobble = fbm(c * 1.3 + 11, s * 1.3, y * 0.22, this.seed) * 0.09 + Math.sin(3 * theta + y * 0.15) * 0.012;
    const taper = 1 - 0.025 * (y / length);
    return radius * taper * (1 + wobble);
  }

  barkThickness(y: number, theta: number): number {
    const t = this.species.barkInch;
    return t * (0.75 + 0.5 * (fbm(Math.cos(theta) * 4, Math.sin(theta) * 4, y * 0.8, this.seed + 3) + 0.5));
  }

  /** 0..1 how much a local-space point is bark (vs. wood) — used for vertex attributes and shavings. */
  barkAmount(lx: number, ly: number, lz: number): number {
    const r = Math.hypot(lx, lz);
    const th = Math.atan2(lz, lx);
    const inner = this.originalRadius(ly, th) - this.barkThickness(ly, th);
    const t = (r - inner) / 0.04 + 0.5;
    return t <= 0 ? 0 : t >= 1 ? 1 : t * t * (3 - 2 * t);
  }

  /** Fill the grid with an uncarved log: a wobbly cylinder with slightly uneven saw-cut ends. */
  initLog() {
    const { nx, ny, nz, vpi, data } = this;
    const half = this.size.length / 2;
    const p: [number, number, number] = [0, 0, 0];
    for (let z = 0; z < nz; z++) {
      for (let y = 0; y < ny; y++) {
        for (let x = 0; x < nx; x++) {
          this.gridToLocal(x, y, z, p);
          const r = Math.hypot(p[0], p[2]);
          const th = Math.atan2(p[2], p[0]);
          const side = (r - this.originalRadius(p[1], th)) * vpi;
          // Saw-cut ends: slightly tilted and rough.
          const endTop = p[1] - (half - 0.04 * p[0] + fbm(p[0] * 2, p[2] * 2, 5, this.seed) * 0.05);
          const endBot = -p[1] - (half + 0.03 * p[2] + fbm(p[0] * 2, p[2] * 2, 9, this.seed) * 0.05);
          const ends = Math.max(endTop, endBot) * vpi;
          let f = Math.max(side, ends);
          if (f > CLAMP) f = CLAMP; else if (f < -CLAMP) f = -CLAMP;
          data[x + nx * (y + ny * z)] = f;
        }
      }
    }
  }
}
