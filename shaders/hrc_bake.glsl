#[compute]
#version 450

// Bakes the scene into the participating-media representation used by the paper (Sec. 3):
//   emit.rgb = source term S (emission per unit length), emit.a = attenuation coefficient mu
//   albedo.rgb = scattering albedo used for extra bounces
// Inputs: a CPU-painted custom layer (set_scene_pixel) plus a list of axis-aligned rectangles
// (HRCEmitter / HRCOccluder nodes).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

struct Prim {
	ivec4 rect;   // x, y, w, h
	vec4 emit;    // S.rgb, mu
	vec4 albedo;  // albedo.rgb, a > 0.5 => overrides albedo
};

layout(set = 0, binding = 0, std430) restrict readonly buffer Prims {
	Prim prims[];
};
layout(rgba16f, set = 0, binding = 1) uniform restrict readonly image2D custom_emit;
layout(rgba16f, set = 0, binding = 2) uniform restrict readonly image2D custom_albedo;
layout(rgba16f, set = 0, binding = 3) uniform restrict writeonly image2D out_emit;
layout(rgba16f, set = 0, binding = 4) uniform restrict writeonly image2D out_albedo;
layout(rgba16f, set = 0, binding = 5) uniform restrict writeonly image2D out_src;

layout(push_constant, std430) uniform Params {
	ivec2 size;
	int prim_count;
	int pad0;
	ivec4 pad1;
} pc;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= pc.size.x || p.y >= pc.size.y) {
		return;
	}

	vec4 e = imageLoad(custom_emit, p);
	vec4 a = imageLoad(custom_albedo, p);

	for (int i = 0; i < pc.prim_count; i++) {
		ivec4 r = prims[i].rect;
		if (p.x >= r.x && p.y >= r.y && p.x < r.x + r.z && p.y < r.y + r.w) {
			e.rgb += prims[i].emit.rgb;
			e.a = max(e.a, prims[i].emit.a);
			if (prims[i].albedo.a > 0.5) {
				a.rgb = prims[i].albedo.rgb;
			}
		}
	}

	imageStore(out_emit, p, e);
	imageStore(out_albedo, p, vec4(a.rgb, 1.0));
	imageStore(out_src, p, e);
}
