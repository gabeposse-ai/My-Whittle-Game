// The tool roll. Sizes are in inches; the carver converts them to voxels.

export type ToolId = 'sloyd' | 'detail' | 'hook' | 'ugouge' | 'vgouge' | 'saw' | 'sand';
export type ToolKind = 'blade' | 'vee' | 'saw' | 'sand';

export interface Tool {
  id: ToolId;
  name: string;
  key: string;
  kind: ToolKind;
  /** Cutter radius (blade = curvature of the swept edge; larger = wider, flatter cut). */
  radius: number;
  /** Nominal depth of cut per stroke, before wood hardness and grain are applied. */
  depth: number;
  /** Whether this tool lifts continuous curls when cutting cleanly with the grain. */
  curls: boolean;
  help: string;
}

export const TOOLS: Tool[] = [
  {
    id: 'sloyd', name: 'Sloyd knife', key: '1', kind: 'blade', radius: 0.55, depth: 0.085, curls: true,
    help: 'Your workhorse. Wide, shallow slices for roughing out shapes and smoothing planes.',
  },
  {
    id: 'detail', name: 'Detail knife', key: '2', kind: 'blade', radius: 0.1, depth: 0.05, curls: true,
    help: 'Short, narrow blade for small features: eyes, fingers, crisp corners.',
  },
  {
    id: 'hook', name: 'Hook knife', key: '3', kind: 'blade', radius: 0.3, depth: 0.12, curls: true,
    help: 'Curved blade that scoops. Hollow out spoon bowls and cups.',
  },
  {
    id: 'ugouge', name: 'U-gouge', key: '4', kind: 'blade', radius: 0.16, depth: 0.1, curls: true,
    help: 'Rounded channel. Grooves, flutes, and clearing background.',
  },
  {
    id: 'vgouge', name: 'V-gouge', key: '5', kind: 'vee', radius: 0, depth: 0.09, curls: true,
    help: 'Cuts a crisp V line. Outlines, hair, feathers, lettering.',
  },
  {
    id: 'saw', name: 'Pull saw', key: '6', kind: 'saw', radius: 0, depth: 0, curls: false,
    help: 'Drag back and forth along the line you want to cut. Saw through to drop a piece off.',
  },
  {
    id: 'sand', name: 'Sandpaper', key: '7', kind: 'sand', radius: 0.35, depth: 0, curls: false,
    help: 'Rub to soften ridges and blend facets into smooth curves.',
  },
];

export const toolById = (id: ToolId) => TOOLS.find((t) => t.id === id)!;
