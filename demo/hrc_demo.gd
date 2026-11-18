extends Node2D
## HRC demo: the blue light follows the mouse.

@onready var hrc: HRCGlobalIllumination = $HRCGlobalIllumination
@onready var mouse_light: HRCEmitter = $HRCGlobalIllumination/MouseLight


func _process(_delta: float) -> void:
	# Emitter positions are in GI pixels, i.e. the GI node's local space.
	mouse_light.position = hrc.get_local_mouse_position()
