class_name Settings
extends RefCounted
## Player settings, persisted to user://settings.cfg.

const PATH := "user://settings.cfg"

var master := 0.8
var carving_on := true
var carving := 0.9
var ambience_on := true
var ambience := 0.6
var fullscreen := true
var sensitivity := 1.0


func load_from_disk() -> void:
	var cf := ConfigFile.new()
	if cf.load(PATH) != OK:
		return
	master = cf.get_value("audio", "master", master)
	carving_on = cf.get_value("audio", "carving_on", carving_on)
	carving = cf.get_value("audio", "carving", carving)
	ambience_on = cf.get_value("audio", "ambience_on", ambience_on)
	ambience = cf.get_value("audio", "ambience", ambience)
	fullscreen = cf.get_value("display", "fullscreen", fullscreen)
	sensitivity = cf.get_value("controls", "sensitivity", sensitivity)


func save() -> void:
	var cf := ConfigFile.new()
	cf.set_value("audio", "master", master)
	cf.set_value("audio", "carving_on", carving_on)
	cf.set_value("audio", "carving", carving)
	cf.set_value("audio", "ambience_on", ambience_on)
	cf.set_value("audio", "ambience", ambience)
	cf.set_value("display", "fullscreen", fullscreen)
	cf.set_value("controls", "sensitivity", sensitivity)
	cf.save(PATH)
