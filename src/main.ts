// Whittle — entry point and glue: renderer, input, stroke routing, autosave.

import * as THREE from 'three';
import { Sfx } from './audio';
import { Carver, type CutEvent, type Island, type V3 } from './carver';
import { CLAMP, Field } from './field';
import { Hands } from './hands';
import { buildGeometry, LogMesh } from './logMesh';
import { meshSurfaceNets } from './mesher';
import { clearSave, hasSave, loadInto, loadPrefs, save, savePrefs, type SaveMeta } from './persist';
import { buildWorkshop } from './scene';
import { Shavings } from './shavings';
import { sizeById, speciesById } from './species';
import { toolById, TOOLS, type Tool, type ToolId } from './tools';
import { Ui } from './ui';
import { WoodMaterial, woodColorAt } from './woodMaterial';

// ------------------------------------------------------------------ renderer & world

const renderer = new THREE.WebGLRenderer({ antialias: true, powerPreference: 'high-performance', preserveDrawingBuffer: false });
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.1;
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFShadowMap;
document.getElementById('app')!.append(renderer.domElement);

const { scene, camera, update: updateWorkshop } = buildWorkshop(renderer);
const LOOK_TARGET = new THREE.Vector3(0, 30.5, -15);
const viewDir = LOOK_TARGET.clone().sub(camera.position).normalize();
const DEFAULT_ZOOM = LOOK_TARGET.distanceTo(camera.position);

const shavings = new Shavings();
scene.add(shavings.group);
const hands = new Hands();
scene.add(hands.carving);
const sfx = new Sfx();
const prefs = loadPrefs();
sfx.setMuted(prefs.muted);

const logGroup = new THREE.Group();
logGroup.add(hands.holding);
scene.add(logGroup);

interface Session {
  field: Field;
  carver: Carver;
  mesh: LogMesh;
  material: WoodMaterial;
  speciesId: string;
  sizeId: string;
  gripTop: boolean;
  zoom: number;
}
let S: Session | null = null;
let currentTool: Tool = TOOLS[0];

function placeLog() {
  if (!S) return;
  // Portrait screens are narrow: bring the log a little closer so it fills the view.
  logGroup.position.copy(camera.position).addScaledVector(viewDir, S.zoom * (camera.aspect < 0.8 ? 0.84 : 1));
}

function resize() {
  const w = window.innerWidth, h = window.innerHeight;
  renderer.setSize(w, h);
  camera.aspect = w / h;
  // Keep at least ~44° horizontal field of view in portrait.
  const hfov = THREE.MathUtils.degToRad(44);
  const vfovFromH = THREE.MathUtils.radToDeg(2 * Math.atan(Math.tan(hfov / 2) / camera.aspect));
  camera.fov = Math.max(50, Math.min(80, vfovFromH));
  camera.updateProjectionMatrix();
  camera.updateMatrixWorld();
  hands.setRest(camera);
  placeLog();
}
window.addEventListener('resize', resize);
resize();

// ------------------------------------------------------------------ sessions

function disposeSession() {
  if (!S) return;
  logGroup.remove(S.mesh.group);
  S.mesh.dispose();
  S.material.dispose();
  shavings.clear();
  S = null;
}

function startSession(speciesId: string, sizeId: string, restore: SaveMeta | null) {
  disposeSession();
  const species = speciesById(speciesId);
  const size = sizeById(sizeId);
  const vpi = restore ? restore.vpi : prefs.quality === 'high' ? 12 : 9;
  const seed = restore ? restore.seed : (Math.random() * 1e9) | 0;
  const field = new Field(size, species, vpi, seed);
  let restored = false;
  if (restore) restored = loadInto(field.data);
  if (!restored) field.initLog();
  const material = new WoodMaterial(field, species);
  const mesh = new LogMesh(field, material, prefs.voxel ? 'voxel' : 'smooth');
  const carver = new Carver(field);
  carver.onChange = (x0, y0, z0, x1, y1, z1) => mesh.markBox(x0, y0, z0, x1, y1, z1);
  mesh.update();
  logGroup.add(mesh.group);
  const gripTop = restored && restore ? restore.gripTop : false;
  S = { field, carver, mesh, material, speciesId, sizeId, gripTop, zoom: restored && restore ? restore.zoom : DEFAULT_ZOOM };
  hands.buildHolding(size.radius, size.length, gripTop);
  if (restored && restore) {
    logGroup.quaternion.fromArray(restore.quat);
  } else {
    logGroup.quaternion.setFromEuler(new THREE.Euler(0.28, 0.4, 0.12));
  }
  // Fit thick/long logs a little further away.
  if (!restored) S.zoom = DEFAULT_ZOOM + 2 + (size.length - 12) * 0.4 + (size.radius - 3) * 1.2;
  placeLog();
  ui.setUndo(false);
}

let saveTimer = 0;
function scheduleSave() {
  window.clearTimeout(saveTimer);
  saveTimer = window.setTimeout(() => {
    if (!S) return;
    const q = logGroup.quaternion;
    save({
      species: S.speciesId, size: S.sizeId, vpi: S.field.vpi, seed: S.field.seed,
      gripTop: S.gripTop, quat: [q.x, q.y, q.z, q.w], zoom: S.zoom,
    }, S.field.data);
  }, 900);
}

// ------------------------------------------------------------------ UI

const ui = new Ui({
  begin(speciesId, sizeId) {
    sfx.start();
    ui.setLoading(true);
    // Let the loading screen paint before the (synchronous) initial mesh build.
    requestAnimationFrame(() => setTimeout(() => {
      clearSave();
      startSession(speciesId, sizeId, null);
      ui.setLoading(false);
      ui.hideStart();
      scheduleSave();
    }, 20));
  },
  resume() {
    sfx.start();
    const meta = hasSave();
    if (!meta) return;
    ui.setLoading(true);
    requestAnimationFrame(() => setTimeout(() => {
      startSession(meta.species, meta.size, meta);
      ui.setLoading(false);
      ui.hideStart();
    }, 20));
  },
  tool: (id) => selectTool(id),
  undo,
  flip,
  mute(m) { sfx.setMuted(m); savePrefs(prefs); },
  setVoxel(v) { S?.mesh.setMode(v ? 'voxel' : 'smooth'); savePrefs(prefs); },
  setQuality() { savePrefs(prefs); },
  newLog() {
    if (S) scheduleSaveNow();
    ui.showStart(hasSave());
  },
}, prefs);

function scheduleSaveNow() {
  window.clearTimeout(saveTimer);
  if (!S) return;
  const q = logGroup.quaternion;
  save({ species: S.speciesId, size: S.sizeId, vpi: S.field.vpi, seed: S.field.seed, gripTop: S.gripTop, quat: [q.x, q.y, q.z, q.w], zoom: S.zoom }, S.field.data);
}

function selectTool(id: ToolId) {
  if (S?.carver.active) endStroke();
  currentTool = toolById(id);
  hands.setTool(id);
  ui.setTool(id);
}
selectTool('sloyd');

function undo() {
  if (!S || S.carver.active) return;
  const e = S.carver.undo();
  if (e) shavings.removeStroke(e.strokeId);
  ui.setUndo(S.carver.canUndo);
  scheduleSave();
}

function flip() {
  if (!S || S.carver.active) return;
  S.gripTop = !S.gripTop;
  hands.buildHolding(S.field.size.radius, S.field.size.length, S.gripTop);
  // Turn the log end over end so the held end comes to the bottom.
  const right = new THREE.Vector3(1, 0, 0).applyQuaternion(camera.quaternion);
  logGroup.quaternion.premultiply(new THREE.Quaternion().setFromAxisAngle(right, Math.PI));
  scheduleSave();
}

// ------------------------------------------------------------------ geometry helpers

const tmpL: V3 = [0, 0, 0];
const tmpG: V3 = [0, 0, 0];
const invQ = new THREE.Quaternion();
const raycaster = new THREE.Raycaster();
const ndc = new THREE.Vector2();

/** Pointer → ray in grid space. */
function gridRay(px: number, py: number): { o: V3; d: V3 } | null {
  if (!S) return null;
  ndc.set((px / window.innerWidth) * 2 - 1, -(py / window.innerHeight) * 2 + 1);
  raycaster.setFromCamera(ndc, camera);
  logGroup.updateMatrixWorld();
  const o = logGroup.worldToLocal(raycaster.ray.origin.clone());
  invQ.copy(logGroup.quaternion).invert();
  const d = raycaster.ray.direction.clone().applyQuaternion(invQ);
  S.field.localToGrid(o.x, o.y, o.z, tmpG);
  return { o: [tmpG[0], tmpG[1], tmpG[2]], d: [d.x, d.y, d.z] };
}

function gridToWorld(g: V3, out: THREE.Vector3) {
  S!.field.gridToLocal(g[0], g[1], g[2], tmpL);
  return logGroup.localToWorld(out.set(tmpL[0], tmpL[1], tmpL[2]));
}

function dirToWorld(v: V3, out: THREE.Vector3) {
  return out.set(v[0], v[1], v[2]).applyQuaternion(logGroup.quaternion);
}

/** Screen-space drag (px) → grid-space direction and its length in inches, at the log's depth. */
function dragToGrid(dx: number, dy: number): { dir: V3; inches: number } {
  const dist = camera.position.distanceTo(logGroup.position);
  const inchPerPx = (2 * dist * Math.tan(THREE.MathUtils.degToRad(camera.fov) / 2)) / window.innerHeight;
  const right = new THREE.Vector3(1, 0, 0).applyQuaternion(camera.quaternion);
  const up = new THREE.Vector3(0, 1, 0).applyQuaternion(camera.quaternion);
  const w = right.multiplyScalar(dx * inchPerPx).addScaledVector(up, -dy * inchPerPx);
  const inches = w.length();
  w.applyQuaternion(invQ.copy(logGroup.quaternion).invert());
  return { dir: [w.x, w.y, w.z], inches };
}

// ------------------------------------------------------------------ strokes

const vA = new THREE.Vector3(), vB = new THREE.Vector3(), vC = new THREE.Vector3();
const col = new THREE.Color();
let strokeTime = 0;

const stats: Record<string, number> = {};
function handleEvents(events: CutEvent[], dt: number) {
  if (!S) return;
  for (const ev of events) stats[ev.kind + ':' + ev.feel] = (stats[ev.kind + ':' + ev.feel] ?? 0) + 1;
  const f = S.field;
  const sid = S.carver.strokeId;
  for (const ev of events) {
    const P = gridToWorld(ev.p, vA);
    const T = dirToWorld(ev.t, vB).normalize();
    const N = dirToWorld(ev.n, vC).normalize();
    f.gridToLocal(ev.p[0], ev.p[1], ev.p[2], tmpL);
    // Sample colour a hair inside the surface, which is what just came off.
    woodColorAt(f, tmpL[0] - ev.n[0] * 0.03, tmpL[1] - ev.n[1] * 0.03, tmpL[2] - ev.n[2] * 0.03, col);
    const volIn3 = ev.volume / (f.vpi * f.vpi * f.vpi);
    if (ev.kind === 'curl') {
      shavings.growCurl(sid, P, T, N, ev.width, ev.depth, ev.segLen, col);
    } else if (ev.kind === 'chip') {
      shavings.releaseCurl();
      const count = Math.max(1, Math.min(6, Math.round(volIn3 / 0.0015)));
      const size = Math.min(0.16, Math.max(0.035, Math.cbrt(volIn3 / count) * 1.4));
      shavings.spawnChips(sid, P, N, count, size, col);
    } else {
      const count = Math.max(1, Math.min(4, Math.round(volIn3 / 0.0004)));
      shavings.spawnChips(sid, P, N, count, 0.025 + Math.random() * 0.02, col.multiplyScalar(1.08), true);
    }
    const speed = ev.feel === 'saw' ? ev.segLen / Math.max(dt, 1 / 120) : ev.segLen / Math.max(dt, 1 / 120);
    sfx.cut(ev.feel, speed, volIn3 * 400, f.species.softness);
    ui.feel(ev.feel);
    if (ev.feel !== 'saw') hands.engage(P, N, camera);
  }
}

function beginStroke(px: number, py: number): boolean {
  if (!S) return false;
  const r = gridRay(px, py);
  if (!r) return false;
  const hit = S.carver.raycast(r.o, r.d, false);
  if (!hit) return false;
  S.carver.begin(currentTool, hit);
  strokeTime = performance.now();
  hands.engage(gridToWorld(hit.g, vA), dirToWorld(hit.n, vC).normalize(), camera);
  return true;
}

function moveStroke(px: number, py: number, dx: number, dy: number) {
  if (!S || !S.carver.active) return;
  const now = performance.now();
  const dt = (now - strokeTime) / 1000;
  strokeTime = now;
  const r = gridRay(px, py);
  if (!r) return;
  const drag = dragToGrid(dx, dy);
  const evs = S.carver.move(r.o, r.d, drag.dir, drag.inches);
  handleEvents(evs, dt);
  if (evs.length) lastCutFrame = frame;
}

function endStroke() {
  if (!S || !S.carver.active) return;
  const sid = S.carver.strokeId;
  const { entry, islands } = S.carver.end();
  shavings.releaseCurl();
  hands.release();
  sfx.stopCut();
  for (const isl of islands) dropPiece(isl, sid);
  ui.setUndo(S.carver.canUndo);
  if (entry) scheduleSave();
}

function dropPiece(isl: Island, sid: number) {
  if (!S) return;
  const f = S.field;
  const toLocal = (gx: number, gy: number, gz: number, out: [number, number, number]) => f.gridToLocal(gx + isl.ox, gy + isl.oy, gz + isl.oz, out);
  const data = meshSurfaceNets(isl, 0, 0, 0, isl.nx, isl.ny, isl.nz, toLocal, (x, y, z) => f.barkAmount(x, y, z));
  if (!data) return;
  const geo = buildGeometry(data);
  const c = geo.boundingSphere!.center.clone();
  geo.translate(-c.x, -c.y, -c.z);
  geo.computeBoundingSphere();
  const m = new THREE.Mesh(geo, S.material);
  m.castShadow = m.receiveShadow = true;
  logGroup.updateMatrixWorld();
  m.position.copy(logGroup.localToWorld(c));
  m.quaternion.copy(logGroup.quaternion);
  shavings.addPiece(m, sid, geo.boundingSphere!.radius);
  if (isl.cells > 30) setTimeout(() => sfx.thud(), 260);
}

// ------------------------------------------------------------------ input

const canvas = renderer.domElement;
type Mode = 'none' | 'carve' | 'orbit' | 'pinch';
let mode: Mode = 'none';
const pointers = new Map<number, { x: number; y: number }>();
let carvePointer = -1;
let pinchDist = 0;
let pinchCx = 0, pinchCy = 0;
let frame = 0;
let lastCutFrame = 0;

function rotateLog(dx: number, dy: number) {
  const up = new THREE.Vector3(0, 1, 0);
  const right = new THREE.Vector3(1, 0, 0).applyQuaternion(camera.quaternion);
  const q = new THREE.Quaternion().setFromAxisAngle(up, dx * 0.009);
  q.multiply(new THREE.Quaternion().setFromAxisAngle(right, dy * 0.009));
  logGroup.quaternion.premultiply(q);
}

function zoomBy(factor: number) {
  if (!S) return;
  S.zoom = THREE.MathUtils.clamp(S.zoom * factor, 9, 34);
  placeLog();
}

canvas.addEventListener('contextmenu', (e) => e.preventDefault());

canvas.addEventListener('pointerdown', (e) => {
  sfx.start();
  canvas.setPointerCapture(e.pointerId);
  pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
  if (!S) return;
  if (pointers.size === 1) {
    const wantsOrbit = e.button === 2 || e.button === 1 || e.shiftKey || e.altKey;
    if (!wantsOrbit && beginStroke(e.clientX, e.clientY)) {
      mode = 'carve';
      carvePointer = e.pointerId;
    } else {
      mode = 'orbit';
    }
  } else if (pointers.size === 2) {
    if (mode === 'carve') endStroke();
    mode = 'pinch';
    const [a, b] = [...pointers.values()];
    pinchDist = Math.hypot(a.x - b.x, a.y - b.y);
    pinchCx = (a.x + b.x) / 2;
    pinchCy = (a.y + b.y) / 2;
  }
});

canvas.addEventListener('pointermove', (e) => {
  const p = pointers.get(e.pointerId);
  if (!p) return;
  const dx = e.clientX - p.x, dy = e.clientY - p.y;
  p.x = e.clientX;
  p.y = e.clientY;
  if (mode === 'carve' && e.pointerId === carvePointer) {
    // Use coalesced events for smooth, accurate strokes on high-rate input.
    const list = typeof e.getCoalescedEvents === 'function' ? e.getCoalescedEvents() : [];
    if (list.length > 1) {
      let lx = p.x - dx, ly = p.y - dy;
      for (const ce of list) {
        moveStroke(ce.clientX, ce.clientY, ce.clientX - lx, ce.clientY - ly);
        lx = ce.clientX; ly = ce.clientY;
      }
    } else {
      moveStroke(e.clientX, e.clientY, dx, dy);
    }
  } else if (mode === 'orbit') {
    rotateLog(dx, dy);
  } else if (mode === 'pinch' && pointers.size >= 2) {
    const [a, b] = [...pointers.values()];
    const d = Math.hypot(a.x - b.x, a.y - b.y);
    const cx = (a.x + b.x) / 2, cy = (a.y + b.y) / 2;
    if (pinchDist > 0) zoomBy(pinchDist / d);
    rotateLog(cx - pinchCx, cy - pinchCy);
    pinchDist = d;
    pinchCx = cx;
    pinchCy = cy;
  }
});

function pointerEnd(e: PointerEvent) {
  pointers.delete(e.pointerId);
  if (mode === 'carve' && e.pointerId === carvePointer) {
    endStroke();
    carvePointer = -1;
  }
  if (pointers.size === 0) {
    mode = 'none';
    scheduleSaveIfMoved();
  } else if (pointers.size === 1 && mode === 'pinch') {
    mode = 'orbit';
  }
}
canvas.addEventListener('pointerup', pointerEnd);
canvas.addEventListener('pointercancel', pointerEnd);

function scheduleSaveIfMoved() { if (S) scheduleSave(); }

canvas.addEventListener('wheel', (e) => {
  e.preventDefault();
  zoomBy(Math.exp(e.deltaY * 0.0012));
}, { passive: false });

window.addEventListener('keydown', (e) => {
  if (!S) return;
  const t = TOOLS.find((x) => x.key === e.key);
  if (t) selectTool(t.id);
  else if (e.key === 'z' || e.key === 'Z') undo();
  else if (e.key === 'f' || e.key === 'F') flip();
  else if (e.key === 'h' || e.key === 'H') ui.toggleHidden();
});

// Prevent iOS page gestures.
document.addEventListener('gesturestart', (e) => e.preventDefault());
document.addEventListener('touchmove', (e) => { if (e.target === canvas) e.preventDefault(); }, { passive: false });

// ------------------------------------------------------------------ loop

const clock = new THREE.Timer();
let elapsed = 0;
function tick() {
  clock.update();
  const dt = Math.min(clock.getDelta(), 0.05);
  elapsed += dt;
  frame++;
  updateWorkshop(elapsed);
  if (S) S.mesh.update(S.carver.active ? 48 : 96);
  if (S?.carver.active && frame - lastCutFrame > 3) sfx.stopCut();
  shavings.update(dt);
  hands.update(dt);
  renderer.render(scene, camera);
  requestAnimationFrame(tick);
}

// Idle log behind the start screen so the workshop isn't empty.
startSession('basswood', 'medium', null);
ui.showStart(hasSave());
requestAnimationFrame(tick);

// Expose a tiny debug/test hook.
(window as unknown as Record<string, unknown>).__whittle = {
  get session() { return S; },
  CLAMP,
  camera,
  logGroup,
  beginStroke, moveStroke, endStroke, selectTool, undo, stats, shavings,
};
