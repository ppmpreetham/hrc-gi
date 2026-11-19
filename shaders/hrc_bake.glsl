#[compute]
#version 450

// Bakes the scene into the participating-media representation used by the paper (Sec. 3):
//   emit.rgb = source term S (emission per unit length), emit.a = attenuation coefficient mu
//   albedo.rgb = scattering albedo used for extra bounces
// Inputs: a CPU-painted custom layer (set_scene_pixel) plus a list of rectangles / ellipses
// (HRCEmitter / HRCOccluder nodes) with sub-pixel positions.
//
// Anti-aliasing: a pixel only partly covered by a shape (fraction c) gets the opacity and the
// emitted radiance of that fraction, so edges are smooth and shapes move by less than a pixel.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

struct Prim {
	vec4 rect;    // x, y, w, h in GI pixels (fractional)
	vec4 emit;    // S.rgb, mu
	vec4 albedo;  // albedo.rgb, a = flags: 1 = overrides albedo, 2 = ellipse
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
	int anti_alias;  // 1: fractional coverage at edges; 0: a pixel is inside if its centre is
	ivec4 pad1;
} pc;

// Fraction of pixel p (the unit square [p, p+1]) covered by the shape.
float coverage(vec2 p, vec4 r, bool ellipse) {
	vec2 lo = max(p, r.xy);
	vec2 hi = min(p + 1.0, r.xy + r.zw);
	vec2 o = max(hi - lo, vec2(0.0));
	float box = o.x * o.y;  // exact overlap with the rectangle
	if (!ellipse || box <= 0.0) {
		return box;
	}
	// Ellipse inscribed in the rectangle: 4x4 supersampling.
	vec2 c = r.xy + r.zw * 0.5;
	vec2 inv = 1.0 / max(r.zw * 0.5, vec2(1e-3));
	float n = 0.0;
	for (int j = 0; j < 4; j++) {
		for (int i = 0; i < 4; i++) {
			vec2 d = (p + (vec2(i, j) + 0.5) * 0.25 - c) * inv;
			n += dot(d, d) <= 1.0 ? 1.0 : 0.0;
		}
	}
	return n / 16.0;
}

// Without anti-aliasing: 1 if the pixel centre is inside the shape, else 0.
float centre_inside(vec2 q, vec4 r, bool ellipse) {
	if (any(lessThan(q, r.xy)) || any(greaterThanEqual(q, r.xy + r.zw))) {
		return 0.0;
	}
	if (ellipse) {
		vec2 d = (q - (r.xy + r.zw * 0.5)) / max(r.zw * 0.5, vec2(0.5));
		return dot(d, d) <= 1.0 ? 1.0 : 0.0;
	}
	return 1.0;
}

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= pc.size.x || p.y >= pc.size.y) {
		return;
	}

	vec4 e = imageLoad(custom_emit, p);
	vec4 a = imageLoad(custom_albedo, p);

	for (int i = 0; i < pc.prim_count; i++) {
		int flags = int(prims[i].albedo.a + 0.5);
		float c = pc.anti_alias != 0 ? coverage(vec2(p), prims[i].rect, (flags & 2) != 0)
				: centre_inside(vec2(p) + 0.5, prims[i].rect, (flags & 2) != 0);
		if (c <= 0.0) {
			continue;
		}
		vec3 s = prims[i].emit.rgb;
		float mu = prims[i].emit.a;
		if (c < 1.0) {
			// Partial pixel: opacity per unit length alpha = c * (1 - exp(-mu)), and the radiance
			// leaving one pixel length scaled by c.
			if (mu > 1e-6) {
				float alpha = c * (1.0 - exp(-mu));
				float mu_c = -log(max(1.0 - alpha, 1e-6));
				// Keep S * (1 - exp(-mu)) / mu (radiance over one pixel) scaled by c.
				s *= c * (1.0 - exp(-mu)) / mu * (mu_c / max(alpha, 1e-6));
				mu = mu_c;
			} else {
				s *= c;
			}
		}
		e.rgb += s;
		e.a = max(e.a, mu);
		if ((flags & 1) != 0) {
			a.rgb = mix(a.rgb, prims[i].albedo.rgb, c);
		}
	}

	imageStore(out_emit, p, e);
	imageStore(out_albedo, p, vec4(a.rgb, 1.0));
	imageStore(out_src, p, e);
}
