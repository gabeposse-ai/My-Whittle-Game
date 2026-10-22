class_name Species
extends RefCounted
## Wood species and log sizes. Colours are sRGB.

const ALL := [
	{
		"id": "basswood", "name": "Basswood", "blurb": "Soft, pale, forgiving. The classic first carve.",
		"softness": 1.0, "sap": Color("#ead9b4"), "heart": Color("#e0caa0"), "late_mul": 0.88, "rings": 7.0, "heart_frac": 0.0,
		"bark": Color("#6a5a47"), "bark_dark": Color("#3b3026"), "bark_inch": 0.1, "knots": 0, "figure": 0.06,
	},
	{
		"id": "aspen", "name": "Aspen", "blurb": "Soft and creamy, with pale bark.",
		"softness": 0.95, "sap": Color("#efe5cc"), "heart": Color("#e2d4b4"), "late_mul": 0.94, "rings": 6.0, "heart_frac": 0.3,
		"bark": Color("#b8b2a2"), "bark_dark": Color("#4a463e"), "bark_inch": 0.08, "knots": 1, "figure": 0.05,
	},
	{
		"id": "butternut", "name": "Butternut", "blurb": "Soft, warm tan, lovely grain.",
		"softness": 0.9, "sap": Color("#d9c297"), "heart": Color("#b38a58"), "late_mul": 0.82, "rings": 5.0, "heart_frac": 0.78,
		"bark": Color("#6e5d4b"), "bark_dark": Color("#33291f"), "bark_inch": 0.14, "knots": 1, "figure": 0.1,
	},
	{
		"id": "pine", "name": "White Pine", "blurb": "Soft, golden, bold rings and knots.",
		"softness": 0.85, "sap": Color("#f0d9a2"), "heart": Color("#d6ad72"), "late_mul": 0.72, "rings": 6.0, "heart_frac": 0.55,
		"bark": Color("#5c3f2c"), "bark_dark": Color("#2a1c14"), "bark_inch": 0.16, "knots": 3, "figure": 0.08,
	},
	{
		"id": "cherry", "name": "Cherry", "blurb": "Medium-hard, rosy heartwood.",
		"softness": 0.62, "sap": Color("#e7cba6"), "heart": Color("#b4664a"), "late_mul": 0.84, "rings": 9.0, "heart_frac": 0.72,
		"bark": Color("#46302a"), "bark_dark": Color("#1f1513"), "bark_inch": 0.1, "knots": 1, "figure": 0.08,
	},
	{
		"id": "walnut", "name": "Black Walnut", "blurb": "Hard, deep chocolate brown.",
		"softness": 0.5, "sap": Color("#d9c6a2"), "heart": Color("#5b3b27"), "late_mul": 0.78, "rings": 7.0, "heart_frac": 0.82,
		"bark": Color("#332a23"), "bark_dark": Color("#14100d"), "bark_inch": 0.15, "knots": 0, "figure": 0.12,
	},
]

const SIZES := [
	{"id": "small", "name": "Small  4 × 8 in", "radius": 2.0, "length": 8.0},
	{"id": "medium", "name": "Medium  6 × 12 in", "radius": 3.0, "length": 12.0},
	{"id": "thick", "name": "Thick  8 × 10 in", "radius": 4.0, "length": 10.0},
]

static func by_id(id: String) -> Dictionary:
	for s in ALL:
		if s.id == id:
			return s
	return ALL[0]

static func size_by_id(id: String) -> Dictionary:
	for s in SIZES:
		if s.id == id:
			return s
	return SIZES[1]
