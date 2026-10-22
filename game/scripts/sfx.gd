class_name Sfx
extends Node
## Placeholder synthesised audio until recorded foley exists: filtered noise shaped by the cut,
## a rhythmic rasp for the saw, a soft scrub for sandpaper, and a quiet crackling fire.

const RATE := 44100.0

var muted := false
var _player := AudioStreamPlayer.new()
var _pb: AudioStreamGeneratorPlayback
var _cut_target := 0.0
var _cut_gain := 0.0
var _cut_freq := 2400.0
var _rough := 0.0
var _saw_target := 0.0
var _saw_gain := 0.0
var _sand_target := 0.0
var _sand_gain := 0.0
var _lp1 := 0.0
var _lp2 := 0.0
var _bp_lo := 0.0
var _saw_lp := 0.0
var _saw_phase := 0.0
var _sand_lp := 0.0
var _fire_lp := 0.0
var _crackle := 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = RATE
	gen.buffer_length = 0.12
	_player.stream = gen
	_player.volume_db = -4.0
	add_child(_player)
	_player.play()
	_pb = _player.get_stream_playback()


func cut(feel: String, speed_ips: float, amount: float, softness: float) -> void:
	var level := clampf(speed_ips / 6.0, 0.0, 1.0) * clampf(0.3 + amount * 40.0, 0.0, 1.0)
	match feel:
		"saw":
			_saw_target = clampf(speed_ips / 20.0, 0.0, 0.6)
		"sand":
			_sand_target = clampf(speed_ips / 14.0, 0.0, 0.4)
		_:
			_cut_target = 0.55 * level
			_cut_freq = (3400.0 if feel == "end" else 3000.0 if feel == "across" else 2300.0) * (1.0 + (1.0 - softness) * 0.5)
			_rough = 0.0 if feel == "with" else 0.6


func stop_cut() -> void:
	_cut_target = 0.0
	_saw_target = 0.0
	_sand_target = 0.0


func _process(_delta: float) -> void:
	if not _pb:
		return
	var n := _pb.get_frames_available()
	var a_cut := 1.0 - exp(-2.0 * PI * _cut_freq / RATE)
	for i in n:
		var w := _rng.randf() * 2.0 - 1.0
		_cut_gain += (_cut_target - _cut_gain) * 0.0008
		_saw_gain += (_saw_target - _saw_gain) * 0.0006
		_sand_gain += (_sand_target - _sand_gain) * 0.0006
		# Knife: band-passed hiss (difference of two one-pole lowpasses), crackle when rough.
		_lp1 += (w - _lp1) * a_cut
		_bp_lo += (w - _bp_lo) * 0.02
		var knife := (_lp1 - _bp_lo) * _cut_gain
		if _rough > 0.0 and _rng.randf() < 0.0006 * _rough:
			_crackle = 0.6
		knife += _crackle * w * _cut_gain
		_crackle *= 0.992
		# Saw: noise with a stroke-rate rasp envelope.
		_saw_phase += 9.0 / RATE
		_saw_lp += (w - _saw_lp) * 0.25
		var saw := (w - _saw_lp) * _saw_gain * (0.55 + 0.45 * absf(sin(_saw_phase * PI)))
		# Sandpaper: low, soft scrub.
		_sand_lp += (w - _sand_lp) * 0.12
		var sand := _sand_lp * _sand_gain
		# Fire bed: rumble + sparse crackles.
		_fire_lp += (w - _fire_lp) * 0.035
		var fire := _fire_lp * 0.05
		if _rng.randf() < 0.00012:
			_lp2 = 0.25 + _rng.randf() * 0.4
		fire += _lp2 * w
		_lp2 *= 0.985
		var s := 0.0 if muted else clampf(knife + saw + sand + fire, -1.0, 1.0)
		_pb.push_frame(Vector2(s, s))
	_cut_target *= 0.9
