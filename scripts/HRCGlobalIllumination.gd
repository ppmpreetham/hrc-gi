@tool
class_name HRCGlobalIllumination
extends Node2D
## Holographic Radiance Cascades 2D Global Illumination
## Based on: "Holographic Radiance Cascades for 2D Global Illumination"
## Preetham Pemmasani
##
## Usage:
##   1. Add this node to your scene
##   2. Set scene_size to match your viewport resolution
##   3. Add HRCEmitter and HRCOccluder nodes to populate the scene texture
##   4. Access output via gi_texture property or connect to GI output material

## Size of the GI grid (should be power of 2 for best results)
@export var scene_size := Vector2i(512, 512):
	set(v):
		scene_size = v
		_dirty = true

## Number of GI bounces (1 = direct + single bounce)
@export_range(1, 4) var gi_bounces: int = 1

## Apply cross-blur to reduce checkerboard artifacts
@export var apply_cross_blur: bool = true

## Show GI overlay in editor
@export var preview_in_editor: bool = true

## Debug: show intermediate cascade
@export_enum("None", "T0", "T1", "T2", "R0_Right") var debug_view: int = 0

## Emitted when GI computation completes
signal gi_updated(output_texture: Texture2D)

## The computed GI fluence texture (RGBA16F, same size as scene_size)
var gi_texture: ImageTexture

# RenderingDevice for compute shaders
var _rd: RenderingDevice

# Scene texture: RGB=emission, A=extinction
var _scene_image: Image
var _scene_texture_rd: RID

# Cascade buffers
# T_n[n]: stores ray interval approx for cascade n
# Layout: width = ceil(W/2^n) * (2*2^n + 1), height = H
# Actually stored as: x = px_idx, y = py + H * k_idx
var _t_textures: Array[RID]   # RenderingDevice texture RIDs
var _r_textures: Array[RID]   # R_n textures

# Output
var _output_texture_rd: RID
var _output_image: Image

# Shaders
var _trace_base_shader: RID
var _merge_up_shader: RID
var _merge_down_shader: RID

# Pipeline RIDs
var _trace_base_pipeline: RID
var _merge_up_pipeline: RID
var _merge_down_pipeline: RID

var _dirty: bool = true
var _initialized: bool = false

# Number of cascades needed: ceil(log2(max(W, H)))
var _num_cascades: int

func _ready() -> void:
	if Engine.is_editor_hint() and not preview_in_editor:
		return
	_initialize()

func _initialize() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		push_error("HRCGlobalIllumination: Could not get RenderingDevice. Compute shaders require the Forward+ or Mobile renderer.")
		return
	
	_num_cascades = ceili(log(max(scene_size.x, scene_size.y)) / log(2.0)) + 1
	_num_cascades = maxi(_num_cascades, 4)
	
	_create_scene_texture()
	_compile_shaders()
	_allocate_cascade_buffers()
	_create_output_texture()
	
	gi_texture = ImageTexture.new()
	_initialized = true
	_dirty = true

func _process(_delta: float) -> void:
	if not _initialized:
		return
	if _dirty:
		_update_scene_texture()
		_run_hrc()
		_download_output()
		_dirty = false
		gi_updated.emit(gi_texture)

## Mark scene as changed (call when emitters/occluders move)
func mark_dirty() -> void:
	_dirty = true

## Manually set a pixel in the scene texture
## emission: RGB emission color, extinction: 0.0=transparent, 1.0+=solid
func set_scene_pixel(pos: Vector2i, emission: Color, extinction: float) -> void:
	if _scene_image == null:
		return
	_scene_image.set_pixel(pos.x, pos.y, Color(emission.r, emission.g, emission.b, extinction))
	_dirty = true

## Clear the scene
func clear_scene() -> void:
	if _scene_image == null:
		return
	_scene_image.fill(Color(0, 0, 0, 0))
	_dirty = true

func _create_scene_texture() -> void:
	_scene_image = Image.create(scene_size.x, scene_size.y, false, Image.FORMAT_RGBAH)
	_scene_image.fill(Color(0, 0, 0, 0))
	
	var tex_format := RDTextureFormat.new()
	tex_format.width = scene_size.x
	tex_format.height = scene_size.y
	tex_format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	tex_format.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)
	_scene_texture_rd = _rd.texture_create(tex_format, RDTextureView.new(), [])

func _allocate_cascade_buffers() -> void:
	# Free existing
	for rid in _t_textures:
		if rid.is_valid(): _rd.free_rid(rid)
	for rid in _r_textures:
		if rid.is_valid(): _rd.free_rid(rid)
	_t_textures.clear()
	_r_textures.clear()
	
	var W := scene_size.x
	var H := scene_size.y
	
	for n in range(_num_cascades + 1):
		var dirs := 1 << n       # 2^n
		var step := 1 << n       # probe spacing
		var num_px := (W + step - 1) / step + 1
		var total_k := 2 * dirs + 1  # k*2 indices
		
		# T_n texture: width = num_px, height = H * total_k
		var t_fmt := RDTextureFormat.new()
		t_fmt.width = num_px
		t_fmt.height = H * total_k
		t_fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
		t_fmt.usage_bits = (
			RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
			RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		)
		_t_textures.append(_rd.texture_create(t_fmt, RDTextureView.new(), []))
	
	for n in range(_num_cascades):
		var dirs := 1 << n
		var step := 1 << n
		var num_px := (W + step - 1) / step + 1
		
		# R_n texture: width = num_px, height = H * dirs
		var r_fmt := RDTextureFormat.new()
		r_fmt.width = num_px
		r_fmt.height = H * dirs
		r_fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
		r_fmt.usage_bits = (
			RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
			RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		)
		_r_textures.append(_rd.texture_create(r_fmt, RDTextureView.new(), []))

func _create_output_texture() -> void:
	var fmt := RDTextureFormat.new()
	fmt.width = scene_size.x
	fmt.height = scene_size.y
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	)
	_output_texture_rd = _rd.texture_create(fmt, RDTextureView.new(), [])

func _compile_shaders() -> void:
	var base_src := _load_shader_source("res://addons/hrc_gi/shaders/hrc_trace_base.glsl")
	var up_src   := _load_shader_source("res://addons/hrc_gi/shaders/hrc_merge_up.glsl")
	var down_src := _load_shader_source("res://addons/hrc_gi/shaders/hrc_merge_down.glsl")
	
	_trace_base_shader  = _compile_compute_shader(base_src)
	_merge_up_shader    = _compile_compute_shader(up_src)
	_merge_down_shader  = _compile_compute_shader(down_src)
	
	if _trace_base_shader.is_valid():
		_trace_base_pipeline = _rd.compute_pipeline_create(_trace_base_shader)
	if _merge_up_shader.is_valid():
		_merge_up_pipeline = _rd.compute_pipeline_create(_merge_up_shader)
	if _merge_down_shader.is_valid():
		_merge_down_pipeline = _rd.compute_pipeline_create(_merge_down_shader)

func _load_shader_source(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("HRC: Could not open shader: " + path)
		return ""
	return file.get_as_text()

func _compile_compute_shader(source: String) -> RID:
	if source.is_empty():
		return RID()
	var src := RDShaderSource.new()
	src.source_compute = source
	var spirv := _rd.shader_compile_spirv_from_source(src)
	if spirv.compile_error_compute != "":
		push_error("HRC Shader compile error: " + spirv.compile_error_compute)
		return RID()
	return _rd.shader_create_from_spirv(spirv)

func _update_scene_texture() -> void:
	# Collect all HRCEmitter and HRCOccluder children and bake into scene texture
	_scene_image.fill(Color(0, 0, 0, 0))
	
	for child in get_children():
		if child.get_script() and child.get_script().get_global_name() == "HRCEmitter":
			_bake_emitter(child)
		elif child.get_script() and child.get_script().get_global_name() == "HRCOccluder":
			_bake_occluder(child)
	
	# Upload to GPU
	var data := _scene_image.get_data()
	_rd.texture_update(_scene_texture_rd, 0, data)

func _bake_emitter(emitter: Node2D) -> void:
	var rect: Rect2i = emitter.call("get_bake_rect")
	var color: Color = emitter.get("emission_color")
	var strength: float = emitter.get("emission_strength")
	
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			if x >= 0 and x < scene_size.x and y >= 0 and y < scene_size.y:
				_scene_image.set_pixel(x, y, Color(
					color.r * strength,
					color.g * strength,
					color.b * strength,
					0.0  # emitters don't occlude by default
				))

func _bake_occluder(occluder: Node2D) -> void:
	var rect: Rect2i = occluder.call("get_bake_rect")
	var extinction: float = occluder.get("extinction")
	
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			if x >= 0 and x < scene_size.x and y >= 0 and y < scene_size.y:
				var existing := _scene_image.get_pixel(x, y)
				_scene_image.set_pixel(x, y, Color(existing.r, existing.g, existing.b, extinction))

func _run_hrc() -> void:
	if not _trace_base_pipeline.is_valid():
		return
	
	var W := scene_size.x
	var H := scene_size.y
	
	var cl := _rd.compute_list_begin()
	
	# === PHASE 1: Trace base levels (n=0,1,2) ===
	for n in range(3):
		_dispatch_trace_base(cl, n, W, H)
	
	# === PHASE 2: Merge up (n=3..N) ===
	for n in range(3, _num_cascades + 1):
		_dispatch_merge_up(cl, n, W, H)
	
	# === PHASE 3: Merge down (n=N-1..0) ===
	for n in range(_num_cascades - 1, -1, -1):
		_dispatch_merge_down(cl, n, W, H)
	
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()

func _dispatch_trace_base(cl: int, n: int, W: int, H: int) -> void:
	if not _trace_base_pipeline.is_valid():
		return
	
	var dirs := 1 << n
	var step := 1 << n
	var num_px := (W + step - 1) / step + 1
	var total_k := 2 * dirs + 1
	
	# Uniforms: scene_tex (sampler), t_out (storage image)
	var uniforms := [
		_make_sampler_uniform(0, _scene_texture_rd),
		_make_storage_image_uniform(1, _t_textures[n]),
	]
	var uniform_set := _rd.uniform_set_create(uniforms, _trace_base_shader, 0)
	
	# Push constants
	var push_data := PackedInt32Array([n, W, H, dirs])
	
	_rd.compute_list_bind_compute_pipeline(cl, _trace_base_pipeline)
	_rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	_rd.compute_list_set_push_constant(cl, push_data.to_byte_array(), push_data.size() * 4)
	
	var gx := ceili(float(num_px * total_k) / 8.0)
	var gy := ceili(float(H) / 8.0)
	_rd.compute_list_dispatch(cl, gx, gy, 1)

func _dispatch_merge_up(cl: int, n: int, W: int, H: int) -> void:
	if not _merge_up_pipeline.is_valid():
		return
	
	var dirs := 1 << n
	var step := 1 << n
	var num_px := (W + step - 1) / step + 1
	var total_k := 2 * dirs + 1
	
	var uniforms := [
		_make_sampler_uniform(0, _scene_texture_rd),
		_make_sampler_uniform(1, _t_textures[n - 1]),
		_make_storage_image_uniform(2, _t_textures[n]),
	]
	var uniform_set := _rd.uniform_set_create(uniforms, _merge_up_shader, 0)
	
	var push_data := PackedInt32Array([n, W, H, dirs, 0])
	
	_rd.compute_list_bind_compute_pipeline(cl, _merge_up_pipeline)
	_rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	_rd.compute_list_set_push_constant(cl, push_data.to_byte_array(), push_data.size() * 4)
	
	var gx := ceili(float(num_px * total_k) / 8.0)
	var gy := ceili(float(H) / 8.0)
	_rd.compute_list_dispatch(cl, gx, gy, 1)

func _dispatch_merge_down(cl: int, n: int, W: int, H: int) -> void:
	if not _merge_down_pipeline.is_valid():
		return
	
	var dirs_n := 1 << n
	var dirs_n1 := 1 << (n + 1)
	var step := 1 << n
	var num_px := (W + step - 1) / step + 1
	var is_top := 1 if (n + 1 >= _num_cascades) else 0
	
	var r_high_tex := _r_textures[n + 1] if (n + 1 < _r_textures.size()) else _r_textures[n]
	
	var uniforms := [
		_make_sampler_uniform(0, r_high_tex if not is_top else _r_textures[n]),
		_make_sampler_uniform(1, _t_textures[n]),
		_make_sampler_uniform(2, _t_textures[n + 1] if n + 1 < _t_textures.size() else _t_textures[n]),
		_make_storage_image_uniform(3, _r_textures[n]),
	]
	var uniform_set := _rd.uniform_set_create(uniforms, _merge_down_shader, 0)
	
	var push_data := PackedInt32Array([n, W, H, dirs_n, dirs_n1, is_top])
	
	_rd.compute_list_bind_compute_pipeline(cl, _merge_down_pipeline)
	_rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	_rd.compute_list_set_push_constant(cl, push_data.to_byte_array(), push_data.size() * 4)
	
	var gx := ceili(float(num_px * dirs_n) / 8.0)
	var gy := ceili(float(H) / 8.0)
	_rd.compute_list_dispatch(cl, gx, gy, 1)

func _download_output() -> void:
	if _r_textures.is_empty():
		return
	
	# R0 contains the final fluence for the +x quadrant
	# In full implementation we'd composite all 4 quadrants
	# For now, download R0 and composite on CPU (production code would use a final pass shader)
	var W := scene_size.x
	var H := scene_size.y
	
	# Create output image
	if _output_image == null:
		_output_image = Image.create(W, H, false, Image.FORMAT_RGBAH)
	
	# Download R0 texture (first cascade, first direction = summed fluence)
	var r0_data := _rd.texture_get_data(_r_textures[0], 0)
	if r0_data.is_empty():
		return
	
	# R0 has width = W+1 probes, height = H * 1 direction
	# Each pixel corresponds to probe (px, py) with fluence = R0(px, py, 0)
	var r0_image := Image.create_from_data(
		(W + 1), H,
		false, Image.FORMAT_RGBAH, r0_data
	)
	
	# Map back to output pixels: pixel [x,y] uses R0([x+1, y], 0)
	for y in range(H):
		for x in range(W):
			var probe_x := x + 1
			if probe_x <= W:
				var c := r0_image.get_pixel(probe_x, y)
				_output_image.set_pixel(x, y, Color(c.r, c.g, c.b, 1.0))
	
	gi_texture.set_image(_output_image)

# Helper: create sampler uniform
func _make_sampler_uniform(binding: int, texture: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = binding
	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	var sampler := _rd.sampler_create(sampler_state)
	u.add_id(sampler)
	u.add_id(texture)
	return u

# Helper: create storage image uniform
func _make_storage_image_uniform(binding: int, texture: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = binding
	u.add_id(texture)
	return u

func _exit_tree() -> void:
	_cleanup()

func _cleanup() -> void:
	for rid in _t_textures:
		if rid.is_valid(): _rd.free_rid(rid)
	for rid in _r_textures:
		if rid.is_valid(): _rd.free_rid(rid)
	if _scene_texture_rd.is_valid(): _rd.free_rid(_scene_texture_rd)
	if _output_texture_rd.is_valid(): _rd.free_rid(_output_texture_rd)
	if _trace_base_pipeline.is_valid(): _rd.free_rid(_trace_base_pipeline)
	if _merge_up_pipeline.is_valid(): _rd.free_rid(_merge_up_pipeline)
	if _merge_down_pipeline.is_valid(): _rd.free_rid(_merge_down_pipeline)
	if _trace_base_shader.is_valid(): _rd.free_rid(_trace_base_shader)
	if _merge_up_shader.is_valid(): _rd.free_rid(_merge_up_shader)
	if _merge_down_shader.is_valid(): _rd.free_rid(_merge_down_shader)
	_initialized = false
