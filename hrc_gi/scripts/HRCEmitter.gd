class_name HRCEmitter
extends Node2D
## Light emitter for HRC Global Illumination.
## Add as a child of HRCGlobalIllumination to register it as a light source.

@export var emission_color: Color = Color.WHITE
@export var emission_strength: float = 10.0
@export var size: Vector2 = Vector2(16, 16)

func _ready() -> void:
	queue_redraw()

func _draw() -> void:
	# Visual preview of emitter
	var rect := Rect2(-size / 2.0, size)
	draw_rect(rect, Color(emission_color.r, emission_color.g, emission_color.b, 0.8))
	draw_rect(rect, Color.WHITE, false, 1.0)

func get_bake_rect() -> Rect2i:
	var parent := get_parent()
	if parent == null:
		return Rect2i()
	var local_pos := position
	var half := size / 2.0
	return Rect2i(
		int(local_pos.x - half.x),
		int(local_pos.y - half.y),
		int(size.x),
		int(size.y)
	)

func _process(_delta: float) -> void:
	var parent := get_parent()
	if parent and parent.get_script() and parent.get_script().get_global_name() == "HRCGlobalIllumination":
		parent.mark_dirty()
