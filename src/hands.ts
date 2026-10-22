// Blocky voxel-style hands and tools. The holding hand grips one end of the log and turns with
// it; the carving hand holds the active tool, rests at the lower right, and moves the tool tip
// onto the cut while a stroke is in progress.

import * as THREE from 'three';
import type { ToolId } from './tools';

const skin = new THREE.MeshStandardMaterial({ color: '#d39b76', roughness: 0.75, flatShading: true });
const sleeve = new THREE.MeshStandardMaterial({ color: '#4b5a3c', roughness: 0.95, flatShading: true });
const steel = new THREE.MeshStandardMaterial({ color: '#c9ccd0', metalness: 0.85, roughness: 0.28, flatShading: true });
const darkSteel = new THREE.MeshStandardMaterial({ color: '#555a60', metalness: 0.7, roughness: 0.4, flatShading: true });
const handleWood = new THREE.MeshStandardMaterial({ color: '#8a5a34', roughness: 0.6, flatShading: true });
const handleDark = new THREE.MeshStandardMaterial({ color: '#4a2e1a', roughness: 0.6, flatShading: true });
const paper = new THREE.MeshStandardMaterial({ color: '#c7a57a', roughness: 1, flatShading: true });

function box(w: number, h: number, d: number, mat: THREE.Material, x = 0, y = 0, z = 0) {
  const m = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), mat);
  m.position.set(x, y, z);
  m.castShadow = true;
  return m;
}

function shadowAll(o: THREE.Object3D) {
  o.traverse((c) => { if (c instanceof THREE.Mesh) c.castShadow = true; });
}

/** Tool models: the cutting tip is at the origin, the handle runs along +z. */
function toolModel(id: ToolId): THREE.Group {
  const g = new THREE.Group();
  const handle = (len: number, r: number, start: number, mat = handleWood) => {
    const h = new THREE.Mesh(new THREE.CylinderGeometry(r * 0.9, r, len, 8), mat);
    h.rotation.x = Math.PI / 2;
    h.position.z = start + len / 2;
    g.add(h);
  };
  switch (id) {
    case 'sloyd':
      g.add(box(0.05, 0.45, 2.4, steel, 0, 0.2, 1.2));
      g.add(box(0.07, 0.12, 2.4, darkSteel, 0, 0.42, 1.2));
      handle(4, 0.42, 2.4);
      break;
    case 'detail':
      g.add(box(0.04, 0.22, 1.1, steel, 0, 0.1, 0.55));
      handle(3.6, 0.36, 1.1);
      break;
    case 'hook': {
      for (let i = 0; i < 5; i++) {
        const a = (i / 4) * Math.PI * 0.9;
        const seg = box(0.05, 0.3, 0.32, steel, 0, Math.sin(a) * 0.35, 0.35 - Math.cos(a) * 0.35);
        seg.rotation.x = -a;
        g.add(seg);
      }
      g.add(box(0.07, 0.25, 1.2, steel, 0, 0.12, 1.0));
      handle(4, 0.42, 1.5);
      break;
    }
    case 'ugouge':
    case 'vgouge': {
      const shaft = new THREE.Mesh(new THREE.CylinderGeometry(0.12, 0.15, 2.8, 8), steel);
      shaft.rotation.x = Math.PI / 2;
      shaft.position.z = 1.4;
      g.add(shaft);
      g.add(box(0.36, 0.06, 0.3, id === 'vgouge' ? darkSteel : steel, 0, 0.05, 0.12));
      handle(0.4, 0.3, 2.8, handleDark);
      const bulb = new THREE.Mesh(new THREE.SphereGeometry(0.6, 8, 6), handleWood);
      bulb.scale.set(1, 1, 1.9);
      bulb.position.z = 4.3;
      g.add(bulb);
      break;
    }
    case 'saw':
      g.add(box(0.03, 1.1, 8, steel, 0, 0.55, 4));
      g.add(box(0.045, 0.06, 8, darkSteel, 0, 0.02, 4));
      handle(4.5, 0.42, 8, handleDark);
      break;
    case 'sand':
      g.add(box(1.6, 0.14, 2.4, paper, 0, 0.07, 0.6));
      g.add(box(1.4, 0.4, 1.2, paper, 0, 0.3, 1.5));
      break;
  }
  shadowAll(g);
  return g;
}

function carvingHand(id: ToolId): THREE.Group {
  const g = new THREE.Group();
  const z = id === 'sand' ? 1.2 : id === 'saw' ? 10 : id === 'detail' ? 2.8 : id === 'ugouge' || id === 'vgouge' ? 4 : 4.2;
  g.add(box(1.5, 1.3, 1.9, skin, 0.15, -0.1, z));
  for (let i = 0; i < 4; i++) g.add(box(0.36, 0.42, 0.42, skin, -0.62, -0.45 + i * 0.36, z - 0.7 + i * 0.42));
  g.add(box(0.4, 0.4, 1.0, skin, 0.25, 0.75, z - 0.6)); // thumb
  g.add(box(1.4, 1.2, 1.2, sleeve, 0.2, -0.2, z + 1.5)); // cuff
  shadowAll(g);
  return g;
}

export class Hands {
  /** Attach to the log group; repositioned when the grip end flips. */
  readonly holding = new THREE.Group();
  /** World-space carving hand + tool. */
  readonly carving = new THREE.Group();
  private toolGroup = new THREE.Group();
  private target = new THREE.Vector3();
  private targetQ = new THREE.Quaternion();
  private restPos = new THREE.Vector3();
  private restQ = new THREE.Quaternion();
  private engaged = false;

  constructor() {
    this.carving.add(this.toolGroup);
  }

  buildHolding(radius: number, length: number, gripTop: boolean) {
    this.holding.clear();
    const g = new THREE.Group();
    // Polar placement around the log axis: x = sin(θ)·r, z = cos(θ)·r, θ = 0 faces the carver.
    const put = (m: THREE.Object3D, theta: number, rad: number, y: number) => {
      m.position.set(Math.sin(theta) * rad, y, Math.cos(theta) * rad);
      m.rotation.y = theta;
      g.add(m);
    };
    const R = radius + 0.3;
    const fingerT = 0.58;
    const palmTheta = -Math.PI / 2;
    // Four fingers wrap from the palm around the back, ending at the front-right.
    for (let i = 0; i < 4; i++) {
      const y = -1.05 + i * 0.66;
      const span = Math.PI * (1.28 - i * 0.07);
      const segs = 6;
      for (let k = 0; k < segs; k++) {
        const a = palmTheta - (span * (k + 0.5)) / segs;
        const segLen = (span / segs) * R * 1.08;
        const knuckle = k === 0 || k === 2 || k === 4 ? 1.07 : 1;
        put(box(segLen, fingerT * (k === segs - 1 ? 0.9 : 1), fingerT * knuckle, skin), a, R + 0.02 * k, y);
      }
    }
    // Palm against the left side.
    put(box(2.3, 2.9, 0.9, skin), palmTheta, R + 0.25, -0.1);
    // Thumb wraps the front from the left, just above the fingers.
    for (let k = 0; k < 3; k++) {
      const a = palmTheta + 0.35 + k * 0.32;
      put(box(0.32 * R, 0.62, 0.62, skin), a, R + 0.08, 1.55);
    }
    shadowAll(g);
    g.position.y = gripTop ? length / 2 - 1.2 : -length / 2 + 1.2;
    if (gripTop) g.rotation.z = Math.PI;
    this.holding.add(g);
  }

  setTool(id: ToolId) {
    this.toolGroup.clear();
    this.toolGroup.add(toolModel(id));
    this.toolGroup.add(carvingHand(id));
  }

  /** Rest pose in front of the camera, lower right. */
  setRest(camera: THREE.Camera) {
    const p = new THREE.Vector3(7.5, -7.5, -16).applyMatrix4(camera.matrixWorld);
    this.restPos.copy(p);
    const look = new THREE.Vector3(9, -10, -4).applyMatrix4(camera.matrixWorld);
    const m = new THREE.Matrix4().lookAt(p, look, new THREE.Vector3(0, 1, 0));
    // Object3D.lookAt convention: +z toward target. Matrix4.lookAt gives -z... flip:
    this.restQ.setFromRotationMatrix(m).multiply(new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 1, 0), Math.PI));
    this.restQ.multiply(new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 0, 1), 0.5));
    if (!this.engaged) {
      this.carving.position.copy(this.restPos);
      this.carving.quaternion.copy(this.restQ);
    }
  }

  /** Put the tool tip on the cut; the handle points back toward the camera's lower right. */
  engage(tip: THREE.Vector3, normal: THREE.Vector3, camera: THREE.Camera) {
    this.engaged = true;
    this.target.copy(tip);
    // Handle off to the lower right of the cut (not between the eye and the blade).
    const right = new THREE.Vector3(1, 0, 0).applyQuaternion(camera.quaternion);
    const up = new THREE.Vector3(0, 1, 0).applyQuaternion(camera.quaternion);
    const back = new THREE.Vector3(0, 0, 1).applyQuaternion(camera.quaternion);
    const handleDir = right.multiplyScalar(1).addScaledVector(up, -0.55).addScaledVector(back, 0.35);
    handleDir.addScaledVector(normal, 0.35).normalize();
    const m = new THREE.Matrix4().lookAt(tip.clone().add(handleDir), tip, normal);
    this.targetQ.setFromRotationMatrix(m);
  }

  release() {
    this.engaged = false;
  }

  update(dt: number) {
    const k = 1 - Math.exp(-dt * (this.engaged ? 28 : 8));
    const tp = this.engaged ? this.target : this.restPos;
    const tq = this.engaged ? this.targetQ : this.restQ;
    this.carving.position.lerp(tp, k);
    this.carving.quaternion.slerp(tq, k);
  }
}
