#[compute]
#version 450

// HRC merge down (paper Sec. 4, Eqs. 13-17, Algorithm 1 last loop), computing R_n from R_{n+1}.
//
// Probe p = (x * 2^n, y). Direction i is a half integer in [1/2, 2^n - 1/2]; stored index ii = i - 1/2.
// Cone i has edges through p + v_n(i +- 1/2). Its halves map to directions j+- = 2i +- 1/2 at n+1.
//   odd x  (Eq. 14): F+- = Merge(A_{n+1}(j+-) * T_n(p, i +- 1/2), R_{n+1}(p + v_n(i +- 1/2), j+-))
//   even x (Eq. 15-17):
//          F0+- = R_{n+1}(p, j+-)
//          F1+- = Merge(A_{n+1}(j+-) * T_{n+1}(p, 2i +- 1), R_{n+1}(p + 2 v_n(i +- 1/2), j+-))
//          F+-  = (F0+- + F1+-) / 2
//   R_n(p, i) = F+ + F-
// R_N is treated as 0 at the top level. At n = 0, R_0 is the fluence of this quadrant and is
// written straight into this quadrant's scene-space accumulator.
//
// R_n layout: texel (x * 2^n + ii, y). T_n layout: texel (x * (2^n + 1) + k, y).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D r_next;  // R_{n+1}
layout(rgba16f, set = 0, binding = 1) uniform restrict readonly image2D t_cur;   // T_n
layout(rgba16f, set = 0, binding = 2) uniform restrict readonly image2D t_next;  // T_{n+1}
layout(rgba16f, set = 0, binding = 3) uniform restrict writeonly image2D r_out;  // R_n
layout(rgba16f, set = 0, binding = 4) uniform restrict writeonly image2D accum;  // this quadrant's fluence (scene space)

layout(push_constant, std430) uniform Params {
	int n;
	int quadrant;
	int wc;
	int hc;
	int w;
	int h;
	int is_top;
	int pad0;
} pc;

ivec2 to_scene(ivec2 c) {
	switch (pc.quadrant) {
		case 0: return c;
		case 1: return ivec2(pc.w - 1 - c.x, c.y);
		case 2: return c.yx;
		default: return ivec2(c.y, pc.h - 1 - c.x);
	}
}

// angle(v_m(k)) for (possibly half-integer) k.
float angle_v(int m, float k) {
	float s = float(1 << m);
	return atan(2.0 * k - s, s);
}

// Eq. 13: angular size of cone j at cascade m.
float cone_size(int m, float j) {
	return angle_v(m, j + 0.5) - angle_v(m, j - 0.5);
}

vec4 load_t_cur(ivec2 p, int k) {
	int K = 1 << pc.n;
	return imageLoad(t_cur, ivec2((p.x >> pc.n) * (K + 1) + k, p.y));
}

vec4 load_t_next(ivec2 p, int k) {
	int m = pc.n + 1;
	int K = 1 << m;
	return imageLoad(t_next, ivec2((p.x >> m) * (K + 1) + k, p.y));
}

vec3 load_r_next(ivec2 p, int jj) {
	if (pc.is_top != 0 || p.x >= pc.wc || p.y < 0 || p.y >= pc.hc) {
		return vec3(0.0);
	}
	int m = pc.n + 1;
	int K = 1 << m;
	return imageLoad(r_next, ivec2((p.x >> m) * K + jj, p.y)).rgb;
}

void main() {
	ivec2 g = ivec2(gl_GlobalInvocationID.xy);
	int n = pc.n;
	int K = 1 << n;
	int num_px = (pc.wc + K - 1) >> n;
	int x = g.x / K;
	int ii = g.x - x * K;
	if (x >= num_px || g.y >= pc.hc) {
		return;
	}

	ivec2 p = ivec2(x << n, g.y);

	// Upper / lower halves of cone i.
	int jj_plus = 2 * ii + 1;  // j+ = 2i + 1/2
	int jj_minus = 2 * ii;     // j- = 2i - 1/2
	float a_plus = cone_size(n + 1, float(jj_plus) + 0.5);
	float a_minus = cone_size(n + 1, float(jj_minus) + 0.5);
	int k_up = ii + 1;  // i + 1/2
	int k_lo = ii;      // i - 1/2
	ivec2 v_up = ivec2(K, 2 * k_up - K);  // v_n(i + 1/2)
	ivec2 v_lo = ivec2(K, 2 * k_lo - K);  // v_n(i - 1/2)

	vec3 f_plus;
	vec3 f_minus;

	if ((x & 1) == 1) {
		// Eq. 14
		vec4 t_up = load_t_cur(p, k_up);
		vec4 t_lo = load_t_cur(p, k_lo);
		f_plus = a_plus * t_up.rgb + t_up.a * load_r_next(p + v_up, jj_plus);
		f_minus = a_minus * t_lo.rgb + t_lo.a * load_r_next(p + v_lo, jj_minus);
	} else {
		// Eq. 15-17
		vec3 f0_plus = load_r_next(p, jj_plus);
		vec3 f0_minus = load_r_next(p, jj_minus);
		vec4 t_up = load_t_next(p, 2 * k_up);
		vec4 t_lo = load_t_next(p, 2 * k_lo);
		vec3 f1_plus = a_plus * t_up.rgb + t_up.a * load_r_next(p + 2 * v_up, jj_plus);
		vec3 f1_minus = a_minus * t_lo.rgb + t_lo.a * load_r_next(p + 2 * v_lo, jj_minus);
		f_plus = 0.5 * (f0_plus + f1_plus);
		f_minus = 0.5 * (f0_minus + f1_minus);
	}

	vec3 r = f_plus + f_minus;

	if (n == 0) {
		// Each quadrant has its own accumulator, so quadrants never wait on each other.
		imageStore(accum, to_scene(p), vec4(r, 1.0));
	} else {
		imageStore(r_out, g, vec4(r, 1.0));
	}
}
