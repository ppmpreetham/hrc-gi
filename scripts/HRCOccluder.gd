@tool
class_name HRCOccluder
extends Node2D
## Rectangular light blocker. Must be a direct child of HRCGlobalIllumination.
## Position/size are in the GI grid's pixels (the parent's local space). Rotation/scale are applied
## as an axis-aligned bounding box.

## Attenuation per pixel: 0 = transparent, ~1 = translucent, 10 = solid.
@export_range(0.0, 50.0, 0.01, "or_greater") var extinction := 10.0:
	set(v):
		extinction = v
		_changed()

## Size in GI pixels.
@export var size := Vector2(32, 32):
	set(v):
		size = v
		_changed()

## Surface reflectance, used when gi_bounces > 1.
@export var albedo := Color(0.5, 0.5, 0.5):
	set(v):
		albedo = v
		_changed()

## Draw an outline of the occluder (always shown in the editor).
@export var draw_debug := false:
	set(v):
		draw_debug = v
		queue_redraw()


func _init() -> void:
	set_notify_local_transform(true)


func _notification(what: int) -> void:
	if what in [NOTIFICATION_LOCAL_TRANSFORM_CHANGED, NOTIFICATION_VISIBILITY_CHANGED,
			NOTIFICATION_ENTER_TREE, NOTIFICATION_EXIT_TREE]:
		_changed()


func _draw() -> void:
	if not (draw_debug or Engine.is_editor_hint()):
		return
	var rect := Rect2(-size / 2.0, size)
	draw_rect(rect, Color(albedo, 0.6))
	draw_rect(rect, Color(0.8, 0.8, 0.8), false, 1.0)


## Returns [Rect2i in GI pixels, Color(S.rgb, mu), Color(albedo.rgb, override flag)].
func get_hrc_data() -> Array:
	var r := transform * Rect2(-size / 2.0, size)
	var rect := Rect2i(Vector2i(r.position.round()), Vector2i(r.size.round()))
	return [rect, Color(0, 0, 0, extinction), Color(albedo.r, albedo.g, albedo.b, 1.0)]


func _changed() -> void:
	queue_redraw()
	var p = get_parent()
	if p != null and p.has_method("mark_dirty"):
		p.mark_dirty()
