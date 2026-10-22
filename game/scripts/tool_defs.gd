class_name ToolDefs
extends RefCounted
## The tool roll. Sizes are in inches.
## kind: blade (swept round-edged cutter), vee (V groove), saw (kerf), sand (smoothing).

const ALL := [
	{"id": "sloyd", "name": "Sloyd knife", "key": KEY_1, "kind": "blade", "radius": 0.55, "depth": 0.085, "curls": true,
		"help": "Your workhorse. Wide, shallow slices for roughing out shapes."},
	{"id": "detail", "name": "Detail knife", "key": KEY_2, "kind": "blade", "radius": 0.1, "depth": 0.05, "curls": true,
		"help": "Short, narrow blade for small features: eyes, fingers, crisp corners."},
	{"id": "hook", "name": "Hook knife", "key": KEY_3, "kind": "blade", "radius": 0.3, "depth": 0.12, "curls": true,
		"help": "Curved blade that scoops. Hollow out spoon bowls and cups."},
	{"id": "ugouge", "name": "U-gouge", "key": KEY_4, "kind": "blade", "radius": 0.16, "depth": 0.1, "curls": true,
		"help": "Rounded channel. Grooves, flutes, and clearing background."},
	{"id": "vgouge", "name": "V-gouge", "key": KEY_5, "kind": "vee", "radius": 0.0, "depth": 0.09, "curls": true,
		"help": "Cuts a crisp V line. Outlines, hair, feathers, lettering."},
	{"id": "saw", "name": "Pull saw", "key": KEY_6, "kind": "saw", "radius": 0.0, "depth": 0.0, "curls": false,
		"help": "Drag back and forth along your line. Saw through and the piece drops off."},
	{"id": "sand", "name": "Sandpaper", "key": KEY_7, "kind": "sand", "radius": 0.35, "depth": 0.0, "curls": false,
		"help": "Rub to soften ridges and blend facets into smooth curves."},
]

static func by_id(id: String) -> Dictionary:
	for t in ALL:
		if t.id == id:
			return t
	return ALL[0]
