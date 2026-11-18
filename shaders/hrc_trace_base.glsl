#[compute]
#version 450

// HRC base levels (paper Algorithm 1, first loop):
//   for n in 0..2:  T_n(p, k) <- Trace(p, p + v_n(k)),  p = (x * 2^n, y),  k in 0..2^n
// with v_n(k) = (2^n, 2k - 2^n).
//
// Trace integrates the radiance interval and transmittance (Eqs. 2-4) exactly for a medium that
// is piecewise constant per pixel, using a DDA walk.
//
// Everything is done in "canonical" space, where the quadrant being solved faces +x.
// T_n layout: texel (x * (2^n + 1) + k, y).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D src;   // S.rgb, mu (scene space)
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D t_out;

layout(push_constant, std430) uniform Params {
	int n;
	int quadrant;
	int wc;  // canonical width
	int hc;  // canonical height
	int w;   // scene width
	int h;   // scene height
	int pad0;
	int pad1;
} pc;

ivec2 to_scene(ivec2 c) {
	switch (pc.quadrant) {
		case 0: return c;                              // +x
		case 1: return ivec2(pc.w - 1 - c.x, c.y);     // -x
		case 2: return c.yx;                           // +y
		default: return ivec2(c.y, pc.h - 1 - c.x);    // -y
	}
}

// Returns (radiance interval L(o <- o + d), transmittance T(o <- o + d)).
vec4 trace(vec2 o, vec2 d) {
	float len = length(d);
	vec2 dir = d / len;
	ivec2 cell = ivec2(floor(o));
	ivec2 stp = ivec2(sign(dir));
	vec2 t_delta = 1.0 / max(abs(dir), vec2(1e-8));
	vec2 t_max;
	t_max.x = dir.x > 0.0 ? (float(cell.x + 1) - o.x) * t_delta.x : (dir.x < 0.0 ? (o.x - float(cell.x)) * t_delta.x : 1e30);
	t_max.y = dir.y > 0.0 ? (float(cell.y + 1) - o.y) * t_delta.y : (dir.y < 0.0 ? (o.y - float(cell.y)) * t_delta.y : 1e30);

	vec3 L = vec3(0.0);
	float T = 1.0;
	float t = 0.0;

	for (int i = 0; i < 64; i++) {
		// Outside the scene is vacuum; rays leave monotonically so nothing more can contribute.
		if (cell.x < 0 || cell.y < 0 || cell.x >= pc.wc || cell.y >= pc.hc) {
			break;
		}
		float t_next = min(min(t_max.x, t_max.y), len);
		float seg = t_next - t;
		if (seg > 0.0) {
			vec4 s = imageLoad(src, to_scene(cell));
			if (s.a > 1e-6) {
				float tr = exp(-s.a * seg);
				L += T * s.rgb * (1.0 - tr) / s.a;
				T *= tr;
			} else {
				L += T * s.rgb * seg;
			}
		}
		t = t_next;
		if (t >= len) {
			break;
		}
		if (t_max.x < t_max.y) {
			t_max.x += t_delta.x;
			cell.x += stp.x;
		} else {
			t_max.y += t_delta.y;
			cell.y += stp.y;
		}
	}
	return vec4(L, T);
}

void main() {
	ivec2 g = ivec2(gl_GlobalInvocationID.xy);
	int n = pc.n;
	int K = 1 << n;
	int num_px = (pc.wc + K - 1) >> n;
	int x = g.x / (K + 1);
	int k = g.x - x * (K + 1);
	if (x >= num_px || g.y >= pc.hc) {
		return;
	}

	ivec2 p = ivec2(x << n, g.y);
	vec2 v = vec2(float(K), float(2 * k - K));
	imageStore(t_out, g, trace(vec2(p) + 0.5, v));
}
