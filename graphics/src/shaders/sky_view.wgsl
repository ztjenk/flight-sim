// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

// Sky-view LUT Compute Shader
// Maps (azimuth, elevation) -> RGB sky color for current camera position

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

@group(0) @binding(0) var<uniform> atmosphere: AtmosphereUniforms;
@group(1) @binding(0) var transmittance_lut: texture_2d<f32>;
@group(1) @binding(1) var multiscatter_lut: texture_2d<f32>;
@group(1) @binding(2) var lut_sampler: sampler;
@group(1) @binding(3) var output: texture_storage_2d<rgba16float, write>;

const PI: f32 = 3.14159265359;
const INSCATTER_STEPS: i32 = 32;

fn rayleigh_density(altitude: f32) -> f32 {
    return exp(-altitude / atmosphere.rayleigh_scale_height);
}

fn mie_density(altitude: f32) -> f32 {
    return exp(-altitude / atmosphere.mie_scale_height);
}

fn ozone_density(altitude: f32) -> f32 {
    let d = (altitude - atmosphere.ozone_center_height) / atmosphere.ozone_width;
    return exp(-d * d);
}

fn ray_sphere_intersect_far(origin: vec3<f32>, dir: vec3<f32>, radius: f32) -> f32 {
    let a = dot(dir, dir);
    let b = 2.0 * dot(origin, dir);
    let c = dot(origin, origin) - radius * radius;
    let discriminant = b * b - 4.0 * a * c;
    if (discriminant < 0.0) { return -1.0; }
    return (-b + sqrt(discriminant)) / (2.0 * a);
}

fn ray_sphere_intersect_near(origin: vec3<f32>, dir: vec3<f32>, radius: f32) -> f32 {
    let a = dot(dir, dir);
    let b = 2.0 * dot(origin, dir);
    let c = dot(origin, origin) - radius * radius;
    let discriminant = b * b - 4.0 * a * c;
    if (discriminant < 0.0) { return -1.0; }
    let t = (-b - sqrt(discriminant)) / (2.0 * a);
    if (t > 0.0) { return t; }
    return -1.0;
}

fn rayleigh_phase(cos_theta: f32) -> f32 {
    return 3.0 / (16.0 * PI) * (1.0 + cos_theta * cos_theta);
}

fn mie_phase(cos_theta: f32, g: f32) -> f32 {
    let g2 = g * g;
    let denom = 1.0 + g2 - 2.0 * g * cos_theta;
    return (1.0 - g2) / (4.0 * PI * pow(denom, 1.5));
}

// Sample transmittance LUT
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

// Sample multi-scattering LUT
fn sample_multiscatter(altitude: f32, cos_sun_zenith: f32) -> vec3<f32> {
    let uv = vec2<f32>(
        cos_sun_zenith * 0.5 + 0.5,
        altitude / (atmosphere.atmosphere_radius - atmosphere.earth_radius)
    );
    return textureSampleLevel(multiscatter_lut, lut_sampler, uv, 0.0).rgb;
}

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let dims = textureDimensions(output);
    if (global_id.x >= dims.x || global_id.y >= dims.y) {
        return;
    }

    let uv = vec2<f32>(
        (f32(global_id.x) + 0.5) / f32(dims.x),
        (f32(global_id.y) + 0.5) / f32(dims.y)
    );

    // Map UV to view direction
    // x: azimuth [0, 2pi], y: elevation [-pi/2, pi/2]
    let azimuth = uv.x * 2.0 * PI;
    let elevation = (uv.y - 0.5) * PI;

    let cos_elev = cos(elevation);
    let sin_elev = sin(elevation);
    let view_dir = vec3<f32>(
        cos_elev * sin(azimuth),
        sin_elev,
        cos_elev * cos(azimuth)
    );

    // Camera position (on surface + height)
    let r = atmosphere.earth_radius + atmosphere.camera_height;
    let origin = vec3<f32>(0.0, r, 0.0);

    // Find ray end (atmosphere or ground)
    var t_max = ray_sphere_intersect_far(origin, view_dir, atmosphere.atmosphere_radius);
    let t_ground = ray_sphere_intersect_near(origin, view_dir, atmosphere.earth_radius);
    var hit_ground = false;
    if (t_ground > 0.0 && t_ground < t_max) {
        t_max = t_ground;
        hit_ground = true;
    }

    if (t_max < 0.0) {
        textureStore(output, vec2<i32>(global_id.xy), vec4<f32>(0.0, 0.0, 0.0, 1.0));
        return;
    }

    // Convert sun direction from NED to Y-up coordinate system used by LUT
    // NED: X=North, Y=East, Z=Down
    // LUT azimuth mapping: NED North -> LUT -Z (due to π offset in UV mapping)
    // LUT: X corresponds to sin(azimuth), Z corresponds to cos(azimuth)
    // When looking North in NED (azimuth_render=0), we sample at uv.x=0.5, which gives azimuth_compute=π
    // So cos(π)=-1, meaning NED North maps to LUT -Z
    let sun_dir = vec3<f32>(
        -atmosphere.sun_direction.y,  // NED East -> LUT -X (sin component, negated due to azimuth offset)
        -atmosphere.sun_direction.z,  // NED Down (negated) -> LUT Y (up)
        -atmosphere.sun_direction.x   // NED North -> LUT -Z (cos component, negated due to azimuth offset)
    );

    // Phase function for sun direction
    let cos_theta = dot(view_dir, sun_dir);
    let phase_r = rayleigh_phase(cos_theta);
    let phase_m = mie_phase(cos_theta, atmosphere.mie_asymmetry_g);

    // Ray march
    let dt = t_max / f32(INSCATTER_STEPS);
    var in_scatter = vec3<f32>(0.0);
    var transmittance = vec3<f32>(1.0);

    for (var i = 0; i < INSCATTER_STEPS; i++) {
        let t = (f32(i) + 0.5) * dt;
        let pos = origin + view_dir * t;
        let h = length(pos) - atmosphere.earth_radius;

        // Extinction at this point
        let density_r = rayleigh_density(h);
        let density_m = mie_density(h);
        let density_o = ozone_density(h);

        let extinction = atmosphere.rayleigh_scattering * density_r +
                        vec3<f32>(atmosphere.mie_extinction) * density_m +
                        atmosphere.ozone_absorption * density_o;

        let sample_trans = exp(-extinction * dt);

        // Scattering at this point
        let scattering_r = atmosphere.rayleigh_scattering * density_r;
        let scattering_m = vec3<f32>(atmosphere.mie_scattering) * density_m;

        // Transmittance from sun to this point
        let sun_cos = dot(normalize(pos), sun_dir);
        let sun_trans = sample_transmittance(h, sun_cos);

        // Single scattering
        let single_scatter = (scattering_r * phase_r + scattering_m * phase_m) *
                            sun_trans * atmosphere.sun_intensity;

        // Multi-scattering contribution
        let ms = sample_multiscatter(h, sun_cos);
        let multi_scatter = (scattering_r + scattering_m) * ms * atmosphere.sun_intensity;

        // Integrate with transmittance
        let scatter_integral = (single_scatter + multi_scatter) *
                              (1.0 - sample_trans) / max(extinction, vec3<f32>(0.0001));

        in_scatter += transmittance * scatter_integral;
        transmittance *= sample_trans;
    }

    // Skip ground contribution - let atmospheric scattering continue below horizon
    // This avoids a hard line at the horizon when terrain doesn't reach it
    _ = hit_ground;

    textureStore(output, vec2<i32>(global_id.xy), vec4<f32>(in_scatter, 1.0));
}
