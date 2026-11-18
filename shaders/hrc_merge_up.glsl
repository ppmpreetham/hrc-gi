#[compute]
#version 450

// HRC acceleration structure (paper Sec. 4.1, Eqs. 18-20), computing T_n from T_{n-1} for n >= 3.
// With m = n - 1 and k' in 0..2^n:
//   k' = 2k even:  T_n(p, 2k) = Merge(T_m(p, k), T_m(p + v_m(k), k))                     (18)
//   k' = 2k odd:   F-+ = Merge(T_m(p, k -+ 1/2), T_m(p + v_m(k -+ 1/2), k +- 1/2))        (19)
//                  T_n(p, 2k) = (F- + F+) / 2                                               (20)
// T_n layout: texel (x * (2^n + 1) + k, y), probe p = (x * 2^n, y), canonical space.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D t_prev;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D t_out;

layout(push_constant, std430) uniform Params {
	int n;
	int quadrant;
	int wc;
	int hc;
	int w;
	int h;
	int pad0;
	int pad1;
} pc;

// Eq. 7/8: (L1, T1) followed by (L2, T2).
vec4 merge(vec4 a, vec4 b) {
	return vec4(a.rgb + a.a * b.rgb, a.a * b.a);
}

// T_{n-1}(p, k); probes outside the scene start an interval that lies entirely in vacuum.
vec4 load_prev(ivec2 p, int k) {
	if (p.x >= pc.wc || p.y < 0 || p.y >= pc.hc) {
		return vec4(0.0, 0.0, 0.0, 1.0);
	}
	int m = pc.n - 1;
	int Km = 1 << m;
	return imageLoad(t_prev, ivec2((p.x >> m) * (Km + 1) + k, p.y));
}

ivec2 v(int m, int k) {
	return ivec2(1 << m, 2 * k - (1 << m));
}

void main() {
	ivec2 g = ivec2(gl_GlobalInvocationID.xy);
	int n = pc.n;
	int K = 1 << n;
	int num_px = (pc.wc + K - 1) >> n;
	int x = g.x / (K + 1);
	int kk = g.x - x * (K + 1);
	if (x >= num_px || g.y >= pc.hc) {
		return;
	}

	ivec2 p = ivec2(x << n, g.y);
	int m = n - 1;
	vec4 result;

	if ((kk & 1) == 0) {
		int k = kk >> 1;
		result = merge(load_prev(p, k), load_prev(p + v(m, k), k));
	} else {
		int k_lo = kk >> 1;
		int k_hi = k_lo + 1;
		vec4 f_minus = merge(load_prev(p, k_lo), load_prev(p + v(m, k_lo), k_hi));
		vec4 f_plus = merge(load_prev(p, k_hi), load_prev(p + v(m, k_hi), k_lo));
		result = 0.5 * (f_minus + f_plus);
	}

	imageStore(t_out, g, result);
}
