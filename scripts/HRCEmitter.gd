@tool
class_name HRCEmitter
extends Node2D
## Rectangular light source. Must be a direct child of HRCGlobalIllumination.
## Position/size are in the GI grid's pixels (the parent's local space). Rotation/scale are applied
## as an axis-aligned bounding box.

## Light color.
@export var emission_color := Color.WHITE:
	set(v):
		emission_color = v
		_changed()

## Brightness: the radiance leaving a thick emitter is emission_color * emission_strength.
@export_range(0.0, 100.0, 0.01, "or_greater") var emission_strength := 10.0:
	set(v):
		emission_strength = v
		_changed()

## Attenuation per pixel. ~10 = solid light; 0 = transparent glowing gas (emits strength per pixel
## of path length).
@export_range(0.0, 50.0, 0.01, "or_greater") var extinction := 10.0:
	set(v):
		extinction = v
		_changed()

## Size in GI pixels.
@export var size := Vector2(16, 16):
	set(v):
		size = v
		_changed()

## Shape inside the size rectangle. Ellipse with equal width and height gives a circle.
@export_enum("Rectangle", "Ellipse") var shape: int = 0:
	set(v):
		shape = v
		_changed()

## Draw an outline of the emitter (always shown in the editor).
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
	if shape == 1:
		# Ellipse: draw a unit circle scaled to the size.
		draw_set_transform(Vector2.ZERO, 0.0, size / 2.0)
		draw_circle(Vector2.ZERO, 1.0, Color(emission_color, 0.6))
		draw_arc(Vector2.ZERO, 1.0, 0.0, TAU, 48, Color.WHITE, 2.0 / maxf(minf(size.x, size.y), 1.0))
		draw_set_transform(Vector2.ZERO)
		return
	var rect := Rect2(-size / 2.0, size)
	draw_rect(rect, Color(emission_color, 0.6))
	draw_rect(rect, Color.WHITE, false, 1.0)


## Returns [Rect2 in GI pixels (fractional), Color(S.rgb, mu), Color(albedo.rgb, override flag)].
func get_hrc_data() -> Array:
	var r := transform * Rect2(-size / 2.0, size)
	var rect := r  # sub-pixel; the bake shader anti-aliases the edges
	# A thick medium with source S and attenuation mu has radiance S / mu.
	var k := extinction if extinction > 0.0 else 1.0
	var s := emission_strength * k
	# Inspector colours are sRGB; with gamma_correct the lighting is computed in linear space.
	var p = get_parent()
	var c := emission_color.srgb_to_linear() if (p == null or p.get("gamma_correct") != false) else emission_color
	# albedo.a holds flags: 1 = override albedo, 2 = ellipse.
	return [rect, Color(c.r * s, c.g * s, c.b * s, extinction), Color(0, 0, 0, 2.0 if shape == 1 else 0.0)]


func _changed() -> void:
	queue_redraw()
	var p = get_parent()
	if p != null and p.has_method("mark_scene_dirty"):
		p.mark_scene_dirty()
