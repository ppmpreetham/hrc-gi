#[compute]
#version 450

// HRC Base Trace Pass: directly ray-trace T_n for n=0,1,2
// DDA to march through scene pixels and integrate radiance/transmittance

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// RGB = emission color, A = extinction coefficient (0=empty, 1=solid)
layout(set = 0, binding = 0) uniform sampler2D scene_tex;

// Output T_n: RGB = accumulated radiance, A = transmittance
layout(rgba16f, set = 0, binding = 1) uniform writeonly image2D t_out;

layout(push_constant, std430) uniform Params {
    int cascade_n;      // 0, 1, or 2
    int scene_width;
    int scene_height;
    int directions;     // 2^n
} params;

// DDA ray march from start to end pixel, accumulate radiance/transmittance
// Returns vec4(radiance.rgb, transmittance)
vec4 trace_ray(vec2 p_start, vec2 p_end, sampler2D scene) {
    vec2 dir = p_end - p_start;
    float dist = length(dir);
    if (dist < 0.001) return vec4(0.0, 0.0, 0.0, 1.0);
    
    dir /= dist;
    
    // DDA setup
    ivec2 cell = ivec2(floor(p_start));
    ivec2 end_cell = ivec2(floor(p_end));
    ivec2 step_sign = ivec2(sign(dir));
    
    vec2 t_delta = abs(vec2(1.0) / max(abs(dir), vec2(0.0001)));
    vec2 t_max;
    
    // Initial t_max to first cell boundary
    if (dir.x > 0.0) t_max.x = (float(cell.x + 1) - p_start.x) * t_delta.x;
    else if (dir.x < 0.0) t_max.x = (p_start.x - float(cell.x)) * t_delta.x;
    else t_max.x = 1e30;
    
    if (dir.y > 0.0) t_max.y = (float(cell.y + 1) - p_start.y) * t_delta.y;
    else if (dir.y < 0.0) t_max.y = (p_start.y - float(cell.y)) * t_delta.y;
    else t_max.y = 1e30;
    
    vec3 accum_radiance = vec3(0.0);
    float accum_transmittance = 1.0;
    float t_current = 0.0;
    
    int max_steps = int(dist) + 2;
    
    for (int i = 0; i < max_steps && i < 512; i++) {
        if (cell.x < 0 || cell.x >= params.scene_width || 
            cell.y < 0 || cell.y >= params.scene_height) break;
        
        float t_next = min(t_max.x, t_max.y);
        t_next = min(t_next, dist);
        
        float seg_len = t_next - t_current;
        if (seg_len <= 0.0) break;
        
        vec4 scene_val = texelFetch(scene, cell, 0);
        vec3 emission = scene_val.rgb;
        float extinction = scene_val.a;
        
        // Integrate: assuming uniform extinction and emission within pixel
        // L_r(p <- q) integral solution
        if (extinction > 0.0001) {
            float optical_depth = extinction * seg_len;
            float seg_transmittance = exp(-optical_depth);
            
            // Integrated emission contribution
            vec3 seg_radiance = emission * (1.0 - seg_transmittance) / extinction;
            
            accum_radiance += accum_transmittance * seg_radiance;
            accum_transmittance *= seg_transmittance;
        }
        
        t_current = t_next;
        if (t_current >= dist) break;
        
        // adv DDA
        if (t_max.x < t_max.y) {
            t_max.x += t_delta.x;
            cell.x += step_sign.x;
        } else {
            t_max.y += t_delta.y;
            cell.y += step_sign.y;
        }
        
        if (cell == end_cell) break;
    }
    
    return vec4(accum_radiance, accum_transmittance);
}

// v_n(k) offset vector: (2^n, 2k - 2^n)
ivec2 v_n_int(int n, int k_times2) {
    int step = 1 << n;
    return ivec2(step, k_times2 - step);
}

void main() {
    ivec2 gid = ivec2(gl_GlobalInvocationID.xy);
    int n = params.cascade_n;
    int dirs = params.directions; // 2^n
    int step = 1 << n;
    int total_k = 2 * dirs + 1; // k*2 from 0 to 2*dirs (covers k=0.0 to k=dirs in 0.5 steps)
    
    // gid.x = px * total_k + k_idx
    int k_idx = gid.x % total_k;
    int px = gid.x / total_k;
    int py = gid.y;
    
    int max_px = (params.scene_width + step - 1) / step;
    if (px >= max_px || py >= params.scene_height) return;
    
    ivec2 probe_pos = ivec2(px * step, py);
    
    // offset v_n(k) where k = k_idx/2.0
    // for integer k: straightforward
    // for half-integer k: use actual direction
    int vx = step;
    int vy = k_idx - step; // = 2*(k_idx/2) - step when k_idx even, gives v_n(k)
    // for k = k_idx/2.0: v = (2^n, 2*(k_idx/2.0) - 2^n) = (step, k_idx - step)
    
    vec2 ray_start = vec2(probe_pos) + vec2(0.5);
    vec2 ray_end = ray_start + vec2(vx, vy);
    
    vec4 result = trace_ray(ray_start, ray_end, scene_tex);
    
    // texture layout: x = px, y = py + height * k_idx
    ivec2 out_coord = ivec2(px, py + params.scene_height * k_idx);
    imageStore(t_out, out_coord, result);
}
