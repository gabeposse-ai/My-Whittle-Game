class_name Carver
extends RefCounted
## Turns strokes into cutter segments for the GPU, with grain-aware behaviour.
##
## All maths is in GRID space (voxels). The log axis, and therefore the grain, runs along +y.
## Per stroke segment, with tangent t projected onto the surface and outward normal n:
##   along     = |t·y|         1 = with the fibres, 0 = straight across them
##   end_grain = |n·y|         1 = slicing the end of the log (tough, slow)
##   uphill    = -(t·y)(n·y)   > 0 when the blade travels toward where fibres dive INTO the wood:
##               the edge follows them in and pries them out ahead of the blade (tear-out).
## These set the depth of cut, curls vs. flakes, and how torn the cut surface is.

signal cut(ev: Dictionary) ## shaving event: kind (curl/flake/dust), pos, t, n (grid), width, depth, seg_len (in), feel, volume (in³)
signal offcut(info: Dictionary) ## a sawn-through piece: plane (grid), grip_side

const KINDS := {"blade": 0.0, "vee": 1.0, "saw": 2.0, "half": 3.0}
const UNDO_BUDGET := 512 * 1024 * 1024

var vol: LogVolume
var softness := 1.0
var grip_top := false

var tool: Dictionary = {}
var active := false
var stroke_id := 0
var _last_pos := Vector3.ZERO
var _last_n := Vector3.UP
var _lo := Vector3i.ZERO
var _hi := Vector3i.ZERO
var _has_box := false
var _undo: Array = []
var _undo_bytes := 0
# Saw state
var _saw_origin := Vector3.ZERO
var _saw_normal := Vector3.UP
var _saw_plane := Vector3.ZERO
var _saw_depth := 0.0
var _saw_exit := INF
var _saw_done := false


func _init(volume: LogVolume, species: Dictionary) -> void:
	vol = volume
	softness = species.softness


func begin(t: Dictionary, hit: Dictionary) -> void:
	tool = t
	active = true
	stroke_id += 1
	_last_pos = hit.pos
	_last_n = hit.normal
	_has_box = false
	vol.snapshot()
	vol.pick_frozen = tool.kind == "blade" or tool.kind == "vee"
	_saw_origin = hit.pos
	_saw_normal = hit.normal
	_saw_plane = Vector3.ZERO
	_saw_depth = 0.0
	_saw_done = false


## Continue the stroke with a pick result. If the pointer slid off the wood, the stroke continues
## on the last tangent plane so the blade runs off the edge (how you take off a corner).
func move(hit: Dictionary, ray_o: Vector3, ray_d: Vector3, drag_dir: Vector3, travel_in: float) -> void:
	if not active:
		return
	if tool.kind == "saw":
		_move_saw(drag_dir, travel_in)
		return
	var pos: Vector3
	var n: Vector3
	if hit.found:
		pos = hit.pos
		n = hit.normal
	else:
		var denom := ray_d.dot(_last_n)
		if absf(denom) < 1e-4:
			return
		var tt := (_last_pos - ray_o).dot(_last_n) / denom
		if tt <= 0.0:
			return
		pos = ray_o + ray_d * tt
		n = _last_n
		if pos.distance_to(_last_pos) > vol.vpi * 1.5:
			return
	if tool.kind == "sand":
		_sand(pos, n)
		_last_pos = pos
		_last_n = n
		return
	var seg := pos - _last_pos
	var seg_len := seg.length()
	if seg_len < 0.6:
		return
	_cut_segment(_last_pos, _last_n, pos, n, seg, seg_len)
	_last_pos = pos
	_last_n = n


func _cut_segment(a: Vector3, na: Vector3, b: Vector3, nb: Vector3, seg: Vector3, seg_len: float) -> void:
	var n := (na + nb).normalized()
	var t := (seg - n * seg.dot(n)).normalized()
	if t == Vector3.ZERO:
		return
	var along := absf(t.y)
	var end_grain := smoothstep(0.65, 0.95, absf(n.y))
	var uphill := clampf(-t.y * n.y * 3.0, 0.0, 1.0)

	var depth_in: float = tool.depth * softness * (0.5 + 0.5 * along) * (1.0 - 0.55 * end_grain)
	if uphill > 0.3:
		depth_in *= 1.15 # the blade dives in
	var vpi := vol.vpi
	var dv := depth_in * vpi
	var tear_v := 0.0
	if uphill > 0.3:
		tear_v = (uphill - 0.3) * 1.3 * maxf(0.11, depth_in) * vpi
	var fuzz_v := (1.0 - along) * 0.03 * (1.0 - end_grain) * vpi

	var feel := "with"
	if end_grain > 0.6:
		feel = "end"
	elif uphill > 0.3:
		feel = "against"
	elif along < 0.45:
		feel = "across"

	var width_in: float
	var data := PackedFloat32Array()
	var pad: float
	if tool.kind == "vee":
		var half := deg_to_rad(32.0)
		width_in = 2.0 * depth_in * tan(half)
		var pa := a - n * dv
		var pb := b - n * dv
		data = PackedFloat32Array([
			pa.x, pa.y, pa.z, 0.0,
			pb.x, pb.y, pb.z, KINDS.vee,
			n.x, n.y, n.z, tear_v,
			t.x, t.y, t.z, fuzz_v,
			cos(half), sin(half), vpi, 0.0,
		])
		pad = dv * 2.5 + tear_v + 2.0
		_queue(data, pa, pb, pad)
	else:
		var r := maxf(tool.radius * vpi, dv * 1.05)
		width_in = 2.0 * sqrt(maxf(0.0, 2.0 * r * dv - dv * dv)) / vpi
		var off := r - dv
		var pa := a + n * off
		var pb := b + n * off
		data = PackedFloat32Array([
			pa.x, pa.y, pa.z, r,
			pb.x, pb.y, pb.z, KINDS.blade,
			n.x, n.y, n.z, tear_v,
			t.x, t.y, t.z, fuzz_v,
			0.0, 0.0, vpi, 0.0,
		])
		pad = r + tear_v + 1.5
		_queue(data, pa, pb, pad)

	var seg_in := seg_len / vpi
	var volume := width_in * depth_in * seg_in * (0.5 if tool.kind == "vee" else 0.67)
	var curl: bool = tool.curls and feel == "with" and along > 0.6
	cut.emit({
		"kind": "curl" if curl else "flake", "pos": b, "t": t, "n": n,
		"width": width_in, "depth": depth_in, "seg_len": seg_in, "feel": feel, "volume": volume,
	})


func _queue(data: PackedFloat32Array, a: Vector3, b: Vector3, pad: float) -> void:
	var lo := Vector3i((a.min(b) - Vector3.ONE * pad).floor())
	var hi := Vector3i((a.max(b) + Vector3.ONE * pad).ceil())
	_grow_box(lo, hi)
	vol.queue_segment(data, lo, hi)


func _grow_box(lo: Vector3i, hi: Vector3i) -> void:
	if not _has_box:
		_lo = lo
		_hi = hi
		_has_box = true
	else:
		_lo = _lo.min(lo)
		_hi = _hi.max(hi)


## Saw: the kerf is a thin slab through the start point that contains the surface normal and the
## drag direction. Hand travel deepens it; once it passes all the way through, the part not held
## in the hand falls away.
func _move_saw(drag_dir: Vector3, travel_in: float) -> void:
	if _saw_done:
		return
	var vpi := vol.vpi
	if _saw_plane == Vector3.ZERO:
		if drag_dir.length() < 1e-5:
			return
		var n := _saw_normal
		var tang := (drag_dir - n * drag_dir.dot(n)).normalized()
		if tang == Vector3.ZERO:
			return
		_saw_plane = tang.cross(n).normalized()
		_saw_exit = _through_distance(_saw_origin, -n)
	if travel_in <= 0.0:
		return
	_saw_depth += travel_in * 0.22 * softness
	var depth_v := _saw_depth * vpi
	var half_k := maxf(0.04 * vpi, 0.75)
	var o := _saw_origin
	var data := PackedFloat32Array([
		o.x, o.y, o.z, 0.0,
		0.0, 0.0, 0.0, KINDS.saw,
		_saw_normal.x, _saw_normal.y, _saw_normal.z, 0.0,
		_saw_plane.x, _saw_plane.y, _saw_plane.z, 0.0,
		half_k, depth_v, vpi, 0.0,
	])
	# The kerf can reach anywhere in the plane: cover the whole grid.
	_grow_box(Vector3i.ZERO, vol.dims - Vector3i.ONE)
	vol.queue_segment(data, Vector3i.ZERO, vol.dims - Vector3i.ONE)
	var dust_at := o - _saw_normal * minf(depth_v, _saw_exit)
	cut.emit({
		"kind": "dust", "pos": dust_at, "t": _saw_plane, "n": _saw_normal,
		"width": 0.08, "depth": 0.0, "seg_len": travel_in, "feel": "saw", "volume": 0.08 * travel_in * 0.22 * radius_in() * 1.5,
	})
	if depth_v >= _saw_exit:
		_saw_done = true
		_sever(_saw_origin, _saw_plane)


func radius_in() -> float:
	return vol.radius


## Grid distance from `o` along `dir` until leaving the original log (cylinder ∩ end slab).
func _through_distance(o: Vector3, dir: Vector3) -> float:
	var c := vol.centre
	var r := vol.radius * 1.12 * vol.vpi
	var ox := o.x - c.x
	var oz := o.z - c.z
	var a := dir.x * dir.x + dir.z * dir.z
	var s_cyl := INF
	if a > 1e-6:
		var b := 2.0 * (ox * dir.x + oz * dir.z)
		var cc := ox * ox + oz * oz - r * r
		var disc := b * b - 4.0 * a * cc
		if disc >= 0.0:
			s_cyl = (-b + sqrt(disc)) / (2.0 * a)
	var half := vol.length * 0.5 * vol.vpi + 2.0
	var s_y := INF
	if absf(dir.y) > 1e-6:
		var y0 := o.y - c.y
		s_y = maxf((half - y0) / dir.y, (-half - y0) / dir.y)
	return minf(s_cyl, s_y)


func _sever(o: Vector3, plane_n: Vector3) -> void:
	# Keep the side that holds the grip; everything on the other side of the kerf falls.
	var grip_local := Vector3(0, (vol.length * 0.5 - 1.2) * (1.0 if grip_top else -1.0), 0)
	var grip_g := vol.local_to_grid(grip_local)
	var side := signf((grip_g - o).dot(plane_n))
	if side == 0.0:
		side = 1.0
	# Removed region: dot(-side*plane_n, g - o) > 0  →  dot(N, g) + w > 0 with N = -side*plane_n.
	var nn := -side * plane_n
	var w := -nn.dot(o)
	offcut.emit({"normal": nn, "w": w, "stroke": stroke_id})


## Remove everything on one side of a plane (called by main after the offcut copy is made).
func remove_half_space(nn: Vector3, w: float) -> void:
	var data := PackedFloat32Array([
		0.0, 0.0, 0.0, w,
		0.0, 0.0, 0.0, KINDS.half,
		nn.x, nn.y, nn.z, 0.0,
		0.0, 0.0, 0.0, 0.0,
		0.0, 0.0, vol.vpi, 0.0,
	])
	_grow_box(Vector3i.ZERO, vol.dims - Vector3i.ONE)
	vol.queue_segment(data, Vector3i.ZERO, vol.dims - Vector3i.ONE)


func _sand(pos: Vector3, n: Vector3) -> void:
	var r: float = tool.radius * vol.vpi
	vol.queue_sand(pos, r, 0.35 + 0.25 * softness, 0.0015 * vol.vpi)
	var rr := Vector3.ONE * (r + 2.0)
	_grow_box(Vector3i((pos - rr).floor()), Vector3i((pos + rr).ceil()))
	cut.emit({
		"kind": "dust", "pos": pos, "t": Vector3.RIGHT, "n": n,
		"width": 0.02, "depth": 0.0, "seg_len": 0.0, "feel": "sand", "volume": 0.0004,
	})


## Finish the stroke and record undo. Returns the stroke id, or -1 if nothing changed.
func end() -> int:
	if not active:
		return -1
	active = false
	vol.pick_frozen = false
	vol.flush()
	if not _has_box:
		return -1
	var entry := vol.capture_undo(_lo - Vector3i.ONE, _hi + Vector3i.ONE)
	entry.stroke = stroke_id
	_undo.append(entry)
	_undo_bytes += entry.bytes
	while _undo.size() > 40 or (_undo_bytes > UNDO_BUDGET and _undo.size() > 1):
		var old: Dictionary = _undo.pop_front()
		_undo_bytes -= old.bytes
		vol.drop_undo(old)
	return stroke_id


func can_undo() -> bool:
	return not _undo.is_empty()


## Restore the last stroke. Returns its stroke id (so its shavings and offcuts can be removed).
func undo() -> int:
	if active or _undo.is_empty():
		return -1
	var e: Dictionary = _undo.pop_back()
	_undo_bytes -= e.bytes
	vol.restore_undo(e)
	return e.stroke
