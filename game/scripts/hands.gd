class_name Hands
extends Node3D
## Albert's hands and tools. The holding hand grips one end of the log (it lives in the log's
## local space, in inches, and turns with it). The carving hand holds the active tool, rests at the
## lower right, and puts the tool's edge on the cut while a stroke is in progress.

const INCH := 0.0254

var holding := Node3D.new() ## add to the log node (inches)
var carving := Node3D.new() ## world space
var _tool_root := Node3D.new()
var _engaged := false
var _target := Transform3D()
var _rest := Transform3D()
var _wrist: Node3D
var _camera: Camera3D
var _forearm := MeshInstance3D.new()
var _sleeve := MeshInstance3D.new()

var skin := StandardMaterial3D.new()
var sleeve := StandardMaterial3D.new()
var steel := StandardMaterial3D.new()
var dark_steel := StandardMaterial3D.new()
var handle_wood := StandardMaterial3D.new()
var handle_dark := StandardMaterial3D.new()
var brass := StandardMaterial3D.new()
var paper := StandardMaterial3D.new()


func _init() -> void:
	skin.albedo_color = Color("#c98f6c")
	skin.roughness = 0.55
	skin.subsurf_scatter_enabled = true
	skin.subsurf_scatter_strength = 0.35
	skin.rim_enabled = true
	skin.rim = 0.15
	sleeve.albedo_color = Color("#4b5a3c")
	sleeve.roughness = 0.95
	steel.albedo_color = Color("#c9ccd0")
	steel.metallic = 1.0
	steel.roughness = 0.26
	dark_steel.albedo_color = Color("#5a5f66")
	dark_steel.metallic = 0.9
	dark_steel.roughness = 0.42
	handle_wood.albedo_color = Color("#8a5a34")
	handle_wood.roughness = 0.45
	handle_dark.albedo_color = Color("#4a2e1a")
	handle_dark.roughness = 0.5
	brass.albedo_color = Color("#b08a4a")
	brass.metallic = 1.0
	brass.roughness = 0.35
	paper.albedo_color = Color("#c7a57a")
	paper.roughness = 1.0
	_tool_root.scale = Vector3.ONE * INCH
	carving.add_child(_tool_root)


func _ready() -> void:
	add_child(carving)
	var fa := CylinderMesh.new()
	fa.top_radius = 0.75 * INCH
	fa.bottom_radius = 0.95 * INCH
	fa.height = 1.0
	_forearm.mesh = fa
	_forearm.material_override = skin
	add_child(_forearm)
	var sl := CylinderMesh.new()
	sl.top_radius = 1.25 * INCH
	sl.bottom_radius = 1.6 * INCH
	sl.height = 1.0
	_sleeve.mesh = sl
	_sleeve.material_override = sleeve
	add_child(_sleeve)


# ------------------------------------------------------------------ building blocks (inches)

func _capsule(parent: Node3D, a: Vector3, b: Vector3, r: float, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = r
	cm.height = maxf(a.distance_to(b) + 2.0 * r, 2.0 * r + 0.001)
	cm.radial_segments = 16
	cm.rings = 6
	mi.mesh = cm
	mi.material_override = mat
	var dir := (b - a).normalized()
	mi.transform = Transform3D(Basis(Quaternion(Vector3.UP, dir)) if dir.length() > 0.0 and absf(dir.dot(Vector3.UP)) < 0.9999 else Basis(), (a + b) * 0.5)
	if dir.dot(Vector3.UP) < -0.9999:
		mi.transform.basis = Basis(Vector3.RIGHT, PI)
	parent.add_child(mi)
	return mi


func _cylinder(parent: Node3D, a: Vector3, b: Vector3, r0: float, r1: float, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = r1
	cm.bottom_radius = r0
	cm.height = a.distance_to(b)
	cm.radial_segments = 20
	mi.mesh = cm
	mi.material_override = mat
	var dir := (b - a).normalized()
	mi.transform = Transform3D(Basis(Quaternion(Vector3.UP, dir)), (a + b) * 0.5)
	parent.add_child(mi)
	return mi


## A knife blade: a wedge with a spine and a ground edge, tip at the origin, running along +z.
func _blade(parent: Node3D, length: float, height: float, thick: float, belly: float) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := 16
	var spine: Array[Vector3] = []
	var edge: Array[Vector3] = []
	for i in n + 1:
		var u := float(i) / n
		var z := u * length
		var tip := smoothstep(0.0, 0.35, u) # tip rises to a point
		var e_y := belly * (1.0 - u) * u * 2.0 * 0.0 + 0.0
		var s_y := height * tip
		spine.append(Vector3(0, s_y + e_y, z))
		edge.append(Vector3(0, e_y - belly * sin(u * PI) * 0.15, z))
	for side in [1.0, -1.0]:
		for i in n:
			var s0 := spine[i] + Vector3(side * thick * 0.5 * smoothstep(0.0, 0.3, float(i) / n), 0, 0)
			var s1 := spine[i + 1] + Vector3(side * thick * 0.5 * smoothstep(0.0, 0.3, float(i + 1) / n), 0, 0)
			var e0 := edge[i]
			var e1 := edge[i + 1]
			if side > 0:
				st.add_vertex(s0); st.add_vertex(e0); st.add_vertex(s1)
				st.add_vertex(s1); st.add_vertex(e0); st.add_vertex(e1)
			else:
				st.add_vertex(s0); st.add_vertex(s1); st.add_vertex(e0)
				st.add_vertex(s1); st.add_vertex(e1); st.add_vertex(e0)
	for i in n:
		var a0 := spine[i] + Vector3(thick * 0.5 * smoothstep(0.0, 0.3, float(i) / n), 0, 0)
		var a1 := spine[i + 1] + Vector3(thick * 0.5 * smoothstep(0.0, 0.3, float(i + 1) / n), 0, 0)
		var b0 := spine[i] - Vector3(thick * 0.5 * smoothstep(0.0, 0.3, float(i) / n), 0, 0)
		var b1 := spine[i + 1] - Vector3(thick * 0.5 * smoothstep(0.0, 0.3, float(i + 1) / n), 0, 0)
		st.add_vertex(a0); st.add_vertex(a1); st.add_vertex(b0)
		st.add_vertex(b0); st.add_vertex(a1); st.add_vertex(b1)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = steel
	parent.add_child(mi)


# ------------------------------------------------------------------ holding hand

## Fingers wrap the grip end of the log: palm on the left, fingers around the back to the front
## right, thumb across the front above them.
func build_holding(radius: float, length: float, grip_top: bool) -> void:
	for c in holding.get_children():
		c.queue_free()
	var g := Node3D.new()
	holding.add_child(g)
	var R := radius + 0.32
	var polar := func(a: float, r: float, y: float) -> Vector3: return Vector3(sin(a) * r, y, cos(a) * r)
	var palm_a := -PI / 2
	var phal := [1.25, 0.95, 0.75]
	for f in 4:
		var y := -0.95 + f * 0.62
		var a := palm_a - 0.18
		var r := R
		var p0: Vector3 = polar.call(a, r, y)
		var fr := 0.29 - f * 0.012
		var lens := phal.map(func(l): return l * (1.0 - f * 0.07))
		for j in 3:
			var da: float = lens[j] / r
			var p1: Vector3 = polar.call(a - da, r, y)
			_capsule(g, p0, p1, fr - j * 0.02, skin)
			p0 = p1
			a -= da
	_capsule(g, polar.call(palm_a, R + 0.25, -1.1), polar.call(palm_a, R + 0.25, 1.1), 0.62, skin)
	var t0: Vector3 = polar.call(palm_a + 0.25, R + 0.05, 1.3)
	var t1: Vector3 = polar.call(palm_a + 0.75, R + 0.02, 1.45)
	var t2: Vector3 = polar.call(palm_a + 1.2, R, 1.5)
	_capsule(g, t0, t1, 0.31, skin)
	_capsule(g, t1, t2, 0.27, skin)
	# Wrist stub; the forearm itself is drawn in world space toward the player (see _process).
	var w0: Vector3 = polar.call(palm_a + 0.3, R + 0.7, -1.2)
	_capsule(g, polar.call(palm_a, R + 0.3, -0.9), w0, 0.62, skin)
	_wrist = Node3D.new()
	_wrist.position = w0
	g.add_child(_wrist)
	g.position.y = (length / 2 - 1.3) if grip_top else (-length / 2 + 1.3)
	if grip_top:
		g.rotation.z = PI


# ------------------------------------------------------------------ tools + carving hand

func set_tool(id: String) -> void:
	for c in _tool_root.get_children():
		c.queue_free()
	var t := Node3D.new()
	_tool_root.add_child(t)
	var grip_z := 4.2
	match id:
		"sloyd":
			_blade(t, 2.4, 0.5, 0.07, 0.3)
			_cylinder(t, Vector3(0, 0.22, 2.35), Vector3(0, 0.22, 6.4), 0.42, 0.38, handle_wood)
		"detail":
			_blade(t, 1.1, 0.24, 0.05, 0.1)
			_cylinder(t, Vector3(0, 0.1, 1.05), Vector3(0, 0.1, 4.6), 0.36, 0.32, handle_wood)
			grip_z = 2.9
		"hook":
			var hook := Node3D.new()
			t.add_child(hook)
			for i in 7:
				var a0 := float(i) / 7.0 * PI * 1.1
				var a1 := float(i + 1) / 7.0 * PI * 1.1
				_capsule(hook, Vector3(0, sin(a0) * 0.32, 0.35 - cos(a0) * 0.32), Vector3(0, sin(a1) * 0.32, 0.35 - cos(a1) * 0.32), 0.04, steel)
			_capsule(t, Vector3(0, 0.0, 0.35), Vector3(0, 0.12, 1.5), 0.05, steel)
			_cylinder(t, Vector3(0, 0.12, 1.45), Vector3(0, 0.12, 5.4), 0.42, 0.38, handle_wood)
		"ugouge", "vgouge":
			_cylinder(t, Vector3(0, 0.05, 0.05), Vector3(0, 0.08, 2.8), 0.16, 0.12, steel)
			_cylinder(t, Vector3(0, 0.08, 2.8), Vector3(0, 0.08, 3.2), 0.24, 0.24, brass)
			var bulb := MeshInstance3D.new()
			var sm := SphereMesh.new()
			sm.radius = 0.6
			sm.height = 1.2
			bulb.mesh = sm
			bulb.material_override = handle_dark if id == "vgouge" else handle_wood
			bulb.scale = Vector3(1, 1, 2.3)
			bulb.position = Vector3(0, 0.08, 4.5)
			t.add_child(bulb)
			grip_z = 4.4
		"saw":
			var blade := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(0.025, 1.0, 8.0)
			blade.mesh = bm
			blade.material_override = steel
			blade.position = Vector3(0, 0.5, 4.0)
			t.add_child(blade)
			_cylinder(t, Vector3(0, 0.45, 8.0), Vector3(0, 0.45, 12.5), 0.42, 0.42, handle_dark)
			grip_z = 10.2
		"sand":
			var sheet := MeshInstance3D.new()
			var sb := BoxMesh.new()
			sb.size = Vector3(1.6, 0.12, 2.4)
			sheet.mesh = sb
			sheet.material_override = paper
			sheet.position = Vector3(0, 0.06, 0.8)
			t.add_child(sheet)
			grip_z = 1.0
	_carving_hand(t, grip_z, id == "sand")
	for mi in t.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON


func _carving_hand(t: Node3D, z: float, flat: bool) -> void:
	if flat:
		# Fingertips pressing the paper.
		for i in 4:
			var x := -0.55 + i * 0.37
			_capsule(t, Vector3(x, 0.35, 0.6), Vector3(x, 0.45, 1.8), 0.22, skin)
		_capsule(t, Vector3(0, 0.6, 2.0), Vector3(0, 0.9, 3.6), 0.75, skin)
		_capsule(t, Vector3(0, 0.9, 3.8), Vector3(0, 1.2, 7.0), 0.95, sleeve)
		return
	# Fist around the handle: four curled fingers below, thumb along the spine.
	for i in 4:
		var zz := z - 0.9 + i * 0.6
		var r := 0.55
		var prev := Vector3(0.45, 0.2, zz)
		for j in 3:
			var a := -0.3 - (j + 1) * 1.0
			var p := Vector3(cos(a) * r * 1.2, 0.2 + sin(a) * r, zz)
			_capsule(t, prev, p, 0.24 - j * 0.02, skin)
			prev = p
	_capsule(t, Vector3(0.55, 0.3, z - 1.2), Vector3(0.55, 0.3, z + 1.3), 0.7, skin) # palm
	_capsule(t, Vector3(0.1, 0.75, z - 1.0), Vector3(-0.05, 0.62, z - 2.0), 0.24, skin) # thumb
	_capsule(t, Vector3(0.7, 0.3, z + 1.6), Vector3(1.0, 0.0, z + 4.2), 0.75, skin) # wrist
	_capsule(t, Vector3(1.0, 0.0, z + 4.2), Vector3(1.3, -0.3, z + 7.5), 1.0, sleeve)


## Rest pose: lower right of the view, blade pointing in and away.
func set_rest(camera: Camera3D) -> void:
	_camera = camera
	var cam := camera.global_transform
	var p := cam * Vector3(0.17, -0.2, -0.42)
	var handle_dir := (cam.basis * Vector3(0.45, -0.6, 0.65)).normalized()
	_rest = Transform3D(Basis.looking_at(-handle_dir, cam.basis.y), p)
	if not _engaged:
		carving.global_transform = _rest


## Edge on the cut; handle off to the lower right so it never blocks the view of the blade.
func engage(tip: Vector3, normal: Vector3, camera: Camera3D) -> void:
	_engaged = true
	var cam := camera.global_transform.basis
	var handle_dir := (cam.x * 1.0 - cam.y * 0.55 + cam.z * 0.35 + normal * 0.35).normalized()
	_target = Transform3D(Basis.looking_at(-handle_dir, normal), tip)


func release() -> void:
	_engaged = false


func _place_segment(mi: MeshInstance3D, a: Vector3, b: Vector3) -> void:
	var d := b - a
	var l := d.length()
	if l < 1e-4:
		mi.visible = false
		return
	mi.visible = true
	var y := d / l
	var basis := Basis(Quaternion(Vector3.UP, y)) if y.dot(Vector3.UP) > -0.9999 else Basis(Vector3.RIGHT, PI)
	mi.global_transform = Transform3D(basis.scaled_local(Vector3(1, l, 1)), (a + b) * 0.5)


func _process(delta: float) -> void:
	if _wrist and is_instance_valid(_wrist) and _camera and holding.is_visible_in_tree():
		var a := _wrist.global_position
		var anchor := _camera.global_transform * Vector3(-0.2, -0.42, -0.05)
		var elbow := a.lerp(anchor, 0.45)
		_place_segment(_forearm, a, elbow)
		_place_segment(_sleeve, elbow - (elbow - a).normalized() * 0.01, anchor)
	else:
		_forearm.visible = false
		_sleeve.visible = false
	var k := 1.0 - exp(-delta * (28.0 if _engaged else 8.0))
	var tgt := _target if _engaged else _rest
	var cur := carving.global_transform
	var q := Quaternion(cur.basis.orthonormalized()).slerp(Quaternion(tgt.basis.orthonormalized()), k)
	carving.global_transform = Transform3D(Basis(q), cur.origin.lerp(tgt.origin, k))
