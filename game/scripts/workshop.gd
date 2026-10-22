class_name Workshop
extends Node3D
## Albert's workshop at dusk: a seated view of the lap, a work lamp, the lantern, the fire, the
## window. Units are metres. Everything here is set dressing apart from the surfaces things land on.

const INCH := 0.0254
const LAP_Y := 22.2 * INCH
const LAP_MIN := Vector2(-13 * INCH, -26 * INCH)
const LAP_MAX := Vector2(13 * INCH, -3 * INCH)

var camera: Camera3D
var work_light: SpotLight3D
var haze: FogVolume
var _fire: OmniLight3D
var _lantern: OmniLight3D
var _hearth: MeshInstance3D
var _t := 0.0
var _haze_level := 0.0


static func surface_height(x: float, z: float) -> float:
	if x > LAP_MIN.x and x < LAP_MAX.x and z > LAP_MIN.y and z < LAP_MAX.y:
		return LAP_Y
	return 0.0


func _ready() -> void:
	_build_environment()
	_build_room()
	_build_lights()
	_build_props()
	camera = Camera3D.new()
	camera.fov = 52.0
	camera.near = 0.02
	camera.far = 40.0
	camera.position = Vector3(0, 40 * INCH, 2 * INCH)
	add_child(camera)
	camera.look_at(Vector3(0, 30.5 * INCH, -15 * INCH))
	var attrs := CameraAttributesPractical.new()
	attrs.dof_blur_far_enabled = true
	attrs.dof_blur_far_distance = 1.4
	attrs.dof_blur_far_transition = 2.5
	attrs.dof_blur_amount = 0.06
	camera.attributes = attrs


func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("#120c08")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("#3a2a1e")
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.05
	env.ssao_enabled = true
	env.ssao_radius = 0.6
	env.ssao_intensity = 1.6
	env.ssil_enabled = true
	env.sdfgi_enabled = true
	env.sdfgi_use_occlusion = true
	env.sdfgi_cascades = 4
	env.sdfgi_min_cell_size = 0.05
	env.glow_enabled = true
	env.glow_intensity = 0.35
	env.glow_bloom = 0.04
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.012
	env.volumetric_fog_albedo = Color("#d8c3a5")
	env.volumetric_fog_anisotropy = 0.55
	env.volumetric_fog_length = 12.0
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.05
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


func _noise_tex(freq: float, normal: bool, seed: int, w := 512, h := 512) -> NoiseTexture2D:
	var n := FastNoiseLite.new()
	n.seed = seed
	n.frequency = freq
	n.fractal_octaves = 4
	var t := NoiseTexture2D.new()
	t.noise = n
	t.width = w
	t.height = h
	t.seamless = true
	t.as_normal_map = normal
	t.bump_strength = 2.0
	return t


func _planks(color: Color, boards: float, vertical: bool, scale_uv: Vector2) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/planks.gdshader")
	m.set_shader_parameter("base", color)
	m.set_shader_parameter("boards", boards)
	m.set_shader_parameter("vertical", vertical)
	m.set_shader_parameter("uv_scale", scale_uv)
	return m


func _box(size: Vector3, pos: Vector3, mat: Material, shadow := true) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


func _static_box(size: Vector3, pos: Vector3) -> void:
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = size
	cs.shape = sh
	body.add_child(cs)
	body.position = pos
	add_child(body)


func _build_room() -> void:
	var floor_m := _planks(Color("#5c3e28"), 8.0, false, Vector2(6, 6))
	var floor := MeshInstance3D.new()
	var fp := PlaneMesh.new()
	fp.size = Vector2(10, 10)
	floor.mesh = fp
	floor.material_override = floor_m
	add_child(floor)
	_static_box(Vector3(10, 0.2, 10), Vector3(0, -0.1, 0))

	var wall_m := _planks(Color("#3e3024"), 10.0, true, Vector2(5, 1))
	for w in [[Vector3(0, 1.5, -2.6), 0.0], [Vector3(-2.3, 1.5, -0.3), PI / 2], [Vector3(2.3, 1.5, -0.3), -PI / 2], [Vector3(0, 1.5, 2.1), PI]]:
		var mi := MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(6, 3)
		pm.orientation = PlaneMesh.FACE_Z
		mi.mesh = pm
		mi.material_override = wall_m
		mi.position = w[0]
		mi.rotation.y = w[1]
		add_child(mi)
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color("#1a120c")
	dark.roughness = 1.0
	_box(Vector3(6, 0.05, 6), Vector3(0, 3.05, -0.3), dark, false)
	var beam_m := StandardMaterial3D.new()
	beam_m.albedo_color = Color("#3a2618")
	beam_m.roughness = 0.9
	beam_m.albedo_texture = _noise_tex(0.02, false, 3, 256, 256)
	for i in range(-2, 3):
		_box(Vector3(0.15, 0.15, 6), Vector3(i * 1.0, 2.95, -0.3), beam_m)

	# Window with a dusk sky on the back wall.
	var sky := ShaderMaterial.new()
	sky.shader = load("res://shaders/window.gdshader")
	var win := MeshInstance3D.new()
	var wq := QuadMesh.new()
	wq.size = Vector2(0.8, 1.0)
	win.mesh = wq
	win.material_override = sky
	win.position = Vector3(-0.56, 1.58, -2.585)
	add_child(win)
	_box(Vector3(0.9, 0.04, 0.06), Vector3(-0.56, 1.58, -2.57), beam_m)
	_box(Vector3(0.04, 1.1, 0.06), Vector3(-0.56, 1.58, -2.57), beam_m)
	_box(Vector3(0.92, 1.12, 0.03), Vector3(-0.56, 1.58, -2.6), beam_m)

	# Fireplace on the right wall.
	var stone := StandardMaterial3D.new()
	stone.albedo_color = Color("#3a332e")
	stone.albedo_texture = _noise_tex(0.03, false, 9)
	stone.normal_enabled = true
	stone.normal_texture = _noise_tex(0.03, true, 9)
	stone.roughness = 1.0
	_box(Vector3(0.3, 1.2, 1.25), Vector3(2.15, 0.6, -1.0), stone)
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.albedo_color = Color("#ff8a3a")
	glow.emission_enabled = true
	glow.emission = Color("#ff7a30")
	glow.emission_energy_multiplier = 3.0
	_hearth = MeshInstance3D.new()
	var hq := QuadMesh.new()
	hq.size = Vector2(0.65, 0.4)
	_hearth.mesh = hq
	_hearth.material_override = glow
	_hearth.position = Vector3(1.995, 0.26, -1.0)
	_hearth.rotation.y = -PI / 2
	add_child(_hearth)

	# The whittler's lap: a leather apron over the knees.
	var leather := StandardMaterial3D.new()
	leather.albedo_color = Color("#5a3a24")
	leather.albedo_texture = _noise_tex(0.05, false, 21)
	leather.normal_enabled = true
	leather.normal_texture = _noise_tex(0.08, true, 22)
	leather.normal_scale = 0.4
	leather.roughness = 0.75
	var lap_size := Vector3(LAP_MAX.x - LAP_MIN.x, 0.025, LAP_MAX.y - LAP_MIN.y)
	var lap_pos := Vector3((LAP_MIN.x + LAP_MAX.x) / 2, LAP_Y - 0.0125, (LAP_MIN.y + LAP_MAX.y) / 2)
	_box(lap_size, lap_pos, leather)
	_static_box(lap_size, lap_pos)
	var trouser := StandardMaterial3D.new()
	trouser.albedo_color = Color("#3b2a20")
	trouser.roughness = 1.0
	_box(Vector3(lap_size.x - 0.02, 0.46, 0.1), Vector3(0, LAP_Y - 0.25, LAP_MIN.y + 0.04), trouser)


func _build_lights() -> void:
	work_light = SpotLight3D.new()
	work_light.light_color = Color("#ffd6a0")
	work_light.light_energy = 5.0
	work_light.spot_range = 3.0
	work_light.spot_angle = 30.0
	work_light.spot_angle_attenuation = 0.8
	work_light.shadow_enabled = true
	work_light.shadow_blur = 1.2
	work_light.light_size = 0.04
	work_light.light_volumetric_fog_energy = 1.4
	work_light.position = Vector3(-0.42, 1.48, -0.1)
	add_child(work_light)
	work_light.look_at(Vector3(0, 0.71, -0.38))

	_lantern = OmniLight3D.new()
	_lantern.light_color = Color("#ffb067")
	_lantern.light_energy = 0.9
	_lantern.omni_range = 2.2
	_lantern.position = Vector3(-0.61, 0.78, -0.56)
	add_child(_lantern)

	_fire = OmniLight3D.new()
	_fire.light_color = Color("#ff7a30")
	_fire.light_energy = 1.3
	_fire.omni_range = 5.0
	_fire.shadow_enabled = true
	_fire.position = Vector3(1.85, 0.32, -1.0)
	add_child(_fire)

	var window := DirectionalLight3D.new()
	window.light_color = Color("#8a8cc8")
	window.light_energy = 0.12
	window.rotation_degrees = Vector3(-25, 160, 0)
	add_child(window)

	# Local haze around the work area: thickens while sawing or sanding, so dust hangs in the beam.
	haze = FogVolume.new()
	haze.size = Vector3(0.9, 0.7, 0.9)
	haze.position = Vector3(0, 0.8, -0.38)
	var fm := FogMaterial.new()
	fm.density = 0.0
	fm.albedo = Color("#e8d6b8")
	fm.edge_fade = 0.6
	haze.material = fm
	add_child(haze)


func _build_props() -> void:
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color("#4a3020")
	wood.albedo_texture = _noise_tex(0.01, false, 31, 256, 256)
	wood.roughness = 0.8
	# Side table with the lantern.
	_box(Vector3(0.4, 0.04, 0.4), Vector3(-0.61, 0.66, -0.51), wood)
	for d in [Vector2(-0.15, -0.15), Vector2(0.15, -0.15), Vector2(-0.15, 0.15), Vector2(0.15, 0.15)]:
		_box(Vector3(0.035, 0.64, 0.035), Vector3(-0.61 + d.x, 0.32, -0.51 + d.y), wood)
	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color("#ffc77a")
	glass.emission_enabled = true
	glass.emission = Color("#ffb060")
	glass.emission_energy_multiplier = 2.0
	var lantern := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.045
	cyl.bottom_radius = 0.045
	cyl.height = 0.11
	lantern.mesh = cyl
	lantern.material_override = glass
	lantern.position = Vector3(-0.61, 0.75, -0.56)
	add_child(lantern)
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color("#2a2622")
	metal.metallic = 0.7
	metal.roughness = 0.45
	var cap := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.06
	cone.height = 0.05
	cap.mesh = cone
	cap.material_override = metal
	cap.position = Vector3(-0.61, 0.83, -0.56)
	add_child(cap)

	# Shelves on the left wall, lined with Albert's figurines.
	var fig := StandardMaterial3D.new()
	fig.albedo_color = Color("#d9bf8f")
	fig.roughness = 0.6
	for s in 2:
		var y := 1.22 + s * 0.46
		_box(Vector3(0.2, 0.03, 1.5), Vector3(-2.18, y, -1.0), wood)
		for j in 7:
			var f := MeshInstance3D.new()
			var cap_m := CapsuleMesh.new()
			cap_m.radius = 0.03 + (j % 3) * 0.008
			cap_m.height = 0.1 + (j % 4) * 0.03
			f.mesh = cap_m
			f.material_override = fig
			f.position = Vector3(-2.16, y + 0.015 + cap_m.height / 2, -1.65 + j * 0.2)
			add_child(f)

	# Autumn's chair by the window.
	var chair := StandardMaterial3D.new()
	chair.albedo_color = Color("#4a3a46")
	chair.roughness = 0.9
	_box(Vector3(0.6, 0.12, 0.55), Vector3(-1.2, 0.42, -2.1), chair)
	_box(Vector3(0.6, 0.6, 0.12), Vector3(-1.2, 0.75, -2.35), chair)
	_box(Vector3(0.1, 0.3, 0.55), Vector3(-1.48, 0.6, -2.1), chair)
	_box(Vector3(0.1, 0.3, 0.55), Vector3(-0.92, 0.6, -2.1), chair)


## Thicken the local haze (sawing/sanding); it relaxes back on its own.
func puff(amount: float) -> void:
	_haze_level = minf(1.0, _haze_level + amount)


func _process(delta: float) -> void:
	_t += delta
	var fl := 0.8 + 0.12 * sin(_t * 7.3) + 0.08 * sin(_t * 13.1 + 1.7) + 0.05 * sin(_t * 23.7)
	_fire.light_energy = 1.3 * fl
	(_hearth.material_override as StandardMaterial3D).emission_energy_multiplier = 2.5 + fl
	_lantern.light_energy = 0.9 + 0.04 * sin(_t * 5.1) + 0.03 * sin(_t * 11.3)
	_haze_level = maxf(0.0, _haze_level - delta * 0.12)
	(haze.material as FogMaterial).density = _haze_level * 0.8
