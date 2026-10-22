class_name GameUI
extends CanvasLayer
## Start screen, tool bar, top buttons, grain hint and help. Built in code with a warm theme.

signal begin(species_id: String, size_id: String)
signal tool_selected(id: String)
signal undo_pressed
signal flip_pressed
signal new_log_pressed
signal settings_changed
signal quit_pressed

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
var settings: Settings ## assign before adding to the tree
var menu := Control.new()
var settings_panel := Control.new()
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
	_build_menu()
	_build_settings()


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
	tl.add_child(_button("Menu  (Esc)", func(): open_menu()))
	_undo_btn = _button("Undo  (Z)", func(): undo_pressed.emit())
	_undo_btn.disabled = true
	tl.add_child(_undo_btn)
	tl.add_child(_button("Switch grip  (F)", func(): flip_pressed.emit()))
	hud.add_child(tl)

	var keys := Label.new()
	keys.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	keys.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	keys.offset_left = -560
	keys.offset_right = -22
	keys.offset_top = 22
	keys.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	keys.add_theme_font_size_override("font_size", 14)
	keys.add_theme_color_override("font_color", INK_FAINT)
	keys.text = "Left-drag: carve   Right-drag: turn & tilt   Scroll: closer   R: reset"
	hud.add_child(keys)

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
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 10)
	actions.add_child(go)
	var st := _button("Settings", func(): show_settings(true))
	st.custom_minimum_size = Vector2(140, 56)
	actions.add_child(st)
	var q := _button("Quit", func(): quit_pressed.emit())
	q.custom_minimum_size = Vector2(110, 56)
	actions.add_child(q)
	col.add_child(actions)


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
[b]Closer / further[/b]: scroll.

[b]Read the grain.[/b] Fibres run the length of the log. Cutting along them lifts long curls; across them gives short flakes. On a slope, cut [b]downhill[/b]: cutting uphill lets the blade follow the fibres in and tear them out. End grain is tough; take light cuts.

[b]Saw[/b] by dragging back and forth along your line; saw all the way through and the piece drops away. [b]Sandpaper[/b] blends facets into smooth curves.

Turn the log: [b]right-drag[/b] (sideways spins it in your hand, up/down tilts it), or [b]A/D[/b] spin, [b]W/S[/b] tilt, [b]Q/E[/b] roll, [b]R[/b] reset.

Keys: [b]1–7[/b] tools · [b]Z[/b] undo · [b]F[/b] switch grip end · [b]H[/b] hide interface · [b]Esc[/b] menu"""
	var hcol := VBoxContainer.new()
	hcol.add_theme_constant_override("separation", 12)
	hcol.add_child(t)
	hcol.add_child(_button("Close", func(): help.visible = false))
	help.add_child(hcol)
	root.add_child(help)
	help.reset_size()
	help.position = -help.size / 2


func _overlay(title_text: String) -> VBoxContainer:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(440, 0)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	var t := Label.new()
	t.text = title_text
	t.add_theme_font_override("font", serif)
	t.add_theme_font_size_override("font_size", 40)
	col.add_child(t)
	panel.add_child(col)
	center.add_child(panel)
	return col


func _build_menu() -> void:
	menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	menu.visible = false
	root.add_child(menu)
	var col := _overlay("Paused")
	var shade := ColorRect.new()
	shade.color = Color(0.05, 0.03, 0.02, 0.62)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	menu.add_child(shade)
	menu.add_child(col.get_parent().get_parent())
	for item in [
		["Resume", func(): close_menu()],
		["Settings", func(): show_settings(true)],
		["How to whittle", func():
			help.visible = true
			help.move_to_front()],
		["New log", func():
			close_menu()
			new_log_pressed.emit()],
		["Quit to desktop", func(): quit_pressed.emit()],
	]:
		var b := _button(item[0], item[1])
		b.custom_minimum_size = Vector2(0, 52)
		col.add_child(b)


func _slider_row(col: VBoxContainer, label: String, value: float, on_change: Callable, toggle: Variant = null, on_toggle: Callable = Callable()) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(170, 0)
	row.add_child(l)
	if toggle != null:
		var cb := CheckButton.new()
		cb.button_pressed = toggle
		cb.focus_mode = Control.FOCUS_NONE
		cb.toggled.connect(on_toggle)
		cb.custom_minimum_size = Vector2(60, 0)
		row.add_child(cb)
	else:
		var pad := Control.new()
		pad.custom_minimum_size = Vector2(60, 0)
		row.add_child(pad)
	var sl := HSlider.new()
	sl.min_value = 0.0
	sl.max_value = 1.0
	sl.step = 0.01
	sl.value = value
	sl.custom_minimum_size = Vector2(220, 0)
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sl.focus_mode = Control.FOCUS_NONE
	sl.value_changed.connect(on_change)
	row.add_child(sl)
	col.add_child(row)


func _build_settings() -> void:
	for c in settings_panel.get_children():
		c.queue_free()
	settings_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	settings_panel.visible = false
	if settings_panel.get_parent() == null:
		root.add_child(settings_panel)
	var col := _overlay("Settings")
	var shade := ColorRect.new()
	shade.color = Color(0.05, 0.03, 0.02, 0.5)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	settings_panel.add_child(shade)
	settings_panel.add_child(col.get_parent().get_parent())
	(col.get_parent() as Control).custom_minimum_size = Vector2(560, 0)
	var s := settings
	var changed := func():
		s.save()
		settings_changed.emit()
	_slider_row(col, "Master volume", s.master, func(v): s.master = v; changed.call())
	_slider_row(col, "Carving sounds", s.carving, func(v): s.carving = v; changed.call(),
		s.carving_on, func(on): s.carving_on = on; changed.call())
	_slider_row(col, "Fire & room", s.ambience, func(v): s.ambience = v; changed.call(),
		s.ambience_on, func(on): s.ambience_on = on; changed.call())
	_slider_row(col, "Turn sensitivity", s.sensitivity * 0.5, func(v): s.sensitivity = maxf(0.2, v * 2.0); changed.call())
	var fs := CheckButton.new()
	fs.text = "Fullscreen"
	fs.button_pressed = s.fullscreen
	fs.focus_mode = Control.FOCUS_NONE
	fs.toggled.connect(func(on): s.fullscreen = on; changed.call())
	col.add_child(fs)
	var back := _button("Back", func(): show_settings(false))
	back.custom_minimum_size = Vector2(0, 48)
	col.add_child(back)


var _settings_from_menu := false

func show_settings(on: bool) -> void:
	if on:
		_settings_from_menu = menu.visible
		menu.visible = false
	elif _settings_from_menu:
		menu.visible = true
	settings_panel.visible = on
	settings_panel.move_to_front()


func open_menu() -> void:
	if start.visible:
		return
	menu.visible = true


func close_menu() -> void:
	menu.visible = false
	settings_panel.visible = false
	help.visible = false


## Esc: close the topmost overlay, or open the menu.
func back() -> void:
	if help.visible:
		help.visible = false
	elif settings_panel.visible:
		show_settings(false)
	elif menu.visible:
		menu.visible = false
	elif not start.visible:
		menu.visible = true


func is_blocking() -> bool:
	return start.visible or menu.visible or settings_panel.visible or help.visible


func show_start(on: bool) -> void:
	start.visible = on
	hud.visible = not on
	if on:
		close_menu()


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
