#[compute]
#version 450

// Final pass (paper Sec. 4.2): 1px cross blur of the summed 4-quadrant fluence with kernel
//   1/8 * [[0,1,0],[1,4,1],[0,1,0]]                                                 (21)
// ignoring neighbours whose opacity differs significantly from the centre pixel
// (weights are renormalised).
// Writes the raw fluence (used for further bounces) and a display texture scaled by
// exposure / (2*pi), i.e. the average incoming radiance.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D accum0;  // one per quadrant
layout(rgba16f, set = 0, binding = 1) uniform restrict readonly image2D accum1;
layout(rgba16f, set = 0, binding = 2) uniform restrict readonly image2D accum2;
layout(rgba16f, set = 0, binding = 3) uniform restrict readonly image2D accum3;
layout(rgba16f, set = 0, binding = 4) uniform restrict readonly image2D emit;  // .a = mu
layout(rgba16f, set = 0, binding = 5) uniform restrict writeonly image2D fluence;
layout(rgba16f, set = 0, binding = 6) uniform restrict writeonly image2D display;

layout(push_constant, std430) uniform Params {
	ivec2 size;
	int apply_blur;
	float exposure;
	int srgb_output;  // 1: encode the display texture as sRGB (normal 2D); 0: keep linear (HDR 2D)
	int pad0;
	int pad1;
	int pad2;
} pc;

const float TAU = 6.28318530718;
const float OPACITY_TOLERANCE = 0.25;

// Sum of the 4 quadrants' fluence.
vec3 total(ivec2 p) {
	return imageLoad(accum0, p).rgb + imageLoad(accum1, p).rgb + imageLoad(accum2, p).rgb + imageLoad(accum3, p).rgb;
}

float opacity(ivec2 p) {
	return 1.0 - exp(-imageLoad(emit, p).a);
}

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= pc.size.x || p.y >= pc.size.y) {
		return;
	}

	vec3 c = total(p);

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
			sum += total(q);
			wsum += 1.0;
		}
		c = sum / wsum;
	}

	imageStore(fluence, p, vec4(c, 1.0));
	vec3 d = max(c * (pc.exposure / TAU), vec3(0.0));
	if (pc.srgb_output != 0) {
		// Exact sRGB transfer function (lighting itself is linear).
		d = mix(d * 12.92, 1.055 * pow(d, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), d));
	}
	imageStore(display, p, vec4(d, 1.0));
}
