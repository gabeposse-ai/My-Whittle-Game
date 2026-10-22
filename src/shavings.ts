// Shavings, chips, dust and offcuts. All of it is real geometry that falls, tumbles and settles
// on your lap or the floor and stays there, so the pile grows as the log shrinks.
//
// Curls: a ribbon whose width matches the cut width and whose length tracks the stroke length,
// generated as a tightening spiral rising off the blade. While the stroke is active it grows at
// the cutting edge; on release it drops.
// Chips: instanced little boxes, sized from the removed volume.

import * as THREE from 'three';
import { surfaceHeight } from './scene';

const GRAVITY = -386; // in/s²

interface Body {
  obj: THREE.Object3D;
  vel: THREE.Vector3;
  ang: THREE.Vector3;
  rest: number; // half-height used for landing
  resting: boolean;
  strokeId: number;
  kind: 'curl' | 'piece';
}

interface Curl {
  mesh: THREE.Mesh;
  len: number;
  width: number;
  r0: number;
  strokeId: number;
  dir: THREE.Vector3;
}

const SEGS = 36;

function writeCurl(geo: THREE.BufferGeometry, len: number, width: number, r0: number) {
  const pos = geo.getAttribute('position') as THREE.BufferAttribute;
  // Centreline in the local frame: x = cut direction, y = surface normal, z = across the cut.
  let x = 0, y = 0;
  let phi = Math.PI * 0.62; // starts rising up and back off the blade face
  const ds = len / SEGS;
  for (let i = 0; i <= SEGS; i++) {
    const s = i * ds;
    pos.setXYZ(i * 2, x, y, -width / 2);
    pos.setXYZ(i * 2 + 1, x, y, width / 2);
    const r = r0 * (1 - 0.45 * (s / (len + 0.5)));
    phi -= ds / r; // curl over toward the cut direction
    x += Math.cos(phi) * ds;
    y += Math.sin(phi) * ds;
  }
  pos.needsUpdate = true;
  geo.computeVertexNormals();
  geo.computeBoundingSphere();
}

function curlGeometry(): THREE.BufferGeometry {
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.BufferAttribute(new Float32Array((SEGS + 1) * 2 * 3), 3));
  const idx: number[] = [];
  for (let i = 0; i < SEGS; i++) {
    const a = i * 2, b = a + 1, c = a + 2, d = a + 3;
    idx.push(a, c, b, b, c, d);
  }
  g.setIndex(idx);
  return g;
}

const MAX_CHIPS = 3000;
const MAX_CURLS = 140;
const MAX_PIECES = 24;

export class Shavings {
  readonly group = new THREE.Group();
  private bodies: Body[] = [];
  private active: Curl | null = null;
  private curlMats = new Map<string, THREE.MeshStandardMaterial>();

  // Chip pool (instanced)
  private chips: THREE.InstancedMesh;
  private cPos = new Float32Array(MAX_CHIPS * 3);
  private cVel = new Float32Array(MAX_CHIPS * 3);
  private cRot = new Float32Array(MAX_CHIPS * 3);
  private cSpin = new Float32Array(MAX_CHIPS * 3);
  private cScale = new Float32Array(MAX_CHIPS * 3);
  private cState = new Uint8Array(MAX_CHIPS); // 0 free, 1 flying, 2 resting
  private cStroke = new Int32Array(MAX_CHIPS);
  private cNext = 0;
  private flying = new Set<number>();
  private m4 = new THREE.Matrix4();
  private q = new THREE.Quaternion();
  private e = new THREE.Euler();
  private v = new THREE.Vector3();
  private s = new THREE.Vector3();

  constructor() {
    this.chips = new THREE.InstancedMesh(
      new THREE.BoxGeometry(1, 1, 1),
      new THREE.MeshStandardMaterial({ roughness: 0.85 }),
      MAX_CHIPS,
    );
    this.chips.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
    this.chips.castShadow = true;
    this.chips.receiveShadow = true;
    this.chips.frustumCulled = false;
    const zero = new THREE.Matrix4().makeScale(0, 0, 0);
    for (let i = 0; i < MAX_CHIPS; i++) {
      this.chips.setMatrixAt(i, zero);
      this.chips.setColorAt(i, new THREE.Color(1, 1, 1));
    }
    this.group.add(this.chips);
  }

  private curlMat(color: THREE.Color) {
    const key = color.getHexString().slice(0, 5);
    let m = this.curlMats.get(key);
    if (!m) {
      m = new THREE.MeshStandardMaterial({ color, roughness: 0.75, side: THREE.DoubleSide });
      this.curlMats.set(key, m);
    }
    return m;
  }

  /** Grow (or start) the curl coming off the blade at `p`. */
  growCurl(strokeId: number, p: THREE.Vector3, t: THREE.Vector3, n: THREE.Vector3, width: number, depth: number, add: number, color: THREE.Color) {
    let c = this.active;
    if (c && (c.strokeId !== strokeId || c.dir.dot(t) < 0.5 || Math.abs(c.width - width) > Math.max(0.08, c.width * 0.6) || c.len > 7)) {
      this.releaseCurl();
      c = null;
    }
    if (!c) {
      const mesh = new THREE.Mesh(curlGeometry(), this.curlMat(color));
      mesh.castShadow = true;
      mesh.receiveShadow = true;
      c = { mesh, len: 0, width: Math.max(0.05, width), r0: 0.1 + depth * 3 + width * 0.08, strokeId, dir: t.clone() };
      this.group.add(mesh);
      this.active = c;
    }
    c.len += add * 0.9;
    c.width = c.width * 0.8 + Math.max(0.05, width) * 0.2;
    c.dir.lerp(t, 0.3).normalize();
    writeCurl(c.mesh.geometry, c.len, c.width, c.r0);
    // Orient: local x = cut direction, y = normal, z = side.
    const z = new THREE.Vector3().crossVectors(c.dir, n).normalize();
    const y = new THREE.Vector3().crossVectors(z, c.dir).normalize();
    this.m4.makeBasis(c.dir, y, z);
    c.mesh.quaternion.setFromRotationMatrix(this.m4);
    c.mesh.position.copy(p).addScaledVector(n, 0.01);
  }

  releaseCurl() {
    const c = this.active;
    if (!c) return;
    this.active = null;
    if (c.len < 0.08) {
      this.group.remove(c.mesh);
      c.mesh.geometry.dispose();
      return;
    }
    // Re-centre the mesh on its bounding sphere so it tumbles about its middle.
    const g = c.mesh.geometry;
    g.computeBoundingSphere();
    const centre = g.boundingSphere!.center.clone();
    g.translate(-centre.x, -centre.y, -centre.z);
    c.mesh.position.add(centre.applyQuaternion(c.mesh.quaternion));
    this.addBody({
      obj: c.mesh,
      vel: new THREE.Vector3((Math.random() - 0.5) * 8, 6 + Math.random() * 6, (Math.random() - 0.5) * 8),
      ang: new THREE.Vector3((Math.random() - 0.5) * 8, (Math.random() - 0.5) * 8, (Math.random() - 0.5) * 8),
      rest: Math.min(0.5, g.boundingSphere!.radius * 0.5),
      resting: false,
      strokeId: c.strokeId,
      kind: 'curl',
    });
  }

  /** A cut-free piece of the log, already positioned in world space. */
  addPiece(obj: THREE.Object3D, strokeId: number, radius: number) {
    this.group.add(obj);
    this.addBody({
      obj,
      vel: new THREE.Vector3((Math.random() - 0.5) * 6, 2, (Math.random() - 0.5) * 6),
      ang: new THREE.Vector3((Math.random() - 0.5) * 3, (Math.random() - 0.5) * 3, (Math.random() - 0.5) * 3),
      rest: radius * 0.5,
      resting: false,
      strokeId,
      kind: 'piece',
    });
  }

  private addBody(b: Body) {
    this.bodies.push(b);
    const curls = this.bodies.filter((x) => x.kind === b.kind);
    const cap = b.kind === 'curl' ? MAX_CURLS : MAX_PIECES;
    if (curls.length > cap) this.removeBody(curls[0]);
  }

  private removeBody(b: Body) {
    const i = this.bodies.indexOf(b);
    if (i >= 0) this.bodies.splice(i, 1);
    this.group.remove(b.obj);
    if (b.obj instanceof THREE.Mesh) b.obj.geometry.dispose();
  }

  /** Spawn chips/dust. `count` chips of roughly `size` inches. */
  spawnChips(strokeId: number, p: THREE.Vector3, n: THREE.Vector3, count: number, size: number, color: THREE.Color, dust = false) {
    for (let k = 0; k < count; k++) {
      const i = this.cNext;
      this.cNext = (this.cNext + 1) % MAX_CHIPS;
      this.flying.add(i);
      const j = i * 3;
      const spread = dust ? 0.15 : 0.3;
      this.cPos[j] = p.x + (Math.random() - 0.5) * spread;
      this.cPos[j + 1] = p.y + (Math.random() - 0.5) * spread;
      this.cPos[j + 2] = p.z + (Math.random() - 0.5) * spread;
      const sp = dust ? 6 : 14;
      this.cVel[j] = n.x * sp * Math.random() + (Math.random() - 0.5) * sp;
      this.cVel[j + 1] = n.y * sp * Math.random() + Math.random() * sp * 0.6;
      this.cVel[j + 2] = n.z * sp * Math.random() + (Math.random() - 0.5) * sp;
      this.cRot[j] = Math.random() * 6; this.cRot[j + 1] = Math.random() * 6; this.cRot[j + 2] = Math.random() * 6;
      this.cSpin[j] = (Math.random() - 0.5) * 30; this.cSpin[j + 1] = (Math.random() - 0.5) * 30; this.cSpin[j + 2] = (Math.random() - 0.5) * 30;
      const s = size * (0.6 + Math.random() * 0.8);
      this.cScale[j] = s * (dust ? 1 : 1.6); this.cScale[j + 1] = s * (dust ? 1 : 0.35); this.cScale[j + 2] = s;
      this.cState[i] = 1;
      this.cStroke[i] = strokeId;
      const c = color.clone().multiplyScalar(0.92 + Math.random() * 0.16);
      this.chips.setColorAt(i, c);
    }
    if (this.chips.instanceColor) this.chips.instanceColor.needsUpdate = true;
  }

  /** Remove everything that came off during a stroke (used by undo). */
  removeStroke(strokeId: number) {
    if (this.active?.strokeId === strokeId) this.releaseCurl();
    for (const b of [...this.bodies]) if (b.strokeId === strokeId) this.removeBody(b);
    for (let i = 0; i < MAX_CHIPS; i++) {
      if (this.cState[i] !== 0 && this.cStroke[i] === strokeId) {
        this.cState[i] = 0;
        this.flying.delete(i);
        this.chips.setMatrixAt(i, this.m4.makeScale(0, 0, 0));
      }
    }
    this.chips.instanceMatrix.needsUpdate = true;
  }

  clear() {
    this.releaseCurl();
    for (const b of [...this.bodies]) this.removeBody(b);
    for (let i = 0; i < MAX_CHIPS; i++) {
      this.cState[i] = 0;
      this.chips.setMatrixAt(i, this.m4.makeScale(0, 0, 0));
    }
    this.flying.clear();
    this.chips.instanceMatrix.needsUpdate = true;
  }

  update(dt: number) {
    dt = Math.min(dt, 1 / 30);
    // Rigid bodies: curls and offcuts.
    for (const b of this.bodies) {
      if (b.resting) continue;
      b.vel.y += GRAVITY * dt * (b.kind === 'curl' ? 0.55 : 1); // curls are light and draggy
      b.vel.multiplyScalar(b.kind === 'curl' ? 0.985 : 0.995);
      b.obj.position.addScaledVector(b.vel, dt);
      const ang = b.ang.length();
      if (ang > 0) {
        this.q.setFromAxisAngle(this.v.copy(b.ang).divideScalar(ang), ang * dt);
        b.obj.quaternion.premultiply(this.q);
      }
      const floor = surfaceHeight(b.obj.position.x, b.obj.position.z) + b.rest;
      if (b.obj.position.y < floor) {
        b.obj.position.y = floor;
        if (Math.abs(b.vel.y) < 25) {
          b.resting = true;
        } else {
          b.vel.y *= -0.25;
          b.vel.x *= 0.5; b.vel.z *= 0.5;
          b.ang.multiplyScalar(0.4);
        }
      }
    }

    // Chips
    if (this.flying.size) {
      for (const i of this.flying) {
        const j = i * 3;
        this.cVel[j + 1] += GRAVITY * dt * 0.7;
        const drag = 0.97;
        this.cVel[j] *= drag; this.cVel[j + 1] *= drag; this.cVel[j + 2] *= drag;
        this.cPos[j] += this.cVel[j] * dt;
        this.cPos[j + 1] += this.cVel[j + 1] * dt;
        this.cPos[j + 2] += this.cVel[j + 2] * dt;
        this.cRot[j] += this.cSpin[j] * dt; this.cRot[j + 1] += this.cSpin[j + 1] * dt; this.cRot[j + 2] += this.cSpin[j + 2] * dt;
        const floor = surfaceHeight(this.cPos[j], this.cPos[j + 2]) + this.cScale[j + 1] * 0.5;
        if (this.cPos[j + 1] < floor) {
          this.cPos[j + 1] = floor;
          // Settle flat-ish: keep yaw, zero most of pitch/roll.
          this.cRot[j] = (Math.random() - 0.5) * 0.4;
          this.cRot[j + 2] = (Math.random() - 0.5) * 0.4;
          this.cState[i] = 2;
          this.flying.delete(i);
        }
        this.e.set(this.cRot[j], this.cRot[j + 1], this.cRot[j + 2]);
        this.q.setFromEuler(this.e);
        this.v.set(this.cPos[j], this.cPos[j + 1], this.cPos[j + 2]);
        this.s.set(this.cScale[j], this.cScale[j + 1], this.cScale[j + 2]);
        this.m4.compose(this.v, this.q, this.s);
        this.chips.setMatrixAt(i, this.m4);
      }
      this.chips.instanceMatrix.needsUpdate = true;
    }
  }
}
