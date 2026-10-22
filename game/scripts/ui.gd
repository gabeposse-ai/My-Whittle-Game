class_name GameUI
extends CanvasLayer
## Start screen, tool bar, top buttons, grain hint and help. Built in code with a warm theme.

signal begin(species_id: String, size_id: String)
signal tool_selected(id: String)
signal undo_pressed
signal flip_pressed
signal new_log_pressed
signal mute_toggled(muted: bool)

const INK := Color("#f3e6d2")
const INK_DIM := Color("#c9b49a")
const INK_FAINT := Color("#8f7a63")
const ACCENT := Color("#e2a35f")
const PANEL := Color(0.11, 0.075, 0.05, 0.86)

const FEEL := {
	"with": ["With the grain · clean curls", Color("#9bd27a")],
	"across": ["Across the grain · short flakes", Color("#e6c45c")],
	"against": ["Against the grain · tear-out", Color("#e2775c")],
	"end": ["End grain · slow and tough", Color("#d9a35c")],
	"saw": ["Sawing", INK_DIM],
	"sand": ["Sanding", INK_DIM],
}

var root := Control.new()
var hud := Control.new()
var start := Control.new()
var help := PanelContainer.new()
var hint := Label.new()
var _hint_t := 0.0
var _tool_buttons := {}
var _undo_btn: Button
var _mute_btn: Button
var _muted := false
var _sel_species := "basswood"
var _sel_size := "medium"
var serif := SystemFont.new()
var sans := SystemFont.new()


func _ready() -> void:
	serif.font_names = PackedStringArray(["Georgia", "Palatino Linotype", "Book Antiqua", "DejaVu Serif", "serif"])
	sans.font_names = PackedStringArray(["Segoe UI", "Inter", "Helvetica", "DejaVu Sans", "sans-serif"])
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = _theme()
	add_child(root)
	hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(hud)
	_build_hud()
	_build_start()
	_build_help()


func _box(c: Color, radius := 14, pad := 10) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = c
	s.set_corner_radius_all(radius)
	s.set_content_margin_all(pad)
	s.border_color = Color(1, 0.9, 0.75, 0.12)
	s.set_border_width_all(1)
	return s


func _theme() -> Theme:
	var t := Theme.new()
	t.default_font = sans
	t.default_font_size = 17
	t.set_color("font_color", "Label", INK)
	t.set_color("font_color", "Button", INK_DIM)
	t.set_color("font_hover_color", "Button", INK)
	t.set_color("font_pressed_color", "Button", INK)
	t.set_color("font_focus_color", "Button", INK)
	t.set_stylebox("normal", "Button", _box(Color(0.16, 0.11, 0.08, 0.85), 12, 10))
	t.set_stylebox("hover", "Button", _box(Color(0.24, 0.17, 0.11, 0.92), 12, 10))
	t.set_stylebox("pressed", "Button", _box(Color(0.89, 0.64, 0.37, 0.22), 12, 10))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	var on := _box(Color(0.89, 0.64, 0.37, 0.2), 12, 10)
	on.border_color = ACCENT
	t.set_stylebox("hover_pressed", "Button", on)
	t.set_stylebox("panel", "PanelContainer", _box(PANEL, 18, 18))
	return t


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	b.focus_mode = Control.FOCUS_NONE
	return b


func _build_hud() -> void:
	var tl := HBoxContainer.new()
	tl.position = Vector2(18, 18)
	tl.add_theme_constant_override("separation", 8)
	tl.add_child(_button("New log", func(): new_log_pressed.emit()))
	_undo_btn = _button("Undo  (Z)", func(): undo_pressed.emit())
	_undo_btn.disabled = true
	tl.add_child(_undo_btn)
	tl.add_child(_button("Switch grip  (F)", func(): flip_pressed.emit()))
	hud.add_child(tl)

	var tr := HBoxContainer.new()
	tr.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	tr.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	tr.position = Vector2(-18, 18)
	tr.add_theme_constant_override("separation", 8)
	_mute_btn = _button("Sound on", func():
		_muted = not _muted
		_mute_btn.text = "Sound off" if _muted else "Sound on"
		mute_toggled.emit(_muted))
	tr.add_child(_mute_btn)
	tr.add_child(_button("How to whittle", func(): help.visible = not help.visible))
	hud.add_child(tr)

	var strip := CenterContainer.new()
	strip.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	strip.offset_top = -104
	strip.offset_bottom = -20
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(strip)
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", _box(Color(0.2, 0.14, 0.09, 0.9), 20, 8))
	strip.add_child(bar)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	bar.add_child(row)
	for t in ToolDefs.ALL:
		var b := Button.new()
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(118, 64)
		b.text = "%s\n%d" % [t.name, ToolDefs.ALL.find(t) + 1]
		b.tooltip_text = t.help
		b.add_theme_font_size_override("font_size", 15)
		var id: String = t.id
		b.pressed.connect(func(): tool_selected.emit(id))
		_tool_buttons[id] = b
		row.add_child(b)

	hint.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	hint.offset_top = -150
	hint.offset_bottom = -116
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 18)
	hint.modulate.a = 0.0
	hud.add_child(hint)


func _build_start() -> void:
	start.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(start)
	var shade := ColorRect.new()
	shade.color = Color(0.07, 0.047, 0.031, 0.82)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	start.add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	start.add_child(center)
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(760, 0)
	col.add_theme_constant_override("separation", 14)
	center.add_child(col)
	var title := Label.new()
	title.text = "Whittle"
	title.add_theme_font_override("font", serif)
	title.add_theme_font_size_override("font_size", 84)
	col.add_child(title)
	var tag := Label.new()
	tag.text = "Pull up a stool. Pick a log. Take your time."
	tag.add_theme_color_override("font_color", INK_DIM)
	col.add_child(tag)
	col.add_child(_section("WOOD"))
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	var wood_btns: Array[Button] = []
	for s in Species.ALL:
		var b := Button.new()
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(246, 74)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text = "%s\n%s" % [s.name, s.blurb]
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		b.add_theme_font_size_override("font_size", 14)
		b.button_pressed = s.id == _sel_species
		var sid: String = s.id
		b.pressed.connect(func():
			_sel_species = sid
			for x in wood_btns:
				x.button_pressed = x == b)
		wood_btns.append(b)
		grid.add_child(b)
	col.add_child(grid)
	col.add_child(_section("LOG SIZE"))
	var sizes := HBoxContainer.new()
	sizes.add_theme_constant_override("separation", 10)
	var size_btns: Array[Button] = []
	for z in Species.SIZES:
		var b := Button.new()
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.text = z.name
		b.button_pressed = z.id == _sel_size
		var zid: String = z.id
		b.pressed.connect(func():
			_sel_size = zid
			for x in size_btns:
				x.button_pressed = x == b)
		size_btns.append(b)
		sizes.add_child(b)
	col.add_child(sizes)
	var go := Button.new()
	go.text = "Start carving"
	go.focus_mode = Control.FOCUS_NONE
	go.custom_minimum_size = Vector2(220, 56)
	go.add_theme_color_override("font_color", Color("#2a1a0e"))
	go.add_theme_color_override("font_hover_color", Color("#2a1a0e"))
	go.add_theme_stylebox_override("normal", _box(ACCENT, 14, 12))
	go.add_theme_stylebox_override("hover", _box(ACCENT.lightened(0.08), 14, 12))
	go.pressed.connect(func(): begin.emit(_sel_species, _sel_size))
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 10)
	col.add_child(spacer)
	col.add_child(go)


func _section(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", INK_FAINT)
	return l


func _build_help() -> void:
	help.visible = false
	help.set_anchors_preset(Control.PRESET_CENTER)
	help.custom_minimum_size = Vector2(620, 0)
	var t := RichTextLabel.new()
	t.bbcode_enabled = true
	t.fit_content = true
	t.custom_minimum_size = Vector2(580, 0)
	t.add_theme_font_size_override("normal_font_size", 16)
	t.add_theme_font_size_override("bold_font_size", 16)
	t.text = """[font_size=26]How to whittle[/font_size]

[b]Carve[/b]: hold the left mouse button and drag across the wood. Each stroke takes an even layer; go over an area again to go deeper.
[b]Turn the log[/b]: drag with the right mouse button. [b]Closer / further[/b]: scroll.

[b]Read the grain.[/b] Fibres run the length of the log. Cutting along them lifts long curls; across them gives short flakes. On a slope, cut [b]downhill[/b]: cutting uphill lets the blade follow the fibres in and tear them out. End grain is tough; take light cuts.

[b]Saw[/b] by dragging back and forth along your line; saw all the way through and the piece drops away. [b]Sandpaper[/b] blends facets into smooth curves.

Keys: [b]1–7[/b] tools · [b]Z[/b] undo · [b]F[/b] switch grip end · [b]H[/b] hide interface · [b]Esc[/b] close"""
	help.add_child(t)
	root.add_child(help)
	help.reset_size()
	help.position = -help.size / 2


func show_start(on: bool) -> void:
	start.visible = on
	hud.visible = not on


func set_tool(id: String) -> void:
	for k in _tool_buttons:
		(_tool_buttons[k] as Button).button_pressed = k == id


func set_undo(can: bool) -> void:
	_undo_btn.disabled = not can


func show_feel(f: String) -> void:
	var d: Array = FEEL.get(f, FEEL.with)
	hint.text = d[0]
	hint.add_theme_color_override("font_color", d[1])
	_hint_t = 1.4


func toggle_hidden() -> void:
	hud.visible = not hud.visible


func _process(delta: float) -> void:
	_hint_t = maxf(0.0, _hint_t - delta)
	hint.modulate.a = move_toward(hint.modulate.a, 1.0 if _hint_t > 0.0 else 0.0, delta * 4.0)
