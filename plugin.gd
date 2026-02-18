@tool
extends EditorPlugin

func _enter_tree() -> void:
	add_custom_type(
		"HRCGlobalIllumination",
		"Node2D",
		preload("res://addons/hrc_gi/scripts/HRCGlobalIllumination.gd"),
		null
	)
	add_custom_type(
		"HRCEmitter",
		"Node2D",
		preload("res://addons/hrc_gi/scripts/HRCEmitter.gd"),
		null
	)
	add_custom_type(
		"HRCOccluder",
		"Node2D",
		preload("res://addons/hrc_gi/scripts/HRCOccluder.gd"),
		null
	)
	add_custom_type(
		"HRCDisplay",
		"TextureRect",
		preload("res://addons/hrc_gi/scripts/HRCDisplay.gd"),
		null
	)
	print("HRC GI Plugin loaded")

func _exit_tree() -> void:
	remove_custom_type("HRCGlobalIllumination")
	remove_custom_type("HRCEmitter")
	remove_custom_type("HRCOccluder")
	remove_custom_type("HRCDisplay")
