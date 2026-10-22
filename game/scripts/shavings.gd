class_name Shavings
extends Node3D
## Everything that comes off the log: curls, flakes and dust. All of it uses the wood shader keyed by
## the exact log-local point it was cut from, falls, and (except airborne dust) stays where it lands.
##
## Curls are grown by the blade: while a stroke cuts cleanly with the grain, a ribbon whose width is
## the cut width and whose thickness is the cut depth rolls up off the edge, rooted at the blade and
## lengthening as it advances. When the stroke ends it is released as a soft body: a chain of points
## with stretch and bending constraints, so it bounces, flexes, partly uncurls and settles.

const INCH := 0.0254
const SEGS := 28
const MAX_CURLS := 160
const MAX_FLAKES := 6000
const MAX_DUST := 1200
const GRAVITY := Vector3(0, -9.8, 0)

var surface_height: Callable ## (x, z) -> y in world metres
var curl_material: ShaderMaterial
var flake_material: ShaderMaterial
var dust_material: StandardMaterial3D

var _active: Dictionary = {} # curl being grown
var _curls: Array = []

var _flakes: MultiMeshInstance3D
var _f_pos := PackedVector3Array()
var _f_vel := PackedVector3Array()
var _f_rot := PackedVector3Array()
var _f_spin := PackedVector3Array()
var _f_scale := PackedVector3Array()
var _f_state := PackedByteArray() # 0 free, 1 flying, 2 resting
var _f_stroke := PackedInt32Array()
var _f_next := 0
var _f_flying := {}

var _dust: MultiMeshInstance3D
var _d_pos := PackedVector3Array()
var _d_vel := PackedVector3Array()
var _d_age := PackedFloat32Array()
var _d_life := PackedFloat32Array()
var _d_next := 0
var _d_live := {}
var _time := 0.0


func setup(wood_material: ShaderMaterial) -> void:
	curl_material = wood_material.duplicate()
	curl_material.shader = load("res://shaders/shaving.gdshader")
	flake_material = curl_material.duplicate()
	flake_material.set_shader_parameter("use_instance_custom", true)

	_flakes = MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = _flake_mesh()
	mm.instance_count = MAX_FLAKES
	mm.visible_instance_count = MAX_FLAKES
	_flakes.multimesh = mm
	_flakes.material_override = flake_material
	_flakes.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_flakes.custom_aabb = AABB(Vector3(-10, -1, -10), Vector3(20, 4, 20))
	add_child(_flakes)
	_f_pos.resize(MAX_FLAKES); _f_vel.resize(MAX_FLAKES); _f_rot.resize(MAX_FLAKES)
	_f_spin.resize(MAX_FLAKES); _f_scale.resize(MAX_FLAKES); _f_state.resize(MAX_FLAKES); _f_stroke.resize(MAX_FLAKES)
	var zero := Transform3D().scaled(Vector3.ZERO)
	for i in MAX_FLAKES:
		mm.set_instance_transform(i, zero)

	_dust = MultiMeshInstance3D.new()
	var dm := MultiMesh.new()
	dm.transform_format = MultiMesh.TRANSFORM_3D
	dm.use_colors = true
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	dm.mesh = quad
	dm.instance_count = MAX_DUST
	_dust.multimesh = dm
	dust_material = StandardMaterial3D.new()
	dust_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dust_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	dust_material.billboard_keep_scale = true
	dust_material.vertex_color_use_as_albedo = true
	dust_material.roughness = 1.0
	dust_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	dust_material.shadow_to_opacity = false
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 1))
	grad.set_color(1, Color(1, 1, 1, 0))
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(1.0, 0.5)
	gt.width = 64
	gt.height = 64
	dust_material.albedo_texture = gt
	_dust.material_override = dust_material
	_dust.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_dust.custom_aabb = AABB(Vector3(-10, -1, -10), Vector3(20, 4, 20))
	add_child(_dust)
	_d_pos.resize(MAX_DUST); _d_vel.resize(MAX_DUST); _d_age.resize(MAX_DUST); _d_life.resize(MAX_DUST)
	for i in MAX_DUST:
		dm.set_instance_transform(i, zero)
		dm.set_instance_color(i, Color(1, 1, 1, 0))


## A thin irregular wedge, elongated along x (the grain), unit size.
func _flake_mesh() -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var outline: Array[Vector2] = []
	var n := 9
	for i in n:
		var a := TAU * i / n
		var r := 0.5 * (0.7 + rng.randf() * 0.45)
		outline.append(Vector2(cos(a) * r * 1.0, sin(a) * r * 0.55))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var h := 0.5
	for side in [1.0, -1.0]:
		st.set_normal(Vector3(0, side, 0))
		for i in n:
			var p0 := outline[i]
			var p1 := outline[(i + 1) % n]
			var tip: float = 0.25 * side # thicker in the middle: a wedge
			if side > 0:
				st.add_vertex(Vector3(0, h * tip, 0)); st.add_vertex(Vector3(p0.x, 0, p0.y)); st.add_vertex(Vector3(p1.x, 0, p1.y))
			else:
				st.add_vertex(Vector3(0, h * tip, 0)); st.add_vertex(Vector3(p1.x, 0, p1.y)); st.add_vertex(Vector3(p0.x, 0, p0.y))
	st.generate_normals()
	return st.commit()


# ------------------------------------------------------------------ curls

## Grow (or start) the curl at the blade. All vectors are in log-local inches; `log_node` is the
## node whose local space they are in (the curl is parented there while attached).
func grow_curl(stroke_id: int, log_node: Node3D, p: Vector3, t: Vector3, n: Vector3, width: float, depth: float, add: float, softness: float) -> void:
	var c := _active
	if not c.is_empty():
		var changed: bool = c.stroke != stroke_id or (c.dir as Vector3).dot(t) < 0.5 \
			or absf(c.width - width) > maxf(0.08, c.width * 0.6) or c.len > 7.0
		if changed:
			release_curl()
			c = {}
	if c.is_empty():
		var mi := MeshInstance3D.new()
		mi.material_override = curl_material
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		log_node.add_child(mi)
		# Stiffer woods (harder) curl looser; thicker cuts curl looser.
		var r0 := 0.08 + depth * 2.6 + width * 0.06 + (1.0 - softness) * 0.08
		c = {
			"mesh": mi, "len": 0.0, "width": maxf(0.04, width), "thick": maxf(0.012, depth * 0.55),
			"r0": r0, "stroke": stroke_id, "dir": t, "n": n, "root": p,
			"path": PackedVector3Array([p]), "path_len": PackedFloat32Array([0.0]),
			"wobble": randf() * 100.0, "twist": 0.0,
		}
		_active = c
	var path: PackedVector3Array = c.path
	var plen: PackedFloat32Array = c.path_len
	var last: Vector3 = path[path.size() - 1]
	path.append(p)
	plen.append(plen[plen.size() - 1] + last.distance_to(p))
	c.path = path
	c.path_len = plen
	c.len += add * 0.9
	c.width = c.width * 0.85 + maxf(0.04, width) * 0.15
	c.dir = (c.dir as Vector3).lerp(t, 0.3).normalized()
	c.n = (c.n as Vector3).lerp(n, 0.3).normalized()
	c.root = p
	_build_attached(c)


## Centreline of an attached curl, in log-local inches, rooted at the blade edge.
func _attached_points(c: Dictionary) -> Dictionary:
	var x: Vector3 = c.dir
	var y: Vector3 = (c.n - x * (c.n as Vector3).dot(x)).normalized()
	var z := x.cross(y).normalized()
	var pts := PackedVector3Array()
	var src := PackedVector3Array()
	var widths := PackedFloat32Array()
	var L: float = maxf(c.len, 0.02)
	var ds := L / SEGS
	var phi := PI * 0.62 # rises up and back off the blade face
	var cx := 0.0
	var cy := 0.0
	var path: PackedVector3Array = c.path
	var plen: PackedFloat32Array = c.path_len
	var total: float = plen[plen.size() - 1]
	for i in SEGS + 1:
		var s := i * ds
		var root: Vector3 = c.root
		pts.append(root + x * cx + y * cy + y * 0.004)
		# Where this part of the ribbon came from: back along the stroke path.
		src.append(_path_at(path, plen, total - s / 0.9) - y * (c.thick as float) * 0.5)
		var u := s / L
		var taper := smoothstep(0.0, 0.12, 1.0 - u) * 0.6 + 0.4 # thin tail where the cut began
		var wav := 1.0 + 0.08 * sin(s * 23.0 + c.wobble)
		widths.append(c.width * taper * wav)
		var r: float = c.r0 * (1.0 - 0.45 * (s / (L + 0.5)))
		phi -= ds / r
		cx += cos(phi) * ds
		cy += sin(phi) * ds
	return {"pts": pts, "src": src, "w": widths, "side": z}

func _path_at(path: PackedVector3Array, plen: PackedFloat32Array, d: float) -> Vector3:
	if d <= 0.0:
		return path[0]
	for i in range(1, path.size()):
		if plen[i] >= d:
			var seg := plen[i] - plen[i - 1]
			var t := 0.0 if seg <= 0.0 else (d - plen[i - 1]) / seg
			return path[i - 1].lerp(path[i], t)
	return path[path.size() - 1]

func _build_attached(c: Dictionary) -> void:
	var d := _attached_points(c)
	var sides := PackedVector3Array()
	for i in (d.pts as PackedVector3Array).size():
		sides.append(d.side)
	(c.mesh as MeshInstance3D).mesh = _ribbon_mesh(d.pts, sides, d.w, d.src, c.thick, d.side)


## Ribbon with real thickness: top and bottom faces plus both edges. Sources ride in CUSTOM0.
func _ribbon_mesh(pts: PackedVector3Array, sides: PackedVector3Array, widths: PackedFloat32Array,
		src: PackedVector3Array, thick: float, src_side: Vector3, src_scale := 1.0) -> ArrayMesh:
	var n := pts.size()
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var custom := PackedFloat32Array()
	var idx := PackedInt32Array()
	verts.resize(n * 8)
	norms.resize(n * 8)
	custom.resize(n * 8 * 4)
	for i in n:
		var tan := (pts[mini(i + 1, n - 1)] - pts[maxi(i - 1, 0)]).normalized()
		var side := sides[i]
		var up := tan.cross(side).normalized()
		var hw := widths[i] * 0.5
		var ht := thick * 0.5
		var p := pts[i]
		var tl := p + side * hw + up * ht
		var tr := p - side * hw + up * ht
		var bl := p + side * hw - up * ht
		var br := p - side * hw - up * ht
		var b := i * 8
		verts[b] = tl; verts[b + 1] = tr; norms[b] = up; norms[b + 1] = up
		verts[b + 2] = bl; verts[b + 3] = br; norms[b + 2] = -up; norms[b + 3] = -up
		verts[b + 4] = tl; verts[b + 5] = bl; norms[b + 4] = side; norms[b + 5] = side
		verts[b + 6] = tr; verts[b + 7] = br; norms[b + 6] = -side; norms[b + 7] = -side
		var s := src[i]
		for k in 8:
			var off := src_side * hw * src_scale * (1.0 if k in [0, 2, 4, 5] else -1.0)
			custom[(b + k) * 4] = s.x + off.x
			custom[(b + k) * 4 + 1] = s.y + off.y
			custom[(b + k) * 4 + 2] = s.z + off.z
			custom[(b + k) * 4 + 3] = 0.0
		if i < n - 1:
			var nb := b + 8
			for q in [[0, 1], [3, 2], [5, 4], [6, 7]]:
				var a0: int = b + q[0]
				var a1: int = b + q[1]
				var b0: int = nb + q[0]
				var b1: int = nb + q[1]
				idx.append_array([a0, b0, a1, a1, b0, b1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_CUSTOM0] = custom
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	var fmt := Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, fmt)
	return m


## Let go of the curl being grown: it becomes a soft body in world space.
func release_curl() -> void:
	var c := _active
	if c.is_empty():
		return
	_active = {}
	var mi: MeshInstance3D = c.mesh
	if c.len < 0.08:
		mi.queue_free()
		return
	var d := _attached_points(c)
	var xf := mi.get_parent_node_3d().global_transform
	var pts := PackedVector3Array()
	for p in (d.pts as PackedVector3Array):
		pts.append(xf * p)
	var side_w: Vector3 = (xf.basis * (d.side as Vector3)).normalized()
	var scale := xf.basis.get_scale().x
	var body := {
		"mesh": mi, "pts": pts, "prev": pts.duplicate(), "src": d.src, "w": d.w, "thick": c.thick,
		"side0": side_w, "src_side": d.side, "scale": scale, "stroke": c.stroke, "rest": false, "still": 0,
		"rest1": PackedFloat32Array(), "rest2": PackedFloat32Array(),
	}
	var r1 := PackedFloat32Array()
	var r2 := PackedFloat32Array()
	for i in pts.size() - 1:
		r1.append(pts[i].distance_to(pts[i + 1]))
	for i in pts.size() - 2:
		r2.append(pts[i].distance_to(pts[i + 2]))
	body.rest1 = r1
	body.rest2 = r2
	# A small flick off the blade.
	var kick := Vector3(randf_range(-0.15, 0.15), randf_range(0.1, 0.35), randf_range(-0.15, 0.15)) * (1.0 / 60.0)
	var prev: PackedVector3Array = body.prev
	for i in prev.size():
		prev[i] = pts[i] - kick
	body.prev = prev
	mi.reparent(self, false)
	mi.transform = Transform3D.IDENTITY
	_curls.append(body)
	_rebuild_body(body)
	while _curls.size() > MAX_CURLS:
		var old: Dictionary = _curls.pop_front()
		(old.mesh as MeshInstance3D).queue_free()


func _rebuild_body(b: Dictionary) -> void:
	var pts: PackedVector3Array = b.pts
	var n := pts.size()
	# Parallel-transport the ribbon's side vector along the chain.
	var sides := PackedVector3Array()
	sides.resize(n)
	var side: Vector3 = b.side0
	for i in n:
		var tan := (pts[mini(i + 1, n - 1)] - pts[maxi(i - 1, 0)]).normalized()
		side = (side - tan * side.dot(tan)).normalized()
		if side == Vector3.ZERO:
			side = tan.cross(Vector3.UP).normalized()
		sides[i] = side
	var widths := PackedFloat32Array()
	for w in (b.w as PackedFloat32Array):
		widths.append(w * b.scale)
	(b.mesh as MeshInstance3D).mesh = _ribbon_mesh(pts, sides, widths, b.src, b.thick * b.scale, b.src_side, 1.0 / b.scale)


func _simulate_curl(b: Dictionary, dt: float) -> void:
	var pts: PackedVector3Array = b.pts
	var prev: PackedVector3Array = b.prev
	var n := pts.size()
	var r1: PackedFloat32Array = b.rest1
	var r2: PackedFloat32Array = b.rest2
	var moved := 0.0
	for i in n:
		var p := pts[i]
		var v := (p - prev[i]) * 0.985
		prev[i] = p
		pts[i] = p + v + GRAVITY * 0.45 * dt * dt # light and draggy
	for _it in 6:
		for i in n - 1:
			_constrain(pts, i, i + 1, r1[i], 1.0)
		for i in n - 2:
			_constrain(pts, i, i + 2, r2[i], 0.35) # bending: keeps the curl springy
		for i in n:
			var p := pts[i]
			var floor_y: float = surface_height.call(p.x, p.z) + b.thick * b.scale * 0.5
			if p.y < floor_y:
				p.y = floor_y
				# Friction: kill most sideways motion on contact.
				var pv := prev[i]
				prev[i] = Vector3(lerpf(pv.x, p.x, 0.6), pv.y, lerpf(pv.z, p.z, 0.6))
				pts[i] = p
	for i in n:
		moved = maxf(moved, pts[i].distance_squared_to(prev[i]))
	b.pts = pts
	b.prev = prev
	if moved < 1e-10:
		b.still += 1
		if b.still > 20:
			b.rest = true
	else:
		b.still = 0
	_rebuild_body(b)

func _constrain(pts: PackedVector3Array, i: int, j: int, rest: float, k: float) -> void:
	var d := pts[j] - pts[i]
	var l := d.length()
	if l < 1e-9:
		return
	var corr := d * ((l - rest) / l) * 0.5 * k
	pts[i] += corr
	pts[j] -= corr


# ------------------------------------------------------------------ flakes and dust

## `src` is the log-local point (inches) the material came from; `grain` the world grain direction.
func spawn_flakes(stroke_id: int, p: Vector3, n: Vector3, grain: Vector3, count: int, size_in: float, src: Vector3) -> void:
	var mm := _flakes.multimesh
	for k in count:
		var i := _f_next
		_f_next = (_f_next + 1) % MAX_FLAKES
		_f_flying[i] = true
		_f_pos[i] = p + Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * 0.004
		_f_vel[i] = n * randf_range(0.2, 0.6) + Vector3(randf_range(-0.25, 0.25), randf_range(0.05, 0.4), randf_range(-0.25, 0.25))
		_f_rot[i] = Vector3(randf() * TAU, randf() * TAU, randf() * TAU)
		_f_spin[i] = Vector3(randf_range(-14, 14), randf_range(-14, 14), randf_range(-14, 14))
		var s := size_in * INCH * randf_range(0.6, 1.4)
		_f_scale[i] = Vector3(s * 1.8, s * 0.35, s)
		_f_state[i] = 1
		_f_stroke[i] = stroke_id
		mm.set_instance_custom_data(i, Color(src.x, src.y, src.z, 0.0))


func spawn_dust(p: Vector3, n: Vector3, count: int, color: Color, spread := 0.01) -> void:
	var dm := _dust.multimesh
	for k in count:
		var i := _d_next
		_d_next = (_d_next + 1) % MAX_DUST
		_d_live[i] = true
		_d_pos[i] = p + Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * spread
		_d_vel[i] = n * randf_range(0.02, 0.12) + Vector3(randf_range(-0.05, 0.05), randf_range(0.0, 0.08), randf_range(-0.05, 0.05))
		_d_age[i] = 0.0
		_d_life[i] = randf_range(4.0, 11.0)
		dm.set_instance_color(i, color)


## Undo: remove everything that came off during a stroke.
func remove_stroke(stroke_id: int) -> void:
	if not _active.is_empty() and _active.stroke == stroke_id:
		release_curl()
	for b in _curls.duplicate():
		if b.stroke == stroke_id:
			(b.mesh as MeshInstance3D).queue_free()
			_curls.erase(b)
	var zero := Transform3D().scaled(Vector3.ZERO)
	for i in MAX_FLAKES:
		if _f_state[i] != 0 and _f_stroke[i] == stroke_id:
			_f_state[i] = 0
			_f_flying.erase(i)
			_flakes.multimesh.set_instance_transform(i, zero)


func clear_all() -> void:
	if not _active.is_empty():
		(_active.mesh as MeshInstance3D).queue_free()
		_active = {}
	for b in _curls:
		(b.mesh as MeshInstance3D).queue_free()
	_curls.clear()
	var zero := Transform3D().scaled(Vector3.ZERO)
	for i in MAX_FLAKES:
		_f_state[i] = 0
		_flakes.multimesh.set_instance_transform(i, zero)
	_f_flying.clear()


func _process(delta: float) -> void:
	var dt := minf(delta, 1.0 / 30.0)
	_time += dt
	for b in _curls:
		if not b.rest:
			_simulate_curl(b, dt)

	var mm := _flakes.multimesh
	for i in _f_flying.keys():
		var v := _f_vel[i]
		v += GRAVITY * 0.6 * dt
		v *= 0.965
		# Flutter: thin flakes catch the air.
		v.x += sin(_time * 9.0 + i) * 0.02
		v.z += cos(_time * 7.0 + i * 1.7) * 0.02
		var p := _f_pos[i] + v * dt
		var r := _f_rot[i] + _f_spin[i] * dt
		var floor_y: float = surface_height.call(p.x, p.z) + _f_scale[i].y * 0.5
		if p.y < floor_y:
			p.y = floor_y
			r.x = randf_range(-0.2, 0.2)
			r.z = randf_range(-0.2, 0.2)
			_f_state[i] = 2
			_f_flying.erase(i)
		_f_pos[i] = p
		_f_vel[i] = v
		_f_rot[i] = r
		var basis := Basis.from_euler(r).scaled(_f_scale[i])
		mm.set_instance_transform(i, Transform3D(basis, p))

	var dm := _dust.multimesh
	var zero := Transform3D().scaled(Vector3.ZERO)
	for i in _d_live.keys():
		var age := _d_age[i] + dt
		if age >= _d_life[i]:
			_d_live.erase(i)
			dm.set_instance_transform(i, zero)
			continue
		var v := _d_vel[i] * 0.97
		v.y -= 0.004 * dt * 60.0 * 0.05
		v += Vector3(sin(_time * 1.3 + i * 0.7), 0.0, cos(_time * 1.1 + i * 1.3)) * 0.0006
		var p := _d_pos[i] + v * dt
		_d_pos[i] = p
		_d_vel[i] = v
		_d_age[i] = age
		var fade := smoothstep(0.0, 0.4, age) * (1.0 - smoothstep(_d_life[i] * 0.6, _d_life[i], age))
		var c := dm.get_instance_color(i)
		c.a = fade * 0.45
		dm.set_instance_color(i, c)
		var s := 0.0012 + 0.0012 * sin(i * 3.1) * sin(i * 3.1)
		dm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ONE * s), p))
