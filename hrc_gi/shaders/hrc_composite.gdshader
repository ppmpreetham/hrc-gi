shader_type canvas_item;
render_mode blend_disabled, unshaded;

// R0 from each quadrant pass (rotated into canonical orientation)
uniform sampler2D r0_right;   // +x quadrant
uniform sampler2D r0_left;    // -x quadrant (rotated 180)
uniform sampler2D r0_up;      // +y quadrant (rotated 90)
uniform sampler2D r0_down;    // -y quadrant (rotated 270)

uniform int scene_width;
uniform int scene_height;
uniform bool apply_cross_blur = true;

// Sample R0 fluence for a pixel at integer offset
vec3 sample_r0(sampler2D r0_tex, vec2 uv) {
    return texture(r0_tex, uv).rgb;
}

// Cross blur kernel: 1/8 * [0,1,0; 1,4,1; 0,1,0]
vec3 cross_blur_r0(sampler2D r0_tex, vec2 uv, vec2 texel_size) {
    vec3 center = texture(r0_tex, uv).rgb;
    vec3 left   = texture(r0_tex, uv + vec2(-texel_size.x, 0.0)).rgb;
    vec3 right  = texture(r0_tex, uv + vec2( texel_size.x, 0.0)).rgb;
    vec3 up     = texture(r0_tex, uv + vec2(0.0,  texel_size.y)).rgb;
    vec3 down   = texture(r0_tex, uv + vec2(0.0, -texel_size.y)).rgb;
    return (4.0 * center + left + right + up + down) / 8.0;
}

void fragment() {
    vec2 texel = TEXTURE_PIXEL_SIZE;
    
    // Each quadrant provides R0 at offset position
    // R0[x+1, y] is the +x angular fluence for pixel [x, y]
    // So we sample with +1 pixel offset in x
    vec2 uv_right = UV + vec2(texel.x, 0.0);
    vec2 uv_left  = UV - vec2(texel.x, 0.0);
    vec2 uv_up    = UV + vec2(0.0, texel.y);
    vec2 uv_down  = UV - vec2(0.0, texel.y);
    
    vec3 fluence = vec3(0.0);
    
    if (apply_cross_blur) {
        fluence += cross_blur_r0(r0_right, uv_right, texel);
        fluence += cross_blur_r0(r0_left,  uv_left,  texel);
        fluence += cross_blur_r0(r0_up,    uv_up,    texel);
        fluence += cross_blur_r0(r0_down,  uv_down,  texel);
    } else {
        fluence += texture(r0_right, uv_right).rgb;
        fluence += texture(r0_left,  uv_left).rgb;
        fluence += texture(r0_up,    uv_up).rgb;
        fluence += texture(r0_down,  uv_down).rgb;
    }
    
    // Tone map and output
    COLOR = vec4(fluence, 1.0);
}
