#[compute]
#version 450

// HRC Merge Down Pass: Computes R_n from R_{n+1} using T_n
// R_n(p, i) = F+ + F- where F+/F- come from merging traced intervals with R_{n+1}
// This resolves the radiance probe values from highest to lowest cascade

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// R_{n+1}: radiance from previous (higher) level
// Format: x = px, y = py + height * i_idx (i = direction index for cascade n+1)
layout(set = 0, binding = 0) uniform sampler2D r_high;

// T_n: ray intervals for current cascade
layout(set = 0, binding = 1) uniform sampler2D t_n;

// T_{n+1}: ray intervals for higher cascade (needed for even x case)
layout(set = 0, binding = 2) uniform sampler2D t_n1;

// R_n output
layout(rgba16f, set = 0, binding = 3) uniform writeonly image2D r_out;

layout(push_constant, std430) uniform Params {
    int cascade_n;          // current n being computed
    int scene_width;
    int scene_height;
    int directions_n;       // 2^n (directions at level n)
    int directions_n1;      // 2^(n+1)
    int is_top_level;       // 1 if n+1 is top (R_{n+1} = 0)
} params;

// Merge r_near + t_near * r_far
vec4 merge_r(vec4 near_rt, vec4 far_r) {
    return vec4(near_rt.rgb + near_rt.a * far_r.rgb, near_rt.a);
}

// Angular size of cone in direction i at cascade n
// A_n(i) = angle(v_n(i + 0.5)) - angle(v_n(i - 0.5))
float cone_angular_size(int n, float i) {
    float step = float(1 << n);
    float v_hi_y = 2.0 * (i + 0.5) - step;
    float v_lo_y = 2.0 * (i - 0.5) - step;
    float angle_hi = atan(v_hi_y, step);
    float angle_lo = atan(v_lo_y, step);
    return angle_hi - angle_lo;
}

// Sample T texture
vec4 sample_t(sampler2D t_tex, ivec2 probe_pos, int k_idx, int n, int width, int height) {
    int step = 1 << n;
    int px = probe_pos.x / step;
    int py = probe_pos.y;
    return texelFetch(t_tex, ivec2(px, py + height * k_idx), 0);
}

// Sample R texture
vec4 sample_r(sampler2D r_tex, ivec2 probe_pos, int i_idx, int n, int height) {
    int step = 1 << n;
    int px = probe_pos.x / step;
    int py = probe_pos.y;
    return texelFetch(r_tex, ivec2(px, py + height * i_idx), 0);
}

void main() {
    ivec2 gid = ivec2(gl_GlobalInvocationID.xy);
    int n = params.cascade_n;
    int dirs_n = params.directions_n;   // 2^n
    int dirs_n1 = params.directions_n1; // 2^(n+1)
    int step = 1 << n;
    int step_n1 = step << 1;
    
    // gid.x = packed(px, i_idx) where i ranges 0..dirs_n
    int i_idx = gid.x % dirs_n;
    int px = gid.x / dirs_n;
    int py = gid.y;
    
    int max_px = (params.scene_width + step - 1) / step;
    if (px >= max_px || py >= params.scene_height) return;
    
    ivec2 probe_pos = ivec2(px * step, py);
    
    // i is half-integer from 0.5 to dirs_n - 0.5, using i_idx as index
    // i = i_idx + 0.5 (as per paper: i takes half-integer values between 1/2 and 2^n - 1/2)
    // j+ = 2*i + 0.5 = 2*(i_idx+0.5) + 0.5 = 2*i_idx + 1.5
    // j- = 2*i - 0.5 = 2*(i_idx+0.5) - 0.5 = 2*i_idx + 0.5
    // In integer index terms for n+1 cascade (where j is i_idx+0.5 style):
    // j+ index = 2*i_idx + 1  (corresponding to i_idx+0.5 = 1.5, 2.5, ...)
    // j- index = 2*i_idx      (corresponding to i_idx+0.5 = 0.5, 1.5, ...)
    
    int j_plus_idx  = 2 * i_idx + 1; // j+ direction index at n+1
    int j_minus_idx = 2 * i_idx;     // j- direction index at n+1
    
    // v_n(i+0.5) = (2^n, 2*(i+0.5) - 2^n) = (step, 2*i_idx + 1 - step)
    // v_n(i-0.5) = (2^n, 2*(i+0.5) - 1 - 2^n) = (step, 2*i_idx - step)
    ivec2 q_plus  = probe_pos + ivec2(step, 2 * i_idx + 1 - step);
    ivec2 q_minus = probe_pos + ivec2(step, 2 * i_idx     - step);
    
    // T_n k index for v_n(i+/-0.5): k*2 = 2*i_idx+1 and 2*i_idx respectively
    int k_plus_t_n  = 2 * i_idx + 1; // half-integer index for T_n
    int k_minus_t_n = 2 * i_idx;
    
    vec4 f_plus, f_minus;
    
    if ((px & 1) == 1) {
        // Odd x: use Eq. 14
        // F± = Merge_r(A_{n+1}(j±) * Trace(p, q±), R_{n+1}(q±, j±))
        
        // Get T_n approximation for the ray p->q±
        vec4 trace_plus  = sample_t(t_n, probe_pos, k_plus_t_n,  n, params.scene_width, params.scene_height);
        vec4 trace_minus = sample_t(t_n, probe_pos, k_minus_t_n, n, params.scene_width, params.scene_height);
        
        // Scale by angular size
        float a_plus  = cone_angular_size(n + 1, float(j_plus_idx)  / 2.0 + 0.5);
        float a_minus = cone_angular_size(n + 1, float(j_minus_idx) / 2.0 + 0.5);
        
        // Get R_{n+1} at q±
        vec4 r_plus  = vec4(0.0);
        vec4 r_minus = vec4(0.0);
        
        if (params.is_top_level == 0) {
            bool q_plus_valid  = q_plus.y  >= 0 && q_plus.y  < params.scene_height && q_plus.x  < params.scene_width;
            bool q_minus_valid = q_minus.y >= 0 && q_minus.y < params.scene_height && q_minus.x < params.scene_width;
            
            if (q_plus_valid)  r_plus  = sample_r(r_high, q_plus,  j_plus_idx,  n + 1, params.scene_height);
            if (q_minus_valid) r_minus = sample_r(r_high, q_minus, j_minus_idx, n + 1, params.scene_height);
        }
        
        // Merge: a * trace is the angular fluence (scale radiance, keep transmittance)
        vec4 af_plus  = vec4(trace_plus.rgb  * a_plus,  trace_plus.a);
        vec4 af_minus = vec4(trace_minus.rgb * a_minus, trace_minus.a);
        
        f_plus  = merge_r(af_plus,  r_plus);
        f_minus = merge_r(af_minus, r_minus);
        
    } else {
        // Even x: use Eq. 15-17 to avoid center bias
        // F± = (F0± + F1±) / 2
        // F0± = R_{n+1}(p, j±)
        // F1± = Merge_r(A_{n+1}(j±) * Trace(p, q±*2), R_{n+1}(q±*2, j±))
        
        // q for 2*v_n: q± * 2 relative to p
        ivec2 q2_plus  = probe_pos + ivec2(step_n1, 2 * (2 * i_idx + 1) - step_n1);
        ivec2 q2_minus = probe_pos + ivec2(step_n1, 2 * (2 * i_idx)     - step_n1);
        
        // F0 from R_{n+1}(p, j±) -- note p is even so it exists at n+1 cascade
        vec4 f0_plus  = vec4(0.0);
        vec4 f0_minus = vec4(0.0);
        
        if (params.is_top_level == 0) {
            f0_plus  = sample_r(r_high, probe_pos, j_plus_idx,  n + 1, params.scene_height);
            f0_minus = sample_r(r_high, probe_pos, j_minus_idx, n + 1, params.scene_height);
        }
        
        // T_{n+1} approximation for 2*v_n = v_{n+1}
        // k_idx for n+1: 2*(2*i_idx+1) = 4*i_idx+2 and 2*(2*i_idx) = 4*i_idx
        vec4 trace2_plus  = sample_t(t_n1, probe_pos, 4 * i_idx + 2, n + 1, params.scene_width, params.scene_height);
        vec4 trace2_minus = sample_t(t_n1, probe_pos, 4 * i_idx,     n + 1, params.scene_width, params.scene_height);
        
        float a_plus  = cone_angular_size(n + 1, float(j_plus_idx)  / 2.0 + 0.5);
        float a_minus = cone_angular_size(n + 1, float(j_minus_idx) / 2.0 + 0.5);
        
        vec4 r_q2_plus  = vec4(0.0);
        vec4 r_q2_minus = vec4(0.0);
        
        if (params.is_top_level == 0) {
            bool q2_plus_valid  = q2_plus.y  >= 0 && q2_plus.y  < params.scene_height && q2_plus.x  < params.scene_width;
            bool q2_minus_valid = q2_minus.y >= 0 && q2_minus.y < params.scene_height && q2_minus.x < params.scene_width;
            if (q2_plus_valid)  r_q2_plus  = sample_r(r_high, q2_plus,  j_plus_idx,  n + 1, params.scene_height);
            if (q2_minus_valid) r_q2_minus = sample_r(r_high, q2_minus, j_minus_idx, n + 1, params.scene_height);
        }
        
        vec4 af2_plus  = vec4(trace2_plus.rgb  * a_plus,  trace2_plus.a);
        vec4 af2_minus = vec4(trace2_minus.rgb * a_minus, trace2_minus.a);
        
        vec4 f1_plus  = merge_r(af2_plus,  r_q2_plus);
        vec4 f1_minus = merge_r(af2_minus, r_q2_minus);
        
        f_plus  = (f0_plus  + f1_plus)  * 0.5;
        f_minus = (f0_minus + f1_minus) * 0.5;
    }
    
    vec4 result = vec4((f_plus + f_minus).rgb, 1.0);
    
    // Write R_n
    ivec2 out_coord = ivec2(px, py + params.scene_height * i_idx);
    imageStore(r_out, out_coord, result);
}
