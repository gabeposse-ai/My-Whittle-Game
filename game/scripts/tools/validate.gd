extends SceneTree
## Headless validation for CI: compiles every compute shader to SPIR-V and reloads every script.
## Exits non-zero on the first class of failure so a broken build never ships.

func _init() -> void:
	var failed := false
	for f in _files("res://shaders", ".glsl"):
		var sf: RDShaderFile = load(f)
		if sf == null:
			printerr("FAIL load ", f)
			failed = true
			continue
		var spv := sf.get_spirv()
		if spv.compile_error_compute != "":
			printerr("FAIL compile ", f, "\n", spv.compile_error_compute)
			failed = true
		else:
			print("ok   ", f)
	for f in _files("res://scripts", ".gd"):
		if f.ends_with("validate.gd"):
			continue
		var s: GDScript = load(f)
		if s == null or s.reload() != OK:
			printerr("FAIL script ", f)
			failed = true
		else:
			print("ok   ", f)
	for f in _files("res://shaders", ".gdshader"):
		var sh: Shader = load(f)
		if sh == null:
			printerr("FAIL shader ", f)
			failed = true
		else:
			print("ok   ", f)
	quit(1 if failed else 0)


func _files(dir: String, ext: String) -> Array:
	var out: Array = []
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for f in d.get_files():
		if f.ends_with(ext):
			out.append(dir.path_join(f))
	for sub in d.get_directories():
		out.append_array(_files(dir.path_join(sub), ext))
	return out
