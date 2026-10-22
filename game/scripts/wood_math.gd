class_name WoodMath
extends RefCounted
## CPU mirror of shaders/wood_math.gdshaderinc (same hashes, same results), for code that needs
## the original log shape on the CPU: offcut hulls, saw-through tests, the low-res fallback.

const M32 := 0xFFFFFFFF

static func pcg(v: int) -> int:
	var state := (v * 747796405 + 2891336453) & M32
	var word := (((state >> ((state >> 28) + 4)) ^ state) * 277803737) & M32
	return ((word >> 22) ^ word) & M32

static func hash3(x: int, y: int, z: int, seed: int) -> float:
	var h := pcg((x & M32) ^ pcg((y & M32) ^ pcg((z & M32) ^ (seed & M32))))
	return float(h) / 4294967295.0

static func vnoise(p: Vector3, seed: int) -> float:
	var fl := p.floor()
	var ix := int(fl.x)
	var iy := int(fl.y)
	var iz := int(fl.z)
	var f := p - fl
	f = f * f * (Vector3(3, 3, 3) - 2.0 * f)
	var c000 := hash3(ix, iy, iz, seed)
	var c100 := hash3(ix + 1, iy, iz, seed)
	var c010 := hash3(ix, iy + 1, iz, seed)
	var c110 := hash3(ix + 1, iy + 1, iz, seed)
	var c001 := hash3(ix, iy, iz + 1, seed)
	var c101 := hash3(ix + 1, iy, iz + 1, seed)
	var c011 := hash3(ix, iy + 1, iz + 1, seed)
	var c111 := hash3(ix + 1, iy + 1, iz + 1, seed)
	return lerpf(lerpf(lerpf(c000, c100, f.x), lerpf(c010, c110, f.x), f.y),
		lerpf(lerpf(c001, c101, f.x), lerpf(c011, c111, f.x), f.y), f.z)

static func fbm(p: Vector3, seed: int) -> float:
	return (vnoise(p, seed) - 0.5) * 0.67 + (vnoise(p * 2.03, seed + 7) - 0.5) * 0.33

static func original_radius(y: float, theta: float, radius: float, len: float, seed: int) -> float:
	var c := cos(theta)
	var s := sin(theta)
	var wobble := fbm(Vector3(c * 1.3 + 11.0, s * 1.3, y * 0.22), seed) * 0.09 + sin(3.0 * theta + y * 0.15) * 0.012
	var taper := 1.0 - 0.025 * (y / len)
	return radius * taper * (1.0 + wobble)

static func log_sdf(p: Vector3, radius: float, len: float, seed: int) -> float:
	var half := len * 0.5
	var r := Vector2(p.x, p.z).length()
	var theta := atan2(p.z, p.x)
	var side := r - original_radius(p.y, theta, radius, len, seed)
	var top := p.y - (half - 0.04 * p.x + fbm(Vector3(p.x * 2.0, p.z * 2.0, 5.0), seed) * 0.05)
	var bot := -p.y - (half + 0.03 * p.z + fbm(Vector3(p.x * 2.0, p.z * 2.0, 9.0), seed) * 0.05)
	return maxf(side, maxf(top, bot))
