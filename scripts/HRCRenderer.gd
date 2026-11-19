@tool
extends RefCounted
## GPU side of Holographic Radiance Cascades.
## Every method here must run on the render thread (via RenderingServer.call_on_render_thread).
## Uses the main RenderingDevice so the result can be shown through a Texture2DRD without any
## CPU readback.

const FMT := RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
const PRIM_STRIDE := 48  # vec4 rect + vec4 emit + vec4 albedo
const SHADERS := ["hrc_bake", "hrc_source", "hrc_trace_base", "hrc_merge_up", "hrc_merge_down", "hrc_blur"]
const GROUP := 8.0
const TEXEL_BYTES := 8

## Texture2DRD that receives the display output.
var texture: Texture2DRD

## Extra GPU memory (MB) that may be spent on giving each of the 4 directions its own cascade
## textures. Independent directions let Godot's render graph run them side by side instead of
## one after another. 0 disables it.
var memory_budget_mb := 96
## Debug: force the number of cascade texture copies (1, 2 or 4). 0 = automatic.
var force_copies := 0

## GPU profiling (debug): when true, timestamps are captured around each phase and the
## previous frame's timings (ms per phase) are stored in last_profile.
var profile := false
var last_profile := {}

var _rd: RenderingDevice
var _valid := false
var _size := Vector2i.ZERO
var _levels := 0  # N: highest cascade, 2^N >= max(W, H)
var _pad := 0     # 2^N
var _side := 0    # max(W, H)
var _copies := 1  # independent cascade texture sets; quadrant q uses copy q % _copies

var _shaders := {}
var _pipelines := {}
var _tex := {}
var _t: Array = []  # _t[copy][n] = T_n
var _r: Array = []  # _r[copy][i]  = R ping-pong; R_n lives in _r[copy][n % 2]
var _prim_buf := RID()
var _prim_cap := 0
var _sets := {}


func setup(new_size: Vector2i) -> void:
	_valid = false
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		push_error("HRC: no RenderingDevice. Use the Forward+ or Mobile renderer.")
		return
	if _shaders.is_empty() and not _load_shaders():
		return

	_free_resources()
	_size = new_size
	_side = maxi(_size.x, _size.y)
	_levels = 0
	while (1 << _levels) < _side:
		_levels += 1
	_levels = maxi(_levels, 3)
	_pad = 1 << _levels
	_copies = _pick_copies()

	var w := _size.x
	var h := _size.y
	var zero := PackedByteArray()
	zero.resize(w * h * 8)
	zero.fill(0)

	for key in ["emit", "albedo", "src", "fluence", "accum0", "accum1", "accum2", "accum3"]:
		_tex[key] = _make_tex(w, h)
	_tex["out"] = _make_tex(w, h, RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT)
	_tex["custom_emit"] = _make_tex(w, h, RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT, zero)
	_tex["custom_albedo"] = _make_tex(w, h, RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT, zero)

	for c in _copies:
		# T_n: one texel per (probe, k): width (2^N / 2^n) * (2^n + 1) <= 2 * 2^N, height max(W, H).
		var ts: Array[RID] = []
		for n in range(_levels + 1):
			ts.append(_make_tex((_pad >> n) * ((1 << n) + 1), _side))
		# R_n: (2^N / 2^n) probes * 2^n directions = 2^N wide. Only two levels are live at once.
		var rs: Array[RID] = [_make_tex(_pad, _side), _make_tex(_pad, _side)]
		_t.append(ts)
		_r.append(rs)

	for rid: RID in _all_textures():
		if not rid.is_valid():
			push_error("HRC: failed to allocate GPU textures for scene_size %s" % _size)
			_free_resources()
			return

	_ensure_prim_capacity(16)
	_sets["source"] = _make_set("hrc_source", [_tex.emit, _tex.albedo, _tex.fluence, _tex.src])
	_sets["blur"] = _make_set("hrc_blur", [_tex.accum0, _tex.accum1, _tex.accum2, _tex.accum3,
			_tex.emit, _tex.fluence, _tex.out])
	for c in _copies:
		var t: Array = _t[c]
		for n in range(mini(2, _levels) + 1):
			_sets["trace%d_%d" % [n, c]] = _make_set("hrc_trace_base", [_tex.src, t[n]])
		for n in range(1, _levels + 1):
			_sets["up%d_%d" % [n, c]] = _make_set("hrc_merge_up", [t[n - 1], t[n]])
	for q in 4:
		var t: Array = _t[q % _copies]
		var r: Array = _r[q % _copies]
		for n in range(_levels):
			_sets["down%d_%d" % [n, q]] = _make_set("hrc_merge_down",
					[r[(n + 1) % 2], t[n], t[n + 1], r[n % 2], _tex["accum%d" % q]])

	_valid = true
	_assign_texture.call_deferred(_tex.out)


## trace_top: highest cascade that is ray-traced (2 = paper, 0 = extend everything from c0).
func compute(prims: PackedByteArray, prim_count: int, custom_emit: PackedByteArray,
		custom_albedo: PackedByteArray, bounces: int, blur: bool, exposure: float,
		trace_top: int = 2, srgb_output: bool = true, anti_alias: bool = true) -> void:
	if not _valid:
		return
	var w := _size.x
	var h := _size.y

	if profile:
		last_profile = _read_profile()
		_rd.capture_timestamp("HRC|begin")

	_ensure_prim_capacity(prim_count)
	if prim_count > 0:
		_rd.buffer_update(_prim_buf, 0, prims.size(), prims)
	if not custom_emit.is_empty():
		_rd.texture_update(_tex.custom_emit, 0, custom_emit)
		_rd.texture_update(_tex.custom_albedo, 0, custom_albedo)

	_dispatch("hrc_bake", "bake", [w, h, prim_count, 1 if anti_alias else 0], w, h)
	_ts("bake")

	var traced := clampi(trace_top, 0, mini(2, _levels))
	for b in maxi(bounces, 1):
		if b > 0:
			_dispatch("hrc_source", "source", [w, h], w, h)
			_ts("source")
		# Quadrants that own separate textures are issued level by level, so consecutive
		# dispatches are independent and the render graph can batch them under one barrier.
		for first in range(0, 4, _copies):
			var quads := range(first, first + _copies)
			for n in range(traced + 1):
				for q in quads:
					_dispatch_level("hrc_trace_base", "trace%d_%d" % [n, q % _copies], n, q, w, h, 1, 0)
			for n in range(traced + 1, _levels + 1):
				for q in quads:
					_dispatch_level("hrc_merge_up", "up%d_%d" % [n, q % _copies], n, q, w, h, 1, 0)
			for n in range(_levels - 1, -1, -1):
				for q in quads:
					_dispatch_level("hrc_merge_down", "down%d_%d" % [n, q], n, q, w, h, 0,
							1 if n == _levels - 1 else 0)
		_ts("cascades")
		_dispatch("hrc_blur", "blur", [w, h, 1 if blur else 0, exposure, 1 if srgb_output else 0], w, h)
		_ts("blur")


## Frees everything. The bound argument keeps this object alive until the render thread runs it.
func free_all(_keep_alive: Variant = null) -> void:
	_free_resources()
	if _rd == null:
		return
	for p: RID in _pipelines.values():
		if p.is_valid():
			_rd.free_rid(p)
	for s: RID in _shaders.values():
		if s.is_valid():
			_rd.free_rid(s)
	_pipelines.clear()
	_shaders.clear()


## How many independent cascade texture sets fit in the memory budget (1, 2 or 4).
func _pick_copies() -> int:
	if force_copies in [1, 2, 4]:
		return force_copies
	var texels := 2 * _pad * _side
	for n in range(_levels + 1):
		texels += (_pad >> n) * ((1 << n) + 1) * _side
	var per_copy_mb := texels * TEXEL_BYTES / 1048576.0
	for c in [4, 2]:
		if (c - 1) * per_copy_mb <= memory_budget_mb:
			return c
	return 1


## One cascade level for one quadrant. ray_texels: 1 = T layout (2^n + 1 per probe), 0 = R layout.
func _dispatch_level(pipeline: String, set_key: String, n: int, q: int, w: int, h: int,
		ray_texels: int, is_top: int) -> void:
	# Quadrants 0/1 face +-x, 2/3 face +-y; canonical space always faces +x.
	var wc := w if q < 2 else h
	var hc := h if q < 2 else w
	var k := 1 << n
	_dispatch(pipeline, set_key, [n, q, wc, hc, w, h, is_top],
			((wc + k - 1) >> n) * (k + ray_texels), hc)


func _assign_texture(rid: RID) -> void:
	if texture != null and _valid:
		texture.texture_rd_rid = rid


func _load_shaders() -> bool:
	var dir: String = (get_script() as Script).resource_path.get_base_dir().get_base_dir().path_join("shaders")
	for shader_name in SHADERS:
		var file := load(dir.path_join(shader_name + ".glsl")) as RDShaderFile
		if file == null:
			push_error("HRC: could not load %s.glsl (is it imported as an RDShaderFile?)" % shader_name)
			free_all()
			return false
		var spirv := file.get_spirv()
		if spirv.compile_error_compute != "":
			push_error("HRC: %s.glsl failed to compile:\n%s" % [shader_name, spirv.compile_error_compute])
			free_all()
			return false
		var shader := _rd.shader_create_from_spirv(spirv, shader_name)
		_shaders[shader_name] = shader
		_pipelines[shader_name] = _rd.compute_pipeline_create(shader)
	return true


func _make_tex(w: int, h: int, extra_bits: int = 0, data: PackedByteArray = PackedByteArray()) -> RID:
	var f := RDTextureFormat.new()
	f.width = w
	f.height = h
	f.format = FMT
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | extra_bits
	var init: Array[PackedByteArray] = []
	if not data.is_empty():
		init.append(data)
	return _rd.texture_create(f, RDTextureView.new(), init)


func _make_set(shader_name: String, rids: Array) -> RID:
	var uniforms: Array[RDUniform] = []
	for i in rids.size():
		var rid: RID = rids[i]
		var u := RDUniform.new()
		u.binding = i
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER if rid == _prim_buf \
				else RenderingDevice.UNIFORM_TYPE_IMAGE
		u.add_id(rid)
		uniforms.append(u)
	return _rd.uniform_set_create(uniforms, _shaders[shader_name], 0)


func _ensure_prim_capacity(count: int) -> void:
	if _prim_buf.is_valid() and count <= _prim_cap:
		return
	_free_set("bake")
	if _prim_buf.is_valid():
		_rd.free_rid(_prim_buf)
	_prim_cap = maxi(16, nearest_po2(count))
	_prim_buf = _rd.storage_buffer_create(_prim_cap * PRIM_STRIDE)
	_sets["bake"] = _make_set("hrc_bake",
			[_prim_buf, _tex.custom_emit, _tex.custom_albedo, _tex.emit, _tex.albedo, _tex.src])


func _dispatch(pipeline: String, set_key: String, params: Array, threads_x: int, threads_y: int) -> void:
	# One compute list per dispatch: Godot's render graph inserts (and batches) the barriers.
	var pc := PackedByteArray()
	pc.resize(32)
	pc.fill(0)
	for i in params.size():
		if params[i] is float:
			pc.encode_float(i * 4, params[i])
		else:
			pc.encode_s32(i * 4, params[i])
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipelines[pipeline])
	_rd.compute_list_bind_uniform_set(cl, _sets[set_key], 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, ceili(threads_x / GROUP), ceili(threads_y / GROUP), 1)
	_rd.compute_list_end()


func _free_set(key: String) -> void:
	if _sets.has(key):
		var s: RID = _sets[key]
		if s.is_valid() and _rd.uniform_set_is_valid(s):
			_rd.free_rid(s)
		_sets.erase(key)


func _free_resources() -> void:
	_valid = false
	if _rd == null:
		return
	for key in _sets.keys():
		_free_set(key)
	if _prim_buf.is_valid():
		_rd.free_rid(_prim_buf)
	_prim_buf = RID()
	_prim_cap = 0
	for rid: RID in _all_textures():
		if rid.is_valid():
			_rd.free_rid(rid)
	_tex.clear()
	_t.clear()
	_r.clear()


func _all_textures() -> Array[RID]:
	var out: Array[RID] = []
	for rid: RID in _tex.values():
		out.append(rid)
	for set_t: Array in _t:
		for rid: RID in set_t:
			out.append(rid)
	for set_r: Array in _r:
		for rid: RID in set_r:
			out.append(rid)
	return out


func _ts(phase: String) -> void:
	if profile:
		_rd.capture_timestamp("HRC|" + phase)


## GPU time (ms) of each phase in the most recent frame that has timestamps.
func _read_profile() -> Dictionary:
	var out := {}
	var prev := -1.0
	for i in _rd.get_captured_timestamps_count():
		var label := _rd.get_captured_timestamp_name(i)
		if not label.begins_with("HRC|"):
			continue
		var t := _rd.get_captured_timestamp_gpu_time(i) / 1000000.0  # ns -> ms
		var phase := label.trim_prefix("HRC|")
		if phase == "begin":
			prev = t
			continue
		if prev >= 0.0:
			out[phase] = out.get(phase, 0.0) + (t - prev)
			out["total"] = out.get("total", 0.0) + (t - prev)
		prev = t
	out["copies"] = _copies
	return out
