class_name HRCOccluder
extends Node2D
## Light occluder for HRC Global Illumination.
## Add as a child of HRCGlobalIllumination to block light.

## Extinction coefficient (0.0 = transparent, 1.0+ = solid)
@export_range(0.0, 10.0) var extinction: float = 10.0
@export var size: Vector2 = Vector2(32, 32)
@export var color: Color = Color(0.3, 0.3, 0.3, 1.0)

func _ready() -> void:
	queue_redraw()

func _draw() -> void:
	var rect := Rect2(-size / 2.0, size)
	draw_rect(rect, Color(color.r, color.g, color.b, 0.7))
	draw_rect(rect, Color(0.8, 0.8, 0.8), false, 1.0)

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
