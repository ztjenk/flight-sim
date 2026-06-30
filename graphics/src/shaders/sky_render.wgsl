// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

// Sky Rendering Shader
// Fullscreen triangle that samples sky-view LUT and adds sun disk

struct AtmosphereUniforms {
    earth_radius: f32,
    atmosphere_radius: f32,
    rayleigh_scale_height: f32,
    mie_scale_height: f32,

    rayleigh_scattering: vec3<f32>,
    mie_scattering: f32,

    mie_extinction: f32,
    mie_asymmetry_g: f32,
    ozone_center_height: f32,
    ozone_width: f32,

    ozone_absorption: vec3<f32>,
    ground_albedo: f32,

    sun_direction: vec3<f32>,
    sun_intensity: f32,

    sun_angular_radius: f32,
    exposure: f32,
    camera_height: f32,
    _pad: f32,
};

struct SkyCameraUniforms {
    inv_view_col0: vec4<f32>,
    inv_view_col1: vec4<f32>,
    inv_view_col2: vec4<f32>,
    fov_y: f32,
    aspect_ratio: f32,
    _pad: vec2<f32>,
};

@group(0) @binding(0) var<uniform> atmosphere: AtmosphereUniforms;
@group(1) @binding(0) var skyview_lut: texture_2d<f32>;
@group(1) @binding(1) var transmittance_lut: texture_2d<f32>;
@group(1) @binding(2) var lut_sampler: sampler;
@group(2) @binding(0) var<uniform> sky_camera: SkyCameraUniforms;

const PI: f32 = 3.14159265359;

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

// Fullscreen triangle vertices
@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32) -> VertexOutput {
    var out: VertexOutput;

    // Generate fullscreen triangle (covers [-1,1] NDC)
    let x = f32((vertex_index << 1u) & 2u);
    let y = f32(vertex_index & 2u);

    out.position = vec4<f32>(x * 2.0 - 1.0, 1.0 - y * 2.0, 1.0, 1.0); // z=1 for far plane
    out.uv = vec2<f32>(x, y);

    return out;
}

// Sample transmittance for sun disk
// Must invert the parameterization used in uv_to_transmittance_params:
// cos_zenith = (H² - ρ² - d²) / (2*r*d)
// Solving for d: d = -r*cos_zenith + sqrt(r²*cos_zenith² + H² - ρ²)
fn sample_transmittance(altitude: f32, cos_zenith: f32) -> vec3<f32> {
    let H = sqrt(atmosphere.atmosphere_radius * atmosphere.atmosphere_radius -
                 atmosphere.earth_radius * atmosphere.earth_radius);
    let r = atmosphere.earth_radius + altitude;
    let rho = sqrt(max(0.0, r * r - atmosphere.earth_radius * atmosphere.earth_radius));

    // Solve quadratic to get d from cos_zenith (inverse of LUT parameterization)
    let discriminant = r * r * cos_zenith * cos_zenith + H * H - rho * rho;
    let d = -r * cos_zenith + sqrt(max(0.0, discriminant));

    let d_min = atmosphere.atmosphere_radius - r;
    let d_max = rho + H;

    let uv = vec2<f32>(
        clamp((d - d_min) / (d_max - d_min), 0.0, 1.0),
        clamp(rho / H, 0.0, 1.0)
    );

    return textureSampleLevel(transmittance_lut, lut_sampler, uv, 0.0).rgb;
}

// Convert clip space to world-space view direction using camera matrix
fn clip_to_view_dir(clip_xy: vec2<f32>) -> vec3<f32> {
    // Scale clip coords by FOV to get camera-space direction
    let half_fov_y = sky_camera.fov_y * 0.5;
    let tan_half_fov = tan(half_fov_y);

    // Camera-space direction (looking down -Z in camera space)
    let cam_dir = vec3<f32>(
        clip_xy.x * tan_half_fov * sky_camera.aspect_ratio,
        clip_xy.y * tan_half_fov,
        -1.0
    );

    // Transform to world space using inverse view rotation
    let inv_view = mat3x3<f32>(
        sky_camera.inv_view_col0.xyz,
        sky_camera.inv_view_col1.xyz,
        sky_camera.inv_view_col2.xyz
    );

    return normalize(inv_view * cam_dir);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    // Convert UV to clip space [-1, 1]
    // Note: Y is flipped because vertex shader uses (1.0 - y*2.0) for position.y
    // but UV stores raw y, so we need to flip Y here to match clip space
    let clip_xy = vec2<f32>(in.uv.x * 2.0 - 1.0, 1.0 - in.uv.y * 2.0);

    // Get world-space view direction using camera matrix
    let view_dir = clip_to_view_dir(clip_xy);

    // Convert view direction to skyview LUT coordinates
    // In NED: X=North, Y=East, Z=Down
    // elevation: angle from horizontal plane (positive = up, negative = down)
    // For sky: we want elevation from horizon, where up is positive
    let elevation = asin(clamp(-view_dir.z, -1.0, 1.0));  // -Z because Z is down in NED
    let azimuth = atan2(view_dir.y, view_dir.x);  // Y=East, X=North

    let lut_uv = vec2<f32>(
        (azimuth + PI) / (2.0 * PI),
        (elevation / PI) + 0.5
    );

    // Sample sky color from LUT
    var sky_color = textureSampleLevel(skyview_lut, lut_sampler, lut_uv, 0.0).rgb;

    // Add sun disk
    let sun_cos = dot(view_dir, atmosphere.sun_direction);
    let sun_angle = acos(clamp(sun_cos, -1.0, 1.0));

    if (sun_angle < atmosphere.sun_angular_radius) {
        // Inside sun disk
        // Limb darkening: center is brighter than edge
        let limb = 1.0 - sun_angle / atmosphere.sun_angular_radius;
        let limb_darkening = pow(limb, 0.5);

        // Sun transmittance (how much sun light reaches us)
        let sun_trans = sample_transmittance(atmosphere.camera_height, -atmosphere.sun_direction.z);

        // Add sun radiance (very bright!)
        let sun_radiance = sun_trans * atmosphere.sun_intensity * 1000.0 * limb_darkening;
        sky_color += sun_radiance;
    } else if (sun_angle < atmosphere.sun_angular_radius * 1.5) {
        // Sun corona/glow (subtle bloom around sun)
        let glow = 1.0 - (sun_angle - atmosphere.sun_angular_radius) /
                        (atmosphere.sun_angular_radius * 0.5);
        let sun_trans = sample_transmittance(atmosphere.camera_height, -atmosphere.sun_direction.z);
        sky_color += sun_trans * atmosphere.sun_intensity * glow * glow * 10.0;
    }

    // ========== ARTISTIC ENHANCEMENTS (Unreal-style) ==========

    // Sun elevation: 0 = at horizon, positive = above, negative = below
    // In NED, sun_direction.z < 0 means sun is up
    let sun_elevation = -atmosphere.sun_direction.z;

    // Sunset intensity: strongest when sun is near horizon (-0.1 to 0.2)
    // Gradually fades as sun goes higher or below horizon
    let sunset_strength = 1.0 - smoothstep(0.0, 0.4, abs(sun_elevation - 0.05));

    // View elevation factor: 1.0 at horizon, fading to 0 at zenith
    // elevation is in radians, 0 at horizon, PI/2 at zenith
    let horizon_band = 1.0 - smoothstep(0.0, 1.2, elevation);  // wider band
    let horizon_band_strong = pow(horizon_band, 0.7);  // less aggressive falloff

    // ===== HORIZON COLOR BAND (the key to good sunsets) =====
    // The entire horizon should be warm at sunset, not just near the sun
    let horizon_orange = vec3<f32>(1.0, 0.45, 0.15);   // rich orange
    let horizon_pink = vec3<f32>(0.95, 0.4, 0.5);      // pink/magenta
    let horizon_yellow = vec3<f32>(1.0, 0.7, 0.3);     // golden yellow

    // Blend horizon colors based on elevation within the band
    let horizon_color = mix(horizon_orange, horizon_pink, smoothstep(0.0, 0.8, elevation));

    // Add golden tint near the very bottom of sky
    let near_horizon = 1.0 - smoothstep(0.0, 0.3, elevation);
    let horizon_final = mix(horizon_color, horizon_yellow, near_horizon * 0.5);

    // ===== SUN PROXIMITY GLOW (Mie-like forward scattering) =====
    // This creates the bright glow spreading from the sun
    let sun_proximity = max(0.0, sun_cos);
    let sun_glow_wide = pow(sun_proximity, 2.0);   // wide soft glow
    let sun_glow_tight = pow(sun_proximity, 8.0);  // tight bright core

    // Sun glow color - more yellow/white near sun, orange further out
    let glow_color_core = vec3<f32>(1.0, 0.85, 0.6);   // warm white/yellow
    let glow_color_wide = vec3<f32>(1.0, 0.5, 0.2);    // orange

    // ===== APPLY EFFECTS =====

    // 1. Subtle warm tint near horizon (very gentle blend)
    let horizon_blend = horizon_band_strong * sunset_strength * 0.15;  // much more subtle
    sky_color = mix(sky_color, sky_color * horizon_final, horizon_blend);

    // 2. Add sun glow (subtle additive glow near sun)
    let glow_intensity = sunset_strength * atmosphere.sun_intensity * 0.003;
    sky_color += glow_color_wide * sun_glow_wide * glow_intensity;
    sky_color += glow_color_core * sun_glow_tight * glow_intensity * 2.0;

    // 3. Mild saturation boost (just enough to enhance natural colors)
    let gray = dot(sky_color, vec3<f32>(0.299, 0.587, 0.114));
    let saturation_boost = 1.0 + sunset_strength * 0.2;  // 1.0x to 1.2x saturation
    sky_color = mix(vec3<f32>(gray), sky_color, saturation_boost);

    // ========== TONE MAPPING (ACES-inspired for better color preservation) ==========
    let exposed = sky_color * atmosphere.exposure;

    // ACES-like filmic tone mapping (preserves warm colors better than Reinhard)
    let a = 2.51;
    let b = 0.03;
    let c = 2.43;
    let d = 0.59;
    let e = 0.14;
    let tone_mapped = clamp((exposed * (a * exposed + b)) / (exposed * (c * exposed + d) + e), vec3<f32>(0.0), vec3<f32>(1.0));

    // Output linear: the surface is an sRGB format (see renderer/context.rs surface_format), so the
    // hardware applies gamma encoding. A manual pow(1/2.2) here would double-encode — mesh, terrain,
    // and grid all output linear too.
    return vec4<f32>(tone_mapped, 1.0);
}
