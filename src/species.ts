// Wood species and log sizes. Colours are sRGB hex; three.js converts them to linear.

export interface Species {
  id: string;
  name: string;
  blurb: string;
  /** Removal multiplier: 1 = basswood. Harder woods remove less per stroke. */
  softness: number;
  sap: string;
  heart: string;
  /** Multiplier applied to the base colour inside latewood bands (lower = stronger rings). */
  lateMul: number;
  ringsPerInch: number;
  /** Fraction of the radius that is heartwood (0 = no visible heart/sap split). */
  heartFrac: number;
  bark: string;
  barkDark: string;
  barkInch: number;
  knots: number;
  /** Fibre streak strength. */
  figure: number;
}

export const SPECIES: Species[] = [
  {
    id: 'basswood', name: 'Basswood', blurb: 'Soft, pale, forgiving. The classic first carve.',
    softness: 1.0, sap: '#ead9b4', heart: '#e0caa0', lateMul: 0.88, ringsPerInch: 7, heartFrac: 0,
    bark: '#6a5a47', barkDark: '#3b3026', barkInch: 0.1, knots: 0, figure: 0.06,
  },
  {
    id: 'aspen', name: 'Aspen', blurb: 'Soft and creamy, with pale bark.',
    softness: 0.95, sap: '#efe5cc', heart: '#e2d4b4', lateMul: 0.94, ringsPerInch: 6, heartFrac: 0.3,
    bark: '#b8b2a2', barkDark: '#4a463e', barkInch: 0.08, knots: 1, figure: 0.05,
  },
  {
    id: 'butternut', name: 'Butternut', blurb: 'Soft, warm tan, lovely grain.',
    softness: 0.9, sap: '#d9c297', heart: '#b38a58', lateMul: 0.82, ringsPerInch: 5, heartFrac: 0.78,
    bark: '#6e5d4b', barkDark: '#33291f', barkInch: 0.14, knots: 1, figure: 0.1,
  },
  {
    id: 'pine', name: 'White Pine', blurb: 'Soft, golden, bold rings and knots.',
    softness: 0.85, sap: '#f0d9a2', heart: '#d6ad72', lateMul: 0.72, ringsPerInch: 6, heartFrac: 0.55,
    bark: '#5c3f2c', barkDark: '#2a1c14', barkInch: 0.16, knots: 3, figure: 0.08,
  },
  {
    id: 'cherry', name: 'Cherry', blurb: 'Medium-hard, rosy heartwood.',
    softness: 0.62, sap: '#e7cba6', heart: '#b4664a', lateMul: 0.84, ringsPerInch: 9, heartFrac: 0.72,
    bark: '#46302a', barkDark: '#1f1513', barkInch: 0.1, knots: 1, figure: 0.08,
  },
  {
    id: 'walnut', name: 'Black Walnut', blurb: 'Hard, deep chocolate brown.',
    softness: 0.5, sap: '#d9c6a2', heart: '#5b3b27', lateMul: 0.78, ringsPerInch: 7, heartFrac: 0.82,
    bark: '#332a23', barkDark: '#14100d', barkInch: 0.15, knots: 0, figure: 0.12,
  },
];

export interface LogSize {
  id: string;
  name: string;
  radius: number; // inches
  length: number; // inches
}

export const SIZES: LogSize[] = [
  { id: 'small', name: 'Small · 4×8″', radius: 2, length: 8 },
  { id: 'medium', name: 'Medium · 6×12″', radius: 3, length: 12 },
  { id: 'thick', name: 'Thick · 8×10″', radius: 4, length: 10 },
];

export const speciesById = (id: string) => SPECIES.find((s) => s.id === id) ?? SPECIES[0];
export const sizeById = (id: string) => SIZES.find((s) => s.id === id) ?? SIZES[1];
