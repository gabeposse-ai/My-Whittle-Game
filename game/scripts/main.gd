extends Node3D
## Whittle: entry point and glue. Builds the workshop, the log, hands, shavings, UI and sound, and
## routes input into carving strokes.

const INCH := 0.0254
const LOOK_TARGET := Vector3(0, 30.5 * INCH, -15 * INCH)

var workshop: Workshop
var camera: Camera3D
var pivot := Node3D.new() ## position + rotation of the log (unscaled)
var log_node := Node3D.new() ## log-local space: inches
var log_mesh := MeshInstance3D.new()
var material: ShaderMaterial
var volume: LogVolume
var carver: Carver
var shavings := Shavings.new()
var hands := Hands.new()
var sfx := Sfx.new()
var ui := GameUI.new()

var species: Dictionary
var size: Dictionary
var current_tool: Dictionary = ToolDefs.ALL[0]
var grip_top := false
var zoom := 0.0
var pieces: Array = [] ## {body, mesh, material, texture, stroke}

enum Mode { NONE, PENDING, CARVE, ORBIT }
var mode := Mode.NONE
var _mouse := Vector2.ZERO
var _drag := Vector2.ZERO
var _last_cut_time := 0.0
var _view_dir := Vector3.FORWARD
var _default_zoom := 0.0


func _ready() -> void:
	workshop = Workshop.new()
	add_child(workshop)
	camera = workshop.camera
	_view_dir = (LOOK_TARGET - camera.global_position).normalized()
	_default_zoom = camera.global_position.distance_to(LOOK_TARGET)
	add_child(pivot)
	log_node.scale = Vector3.ONE * INCH
	pivot.add_child(log_node)
	# Raymarched self-shadows rely on the Forward+ depth convention; skip them elsewhere.
	var forward_plus := RenderingServer.get_rendering_device() != null
	log_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if forward_plus else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	log_node.add_child(log_mesh)
	log_node.add_child(hands.holding)
	add_child(hands)
	shavings.surface_height = Workshop.surface_height
	add_child(shavings)
	add_child(sfx)
	add_child(ui)
	ui.begin.connect(_on_begin)
	ui.tool_selected.connect(select_tool)
	ui.undo_pressed.connect(undo)
	ui.flip_pressed.connect(flip)
	ui.new_log_pressed.connect(func(): ui.show_start(true))
	ui.mute_toggled.connect(func(m): sfx.muted = m)
	get_viewport().size_changed.connect(_on_resize)
	start_session("basswood", "medium")
	select_tool("sloyd")
	ui.show_start(true)
	_on_resize()
	_debug_args()


## Debug / CI: `-- --shot=<path> [--play] [--frames=N] [--yaw=rad] [--zoom=m]` renders and saves a screenshot.
func _debug_args() -> void:
	var args := OS.get_cmdline_user_args()
	var shot := ""
	var frames := 60
	for a in args:
		if a.begins_with("--shot="):
			shot = a.substr(7)
		elif a == "--play":
			ui.show_start(false)
		elif a.begins_with("--frames="):
			frames = int(a.substr(9))
		elif a.begins_with("--yaw="):
			pivot.basis = Basis(Vector3.UP, float(a.substr(6))) * pivot.basis
		elif a.begins_with("--zoom="):
			zoom = float(a.substr(7))
			_place_log()
		elif a == "--noshadow":
			log_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		elif a == "--nohands":
			hands.holding.visible = false
			hands.carving.visible = false
		elif a.begins_with("--tool="):
			select_tool(a.substr(7))
	if "--autocarve" in args:
		await _autocarve(args)
	if shot == "":
		return
	for i in frames:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(shot)
	print("saved ", shot)
	get_tree().quit()


## Debug: drive real mouse events through the input path (knife passes, a V line, a saw-through).
func _autocarve(args: PackedStringArray) -> void:
	for i in 5:
		await get_tree().process_frame
	var to_win := get_viewport().get_screen_transform()
	var c := to_win * camera.unproject_position(pivot.global_position)
	var top := to_win * camera.unproject_position(pivot.global_position + pivot.global_basis.y * 0.12)
	var down := (c - top).normalized()
	var side := Vector2(-down.y, down.x)
	var stroke := func(a: Vector2, b: Vector2, steps: int, btn := MOUSE_BUTTON_LEFT) -> void:
		var ev := InputEventMouseButton.new()
		ev.button_index = btn
		ev.pressed = true
		ev.position = a
		Input.parse_input_event(ev)
		for k in 4:
			await get_tree().process_frame
		var prev := a
		for k in steps:
			var p := a.lerp(b, float(k + 1) / steps)
			var mm := InputEventMouseMotion.new()
			mm.position = p
			mm.relative = p - prev
			prev = p
			Input.parse_input_event(mm)
			await get_tree().process_frame
		var up := InputEventMouseButton.new()
		up.button_index = btn
		up.pressed = false
		up.position = b
		Input.parse_input_event(up)
		await get_tree().process_frame
	select_tool("sloyd")
	for pass_i in 2:
		for k in 5:
			var x := c + side * (k - 2) * 14.0
			await stroke.call(x - down * 90.0, x + down * 60.0, 14)
	if "--vee" in args:
		select_tool("vgouge")
		for k in 2:
			var y := c + down * (20.0 + k * 18.0)
			await stroke.call(y - side * 50.0, y + side * 50.0, 12)
	if "--saw" in args:
		select_tool("saw")
		var o := c - down * 120.0 + side * 60.0
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = true
		ev.position = o
		Input.parse_input_event(ev)
		for k in 4:
			await get_tree().process_frame
		for k in 90:
			var mm := InputEventMouseMotion.new()
			mm.relative = side * (60.0 if k % 2 == 0 else -60.0)
			mm.position = o
			Input.parse_input_event(mm)
			await get_tree().process_frame
		var up := InputEventMouseButton.new()
		up.button_index = MOUSE_BUTTON_LEFT
		up.position = o
		Input.parse_input_event(up)
		await get_tree().process_frame
	print("autocarve done: undo=", carver.can_undo(), " pieces=", pieces.size())


func _on_resize() -> void:
	await get_tree().process_frame
	hands.set_rest(camera)


# ------------------------------------------------------------------ sessions

func start_session(species_id: String, size_id: String) -> void:
	_end_stroke()
	for p in pieces:
		_free_piece(p)
	pieces.clear()
	if volume:
		volume.dispose()
	if shavings.curl_material:
		shavings.clear_all()
	species = Species.by_id(species_id)
	size = Species.size_by_id(size_id)
	var has_compute := RenderingServer.get_rendering_device() != null
	var vpi := 24.0 if has_compute else 5.0
	volume = LogVolume.new(size, species, vpi, randi() % 1000000)
	if not volume.ok:
		volume.init_cpu_fallback()
	volume.picked.connect(_on_picked)
	carver = Carver.new(volume, species)
	carver.grip_top = grip_top
	carver.cut.connect(_on_cut)
	carver.offcut.connect(_on_offcut)

	material = ShaderMaterial.new()
	material.shader = load("res://shaders/log.gdshader")
	_apply_wood_params(material)
	material.set_shader_parameter("sdf", volume.texture)
	var box := BoxMesh.new()
	var aabb := volume.local_aabb()
	box.size = aabb.size
	log_mesh.mesh = box
	log_mesh.position = aabb.get_center()
	log_mesh.material_override = material

	if not shavings.curl_material:
		shavings.setup(material)
	_apply_wood_params(shavings.curl_material)
	_apply_wood_params(shavings.flake_material)

	grip_top = false
	carver.grip_top = false
	hands.build_holding(size.radius, size.length, grip_top)
	pivot.basis = Basis.from_euler(Vector3(0.28, 0.4, 0.12))
	zoom = _default_zoom + 0.06 + (size.length - 12.0) * 0.01 + (size.radius - 3.0) * 0.03
	_place_log()
	ui.set_undo(false)


func _apply_wood_params(m: ShaderMaterial) -> void:
	m.set_shader_parameter("sap_color", species.sap)
	m.set_shader_parameter("heart_color", species.heart)
	m.set_shader_parameter("bark_color", species.bark)
	m.set_shader_parameter("bark_dark", species.bark_dark)
	m.set_shader_parameter("late_mul", species.late_mul)
	m.set_shader_parameter("rings_per_inch", species.rings)
	m.set_shader_parameter("heart_radius", species.heart_frac * size.radius)
	m.set_shader_parameter("figure", species.figure)
	m.set_shader_parameter("log_radius", size.radius)
	m.set_shader_parameter("log_length", size.length)
	m.set_shader_parameter("bark_inch", species.bark_inch)
	m.set_shader_parameter("log_seed", volume.seed)
	var rng := RandomNumberGenerator.new()
	rng.seed = volume.seed
	var knots: Array[Vector4] = []
	for i in 4:
		if i < species.knots:
			knots.append(Vector4((rng.randf() - 0.5) * size.length * 0.7, rng.randf() * TAU, 0.25 + rng.randf() * 0.25, 1.0))
		else:
			knots.append(Vector4.ZERO)
	m.set_shader_parameter("knots", knots)
	m.set_shader_parameter("knot_count", species.knots)
	if m.shader == material.shader:
		m.set_shader_parameter("dims", Vector3(volume.dims))
		m.set_shader_parameter("centre", volume.centre)
		m.set_shader_parameter("vpi", volume.vpi)


func _on_begin(species_id: String, size_id: String) -> void:
	start_session(species_id, size_id)
	ui.show_start(false)


func _place_log() -> void:
	pivot.global_position = camera.global_position + _view_dir * zoom


# ------------------------------------------------------------------ tools, undo, grip

func select_tool(id: String) -> void:
	_end_stroke()
	current_tool = ToolDefs.by_id(id)
	hands.set_tool(id)
	ui.set_tool(id)


func undo() -> void:
	if carver.active:
		return
	var sid := carver.undo()
	if sid < 0:
		return
	shavings.remove_stroke(sid)
	for p in pieces.duplicate():
		if p.stroke == sid:
			_free_piece(p)
			pieces.erase(p)
	ui.set_undo(carver.can_undo())


func flip() -> void:
	if carver.active:
		return
	grip_top = not grip_top
	carver.grip_top = grip_top
	hands.build_holding(size.radius, size.length, grip_top)
	pivot.basis = Basis(camera.global_basis.x, PI) * pivot.basis


# ------------------------------------------------------------------ input

func _unhandled_input(event: InputEvent) -> void:
	if ui.start.visible:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		_mouse = mb.position
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					if mb.shift_pressed:
						mode = Mode.ORBIT
					else:
						mode = Mode.PENDING
						_queue_pointer_ray("begin")
				else:
					_end_stroke()
					mode = Mode.NONE
			MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE:
				if mb.pressed and mode != Mode.CARVE:
					mode = Mode.ORBIT
				elif not mb.pressed and mode == Mode.ORBIT:
					mode = Mode.NONE
			MOUSE_BUTTON_WHEEL_UP:
				zoom = clampf(zoom * 0.94, 0.22, 0.85)
				_place_log()
			MOUSE_BUTTON_WHEEL_DOWN:
				zoom = clampf(zoom / 0.94, 0.22, 0.85)
				_place_log()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		_mouse = mm.position
		if mode == Mode.ORBIT:
			_rotate_log(mm.relative)
		elif mode == Mode.CARVE:
			_drag += mm.relative
	elif event is InputEventKey and event.pressed and not event.echo:
		var k := event as InputEventKey
		for t in ToolDefs.ALL:
			if k.keycode == t.key:
				select_tool(t.id)
				return
		match k.keycode:
			KEY_Z:
				undo()
			KEY_F:
				flip()
			KEY_H:
				ui.toggle_hidden()
			KEY_ESCAPE:
				ui.help.visible = false
			KEY_F11:
				var w := get_window()
				w.mode = Window.MODE_WINDOWED if w.mode == Window.MODE_EXCLUSIVE_FULLSCREEN else Window.MODE_EXCLUSIVE_FULLSCREEN


func _rotate_log(rel: Vector2) -> void:
	var right := camera.global_basis.x
	pivot.basis = (Basis(Vector3.UP, rel.x * 0.006) * Basis(right, rel.y * 0.006) * pivot.basis).orthonormalized()


## Pointer ray converted into the log's grid space.
func _grid_ray(screen: Vector2) -> Array:
	var o := camera.project_ray_origin(screen)
	var d := camera.project_ray_normal(screen)
	var inv := log_node.global_transform.affine_inverse()
	var lo := inv * o
	var ld := (inv.basis * d).normalized()
	return [volume.local_to_grid(lo), ld]


func _queue_pointer_ray(kind: String) -> void:
	var r := _grid_ray(_mouse)
	# Saw: the screen-space drag since the last ray, as a grid direction + inches of hand travel.
	var dist := camera.global_position.distance_to(pivot.global_position)
	var m_per_px := 2.0 * dist * tan(deg_to_rad(camera.fov) / 2.0) / get_viewport().get_visible_rect().size.y
	var w := camera.global_basis.x * (_drag.x * m_per_px) - camera.global_basis.y * (_drag.y * m_per_px)
	var travel := w.length() / INCH
	var drag_local := (log_node.global_transform.affine_inverse().basis * w).normalized() if w.length() > 0.0 else Vector3.ZERO
	_drag = Vector2.ZERO
	volume.queue_ray(r[0], r[1], {"kind": kind, "ro": r[0], "rd": r[1], "drag": drag_local, "travel": travel, "time": Time.get_ticks_msec()})


func _on_picked(results: Array) -> void:
	for res in results:
		var tag: Dictionary = res.tag
		if tag.kind == "begin":
			if mode != Mode.PENDING:
				continue
			if res.found:
				carver.begin(current_tool, res)
				mode = Mode.CARVE
				_last_cut_time = Time.get_ticks_msec() / 1000.0
				hands.engage(_grid_to_world(res.pos), _dir_to_world(res.normal), camera)
			else:
				mode = Mode.ORBIT # dragging off the wood turns the log
		elif tag.kind == "move" and carver.active:
			carver.move(res, tag.ro, tag.rd, tag.drag, tag.travel)


func _end_stroke() -> void:
	if carver == null or not carver.active:
		return
	var sid := carver.end()
	shavings.release_curl()
	hands.release()
	sfx.stop_cut()
	ui.set_undo(carver.can_undo())
	if sid < 0:
		return


# ------------------------------------------------------------------ cut events → shavings, sound

func _grid_to_world(g: Vector3) -> Vector3:
	return log_node.to_global(volume.grid_to_local(g))

func _dir_to_world(v: Vector3) -> Vector3:
	return (log_node.global_basis * v).normalized()


func _on_cut(ev: Dictionary) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var dt := maxf(now - _last_cut_time, 1.0 / 240.0)
	_last_cut_time = now
	var local := volume.grid_to_local(ev.pos)
	var p := log_node.to_global(local)
	var n := _dir_to_world(ev.n)
	var grain := _dir_to_world(Vector3.UP)
	var sid := carver.stroke_id
	match ev.kind:
		"curl":
			shavings.grow_curl(sid, log_node, local, ev.t, ev.n, ev.width, ev.depth, ev.seg_len, species.softness)
		"flake":
			shavings.release_curl()
			var count := clampi(roundi(ev.volume / 0.0012), 1, 5)
			var sz := clampf(pow(ev.volume / count, 1.0 / 3.0) * 1.5, 0.035, 0.18)
			shavings.spawn_flakes(sid, p, n, grain, count, sz, local - ev.n * 0.02)
		"dust":
			var dust_col := Color(species.sap) * 1.05
			if ev.feel == "saw":
				shavings.spawn_flakes(sid, p, n, grain, 2, 0.022, local)
				shavings.spawn_dust(p, n, 2, dust_col, 0.02)
				workshop.puff(0.02)
			else:
				shavings.spawn_dust(p, n, 3, dust_col, 0.012)
				workshop.puff(0.015)
	sfx.cut(ev.feel, ev.seg_len / dt, ev.volume, species.softness)
	ui.show_feel(ev.feel)
	if ev.feel != "saw":
		hands.engage(p, n, camera)


# ------------------------------------------------------------------ offcuts

## A sawn-through piece: copy the field into its own texture, show only the far side of the kerf on
## it, remove that side from the log, and let it fall as a rigid body.
func _on_offcut(info: Dictionary) -> void:
	volume.flush()
	var tex := volume.clone_texture()
	carver.remove_half_space(info.normal, info.w)
	volume.flush()

	var body := RigidBody3D.new()
	body.global_transform = Transform3D(log_node.global_basis.orthonormalized(), log_node.global_position)
	add_child(body)
	var holder := Node3D.new()
	holder.scale = Vector3.ONE * INCH
	body.add_child(holder)
	var mi := MeshInstance3D.new()
	mi.mesh = log_mesh.mesh
	mi.position = log_mesh.position
	var m: ShaderMaterial = material.duplicate()
	m.set_shader_parameter("sdf", tex)
	var nn: Vector3 = info.normal
	m.set_shader_parameter("clip_plane", Vector4(nn.x, nn.y, nn.z, info.w))
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	holder.add_child(mi)

	# Collision hull: the original log's bounding box clipped to the removed side of the plane.
	var hull := _clip_box_points(nn, info.w)
	if hull.size() >= 4:
		var shape := ConvexPolygonShape3D.new()
		var pts := PackedVector3Array()
		var centroid := Vector3.ZERO
		for q in hull:
			pts.append(q * INCH)
			centroid += q * INCH
		centroid /= hull.size()
		shape.points = pts
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
		body.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
		body.center_of_mass = centroid
	body.mass = 0.3
	body.linear_velocity = Vector3(randf_range(-0.1, 0.1), 0.05, randf_range(-0.1, 0.1))
	pieces.append({"body": body, "mesh": mi, "material": m, "texture": tex, "stroke": info.stroke})
	while pieces.size() > 6:
		_free_piece(pieces.pop_front())


## Corners of the log's local bounding box (inches) on the removed side of the plane
## dot(nn, g) + w > 0 (grid space), plus where the box edges cross the plane.
func _clip_box_points(nn: Vector3, w: float) -> Array:
	var r: float = size.radius * 1.08
	var h: float = size.length * 0.5
	var corners: Array[Vector3] = []
	for x in [-r, r]:
		for y in [-h, h]:
			for z in [-r, r]:
				corners.append(Vector3(x, y, z))
	var sdist := func(p: Vector3) -> float: return nn.dot(volume.local_to_grid(p)) + w
	var out: Array = []
	for c in corners:
		if sdist.call(c) > 0.0:
			out.append(c)
	for i in 8:
		for j in range(i + 1, 8):
			var a: Vector3 = corners[i]
			var b: Vector3 = corners[j]
			var diff := 0
			for k in 3:
				if a[k] != b[k]:
					diff += 1
			if diff != 1:
				continue
			var da: float = sdist.call(a)
			var db: float = sdist.call(b)
			if (da > 0.0) != (db > 0.0):
				out.append(a.lerp(b, da / (da - db)))
	return out


func _free_piece(p: Dictionary) -> void:
	(p.body as Node).queue_free()
	volume.free_texture(p.texture)


# ------------------------------------------------------------------ frame

func _process(_delta: float) -> void:
	_update_material(material, log_node)
	for p in pieces:
		_update_material(p.material, p.mesh.get_parent())
	if mode == Mode.CARVE and carver.active:
		_queue_pointer_ray("move")
	volume.flush()


func _update_material(m: ShaderMaterial, node: Node3D) -> void:
	var xf := node.global_transform
	m.set_shader_parameter("local_to_world", Projection(xf))
	m.set_shader_parameter("world_to_local", Projection(xf.affine_inverse()))
