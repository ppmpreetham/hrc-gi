#[compute]
#version 450

// Multiple diffuse bounces (paper Sec. 4.2): feed the output fluence back in as an in-scattering
// source term for another iteration of the algorithm:
//   S' = S_emit + albedo * mu * F / (2*pi)       (isotropic 2D phase function = 1 / 2pi)
// For dense pixels (opaque surfaces) the fluence *inside* the pixel is heavily attenuated, so the
// incoming fluence is estimated from the adjacent less-dense pixels instead (the surface).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D emit;
layout(rgba16f, set = 0, binding = 1) uniform restrict readonly image2D albedo;
layout(rgba16f, set = 0, binding = 2) uniform restrict readonly image2D fluence;
layout(rgba16f, set = 0, binding = 3) uniform restrict writeonly image2D src;

layout(push_constant, std430) uniform Params {
	ivec2 size;
	ivec2 pad0;
	ivec4 pad1;
} pc;

const float TAU = 6.28318530718;

float opacity(float mu) {
	return 1.0 - exp(-mu);
}

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= pc.size.x || p.y >= pc.size.y) {
		return;
	}

	vec4 e = imageLoad(emit, p);
	vec3 a = imageLoad(albedo, p).rgb;

	vec3 f = imageLoad(fluence, p).rgb;
	if (opacity(e.a) > 0.5) {
		vec3 sum = vec3(0.0);
		float cnt = 0.0;
		const ivec2 offs[4] = ivec2[4](ivec2(1, 0), ivec2(-1, 0), ivec2(0, 1), ivec2(0, -1));
		for (int i = 0; i < 4; i++) {
			ivec2 q = p + offs[i];
			if (q.x < 0 || q.y < 0 || q.x >= pc.size.x || q.y >= pc.size.y) {
				continue;
			}
			if (opacity(imageLoad(emit, q).a) <= 0.5) {
				sum += imageLoad(fluence, q).rgb;
				cnt += 1.0;
			}
		}
		if (cnt > 0.0) {
			f = sum / cnt;
		}
	}

	imageStore(src, p, vec4(e.rgb + a * e.a * f / TAU, e.a));
}
