// The cozy workshop: a dusk-lit room seen from a seated whittler. Units are inches.
// Everything here is set dressing; the only interactive thing in the game is the log.

import * as THREE from 'three';
import { RoomEnvironment } from 'three/examples/jsm/environments/RoomEnvironment.js';

export const LAP = { y: 22.2, x0: -13, x1: 13, z0: -26, z1: -3 };
export const FLOOR_Y = 0;

export function surfaceHeight(x: number, z: number): number {
  if (x > LAP.x0 && x < LAP.x1 && z > LAP.z0 && z < LAP.z1) return LAP.y;
  return FLOOR_Y;
}

function canvasTex(w: number, h: number, draw: (g: CanvasRenderingContext2D) => void, repeat?: [number, number]) {
  const c = document.createElement('canvas');
  c.width = w; c.height = h;
  draw(c.getContext('2d')!);
  const t = new THREE.CanvasTexture(c);
  t.colorSpace = THREE.SRGBColorSpace;
  t.anisotropy = 4;
  if (repeat) {
    t.wrapS = t.wrapT = THREE.RepeatWrapping;
    t.repeat.set(repeat[0], repeat[1]);
  }
  return t;
}

let seed = 42;
const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);

function planks(g: CanvasRenderingContext2D, w: number, h: number, n: number, base: [number, number, number], vertical: boolean) {
  const size = (vertical ? w : h) / n;
  for (let i = 0; i < n; i++) {
    const v = 0.8 + rnd() * 0.35;
    g.fillStyle = `rgb(${base[0] * v | 0},${base[1] * v | 0},${base[2] * v | 0})`;
    if (vertical) g.fillRect(i * size, 0, size, h); else g.fillRect(0, i * size, w, size);
    // grain streaks
    for (let k = 0; k < 40; k++) {
      const a = 0.04 + rnd() * 0.06;
      g.fillStyle = `rgba(${rnd() < 0.5 ? '0,0,0' : '255,220,170'},${a})`;
      if (vertical) g.fillRect(i * size + rnd() * size, 0, 1 + rnd() * 2, h);
      else g.fillRect(0, i * size + rnd() * size, w, 1 + rnd() * 2);
    }
    g.fillStyle = 'rgba(0,0,0,0.55)';
    if (vertical) g.fillRect(i * size, 0, 2, h); else g.fillRect(0, i * size, w, 2);
    // board ends / nails
    if (!vertical) {
      const cut = rnd() * w;
      g.fillRect(cut, i * size, 2, size);
    }
  }
}

export interface Workshop {
  scene: THREE.Scene;
  camera: THREE.PerspectiveCamera;
  update(t: number): void;
  workLight: THREE.SpotLight;
}

export function buildWorkshop(renderer: THREE.WebGLRenderer): Workshop {
  const scene = new THREE.Scene();
  scene.background = new THREE.Color('#120c08');
  scene.fog = new THREE.Fog('#120c08', 90, 260);

  const pmrem = new THREE.PMREMGenerator(renderer);
  scene.environment = pmrem.fromScene(new RoomEnvironment() as unknown as THREE.Scene, 0.04).texture;
  scene.environmentIntensity = 0.12;

  const camera = new THREE.PerspectiveCamera(50, 1, 0.5, 600);
  camera.position.set(0, 40, 2);
  camera.lookAt(0, 30.5, -15);

  // Floor
  const floorTex = canvasTex(1024, 1024, (g) => planks(g, 1024, 1024, 8, [92, 62, 40], false), [6, 6]);
  const floor = new THREE.Mesh(
    new THREE.PlaneGeometry(400, 400),
    new THREE.MeshStandardMaterial({ map: floorTex, roughness: 0.85 }),
  );
  floor.rotation.x = -Math.PI / 2;
  floor.receiveShadow = true;
  scene.add(floor);

  // Walls
  const wallTex = canvasTex(1024, 512, (g) => planks(g, 1024, 512, 10, [70, 48, 32], true), [5, 1]);
  const wallMat = new THREE.MeshStandardMaterial({ map: wallTex, roughness: 0.95 });
  const mkWall = (w: number, h: number, x: number, z: number, ry: number) => {
    const m = new THREE.Mesh(new THREE.PlaneGeometry(w, h), wallMat);
    m.position.set(x, h / 2, z);
    m.rotation.y = ry;
    m.receiveShadow = true;
    scene.add(m);
    return m;
  };
  mkWall(240, 120, 0, -100, 0);
  mkWall(240, 120, -90, -10, Math.PI / 2);
  mkWall(240, 120, 90, -10, -Math.PI / 2);
  mkWall(240, 120, 0, 80, Math.PI);
  const ceil = new THREE.Mesh(new THREE.PlaneGeometry(240, 240), new THREE.MeshStandardMaterial({ color: '#1a120c', roughness: 1 }));
  ceil.rotation.x = Math.PI / 2;
  ceil.position.y = 120;
  scene.add(ceil);
  // Beams
  const beamMat = new THREE.MeshStandardMaterial({ color: '#3a2618', roughness: 0.9 });
  for (let i = -2; i <= 2; i++) {
    const b = new THREE.Mesh(new THREE.BoxGeometry(6, 6, 240), beamMat);
    b.position.set(i * 40, 116, -10);
    scene.add(b);
  }

  // Window with dusk sky on the back wall
  const winTex = canvasTex(256, 320, (g) => {
    const grd = g.createLinearGradient(0, 0, 0, 320);
    grd.addColorStop(0, '#1d2340');
    grd.addColorStop(0.55, '#5b4a6e');
    grd.addColorStop(0.8, '#c98a5c');
    grd.addColorStop(1, '#2a2230');
    g.fillStyle = grd;
    g.fillRect(0, 0, 256, 320);
    // distant tree line
    g.fillStyle = '#141018';
    g.beginPath();
    g.moveTo(0, 320);
    for (let x = 0; x <= 256; x += 8) g.lineTo(x, 250 - Math.abs(Math.sin(x * 0.11)) * 30 - rnd() * 18);
    g.lineTo(256, 320);
    g.fill();
    for (let i = 0; i < 18; i++) {
      g.fillStyle = `rgba(255,250,230,${0.4 + rnd() * 0.5})`;
      g.fillRect(rnd() * 256, rnd() * 120, 1.5, 1.5);
    }
    g.fillStyle = '#2b1c12';
    g.fillRect(124, 0, 8, 320);
    g.fillRect(0, 156, 256, 8);
  });
  const win = new THREE.Mesh(new THREE.PlaneGeometry(32, 40), new THREE.MeshBasicMaterial({ map: winTex, fog: false }));
  win.position.set(-22, 62, -99.5);
  scene.add(win);
  const frame = new THREE.Mesh(new THREE.BoxGeometry(36, 44, 1), beamMat);
  frame.position.set(-22, 62, -100.2);
  scene.add(frame);

  // Fireplace on the right wall
  const stoneTex = canvasTex(512, 512, (g) => {
    g.fillStyle = '#2a2420';
    g.fillRect(0, 0, 512, 512);
    for (let y = 0; y < 512; y += 48) {
      for (let x = (y / 48) % 2 ? -40 : 0; x < 512; x += 80) {
        const v = 40 + rnd() * 40;
        g.fillStyle = `rgb(${v + 10},${v + 4},${v})`;
        g.fillRect(x + 3, y + 3, 74, 42);
      }
    }
  });
  const fireplace = new THREE.Mesh(new THREE.BoxGeometry(10, 46, 48), new THREE.MeshStandardMaterial({ map: stoneTex, roughness: 1 }));
  fireplace.position.set(85, 23, -40);
  scene.add(fireplace);
  const hearthGlow = new THREE.Mesh(new THREE.PlaneGeometry(26, 16), new THREE.MeshBasicMaterial({ color: '#ff8a3a', fog: false }));
  hearthGlow.position.set(79.8, 10, -40);
  hearthGlow.rotation.y = -Math.PI / 2;
  scene.add(hearthGlow);

  // Shelves with jars and offcuts on the left wall
  const shelfMat = new THREE.MeshStandardMaterial({ color: '#4a3020', roughness: 0.9 });
  for (let s = 0; s < 2; s++) {
    const shelf = new THREE.Mesh(new THREE.BoxGeometry(8, 1.2, 60), shelfMat);
    shelf.position.set(-85, 48 + s * 18, -40);
    shelf.castShadow = true;
    scene.add(shelf);
    for (let j = 0; j < 7; j++) {
      const hgt = 4 + rnd() * 6;
      const jar = new THREE.Mesh(
        j % 3 === 0 ? new THREE.CylinderGeometry(1.6, 1.6, hgt, 10) : new THREE.BoxGeometry(2.5 + rnd() * 2, hgt, 2.5 + rnd() * 2),
        new THREE.MeshStandardMaterial({ color: new THREE.Color().setHSL(0.07 + rnd() * 0.05, 0.35, 0.25 + rnd() * 0.25), roughness: 0.7 }),
      );
      jar.position.set(-84, 48.6 + s * 18 + hgt / 2, -66 + j * 8 + rnd() * 2);
      scene.add(jar);
    }
  }

  // Side table with a lantern
  const table = new THREE.Mesh(new THREE.BoxGeometry(16, 1.5, 16), shelfMat);
  table.position.set(-24, 26, -20);
  table.castShadow = table.receiveShadow = true;
  scene.add(table);
  for (const [dx, dz] of [[-6, -6], [6, -6], [-6, 6], [6, 6]]) {
    const leg = new THREE.Mesh(new THREE.BoxGeometry(1.4, 25, 1.4), shelfMat);
    leg.position.set(-24 + dx, 12.5, -20 + dz);
    scene.add(leg);
  }
  const lanternGlass = new THREE.Mesh(new THREE.CylinderGeometry(1.8, 1.8, 4.5, 12), new THREE.MeshBasicMaterial({ color: '#ffc77a' }));
  lanternGlass.position.set(-24, 29.5, -22);
  scene.add(lanternGlass);
  const lanternCap = new THREE.Mesh(new THREE.ConeGeometry(2.4, 2, 12), new THREE.MeshStandardMaterial({ color: '#2a2622', metalness: 0.6, roughness: 0.5 }));
  lanternCap.position.set(-24, 32.8, -22);
  scene.add(lanternCap);
  const lanternBase = new THREE.Mesh(new THREE.CylinderGeometry(2.3, 2.3, 0.8, 12), lanternCap.material);
  lanternBase.position.set(-24, 27, -22);
  scene.add(lanternBase);

  // The whittler's lap: a leather apron over the knees.
  const leatherTex = canvasTex(512, 512, (g) => {
    g.fillStyle = '#5a3a24';
    g.fillRect(0, 0, 512, 512);
    for (let i = 0; i < 3000; i++) {
      const v = rnd();
      g.fillStyle = `rgba(${v < 0.5 ? '20,10,5' : '140,95,60'},${0.08 + rnd() * 0.1})`;
      g.fillRect(rnd() * 512, rnd() * 512, 2 + rnd() * 4, 1 + rnd() * 3);
    }
    g.strokeStyle = 'rgba(30,18,10,0.6)';
    g.setLineDash([6, 6]);
    g.lineWidth = 3;
    g.strokeRect(14, 14, 484, 484);
  });
  const lap = new THREE.Mesh(
    new THREE.BoxGeometry(LAP.x1 - LAP.x0, 1, LAP.z1 - LAP.z0),
    new THREE.MeshStandardMaterial({ map: leatherTex, roughness: 0.8 }),
  );
  lap.position.set((LAP.x0 + LAP.x1) / 2, LAP.y - 0.5, (LAP.z0 + LAP.z1) / 2);
  lap.receiveShadow = true;
  scene.add(lap);
  const knees = new THREE.Mesh(
    new THREE.BoxGeometry(LAP.x1 - LAP.x0 - 1, 18, 4),
    new THREE.MeshStandardMaterial({ color: '#3b2a20', roughness: 1 }),
  );
  knees.position.set(0, LAP.y - 10, LAP.z0 + 1.5);
  scene.add(knees);

  // Lights
  scene.add(new THREE.HemisphereLight('#ffd9a8', '#1b120c', 0.35));

  const workLight = new THREE.SpotLight('#ffd6a0', 2.6, 0, 0.55, 0.7, 0);
  workLight.position.set(-16, 58, -4);
  workLight.target.position.set(0, 28, -15);
  workLight.castShadow = true;
  workLight.shadow.mapSize.set(2048, 2048);
  workLight.shadow.camera.near = 10;
  workLight.shadow.camera.far = 120;
  workLight.shadow.bias = -0.0004;
  workLight.shadow.normalBias = 0.02;
  workLight.shadow.radius = 4;
  scene.add(workLight, workLight.target);

  const lanternLight = new THREE.PointLight('#ffb067', 0.9, 70, 0);
  lanternLight.position.set(-24, 30, -22);
  scene.add(lanternLight);

  const fireLight = new THREE.PointLight('#ff7a30', 1.1, 160, 0);
  fireLight.position.set(74, 12, -40);
  scene.add(fireLight);

  const windowLight = new THREE.DirectionalLight('#8a8cc8', 0.18);
  windowLight.position.set(-22, 62, -90);
  scene.add(windowLight);

  return {
    scene,
    camera,
    workLight,
    update(t: number) {
      // Fire flicker: sum of incommensurate sines + a little jitter.
      const fl = 0.8 + 0.12 * Math.sin(t * 7.3) + 0.08 * Math.sin(t * 13.1 + 1.7) + 0.05 * Math.sin(t * 23.7);
      fireLight.intensity = 1.1 * fl;
      (hearthGlow.material as THREE.MeshBasicMaterial).color.setRGB(1, 0.45 + 0.1 * fl, 0.18);
      lanternLight.intensity = 0.9 + 0.04 * Math.sin(t * 5.1) + 0.03 * Math.sin(t * 11.3);
    },
  };
}
