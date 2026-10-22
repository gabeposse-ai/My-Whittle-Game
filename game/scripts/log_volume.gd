class_name LogVolume
extends RefCounted
## The log as a signed distance field in a 3D texture on the GPU.
##
## Each texel stores the distance (in voxels) to the wood surface: negative inside, positive in air,
## clamped to ±CLAMP. Carving is CSG subtraction done by compute shaders; the log is drawn by
## sphere-tracing the same texture (log.gdshader), so nothing is ever converted to triangles.
##
## All RenderingDevice work runs on the render thread (RenderingServer.call_on_render_thread), and
## results come back to the main thread through call_deferred.

signal picked(results: Array) ## Array of {found, pos (grid), normal, tag}

const CLAMP := 4.0
const MAX_SEGS := 64
const MAX_RAYS := 8
const SEG_FLOATS := 20 # 5 × vec4

var rd: RenderingDevice
var dims: Vector3i
var vpi: float
var centre: Vector3
var radius: float
var length: float
var seed: int
var ok := false ## false when the renderer has no compute (Compatibility): see init_cpu_fallback()

var texture: Texture3D ## bound to the log material
var sdf := RID()
var snap := RID()
var scratch := RID()

var _sampler := RID()
var _shaders := {}
var _pipelines := {}
var _sets := {}
var _seg_buf := RID()
var _ray_buf := RID()
var _hit_buf := RID()

var _segs := PackedFloat32Array()
var _seg_count := 0
var _box_lo := Vector3i.ZERO
var _box_hi := Vector3i.ZERO
var _rays := PackedFloat32Array()
var _ray_tags: Array = []
var _sand_ops: Array = []


func _init(size: Dictionary, species: Dictionary, vpi_: float, seed_: int) -> void:
	vpi = vpi_
	radius = size.radius
	length = size.length
	seed = seed_ % 16000000
	var pad := 3
	var nxz := int(ceil(radius * 2.0 * 1.08 * vpi)) + pad * 2
	dims = Vector3i(nxz, int(ceil(length * vpi)) + pad * 2, nxz)
	centre = Vector3(dims - Vector3i.ONE) * 0.5
	rd = RenderingServer.get_rendering_device()
	ok = rd != null
	if ok:
		for n in ["log_init", "log_carve", "log_sand", "log_pick"]:
			var file: RDShaderFile = load("res://shaders/%s.glsl" % n)
			_spirv[n] = file.get_spirv()
		texture = Texture3DRD.new()
		RenderingServer.call_on_render_thread(_rt_setup)


# ------------------------------------------------------------------ coordinate helpers

func grid_to_local(g: Vector3) -> Vector3:
	return (g - centre) / vpi

func local_to_grid(p: Vector3) -> Vector3:
	return p * vpi + centre

## Local-space (inches) bounding box of the whole grid.
func local_aabb() -> AABB:
	var lo := grid_to_local(Vector3.ZERO)
	return AABB(lo, Vector3(dims - Vector3i.ONE) / vpi)


# ------------------------------------------------------------------ render-thread setup

var _spirv := {}

func _load_pipeline(name: String) -> void:
	var spirv: RDShaderSPIRV = _spirv[name]
	var sh := rd.shader_create_from_spirv(spirv)
	_shaders[name] = sh
	_pipelines[name] = rd.compute_pipeline_create(sh)

func _make_volume() -> RID:
	var fmt := RDTextureFormat.new()
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	fmt.format = RenderingDevice.DATA_FORMAT_R16_SFLOAT
	fmt.width = dims.x
	fmt.height = dims.y
	fmt.depth = dims.z
	fmt.usage_bits = (RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT)
	return rd.texture_create(fmt, RDTextureView.new(), [])

func _image_uniform(binding: int, tex: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = binding
	u.add_id(tex)
	return u

func _buffer_uniform(binding: int, buf: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(buf)
	return u

func _sampler_uniform(binding: int, tex: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = binding
	u.add_id(_sampler)
	u.add_id(tex)
	return u

func _rt_setup() -> void:
	for n in ["log_init", "log_carve", "log_sand", "log_pick"]:
		_load_pipeline(n)
	sdf = _make_volume()
	snap = _make_volume()
	scratch = _make_volume()
	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = rd.sampler_create(ss)
	_seg_buf = rd.storage_buffer_create(MAX_SEGS * SEG_FLOATS * 4)
	_ray_buf = rd.storage_buffer_create(MAX_RAYS * 8 * 4)
	_hit_buf = rd.storage_buffer_create(MAX_RAYS * 8 * 4)
	_sets.init = rd.uniform_set_create([_image_uniform(0, sdf)], _shaders.log_init, 0)
	_sets.carve = rd.uniform_set_create([_image_uniform(0, sdf), _buffer_uniform(1, _seg_buf)], _shaders.log_carve, 0)
	_sets.sand = rd.uniform_set_create([_image_uniform(0, sdf), _image_uniform(1, scratch)], _shaders.log_sand, 0)
	_sets.pick_live = rd.uniform_set_create([_sampler_uniform(0, sdf), _buffer_uniform(1, _ray_buf), _buffer_uniform(2, _hit_buf)], _shaders.log_pick, 0)
	_sets.pick_snap = rd.uniform_set_create([_sampler_uniform(0, snap), _buffer_uniform(1, _ray_buf), _buffer_uniform(2, _hit_buf)], _shaders.log_pick, 0)

	# Fill with the uncarved log.
	var pc := PackedFloat32Array([
		dims.x, dims.y, dims.z, vpi,
		centre.x, centre.y, centre.z, CLAMP,
		radius, length, 0.0, float(seed),
	]).to_byte_array()
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, _pipelines.log_init)
	rd.compute_list_bind_uniform_set(cl, _sets.init, 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, ceili(dims.x / 8.0), ceili(dims.y / 8.0), ceili(dims.z / 8.0))
	rd.compute_list_end()
	rd.texture_copy(sdf, snap, Vector3.ZERO, Vector3.ZERO, Vector3(dims), 0, 0, 0, 0)
	(texture as Texture3DRD).texture_rd_rid = sdf


# ------------------------------------------------------------------ queueing work (main thread)

## Add one cutter segment. `box_lo`/`box_hi` bound its effect (grid, inclusive).
func queue_segment(seg: PackedFloat32Array, box_lo: Vector3i, box_hi: Vector3i) -> void:
	if not ok:
		_cpu_carve(seg, box_lo, box_hi)
		return
	if _seg_count >= MAX_SEGS:
		flush()
	if _seg_count == 0:
		_box_lo = box_lo
		_box_hi = box_hi
	else:
		_box_lo = _box_lo.min(box_lo)
		_box_hi = _box_hi.max(box_hi)
	_segs.append_array(seg)
	_seg_count += 1

## Ask for a raycast against the live (or stroke-start) surface; answered via `picked`.
func queue_ray(origin: Vector3, dir: Vector3, tag: Variant) -> void:
	if not ok:
		_cpu_pick(origin, dir, tag)
		return
	if _ray_tags.size() >= MAX_RAYS:
		return
	_rays.append_array([origin.x, origin.y, origin.z, 0.0, dir.x, dir.y, dir.z, 0.0])
	_ray_tags.append(tag)

var pick_frozen := false

func queue_sand(centre_g: Vector3, radius_v: float, weight: float, shave: float) -> void:
	if ok:
		_sand_ops.append([centre_g, radius_v, weight, shave])
	else:
		_cpu_sand(centre_g, radius_v, weight, shave)

## Push everything queued this frame to the GPU.
func flush() -> void:
	if not ok:
		_cpu_upload()
		return
	if _seg_count > 0:
		var lo := _box_lo.clamp(Vector3i.ZERO, dims - Vector3i.ONE)
		var hi := _box_hi.clamp(Vector3i.ZERO, dims - Vector3i.ONE)
		if hi.x >= lo.x and hi.y >= lo.y and hi.z >= lo.z:
			RenderingServer.call_on_render_thread(_rt_carve.bind(_segs.duplicate(), _seg_count, lo, hi))
		_segs.clear()
		_seg_count = 0
	if not _sand_ops.is_empty():
		RenderingServer.call_on_render_thread(_rt_sand.bind(_sand_ops.duplicate()))
		_sand_ops.clear()
	if not _ray_tags.is_empty():
		RenderingServer.call_on_render_thread(_rt_pick.bind(_rays.duplicate(), _ray_tags.duplicate(), pick_frozen))
		_rays.clear()
		_ray_tags.clear()


# ------------------------------------------------------------------ render-thread work

func _rt_carve(segs: PackedFloat32Array, count: int, lo: Vector3i, hi: Vector3i) -> void:
	var size := hi - lo + Vector3i.ONE
	rd.buffer_update(_seg_buf, 0, segs.size() * 4, segs.to_byte_array())
	var pc := PackedByteArray()
	pc.resize(64)
	pc.encode_s32(0, lo.x); pc.encode_s32(4, lo.y); pc.encode_s32(8, lo.z); pc.encode_s32(12, 0)
	pc.encode_s32(16, size.x); pc.encode_s32(20, size.y); pc.encode_s32(24, size.z); pc.encode_s32(28, 0)
	pc.encode_s32(32, count); pc.encode_s32(36, int(CLAMP * 1000.0)); pc.encode_s32(40, 0); pc.encode_s32(44, 0)
	pc.encode_float(48, vpi); pc.encode_float(52, 0.0); pc.encode_float(56, 0.0); pc.encode_float(60, 0.0)
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, _pipelines.log_carve)
	rd.compute_list_bind_uniform_set(cl, _sets.carve, 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, ceili(size.x / 8.0), ceili(size.y / 8.0), ceili(size.z / 8.0))
	rd.compute_list_end()

func _rt_sand(ops: Array) -> void:
	for op in ops:
		var c: Vector3 = op[0]
		var r: float = op[1]
		var lo := Vector3i((c - Vector3.ONE * (r + 1.0)).floor()).clamp(Vector3i.ONE, dims - Vector3i(2, 2, 2))
		var hi := Vector3i((c + Vector3.ONE * (r + 1.0)).ceil()).clamp(Vector3i.ONE, dims - Vector3i(2, 2, 2))
		var size := hi - lo + Vector3i.ONE
		if size.x <= 0 or size.y <= 0 or size.z <= 0:
			continue
		# Copy the region (plus a one-voxel border for neighbour reads) into scratch.
		var clo := lo - Vector3i.ONE
		rd.texture_copy(sdf, scratch, Vector3(clo), Vector3(clo), Vector3(size + Vector3i(2, 2, 2)), 0, 0, 0, 0)
		var pc := PackedByteArray()
		pc.resize(64)
		pc.encode_s32(0, lo.x); pc.encode_s32(4, lo.y); pc.encode_s32(8, lo.z)
		pc.encode_s32(16, size.x); pc.encode_s32(20, size.y); pc.encode_s32(24, size.z)
		pc.encode_float(32, c.x); pc.encode_float(36, c.y); pc.encode_float(40, c.z); pc.encode_float(44, r)
		pc.encode_float(48, op[2]); pc.encode_float(52, op[3])
		var cl := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl, _pipelines.log_sand)
		rd.compute_list_bind_uniform_set(cl, _sets.sand, 0)
		rd.compute_list_set_push_constant(cl, pc, pc.size())
		rd.compute_list_dispatch(cl, ceili(size.x / 8.0), ceili(size.y / 8.0), ceili(size.z / 8.0))
		rd.compute_list_end()

func _rt_pick(rays: PackedFloat32Array, tags: Array, frozen: bool) -> void:
	var n := tags.size()
	rd.buffer_update(_ray_buf, 0, rays.size() * 4, rays.to_byte_array())
	var pc := PackedFloat32Array([dims.x, dims.y, dims.z, float(n)]).to_byte_array()
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, _pipelines.log_pick)
	rd.compute_list_bind_uniform_set(cl, _sets.pick_snap if frozen else _sets.pick_live, 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, 1, 1, 1)
	rd.compute_list_end()
	rd.buffer_get_data_async(_hit_buf, _rt_hits_ready.bind(tags), 0, n * 32)

func _rt_hits_ready(data: PackedByteArray, tags: Array) -> void:
	var f := data.to_float32_array()
	var out: Array = []
	for i in tags.size():
		var b := i * 8
		out.append({
			"found": f[b + 3] > 0.5,
			"pos": Vector3(f[b], f[b + 1], f[b + 2]),
			"normal": Vector3(f[b + 4], f[b + 5], f[b + 6]),
			"tag": tags[i],
		})
	picked.emit.call_deferred(out)


# ------------------------------------------------------------------ snapshots, undo, offcuts

## Freeze the current surface (knife strokes ride on it; also the undo source).
func snapshot() -> void:
	if not ok:
		_cpu_snap = _cpu.duplicate()
	if ok:
		RenderingServer.call_on_render_thread(func(): rd.texture_copy(sdf, snap, Vector3.ZERO, Vector3.ZERO, Vector3(dims), 0, 0, 0, 0))

## Save the stroke-start contents of a grid box so it can be restored. Returns an undo handle.
func capture_undo(lo: Vector3i, hi: Vector3i) -> Dictionary:
	lo = lo.clamp(Vector3i.ZERO, dims - Vector3i.ONE)
	hi = hi.clamp(Vector3i.ZERO, dims - Vector3i.ONE)
	var size := hi - lo + Vector3i.ONE
	var entry := {"lo": lo, "size": size, "rid": RID(), "bytes": size.x * size.y * size.z * 2}
	if not ok:
		entry.cpu = _cpu_region(_cpu_snap, lo, size)
	if ok:
		RenderingServer.call_on_render_thread(func():
			var fmt := RDTextureFormat.new()
			fmt.texture_type = RenderingDevice.TEXTURE_TYPE_3D
			fmt.format = RenderingDevice.DATA_FORMAT_R16_SFLOAT
			fmt.width = size.x
			fmt.height = size.y
			fmt.depth = size.z
			fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
			var rid := rd.texture_create(fmt, RDTextureView.new(), [])
			rd.texture_copy(snap, rid, Vector3(lo), Vector3.ZERO, Vector3(size), 0, 0, 0, 0)
			entry.rid = rid)
	return entry

func restore_undo(entry: Dictionary) -> void:
	if not ok and entry.has("cpu"):
		_cpu_write_region(entry.cpu, entry.lo, entry.size)
		_cpu_dirty = true
		_cpu_upload()
	if ok:
		RenderingServer.call_on_render_thread(func():
			if entry.rid.is_valid():
				rd.texture_copy(entry.rid, sdf, Vector3.ZERO, Vector3(entry.lo), Vector3(entry.size), 0, 0, 0, 0)
				rd.free_rid(entry.rid)
				entry.rid = RID())

func drop_undo(entry: Dictionary) -> void:
	if ok:
		RenderingServer.call_on_render_thread(func():
			if entry.rid.is_valid():
				rd.free_rid(entry.rid)
				entry.rid = RID())

## Copy the whole field into a new texture (for an offcut that is about to fall away).
func clone_texture() -> Texture3D:
	if not ok:
		return _cpu_clone()
	var tex := Texture3DRD.new()
	if ok:
		RenderingServer.call_on_render_thread(func():
			var rid := _make_volume()
			rd.texture_copy(sdf, rid, Vector3.ZERO, Vector3.ZERO, Vector3(dims), 0, 0, 0, 0)
			tex.texture_rd_rid = rid)
	return tex

func free_texture(tex: Texture3D) -> void:
	if ok and tex is Texture3DRD:
		RenderingServer.call_on_render_thread(func():
			var rid: RID = (tex as Texture3DRD).texture_rd_rid
			(tex as Texture3DRD).texture_rd_rid = RID()
			if rid.is_valid():
				rd.free_rid(rid))

func dispose() -> void:
	if not ok:
		return
	RenderingServer.call_on_render_thread(func():
		(texture as Texture3DRD).texture_rd_rid = RID()
		for rid in [_seg_buf, _ray_buf, _hit_buf, sdf, snap, scratch, _sampler]:
			if rid.is_valid():
				rd.free_rid(rid)
		for sh in _shaders.values():
			rd.free_rid(sh))


# ------------------------------------------------------------------ CPU backend (Compatibility renderer, tests)
# A low-resolution mirror of the compute path: same cutter maths as log_carve.glsl, run in
# GDScript, uploaded as an ImageTexture3D. Lets the whole stroke pipeline run without compute.

var _cpu := PackedFloat32Array()
var _cpu_snap := PackedFloat32Array()
var _cpu_dirty := false

func init_cpu_fallback() -> void:
	_cpu.resize(dims.x * dims.y * dims.z)
	for z in dims.z:
		for y in dims.y:
			for x in dims.x:
				var p := grid_to_local(Vector3(x, y, z))
				_cpu[x + dims.x * (y + dims.y * z)] = clampf(WoodMath.log_sdf(p, radius, length, seed) * vpi, -CLAMP, CLAMP)
	_cpu_snap = _cpu.duplicate()
	texture = _cpu_build_texture(_cpu)

func _cpu_build_texture(data: PackedFloat32Array) -> ImageTexture3D:
	var tex := ImageTexture3D.new()
	tex.create(Image.FORMAT_RH, dims.x, dims.y, dims.z, false, _cpu_images(data))
	return tex

func _cpu_images(data: PackedFloat32Array) -> Array[Image]:
	var imgs: Array[Image] = []
	var slice := dims.x * dims.y
	for z in dims.z:
		var img := Image.create_from_data(dims.x, dims.y, false, Image.FORMAT_RF, data.slice(z * slice, (z + 1) * slice).to_byte_array())
		img.convert(Image.FORMAT_RH)
		imgs.append(img)
	return imgs

func _cpu_upload() -> void:
	if _cpu_dirty and texture is ImageTexture3D:
		(texture as ImageTexture3D).update(_cpu_images(_cpu))
		_cpu_dirty = false

func _cpu_clone() -> Texture3D:
	return _cpu_build_texture(_cpu)

func _cpu_sample(x: float, y: float, z: float, src: PackedFloat32Array) -> float:
	var x0 := floori(x)
	var y0 := floori(y)
	var z0 := floori(z)
	if x0 < 0 or y0 < 0 or z0 < 0 or x0 >= dims.x - 1 or y0 >= dims.y - 1 or z0 >= dims.z - 1:
		return CLAMP
	var fx := x - x0
	var fy := y - y0
	var fz := z - z0
	var nx := dims.x
	var nxy := dims.x * dims.y
	var i := x0 + nx * y0 + nxy * z0
	var c00 := lerpf(src[i], src[i + 1], fx)
	var c10 := lerpf(src[i + nx], src[i + nx + 1], fx)
	var c01 := lerpf(src[i + nxy], src[i + nxy + 1], fx)
	var c11 := lerpf(src[i + nxy + nx], src[i + nxy + nx + 1], fx)
	return lerpf(lerpf(c00, c10, fy), lerpf(c01, c11, fy), fz)

func _cpu_pick(o: Vector3, d: Vector3, tag: Variant) -> void:
	var src := _cpu_snap if pick_frozen else _cpu
	var res := {"found": false, "pos": Vector3.ZERO, "normal": Vector3.UP, "tag": tag}
	var lo := Vector3.ONE
	var hi := Vector3(dims) - Vector3(2, 2, 2)
	var t0 := 0.0
	var t1 := INF
	for a in 3:
		if absf(d[a]) < 1e-9:
			if o[a] < lo[a] or o[a] > hi[a]:
				picked.emit.call_deferred([res])
				return
		else:
			var ta := (lo[a] - o[a]) / d[a]
			var tb := (hi[a] - o[a]) / d[a]
			t0 = maxf(t0, minf(ta, tb))
			t1 = minf(t1, maxf(ta, tb))
	if t0 <= t1:
		var t := t0
		var v := _cpu_sample(o.x + d.x * t, o.y + d.y * t, o.z + d.z * t, src)
		if v >= 0.0:
			for k in 400:
				var pt := t
				t += maxf(0.3, v * 0.8)
				if t > t1:
					break
				var p := o + d * t
				v = _cpu_sample(p.x, p.y, p.z, src)
				if v < 0.0:
					var a := pt
					var b := t
					for j in 10:
						var m := 0.5 * (a + b)
						var q := o + d * m
						if _cpu_sample(q.x, q.y, q.z, src) < 0.0:
							b = m
						else:
							a = m
					var g := o + d * a
					var h := 0.75
					var n := Vector3(
						_cpu_sample(g.x + h, g.y, g.z, src) - _cpu_sample(g.x - h, g.y, g.z, src),
						_cpu_sample(g.x, g.y + h, g.z, src) - _cpu_sample(g.x, g.y - h, g.z, src),
						_cpu_sample(g.x, g.y, g.z + h, src) - _cpu_sample(g.x, g.y, g.z - h, src)).normalized()
					res = {"found": true, "pos": g, "normal": n, "tag": tag}
					break
	picked.emit.call_deferred([res])

## Mirror of seg_dist() in log_carve.glsl.
func _cpu_seg_dist(s: PackedFloat32Array, g: Vector3) -> float:
	var kind := int(s[7] + 0.5)
	var a := Vector3(s[0], s[1], s[2])
	var n := Vector3(s[8], s[9], s[10])
	var t := Vector3(s[12], s[13], s[14])
	var pin := g / vpi
	if kind == 0 or kind == 1:
		var b := Vector3(s[4], s[5], s[6])
		var ab := b - a
		var pa := g - a
		var hh := clampf(pa.dot(ab) / maxf(ab.dot(ab), 1e-6), 0.0, 1.0)
		var dd: float
		var k := 1.0
		if kind == 0:
			dd = (pa - ab * hh).length() - s[3]
		else:
			k = 0.6
			var side := t.cross(n).normalized()
			var q := pa - ab * hh
			dd = maxf(maxf(absf(q.dot(side)) * s[16] - q.dot(n) * s[17], absf(q.dot(t)) - 0.2), -q.dot(n))
		if s[11] > 0.0:
			dd -= s[11] * k * WoodMath.vnoise(Vector3(pin.x * 6.0, pin.y * 1.2, pin.z * 6.0), 17)
		if s[15] > 0.0:
			dd -= s[15] * k * WoodMath.vnoise(pin * 14.0, 5)
		return dd
	if kind == 2:
		var pa := g - a
		return maxf(absf(pa.dot(t)) - s[16], -pa.dot(n) - s[17])
	return -(n.dot(g) + s[3])

func _cpu_carve(seg: PackedFloat32Array, lo: Vector3i, hi: Vector3i) -> void:
	lo = lo.clamp(Vector3i.ZERO, dims - Vector3i.ONE)
	hi = hi.clamp(Vector3i.ZERO, dims - Vector3i.ONE)
	var kind := int(seg[7] + 0.5)
	for z in range(lo.z, hi.z + 1):
		for y in range(lo.y, hi.y + 1):
			for x in range(lo.x, hi.x + 1):
				var i := x + dims.x * (y + dims.y * z)
				var f := _cpu[i]
				if f >= CLAMP:
					continue
				if kind == 2 or kind == 3:
					pass
				var nf := maxf(f, -_cpu_seg_dist(seg, Vector3(x, y, z)))
				if nf > f:
					_cpu[i] = minf(nf, CLAMP)
					_cpu_dirty = true

func _cpu_sand(c: Vector3, r: float, weight: float, shave: float) -> void:
	var lo := Vector3i((c - Vector3.ONE * (r + 1.0)).floor()).clamp(Vector3i.ONE, dims - Vector3i(2, 2, 2))
	var hi := Vector3i((c + Vector3.ONE * (r + 1.0)).ceil()).clamp(Vector3i.ONE, dims - Vector3i(2, 2, 2))
	var src := _cpu.duplicate()
	var nx := dims.x
	var nxy := dims.x * dims.y
	for z in range(lo.z, hi.z + 1):
		for y in range(lo.y, hi.y + 1):
			for x in range(lo.x, hi.x + 1):
				var i := x + nx * y + nxy * z
				var f := src[i]
				if absf(f) > 2.5:
					continue
				var rr := Vector3(x, y, z).distance_to(c) / r
				if rr >= 1.0:
					continue
				var avg := (src[i + 1] + src[i - 1] + src[i + nx] + src[i - nx] + src[i + nxy] + src[i - nxy]) / 6.0
				var w := (1.0 - rr * rr) * weight
				_cpu[i] = maxf(f, f + (avg - f) * w + shave * w)
				_cpu_dirty = true

func _cpu_region(src: PackedFloat32Array, lo: Vector3i, size: Vector3i) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for z in size.z:
		for y in size.y:
			var row := (lo.x) + dims.x * ((lo.y + y) + dims.y * (lo.z + z))
			out.append_array(src.slice(row, row + size.x))
	return out

func _cpu_write_region(data: PackedFloat32Array, lo: Vector3i, size: Vector3i) -> void:
	var k := 0
	for z in size.z:
		for y in size.y:
			var row := (lo.x) + dims.x * ((lo.y + y) + dims.y * (lo.z + z))
			for x in size.x:
				_cpu[row + x] = data[k]
				k += 1
