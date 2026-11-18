#[compute]
#version 450

// Final pass (paper Sec. 4.2): 1px cross blur of the summed 4-quadrant fluence with kernel
//   1/8 * [[0,1,0],[1,4,1],[0,1,0]]                                                 (21)
// ignoring neighbours whose opacity differs significantly from the centre pixel
// (weights are renormalised).
// Writes the raw fluence (used for further bounces) and a display texture scaled by
// exposure / (2*pi), i.e. the average incoming radiance.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D accum;
layout(rgba16f, set = 0, binding = 1) uniform restrict readonly image2D emit;  // .a = mu
layout(rgba16f, set = 0, binding = 2) uniform restrict writeonly image2D fluence;
layout(rgba16f, set = 0, binding = 3) uniform restrict writeonly image2D display;

layout(push_constant, std430) uniform Params {
	ivec2 size;
	int apply_blur;
	float exposure;
	ivec4 pad;
} pc;

const float TAU = 6.28318530718;
const float OPACITY_TOLERANCE = 0.25;

float opacity(ivec2 p) {
	return 1.0 - exp(-imageLoad(emit, p).a);
}

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= pc.size.x || p.y >= pc.size.y) {
		return;
	}

	vec3 c = imageLoad(accum, p).rgb;

	if (pc.apply_blur != 0) {
		float oc = opacity(p);
		vec3 sum = 4.0 * c;
		float wsum = 4.0;
		const ivec2 offs[4] = ivec2[4](ivec2(1, 0), ivec2(-1, 0), ivec2(0, 1), ivec2(0, -1));
		for (int i = 0; i < 4; i++) {
			ivec2 q = p + offs[i];
			if (q.x < 0 || q.y < 0 || q.x >= pc.size.x || q.y >= pc.size.y) {
				continue;
			}
			if (abs(opacity(q) - oc) > OPACITY_TOLERANCE) {
				continue;
			}
			sum += imageLoad(accum, q).rgb;
			wsum += 1.0;
		}
		c = sum / wsum;
	}

	imageStore(fluence, p, vec4(c, 1.0));
	imageStore(display, p, vec4(c * (pc.exposure / TAU), 1.0));
}
