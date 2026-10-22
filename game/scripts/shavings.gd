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
			or absf(c.width - width) > maxf(0.08, c.width * 0.6) or c.len > c.break_len
		if changed:
			release_curl()
			c = {}
	if c.is_empty():
		var mi := MeshInstance3D.new()
		mi.material_override = curl_material
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		log_node.add_child(mi)
		var thick := maxf(0.012, depth * 0.55)
		# Tighter curls from thin cuts in soft wood; stiffer, harder woods curl looser.
		var r0 := 0.07 + thick * 2.2 + width * 0.04 + (1.0 - softness) * 0.07
		c = {
			"mesh": mi, "len": 0.0, "break_len": randf_range(1.1, 2.6), "grown_at": 0.0, "width": maxf(0.04, width), "thick": thick,
			"r0": r0, "stroke": stroke_id, "dir": t, "n": n, "root": p,
			"path": PackedVector3Array([p]), "path_len": PackedFloat32Array([0.0]),
			"wobble": randf() * 100.0, "pitch": randf_range(-0.25, 0.25),
		}
		_active = c
	var path: PackedVector3Array = c.path
	var plen: PackedFloat32Array = c.path_len
	var last: Vector3 = path[path.size() - 1]
	path.append(p)
	plen.append(plen[plen.size() - 1] + last.distance_to(p))
	c.path = path
	c.path_len = plen
	c.len += add * 0.9 # a shaving is a little shorter than the cut (it compresses as it curls)
	c.root = p
	c.grown_at = _time
	# The frame is fixed when the curl starts: once wood has curled, it keeps its shape.
	_build_attached(c)


## Radius of curvature at material coordinate m (inches from where the cut began): an Archimedean
## spiral, so each newer turn wraps just outside the older ones instead of passing through them.
func _curl_radius(c: Dictionary, m: float) -> float:
	var r0: float = c.r0
	return r0 + c.thick * 1.15 * m / (TAU * r0)


## Centreline of an attached curl in log-local inches. Built from the blade (newest material)
## back to the tip (oldest). Curvature is a function of the material coordinate, so the curled part
## keeps its shape as the shaving lengthens; the coil simply rolls as new wood feeds in at the edge.
func _attached_points(c: Dictionary) -> Dictionary:
	var x: Vector3 = c.dir
	var y: Vector3 = ((c.n as Vector3) - x * (c.n as Vector3).dot(x)).normalized()
	var z := x.cross(y).normalized()
	var L: float = maxf(c.len, 0.02)
	var ds := L / SEGS
	var pts := PackedVector3Array()
	var src := PackedVector3Array()
	var widths := PackedFloat32Array()
	var phi := PI * 0.6 # leaves the edge rising up the blade face
	var cx := 0.0
	var cy := 0.0
	var cz := 0.0
	var path: PackedVector3Array = c.path
	var plen: PackedFloat32Array = c.path_len
	var total: float = plen[plen.size() - 1]
	var root: Vector3 = c.root
	var turn := 0.0
	for i in SEGS + 1:
		var s := i * ds
		var m := L - s # material coordinate of this point
		pts.append(root + x * cx + y * (cy + 0.004) + z * cz)
		src.append(_path_at(path, plen, total - s / 0.9) - y * (c.thick as float) * 0.5)
		var u := s / L
		var taper := lerpf(1.0, 0.45, smoothstep(0.82, 1.0, u)) # thin tail where the cut began
		widths.append(c.width * taper * (1.0 + 0.06 * sin(m * 23.0 + c.wobble)))
		var k := ds / _curl_radius(c, m)
		phi -= k
		turn += k
		cx += cos(phi) * ds
		cy += sin(phi) * ds
		cz += (c.pitch as float) * (c.width as float) * k / TAU # slight helix from a skewed edge
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
		src: PackedVector3Array, thick: float, src_side: Vector3) -> ArrayMesh:
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
		var sp := src[i]
		for k in 8:
			var off := src_side * hw * (1.0 if k in [0, 2, 4, 5] else -1.0)
			custom[(b + k) * 4] = sp.x + off.x
			custom[(b + k) * 4 + 1] = sp.y + off.y
			custom[(b + k) * 4 + 2] = sp.z + off.z
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


## Let go of the curl being grown. It keeps its exact shape and becomes a light rigid body: it
## tumbles off the blade, bounces a little (wood is springy), and settles where it lands.
func release_curl() -> void:
	var c := _active
	if c.is_empty():
		return
	_active = {}
	var mi: MeshInstance3D = c.mesh
	if c.len < 0.08:
		mi.queue_free()
		return
	var log_node := mi.get_parent_node_3d()
	var xf := log_node.global_transform # includes the inch scale
	var d := _attached_points(c)
	var pts: PackedVector3Array = d.pts
	# Body origin at the curl's centroid (world, unscaled); mesh stays in inches under a scaled holder.
	var centroid := Vector3.ZERO
	for q in pts:
		centroid += xf * q
	centroid /= pts.size()
	var body := RigidBody3D.new()
	body.mass = 0.002
	body.gravity_scale = 1.0
	body.linear_damp = 1.6 # light, broad: air drag matters
	body.angular_damp = 1.2
	body.continuous_cd = true
	body.can_sleep = true
	var pm := PhysicsMaterial.new()
	pm.friction = 0.9
	pm.bounce = 0.3
	body.physics_material_override = pm
	add_child(body)
	body.global_transform = Transform3D(xf.basis.orthonormalized(), centroid)
	var holder := Node3D.new()
	body.add_child(holder)
	holder.global_transform = xf
	mi.reparent(holder, true)
	# Collision: convex hull of the ribbon's edges, sampled along its length.
	var side: Vector3 = d.side
	var w: PackedFloat32Array = d.w
	var hull := PackedVector3Array()
	var inv := body.global_transform.affine_inverse()
	for i in range(0, pts.size(), 3):
		for sgn in [-0.5, 0.5]:
			hull.append(inv * (xf * (pts[i] + side * w[i] * sgn)))
	var shape := ConvexPolygonShape3D.new()
	shape.points = hull
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	# Flicked off the edge: up and forward along the cut, with a gentle spin.
	var dir_w := (xf.basis * (c.dir as Vector3)).normalized()
	var up_w := (xf.basis * (c.n as Vector3)).normalized()
	body.linear_velocity = up_w * randf_range(0.06, 0.18) + dir_w * randf_range(0.02, 0.08)
	body.angular_velocity = Vector3(randf_range(-2.5, 2.5), randf_range(-2.5, 2.5), randf_range(-2.5, 2.5))
	# Curls only collide with the room, not each other: light bodies stacked on each other jitter.
	body.collision_layer = 2
	body.collision_mask = 1
	body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	_curls.append({"body": body, "stroke": c.stroke, "born": _time, "still": 0.0})
	while _curls.size() > MAX_CURLS:
		var old: Dictionary = _curls.pop_front()
		(old.body as Node).queue_free()


# ------------------------------------------------------------------ flakes and dust

## `src` is the log-local point (inches) the material came from; `grain` the world grain direction.
func spawn_flakes(stroke_id: int, p: Vector3, n: Vector3, grain: Vector3, count: int, size_in: float, src: Vector3) -> void:
	var mm := _flakes.multimesh
	for k in count:
		var i := _f_next
		_f_next = (_f_next + 1) % MAX_FLAKES
		_f_flying[i] = true
		_f_pos[i] = p + Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * 0.004
		_f_vel[i] = n * randf_range(0.25, 0.7) + Vector3(randf_range(-0.2, 0.2), randf_range(0.1, 0.45), randf_range(-0.2, 0.2))
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
			(b.body as Node).queue_free()
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
		(b.body as Node).queue_free()
	_curls.clear()
	var zero := Transform3D().scaled(Vector3.ZERO)
	for i in MAX_FLAKES:
		_f_state[i] = 0
		_flakes.multimesh.set_instance_transform(i, zero)
	_f_flying.clear()


func _process(delta: float) -> void:
	var dt := minf(delta, 1.0 / 30.0)
	_time += dt
	# A curl drops off the blade when the cut pauses (real shavings break off when pressure stops).
	if not _active.is_empty() and _time - (_active.grown_at as float) > 0.18:
		release_curl()
	# Settle: once a curl has been nearly still for a moment (or has been falling too long), pin it.
	for c in _curls:
		var b: RigidBody3D = c.body
		if b.freeze:
			continue
		var slow := b.linear_velocity.length() < 0.03 and b.angular_velocity.length() < 0.6
		c.still = (c.still + dt) if slow else 0.0
		if c.still > 0.25 or _time - (c.born as float) > 5.0:
			b.freeze = true

	var mm := _flakes.multimesh
	for i in _f_flying.keys():
		var v := _f_vel[i]
		v += GRAVITY * dt
		# Thin flakes catch a little air: mild drag, and a sideways drift that grows as they fall.
		v *= 1.0 - 1.8 * dt
		var p := _f_pos[i] + v * dt
		var r := _f_rot[i] + _f_spin[i] * dt
		var floor_y: float = surface_height.call(p.x, p.z) + _f_scale[i].y * 0.5
		if p.y < floor_y:
			p.y = floor_y
			if v.y < -0.35:
				# Wood clicks and hops once, losing most of its energy.
				v = Vector3(v.x * 0.4, -v.y * 0.22, v.z * 0.4)
				_f_spin[i] *= 0.35
			else:
				r.x = lerp_angle(r.x, 0.0, 1.0)
				r.z = lerp_angle(r.z, 0.0, 1.0)
				r.x = randf_range(-0.12, 0.12)
				r.z = randf_range(-0.12, 0.12)
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
