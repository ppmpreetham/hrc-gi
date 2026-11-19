@tool
class_name HRCDisplay
extends TextureRect
## Shows the output of an HRCGlobalIllumination node.
## Set hrc_node; the rect is sized to scene_size so GI pixels map 1:1 unless you resize it.

## The HRCGlobalIllumination node to display.
@export var hrc_node: NodePath:
	set(v):
		hrc_node = v
		if is_inside_tree():
			_bind()

## How the GI is blended over what is drawn behind it.
@export_enum("Mix", "Add", "Multiply") var blend_mode: int = 0:
	set(v):
		blend_mode = v
		_apply_blend()


func _ready() -> void:
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_SCALE
	# Light is smooth: filter it linearly even in pixel-art projects that default to Nearest
	# (unless a filter was chosen on this node).
	if texture_filter == CanvasItem.TEXTURE_FILTER_PARENT_NODE:
		texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_apply_blend()
	_bind()


func _bind() -> void:
	if hrc_node.is_empty():
		return
	var hrc = get_node_or_null(hrc_node)
	if hrc == null or not ("gi_texture" in hrc):
		return
	texture = hrc.gi_texture
	if size == Vector2.ZERO:
		size = Vector2(hrc.scene_size)


func _apply_blend() -> void:
	var mat := CanvasItemMaterial.new()
	match blend_mode:
		1:
			mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		2:
			mat.blend_mode = CanvasItemMaterial.BLEND_MODE_MUL
		_:
			mat.blend_mode = CanvasItemMaterial.BLEND_MODE_MIX
	material = mat
