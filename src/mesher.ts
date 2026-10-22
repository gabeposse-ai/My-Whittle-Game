// Turns an SDF grid region into triangles.
//
// Smooth mode uses Surface Nets: one vertex per grid cube whose 8 corners straddle the surface,
// placed at the average of the zero-crossings on its 12 edges; one quad per grid edge with a
// sign change, joining the 4 cubes around that edge. Normals come from the field gradient, so
// chunk seams shade continuously.
//
// Voxel mode emits a cube face for every solid sample next to an air sample (the classic
// voxel look, with the wood shader still producing real growth rings on every face).

export interface MeshSource {
  nx: number;
  ny: number;
  nz: number;
  data: Float32Array;
}

export interface MeshData {
  position: Float32Array;
  normal: Float32Array;
  bark: Float32Array;
  index: Uint32Array;
}

type ToLocal = (gx: number, gy: number, gz: number, out: [number, number, number]) => void;
type BarkFn = (lx: number, ly: number, lz: number) => number;

const CORNERS = [
  [0, 0, 0], [1, 0, 0], [0, 1, 0], [1, 1, 0],
  [0, 0, 1], [1, 0, 1], [0, 1, 1], [1, 1, 1],
];
const EDGES = [
  [0, 1], [2, 3], [4, 5], [6, 7],
  [0, 2], [1, 3], [4, 6], [5, 7],
  [0, 4], [1, 5], [2, 6], [3, 7],
];

function sampleT(src: MeshSource, x: number, y: number, z: number): number {
  const { nx, ny, nz, data } = src;
  let x0 = Math.floor(x), y0 = Math.floor(y), z0 = Math.floor(z);
  if (x0 < 0) x0 = 0; if (y0 < 0) y0 = 0; if (z0 < 0) z0 = 0;
  if (x0 > nx - 2) x0 = nx - 2; if (y0 > ny - 2) y0 = ny - 2; if (z0 > nz - 2) z0 = nz - 2;
  const fx = Math.min(1, Math.max(0, x - x0)), fy = Math.min(1, Math.max(0, y - y0)), fz = Math.min(1, Math.max(0, z - z0));
  const nxy = nx * ny;
  const i = x0 + nx * y0 + nxy * z0;
  const c00 = data[i] + (data[i + 1] - data[i]) * fx;
  const c10 = data[i + nx] + (data[i + nx + 1] - data[i + nx]) * fx;
  const c01 = data[i + nxy] + (data[i + nxy + 1] - data[i + nxy]) * fx;
  const c11 = data[i + nxy + nx] + (data[i + nxy + nx + 1] - data[i + nxy + nx]) * fx;
  const c0 = c00 + (c10 - c00) * fy;
  const c1 = c01 + (c11 - c01) * fy;
  return c0 + (c1 - c0) * fz;
}

class Growable {
  buf: Float32Array;
  n = 0;
  constructor(cap: number) { this.buf = new Float32Array(cap); }
  push3(a: number, b: number, c: number) {
    if (this.n + 3 > this.buf.length) { const nb = new Float32Array(this.buf.length * 2); nb.set(this.buf); this.buf = nb; }
    this.buf[this.n++] = a; this.buf[this.n++] = b; this.buf[this.n++] = c;
  }
  push1(a: number) {
    if (this.n + 1 > this.buf.length) { const nb = new Float32Array(this.buf.length * 2); nb.set(this.buf); this.buf = nb; }
    this.buf[this.n++] = a;
  }
  out() { return this.buf.slice(0, this.n); }
}

class GrowableU32 {
  buf: Uint32Array;
  n = 0;
  constructor(cap: number) { this.buf = new Uint32Array(cap); }
  push(a: number) {
    if (this.n + 1 > this.buf.length) { const nb = new Uint32Array(this.buf.length * 2); nb.set(this.buf); this.buf = nb; }
    this.buf[this.n++] = a;
  }
  out() { return this.buf.slice(0, this.n); }
}

/** Surface Nets over grid points [x0,x1)×[y0,y1)×[z0,z1). */
export function meshSurfaceNets(
  src: MeshSource, x0: number, y0: number, z0: number, x1: number, y1: number, z1: number,
  toLocal: ToLocal, barkFn: BarkFn,
): MeshData | null {
  const { nx, ny, nz, data } = src;
  const nxy = nx * ny;
  // Cube range needed: cubes [x0-1, x1) clipped to valid cubes [0, n-1).
  const cx0 = Math.max(0, x0 - 1), cy0 = Math.max(0, y0 - 1), cz0 = Math.max(0, z0 - 1);
  const cx1 = Math.min(nx - 1, x1), cy1 = Math.min(ny - 1, y1), cz1 = Math.min(nz - 1, z1);
  const sx = cx1 - cx0, sy = cy1 - cy0, sz = cz1 - cz0;
  if (sx <= 0 || sy <= 0 || sz <= 0) return null;
  const cubeIdx = new Int32Array(sx * sy * sz).fill(-1);

  const pos = new Growable(4096), nrm = new Growable(4096), bark = new Growable(1366);
  const idx = new GrowableU32(8192);
  const v = new Float32Array(8);
  const loc: [number, number, number] = [0, 0, 0];
  let vcount = 0;

  for (let z = cz0; z < cz1; z++) {
    for (let y = cy0; y < cy1; y++) {
      for (let x = cx0; x < cx1; x++) {
        let mask = 0;
        const base = x + nx * y + nxy * z;
        for (let c = 0; c < 8; c++) {
          const o = CORNERS[c];
          const val = data[base + o[0] + nx * o[1] + nxy * o[2]];
          v[c] = val;
          if (val < 0) mask |= 1 << c;
        }
        if (mask === 0 || mask === 255) continue;
        let ax = 0, ay = 0, az = 0, cnt = 0;
        for (let e = 0; e < 12; e++) {
          const a = EDGES[e][0], b = EDGES[e][1];
          const va = v[a], vb = v[b];
          if ((va < 0) === (vb < 0)) continue;
          const t = va / (va - vb);
          const oa = CORNERS[a], ob = CORNERS[b];
          ax += oa[0] + (ob[0] - oa[0]) * t;
          ay += oa[1] + (ob[1] - oa[1]) * t;
          az += oa[2] + (ob[2] - oa[2]) * t;
          cnt++;
        }
        const gx = x + ax / cnt, gy = y + ay / cnt, gz = z + az / cnt;
        // Normal from the field gradient.
        const h = 0.75;
        let nX = sampleT(src, gx + h, gy, gz) - sampleT(src, gx - h, gy, gz);
        let nY = sampleT(src, gx, gy + h, gz) - sampleT(src, gx, gy - h, gz);
        let nZ = sampleT(src, gx, gy, gz + h) - sampleT(src, gx, gy, gz - h);
        const l = Math.hypot(nX, nY, nZ) || 1;
        nX /= l; nY /= l; nZ /= l;
        toLocal(gx, gy, gz, loc);
        pos.push3(loc[0], loc[1], loc[2]);
        nrm.push3(nX, nY, nZ);
        bark.push1(barkFn(loc[0], loc[1], loc[2]));
        cubeIdx[(x - cx0) + sx * ((y - cy0) + sy * (z - cz0))] = vcount++;
      }
    }
  }
  if (vcount === 0) return null;

  const cube = (x: number, y: number, z: number) => {
    if (x < cx0 || y < cy0 || z < cz0 || x >= cx1 || y >= cy1 || z >= cz1) return -1;
    return cubeIdx[(x - cx0) + sx * ((y - cy0) + sy * (z - cz0))];
  };

  const dims = [nx, ny, nz];
  const p = [0, 0, 0];
  for (let z = z0; z < z1; z++) {
    for (let y = y0; y < y1; y++) {
      for (let x = x0; x < x1; x++) {
        const f0 = data[x + nx * y + nxy * z];
        p[0] = x; p[1] = y; p[2] = z;
        for (let a = 0; a < 3; a++) {
          if (p[a] + 1 >= dims[a]) continue;
          const f1 = a === 0 ? data[x + 1 + nx * y + nxy * z] : a === 1 ? data[x + nx * (y + 1) + nxy * z] : data[x + nx * y + nxy * (z + 1)];
          const in0 = f0 < 0;
          if (in0 === (f1 < 0)) continue;
          const u = (a + 1) % 3, w = (a + 2) % 3;
          if (p[u] < 1 || p[w] < 1 || p[u] > dims[u] - 2 || p[w] > dims[w] - 2) continue;
          // Four cubes around the edge, ordered counter-clockwise in the (u, w) plane.
          const q = [p[0], p[1], p[2]];
          q[u] = p[u] - 1; q[w] = p[w] - 1; const c00 = cube(q[0], q[1], q[2]);
          q[u] = p[u]; q[w] = p[w] - 1; const c10 = cube(q[0], q[1], q[2]);
          q[u] = p[u]; q[w] = p[w]; const c11 = cube(q[0], q[1], q[2]);
          q[u] = p[u] - 1; q[w] = p[w]; const c01 = cube(q[0], q[1], q[2]);
          if (c00 < 0 || c10 < 0 || c11 < 0 || c01 < 0) continue;
          if (in0) {
            // Solid at p, air at p+e_a: outward normal is +a, quad CCW seen from +a.
            idx.push(c00); idx.push(c10); idx.push(c11);
            idx.push(c00); idx.push(c11); idx.push(c01);
          } else {
            idx.push(c00); idx.push(c11); idx.push(c10);
            idx.push(c00); idx.push(c01); idx.push(c11);
          }
        }
      }
    }
  }
  if (idx.n === 0) return null;
  return { position: pos.out(), normal: nrm.out(), bark: bark.out(), index: idx.out() };
}

/** Blocky voxel faces over grid points [x0,x1)×[y0,y1)×[z0,z1). */
export function meshVoxels(
  src: MeshSource, x0: number, y0: number, z0: number, x1: number, y1: number, z1: number,
  toLocal: ToLocal, barkFn: BarkFn,
): MeshData | null {
  const { nx, ny, nz, data } = src;
  const nxy = nx * ny;
  const pos = new Growable(4096), nrm = new Growable(4096), bark = new Growable(1366);
  const idx = new GrowableU32(6144);
  const loc: [number, number, number] = [0, 0, 0];
  const dims = [nx, ny, nz];
  const p = [0, 0, 0];
  const c = [0, 0, 0];
  let vcount = 0;
  const solid = (x: number, y: number, z: number) =>
    x >= 0 && y >= 0 && z >= 0 && x < nx && y < ny && z < nz && data[x + nx * y + nxy * z] < 0;

  for (let z = z0; z < z1; z++) {
    for (let y = y0; y < y1; y++) {
      for (let x = x0; x < x1; x++) {
        if (data[x + nx * y + nxy * z] >= 0) continue;
        p[0] = x; p[1] = y; p[2] = z;
        for (let a = 0; a < 3; a++) {
          for (let s = -1; s <= 1; s += 2) {
            const qx = x + (a === 0 ? s : 0), qy = y + (a === 1 ? s : 0), qz = z + (a === 2 ? s : 0);
            if (solid(qx, qy, qz)) continue;
            if (p[a] + s < -1 || p[a] + s > dims[a]) continue;
            const u = (a + 1) % 3, w = (a + 2) % 3;
            // Face centre, for a single per-face bark value (crisp voxel look).
            c[0] = x; c[1] = y; c[2] = z; c[a] += 0.5 * s;
            toLocal(c[0], c[1], c[2], loc);
            const b = barkFn(loc[0], loc[1], loc[2]);
            const corners = s > 0
              ? [[-1, -1], [1, -1], [1, 1], [-1, 1]]
              : [[-1, -1], [-1, 1], [1, 1], [1, -1]];
            for (const [du, dw] of corners) {
              c[0] = x; c[1] = y; c[2] = z;
              c[a] += 0.5 * s; c[u] += 0.5 * du; c[w] += 0.5 * dw;
              toLocal(c[0], c[1], c[2], loc);
              pos.push3(loc[0], loc[1], loc[2]);
              nrm.push3(a === 0 ? s : 0, a === 1 ? s : 0, a === 2 ? s : 0);
              bark.push1(b);
            }
            idx.push(vcount); idx.push(vcount + 1); idx.push(vcount + 2);
            idx.push(vcount); idx.push(vcount + 2); idx.push(vcount + 3);
            vcount += 4;
          }
        }
      }
    }
  }
  if (vcount === 0) return null;
  return { position: pos.out(), normal: nrm.out(), bark: bark.out(), index: idx.out() };
}
