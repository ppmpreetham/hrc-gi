#[compute]
#version 450

// T_n(p, k) approximates Trace(p, p + v_n(k))
// For n=0..2: directly ray-traced (done in trace_base.glsl)
// For n=3..N: computed from T_{n-1} via Eq. 18 and 20

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Scene: RGBA = (emission.rgb, extinction)
layout(set = 0, binding = 0) uniform sampler2D scene_tex;

// T_n input (previous level): packed as (radiance.rgb, transmittance)
layout(set = 0, binding = 1) uniform sampler2D t_prev;

// T_n output (this level)
layout(rgba16f, set = 0, binding = 2) uniform writeonly image2D t_curr;

layout(push_constant, std430) uniform Params {
    int cascade_n;      // current n (level being written)
    int scene_width;
    int scene_height;
    int directions;     // 2^n directions in this cascade
    float base_spacing; // probe spacing = 2^n
} params;

// Merge two ray intervals: (r_near, t_near) + (r_far, t_far) -> (r_near + t_near*r_far, t_near*t_far)
vec4 merge_intervals(vec4 near, vec4 far) {
    // near/far: .rgb = radiance, .a = transmittance
    return vec4(near.rgb + near.a * far.rgb, near.a * far.a);
}

// Get probe position for cascade n, probe index (px, py), direction k
// v_n(k) = (2^n, 2k - 2^n)
ivec2 v_n(int n, float k) {
    int step = 1 << n;
    return ivec2(step, int(round(2.0 * k)) - step);
}

// Sample T from texture at probe position p, direction k
// Texture layout: for cascade n, stored as 2D array
// x coord = px (probe x index), y coord = py + scene_height * k_index
vec4 sample_t(sampler2D tex, ivec2 probe_pos, int k_idx, int n, int width, int height) {
    // probe_pos.x is already pixel x (multiples of 2^n)
    int num_probes_x = (width >> n) + 1;
    int px = probe_pos.x >> n; // probe index
    int py = probe_pos.y;
    // Pack: x = px, y = py + height * k_idx
    ivec2 tc = ivec2(px, py + height * k_idx);
    return texelFetch(tex, tc, 0);
}

void main() {
    ivec2 gid = ivec2(gl_GlobalInvocationID.xy);
    int n = params.cascade_n;
    int dirs = params.directions; // 2^n
    int step = 1 << n; // 2^n
    int prev_step = step >> 1; // 2^(n-1)
    int prev_dirs = dirs >> 1; // 2^(n-1)

    // gid.x = probe index px (0..ceil(W/step))
    // gid.y = py (0..H)

    int total_k = 2 * dirs + 1; // half-integer k from 0 to dirs, step 0.5 -> indices 0..2*dirs
    int packed_x = gid.x;
    int k_idx = packed_x % total_k; // k * 2 (to handle half-integers as integers)
    int px = packed_x / total_k;

    int max_px = (params.scene_width + step - 1) / step;
    if (px >= max_px || gid.y >= params.scene_height) return;

    ivec2 probe_pos = ivec2(px * step, gid.y);
    
    // k as float half-integer: k_idx/2.0 ranges from 0.0 to dirs
    float k = float(k_idx) / 2.0;

    vec4 result;

    if ((k_idx & 1) == 0) {
        // k is integer: use Eq. 18
        // T_n+1(p, 2k) = Merge(T_n(p, k), T_n(p + v_n(k), k))
        // computing T_n from T_{n-1}: T_n(p, k_int)
        // k_int = k_idx/2
        int k_int = k_idx / 2; // 0..dirs (integer k)
        
        // for even 2k: T_n(p, k) = Merge(T_{n-1}(p, k/2), T_{n-1}(p + v_{n-1}(k/2), k/2))
        // but k here refers to n-1 level:
        // T_n(p, k) where k is integer 0..2^n corresponds to:
        // near: T_{n-1}(p, k) -- half the ray
        // far:  T_{n-1}(p + v_{n-1}(k), k)
        
        // v_{n-1}(k) with prev_step
        ivec2 offset = ivec2(prev_step, 2 * k_int - prev_step);
        ivec2 far_probe = probe_pos + offset;
        
        // clamp far probe to scene
        if (far_probe.y < 0 || far_probe.y >= params.scene_height || far_probe.x >= params.scene_width) {
            // out of bounds: use near only with transmittance 1 beyond
            vec4 near_val = sample_t(t_prev, probe_pos, k_int, n - 1, params.scene_width, params.scene_height);
            result = near_val;
        } else {
            vec4 near_val = sample_t(t_prev, probe_pos, k_int, n - 1, params.scene_width, params.scene_height);
            vec4 far_val  = sample_t(t_prev, far_probe, k_int, n - 1, params.scene_width, params.scene_height);
            result = merge_intervals(near_val, far_val);
        }
    } else {
        // k is half-integer: use Eq. 19-20
        // Blend two closest approximations
        // k+0.5 and k-0.5 are integers at indices k_idx+1 and k_idx-1
        int k_lo = (k_idx - 1) / 2; // floor(k)
        int k_hi = (k_idx + 1) / 2; // ceil(k) = k_lo + 1
        
        // F- using k_lo: Merge(T_{n-1}(p, k_lo), T_{n-1}(p + v_{n-1}(k_lo), k_hi))  
        // F+ using k_hi: Merge(T_{n-1}(p, k_hi), T_{n-1}(p + v_{n-1}(k_hi), k_lo))
        
        ivec2 offset_lo = ivec2(prev_step, 2 * k_lo - prev_step);
        ivec2 offset_hi = ivec2(prev_step, 2 * k_hi - prev_step);
        ivec2 far_lo = probe_pos + offset_lo;
        ivec2 far_hi = probe_pos + offset_hi;
        
        vec4 near_lo = sample_t(t_prev, probe_pos, k_lo, n - 1, params.scene_width, params.scene_height);
        vec4 near_hi = sample_t(t_prev, probe_pos, k_hi, n - 1, params.scene_width, params.scene_height);
        
        vec4 f_minus, f_plus;
        
        if (far_lo.y >= 0 && far_lo.y < params.scene_height && far_lo.x < params.scene_width) {
            vec4 far_lo_val = sample_t(t_prev, far_lo, k_hi, n - 1, params.scene_width, params.scene_height);
            f_minus = merge_intervals(near_lo, far_lo_val);
        } else {
            f_minus = near_lo;
        }
        
        if (far_hi.y >= 0 && far_hi.y < params.scene_height && far_hi.x < params.scene_width) {
            vec4 far_hi_val = sample_t(t_prev, far_hi, k_lo, n - 1, params.scene_width, params.scene_height);
            f_plus = merge_intervals(near_hi, far_hi_val);
        } else {
            f_plus = near_hi;
        }
        
        result = (f_minus + f_plus) * 0.5;
    }

    // Write to output
    int out_total_k = 2 * dirs + 1;
    ivec2 out_coord = ivec2(px, gid.y + params.scene_height * k_idx);
    imageStore(t_curr, out_coord, result);
}
