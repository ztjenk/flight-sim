// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

// Multi-scattering LUT Compute Shader
// Maps (cos_sun_zenith, altitude) -> RGB luminance from multiple scattering

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
@group(1) @binding(1) var lut_sampler: sampler;
@group(1) @binding(2) var output: texture_storage_2d<rgba16float, write>;

const PI: f32 = 3.14159265359;
const MULTISCATTER_STEPS: i32 = 20;
const SPHERE_SAMPLES: i32 = 64;

fn rayleigh_density(altitude: f32) -> f32 {
    return exp(-altitude / atmosphere.rayleigh_scale_height);
}

fn mie_density(altitude: f32) -> f32 {
    return exp(-altitude / atmosphere.mie_scale_height);
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

// Get transmittance between two points
fn get_transmittance_between(p0: vec3<f32>, p1: vec3<f32>) -> vec3<f32> {
    let dir = normalize(p1 - p0);
    let r0 = length(p0);
    let cos_zenith0 = dot(p0, dir) / r0;
    let alt0 = r0 - atmosphere.earth_radius;

    let r1 = length(p1);
    let cos_zenith1 = dot(p1, dir) / r1;
    let alt1 = r1 - atmosphere.earth_radius;

    let t0 = sample_transmittance(alt0, cos_zenith0);
    let t1 = sample_transmittance(alt1, cos_zenith1);

    return t0 / max(t1, vec3<f32>(0.0001));
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

    // Map UV to altitude and sun zenith
    let altitude = uv.y * (atmosphere.atmosphere_radius - atmosphere.earth_radius);
    let cos_sun_zenith = uv.x * 2.0 - 1.0;
    let sin_sun_zenith = sqrt(max(0.0, 1.0 - cos_sun_zenith * cos_sun_zenith));
    let sun_dir = vec3<f32>(sin_sun_zenith, cos_sun_zenith, 0.0);

    let r = atmosphere.earth_radius + altitude;
    let origin = vec3<f32>(0.0, r, 0.0);

    // Integrate over sphere of directions (isotropic approximation)
    var total_luminance = vec3<f32>(0.0);
    var total_weight = 0.0;

    let sqrt_samples = i32(sqrt(f32(SPHERE_SAMPLES)));
    for (var i = 0; i < sqrt_samples; i++) {
        for (var j = 0; j < sqrt_samples; j++) {
            let phi = 2.0 * PI * (f32(i) + 0.5) / f32(sqrt_samples);
            let cos_theta = 1.0 - 2.0 * (f32(j) + 0.5) / f32(sqrt_samples);
            let sin_theta = sqrt(max(0.0, 1.0 - cos_theta * cos_theta));

            let dir = vec3<f32>(
                sin_theta * cos(phi),
                cos_theta,
                sin_theta * sin(phi)
            );

            // Ray march along this direction
            var t_max = ray_sphere_intersect_far(origin, dir, atmosphere.atmosphere_radius);
            let t_ground = ray_sphere_intersect_near(origin, dir, atmosphere.earth_radius);
            if (t_ground > 0.0) {
                t_max = t_ground;
            }

            if (t_max < 0.0) {
                continue;
            }

            let dt = t_max / f32(MULTISCATTER_STEPS);
            var in_scatter = vec3<f32>(0.0);

            for (var k = 0; k < MULTISCATTER_STEPS; k++) {
                let t = (f32(k) + 0.5) * dt;
                let pos = origin + dir * t;
                let h = length(pos) - atmosphere.earth_radius;

                // Transmittance from sun to this point
                let sun_cos = dot(normalize(pos), sun_dir);
                let trans_sun = sample_transmittance(h, sun_cos);

                // Scattering at this point
                let scattering = atmosphere.rayleigh_scattering * rayleigh_density(h) +
                                vec3<f32>(atmosphere.mie_scattering) * mie_density(h);

                in_scatter += scattering * trans_sun * dt;
            }

            total_luminance += in_scatter;
            total_weight += 1.0;
        }
    }

    let result = total_luminance / max(total_weight, 1.0);

    // The multi-scattering factor represents how much of isotropic light
    // gets scattered in each direction. Divide by 4pi for normalization.
    let ms_factor = result / (4.0 * PI);

    textureStore(output, vec2<i32>(global_id.xy), vec4<f32>(ms_factor, 1.0));
}
