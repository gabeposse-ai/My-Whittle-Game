// Chunked mesh for the log. The field is split into 16³ chunks; only chunks touched by a cut
// are re-meshed, which keeps carving at interactive rates even at high resolution.

import * as THREE from 'three';
import type { Field } from './field';
import { meshSurfaceNets, meshVoxels, type MeshData } from './mesher';

export const CHUNK = 16;
export type MeshMode = 'smooth' | 'voxel';

export function buildGeometry(m: MeshData): THREE.BufferGeometry {
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.BufferAttribute(m.position, 3));
  g.setAttribute('normal', new THREE.BufferAttribute(m.normal, 3));
  g.setAttribute('aBark', new THREE.BufferAttribute(m.bark, 1));
  g.setIndex(new THREE.BufferAttribute(m.index, 1));
  g.computeBoundingSphere();
  return g;
}

export class LogMesh {
  readonly group = new THREE.Group();
  private chunks = new Map<number, THREE.Mesh>();
  private dirty = new Set<number>();
  private readonly ncx: number;
  private readonly ncy: number;
  private readonly ncz: number;
  private readonly toLocal: (gx: number, gy: number, gz: number, out: [number, number, number]) => void;
  private readonly barkFn: (x: number, y: number, z: number) => number;

  constructor(private field: Field, private material: THREE.Material, public mode: MeshMode) {
    this.ncx = Math.ceil(field.nx / CHUNK);
    this.ncy = Math.ceil(field.ny / CHUNK);
    this.ncz = Math.ceil(field.nz / CHUNK);
    this.toLocal = (gx, gy, gz, out) => field.gridToLocal(gx, gy, gz, out);
    this.barkFn = (x, y, z) => field.barkAmount(x, y, z);
    this.markAll();
  }

  private key(cx: number, cy: number, cz: number) {
    return cx + this.ncx * (cy + this.ncy * cz);
  }

  markAll() {
    for (let z = 0; z < this.ncz; z++)
      for (let y = 0; y < this.ncy; y++)
        for (let x = 0; x < this.ncx; x++) this.dirty.add(this.key(x, y, z));
  }

  /** Mark chunks overlapping a changed grid-point box (inclusive), padded by one for shared cubes. */
  markBox(x0: number, y0: number, z0: number, x1: number, y1: number, z1: number) {
    const c = (v: number, n: number) => Math.min(n - 1, Math.max(0, Math.floor(v / CHUNK)));
    const ax = c(x0 - 1, this.ncx), bx = c(x1 + 1, this.ncx);
    const ay = c(y0 - 1, this.ncy), by = c(y1 + 1, this.ncy);
    const az = c(z0 - 1, this.ncz), bz = c(z1 + 1, this.ncz);
    for (let z = az; z <= bz; z++)
      for (let y = ay; y <= by; y++)
        for (let x = ax; x <= bx; x++) this.dirty.add(this.key(x, y, z));
  }

  setMode(mode: MeshMode) {
    if (mode === this.mode) return;
    this.mode = mode;
    this.markAll();
  }

  get pending() {
    return this.dirty.size;
  }

  /** Rebuild up to `budget` dirty chunks. Returns true when everything is up to date. */
  update(budget = Infinity): boolean {
    let n = 0;
    for (const k of this.dirty) {
      if (n++ >= budget) return false;
      this.dirty.delete(k);
      this.rebuild(k);
    }
    return true;
  }

  private rebuild(k: number) {
    const cx = k % this.ncx;
    const cy = Math.floor(k / this.ncx) % this.ncy;
    const cz = Math.floor(k / (this.ncx * this.ncy));
    const f = this.field;
    const x0 = cx * CHUNK, y0 = cy * CHUNK, z0 = cz * CHUNK;
    const x1 = Math.min(f.nx, x0 + CHUNK), y1 = Math.min(f.ny, y0 + CHUNK), z1 = Math.min(f.nz, z0 + CHUNK);
    const fn = this.mode === 'smooth' ? meshSurfaceNets : meshVoxels;
    const data = fn(f, x0, y0, z0, x1, y1, z1, this.toLocal, this.barkFn);
    const old = this.chunks.get(k);
    if (!data) {
      if (old) {
        old.geometry.dispose();
        this.group.remove(old);
        this.chunks.delete(k);
      }
      return;
    }
    const geo = buildGeometry(data);
    if (old) {
      old.geometry.dispose();
      old.geometry = geo;
    } else {
      const m = new THREE.Mesh(geo, this.material);
      m.castShadow = true;
      m.receiveShadow = true;
      this.chunks.set(k, m);
      this.group.add(m);
    }
  }

  dispose() {
    for (const m of this.chunks.values()) m.geometry.dispose();
    this.chunks.clear();
    this.group.clear();
  }
}
