// Save / restore the carving in localStorage. The SDF is quantised to int8 (1/32 voxel steps)
// and run-length encoded; the interior and exterior are long constant runs, so a carved log
// usually compresses to well under a megabyte.

import { CLAMP } from './field';

const KEY = 'whittle.save.v1';
const SCALE = 127 / CLAMP;

export interface SaveMeta {
  species: string;
  size: string;
  vpi: number;
  seed: number;
  gripTop: boolean;
  quat: [number, number, number, number];
  zoom: number;
}

function encode(data: Float32Array): string {
  const out: number[] = [];
  let i = 0;
  while (i < data.length) {
    const v = Math.max(-127, Math.min(127, Math.round(data[i] * SCALE)));
    let run = 1;
    while (i + run < data.length && run < 255 && Math.max(-127, Math.min(127, Math.round(data[i + run] * SCALE))) === v) run++;
    out.push(v & 0xff, run);
    i += run;
  }
  const bytes = Uint8Array.from(out);
  let s = '';
  for (let k = 0; k < bytes.length; k += 0x8000) s += String.fromCharCode(...bytes.subarray(k, k + 0x8000));
  return btoa(s);
}

function decode(b64: string, into: Float32Array): boolean {
  const s = atob(b64);
  let o = 0;
  for (let k = 0; k + 1 < s.length; k += 2) {
    let v = s.charCodeAt(k);
    if (v > 127) v -= 256;
    const run = s.charCodeAt(k + 1);
    const f = v / SCALE;
    for (let r = 0; r < run && o < into.length; r++) into[o++] = f;
  }
  return o === into.length;
}

export function hasSave(): SaveMeta | null {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return null;
    return (JSON.parse(raw) as { meta: SaveMeta }).meta;
  } catch {
    return null;
  }
}

export function save(meta: SaveMeta, data: Float32Array): boolean {
  try {
    localStorage.setItem(KEY, JSON.stringify({ meta, field: encode(data) }));
    return true;
  } catch {
    return false;
  }
}

export function loadInto(data: Float32Array): boolean {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return false;
    return decode((JSON.parse(raw) as { field: string }).field, data);
  } catch {
    return false;
  }
}

export function clearSave() {
  try { localStorage.removeItem(KEY); } catch { /* storage unavailable */ }
}

const PREFS = 'whittle.prefs.v1';
export interface Prefs { muted: boolean; voxel: boolean; quality: 'standard' | 'high' }

export function loadPrefs(): Prefs {
  const d: Prefs = { muted: false, voxel: false, quality: 'standard' };
  try { return { ...d, ...JSON.parse(localStorage.getItem(PREFS) || '{}') }; } catch { return d; }
}

export function savePrefs(p: Prefs) {
  try { localStorage.setItem(PREFS, JSON.stringify(p)); } catch { /* storage unavailable */ }
}
