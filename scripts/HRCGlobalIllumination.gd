@tool
class_name HRCGlobalIllumination
extends Node2D
## Holographic Radiance Cascades 2D global illumination.
## Freeman, Sannikov & Margel (2025), "Holographic Radiance Cascades for 2D Global Illumination".
##
## The GI grid covers local pixels [0, scene_size) of this node. HRCEmitter / HRCOccluder children
## (and pixels painted with set_scene_pixel) form the scene. The result lives in gi_texture
## (a Texture2DRD that stays on the GPU), which is updated in place whenever the scene changes.

## Emitted after each GI update. The texture object is always gi_texture.
signal gi_updated(output_texture: Texture2D)

const _Renderer := preload("HRCRenderer.gd")
const _PRIM_STRIDE := 48

## Size of the GI grid in pixels (one probe per pixel at cascade 0).
@export var scene_size := Vector2i(512, 512):
	set(v):
		v = Vector2i(clampi(v.x, 16, 8192), clampi(v.y, 16, 8192))
		if v == scene_size:
			return
		scene_size = v
		_size_changed = true
		mark_dirty()

## Number of light bounces. 1 = direct lighting only; each extra bounce re-runs HRC with the
## previous fluence as an in-scattering source (paper Sec. 4.2).
@export_range(1, 8) var gi_bounces: int = 1:
	set(v):
		gi_bounces = v
		mark_dirty()

## 1px cross blur that removes HRC's checkerboard artifacts (paper Eq. 21). Leave enabled.
@export var apply_cross_blur := true:
	set(v):
		apply_cross_blur = v
		mark_dirty()

## Display scale. The output is fluence * exposure / (2*pi), i.e. the average incoming radiance.
@export_range(0.0, 16.0, 0.01, "or_greater") var exposure := 1.0:
	set(v):
		exposure = v
		mark_dirty()

## Recompute every frame instead of only when something changed.
@export var continuous_update := false

## Run the GI in the editor viewport.
@export var preview_in_editor := true:
	set(v):
		preview_in_editor = v
		if is_inside_tree():
			_refresh_active()

## The computed GI output (RGBA16F, scene_size). Same object for the node's lifetime.
var gi_texture := Texture2DRD.new()

var _renderer = null  # HRCRenderer.gd (untyped so its methods resolve dynamically)
var _active := false
var _dirty := true
var _size_changed := true
var _custom_emit: Image
var _custom_albedo: Image
var _custom_dirty := false


func _enter_tree() -> void:
	_refresh_active()


func _exit_tree() -> void:
	_shutdown()


func _process(_delta: float) -> void:
	if not _active:
		return

	if _size_changed:
		_size_changed = false
		gi_texture.texture_rd_rid = RID()
		_ensure_custom_layer()
		RenderingServer.call_on_render_thread(_renderer.setup.bind(scene_size))
		_custom_dirty = true
		_dirty = true

	if not (_dirty or continuous_update):
		return
	_dirty = false

	var prims := PackedByteArray()
	var count := _collect_prims(prims)
	var ce := PackedByteArray()
	var ca := PackedByteArray()
	if _custom_dirty:
		_custom_dirty = false
		ce = _custom_emit.get_data()
		ca = _custom_albedo.get_data()

	RenderingServer.call_on_render_thread(_renderer.compute.bind(
			prims, count, ce, ca, gi_bounces, apply_cross_blur, exposure))
	gi_updated.emit(gi_texture)


## Request a recompute next frame (emitters/occluders call this when they change).
func mark_dirty() -> void:
	_dirty = true


## Paint one pixel of the custom scene layer.
## emission: radiance of the pixel if it were thick (same convention as HRCEmitter).
## extinction: attenuation per pixel (0 = transparent, ~10 = solid).
## albedo: reflectance used for gi_bounces > 1.
func set_scene_pixel(pos: Vector2i, emission: Color, extinction: float, albedo := Color.BLACK) -> void:
	_ensure_custom_layer()
	if pos.x < 0 or pos.y < 0 or pos.x >= scene_size.x or pos.y >= scene_size.y:
		return
	var k := extinction if extinction > 0.0 else 1.0
	_custom_emit.set_pixelv(pos, Color(emission.r * k, emission.g * k, emission.b * k, maxf(extinction, 0.0)))
	_custom_albedo.set_pixelv(pos, Color(albedo.r, albedo.g, albedo.b, 1.0))
	_custom_dirty = true
	_dirty = true


## Clear the custom scene layer (does not affect HRCEmitter / HRCOccluder nodes).
func clear_scene() -> void:
	_ensure_custom_layer()
	_custom_emit.fill(Color(0, 0, 0, 0))
	_custom_albedo.fill(Color(0, 0, 0, 0))
	_custom_dirty = true
	_dirty = true


func _refresh_active() -> void:
	var want := not (Engine.is_editor_hint() and not preview_in_editor)
	if want and not _active:
		if RenderingServer.get_rendering_device() == null:
			if DisplayServer.get_name() != "headless":
				push_error("HRCGlobalIllumination: compute shaders need the Forward+ or Mobile renderer.")
			return
		_renderer = _Renderer.new()
		_renderer.texture = gi_texture
		_active = true
		_size_changed = true
		_dirty = true
	elif not want and _active:
		_shutdown()


func _shutdown() -> void:
	if not _active:
		return
	_active = false
	gi_texture.texture_rd_rid = RID()
	var r = _renderer
	_renderer = null
	# Bind the renderer as an argument so it stays alive until the render thread frees it.
	RenderingServer.call_on_render_thread(r.free_all.bind(r))


func _ensure_custom_layer() -> void:
	if _custom_emit != null and _custom_emit.get_size() == scene_size:
		return
	_custom_emit = Image.create(scene_size.x, scene_size.y, false, Image.FORMAT_RGBAH)
	_custom_albedo = Image.create(scene_size.x, scene_size.y, false, Image.FORMAT_RGBAH)
	_custom_emit.fill(Color(0, 0, 0, 0))
	_custom_albedo.fill(Color(0, 0, 0, 0))
	_custom_dirty = true


func _collect_prims(out: PackedByteArray) -> int:
	var count := 0
	for child in get_children():
		if not (child is CanvasItem and child.visible and child.has_method("get_hrc_data")):
			continue
		var d: Array = child.get_hrc_data()
		var rect: Rect2i = d[0]
		var e: Color = d[1]
		var a: Color = d[2]
		var o := out.size()
		out.resize(o + _PRIM_STRIDE)
		out.encode_s32(o, rect.position.x)
		out.encode_s32(o + 4, rect.position.y)
		out.encode_s32(o + 8, rect.size.x)
		out.encode_s32(o + 12, rect.size.y)
		out.encode_float(o + 16, e.r)
		out.encode_float(o + 20, e.g)
		out.encode_float(o + 24, e.b)
		out.encode_float(o + 28, e.a)
		out.encode_float(o + 32, a.r)
		out.encode_float(o + 36, a.g)
		out.encode_float(o + 40, a.b)
		out.encode_float(o + 44, a.a)
		count += 1
	return count
