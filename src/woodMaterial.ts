// Procedural wood shader. The colour is computed from the fragment's position in log-local
// inches, so any surface you carve reveals the correct interior: concentric growth rings on end
// grain, long stripes on side grain, heartwood/sapwood, fibre streaks, knots, and bark where the
// original outer shell still exists (passed in per vertex as `aBark`).

import * as THREE from 'three';
import type { Field } from './field';
import type { Species } from './species';

const GLSL_COMMON = /* glsl */ `
uniform vec3 uSap;
uniform vec3 uHeart;
uniform vec3 uBark;
uniform vec3 uBarkDark;
uniform float uLateMul;
uniform float uRings;
uniform float uHeartR;
uniform float uFigure;
uniform float uSeed;
uniform vec4 uKnots[4];
uniform int uKnotCount;
varying float vBark;
varying vec3 vWoodPos;

float wHash(vec3 p) {
  p = fract(p * 0.3183099 + vec3(0.11, 0.17, 0.13));
  p *= 17.0;
  return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}
float wNoise(vec3 x) {
  vec3 i = floor(x);
  vec3 f = fract(x);
  f = f * f * (3.0 - 2.0 * f);
  return mix(
    mix(mix(wHash(i), wHash(i + vec3(1,0,0)), f.x), mix(wHash(i + vec3(0,1,0)), wHash(i + vec3(1,1,0)), f.x), f.y),
    mix(mix(wHash(i + vec3(0,0,1)), wHash(i + vec3(1,0,1)), f.x), mix(wHash(i + vec3(0,1,1)), wHash(i + vec3(1,1,1)), f.x), f.y),
    f.z);
}

vec3 woodColor(vec3 p) {
  vec3 sp = p + vec3(uSeed);
  // Rings wander: low-frequency warp so they are not perfect circles.
  float warp = (wNoise(sp * vec3(0.55, 0.06, 0.55)) - 0.5) * 0.45
             + (wNoise(sp * vec3(2.2, 0.25, 2.2)) - 0.5) * 0.08;
  // Knots deflect the grain around them.
  float knotMask = 0.0;
  float knotRing = 0.0;
  for (int i = 0; i < 4; i++) {
    if (i >= uKnotCount) break;
    vec4 k = uKnots[i];
    vec3 d = normalize(vec3(cos(k.y), k.z, sin(k.y)));
    vec3 v = p - vec3(0.0, k.x, 0.0);
    float t = dot(v, d);
    if (t < 0.0) continue;
    float dist = length(v - d * t);
    float kr = 0.05 + t * 0.075;
    warp += 0.5 * kr * exp(-dist * dist / (kr * kr * 5.0));
    float body = 1.0 - smoothstep(kr * 0.85, kr * 1.1, dist);
    if (body > knotMask) {
      knotMask = body;
      knotRing = fract(dist * 18.0);
    }
  }
  float r = length(p.xz) + warp;
  float ring = fract(r * uRings);
  // Earlywood -> latewood darkens gradually, then snaps back at the next ring.
  float late = smoothstep(0.45, 0.93, ring) * (1.0 - smoothstep(0.93, 1.0, ring));
  float heart = uHeartR > 0.0 ? 1.0 - smoothstep(uHeartR - 0.1, uHeartR + 0.1, r) : 0.0;
  vec3 base = mix(uSap, uHeart, heart);
  vec3 col = mix(base, base * uLateMul, late);
  // Fibres run along the log axis (y): stretched noise.
  float fib = wNoise(vec3(p.x * 34.0, p.y * 1.1, p.z * 34.0));
  float fib2 = wNoise(vec3(p.x * 90.0, p.y * 3.0, p.z * 90.0));
  col *= 1.0 + uFigure * ((fib - 0.5) * 1.6 + (fib2 - 0.5) * 0.8);
  col *= 0.94 + 0.12 * wNoise(sp * 0.7);
  // Pith
  col *= 1.0 - 0.35 * (1.0 - smoothstep(0.03, 0.09, length(p.xz)));
  // Knots: dark, resinous, with their own tight rings.
  vec3 knotCol = uHeart * 0.42 * (0.8 + 0.25 * smoothstep(0.3, 0.9, knotRing));
  col = mix(col, knotCol, knotMask);
  return col;
}

vec3 barkColor(vec3 p) {
  // Bark fissures run along the trunk: high frequency around the circumference, low along y.
  vec2 dir = normalize(p.xz + vec2(1e-4));
  float a = wNoise(vec3(dir * 9.0, p.y * 0.35 + uSeed));
  float b = wNoise(vec3(dir * 21.0 + 5.0, p.y * 0.8));
  float ridge = abs(a * 2.0 - 1.0) * 0.65 + abs(b * 2.0 - 1.0) * 0.35;
  float fissure = smoothstep(0.04, 0.3, ridge);
  vec3 col = mix(uBarkDark, uBark, fissure);
  // Plates catch light on top; lichen-ish speckle.
  col *= 0.85 + 0.25 * smoothstep(0.45, 0.9, ridge);
  col *= 0.9 + 0.2 * wNoise(p * vec3(5.0, 1.5, 5.0));
  return col;
}
`;

export class WoodMaterial extends THREE.MeshStandardMaterial {
  readonly woodUniforms: Record<string, THREE.IUniform>;

  constructor(field: Field, species: Species) {
    super({ roughness: 0.68, metalness: 0, side: THREE.FrontSide });
    const knots: THREE.Vector4[] = [];
    for (let i = 0; i < 4; i++) {
      const k = field.knots[i];
      knots.push(k ? new THREE.Vector4(k.y, k.angle, k.rise, 1) : new THREE.Vector4());
    }
    this.woodUniforms = {
      uSap: { value: new THREE.Color(species.sap) },
      uHeart: { value: new THREE.Color(species.heart) },
      uBark: { value: new THREE.Color(species.bark) },
      uBarkDark: { value: new THREE.Color(species.barkDark) },
      uLateMul: { value: species.lateMul },
      uRings: { value: species.ringsPerInch },
      uHeartR: { value: species.heartFrac * field.size.radius },
      uFigure: { value: species.figure },
      uSeed: { value: (field.seed % 1000) * 0.137 },
      uKnots: { value: knots },
      uKnotCount: { value: field.knots.length },
    };

    this.onBeforeCompile = (shader) => {
      Object.assign(shader.uniforms, this.woodUniforms);
      shader.vertexShader = shader.vertexShader
        .replace('#include <common>', '#include <common>\nattribute float aBark;\nvarying float vBark;\nvarying vec3 vWoodPos;')
        .replace('#include <begin_vertex>', '#include <begin_vertex>\nvBark = aBark;\nvWoodPos = position;');
      shader.fragmentShader = shader.fragmentShader
        .replace('#include <common>', '#include <common>\n' + GLSL_COMMON)
        .replace(
          '#include <color_fragment>',
          '#include <color_fragment>\ndiffuseColor.rgb = mix(woodColor(vWoodPos), barkColor(vWoodPos), vBark);',
        )
        .replace(
          '#include <roughnessmap_fragment>',
          '#include <roughnessmap_fragment>\nroughnessFactor = mix(roughnessFactor, 0.97, vBark);',
        );
    };
    this.customProgramCacheKey = () => 'wood-v1';
  }
}

/** CPU approximation of the wood colour at a local point (for shavings and offcuts). */
export function woodColorAt(field: Field, lx: number, ly: number, lz: number, out: THREE.Color): THREE.Color {
  const sp = field.species;
  const bark = field.barkAmount(lx, ly, lz);
  const r = Math.hypot(lx, lz);
  const heartR = sp.heartFrac * field.size.radius;
  const heart = heartR > 0 ? (r < heartR ? 1 : 0) : 0;
  const base = new THREE.Color(sp.sap).lerp(new THREE.Color(sp.heart), heart);
  if (bark > 0.5) return out.set(sp.bark).lerp(new THREE.Color(sp.barkDark), 0.35);
  // Freshly cut shavings read slightly lighter than the cut face.
  return out.copy(base).multiplyScalar(1.04);
}
