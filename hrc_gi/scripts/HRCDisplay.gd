class_name HRCDisplay
extends TextureRect
## Displays HRC Global Illumination output.
## Add as a sibling or child of your scene.
## Connect HRCGlobalIllumination.gi_updated signal to update_gi.

@export var hrc_node: NodePath
@export_range(0.0, 2.0) var gi_intensity: float = 1.0
@export_enum("Additive", "Multiply", "Replace") var blend_mode: int = 0

var _hrc: HRCGlobalIllumination

func _ready() -> void:
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_SCALE
	
	if not hrc_node.is_empty():
		_hrc = get_node(hrc_node)
		if _hrc:
			_hrc.gi_updated.connect(update_gi)
	
	# Set up material for blending
	var mat := ShaderMaterial.new()
	mat.shader = load("res://addons/hrc_gi/shaders/hrc_composite.gdshader")
	material = mat
	
	# Configure blend mode
	match blend_mode:
		0: # Additive
			show_behind_parent = false
			z_index = 100
		1: # Multiply
			show_behind_parent = false
		2: # Replace
			pass

func update_gi(new_texture: Texture2D) -> void:
	texture = new_texture
	if material is ShaderMaterial:
		(material as ShaderMaterial).set_shader_parameter("gi_intensity", gi_intensity)
