// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

// Transmittance LUT Compute Shader
// Maps (cos_zenith, altitude) -> RGB transmittance

// Atmosphere parameters - layout matches Rust struct for proper alignment
struct AtmosphereUniforms {
    // Block 1: radii and scale heights
    earth_radius: f32,
    atmosphere_radius: f32,
    rayleigh_scale_height: f32,
    mie_scale_height: f32,

    // Block 2: rayleigh (vec3) + mie scattering
    rayleigh_scattering: vec3<f32>,
    mie_scattering: f32,

    // Block 3: mie params + ozone params
    mie_extinction: f32,
    mie_asymmetry_g: f32,
    ozone_center_height: f32,
    ozone_width: f32,

    // Block 4: ozone absorption (vec3) + ground albedo
    ozone_absorption: vec3<f32>,
    ground_albedo: f32,

    // Block 5: sun direction (vec3) + sun intensity
    sun_direction: vec3<f32>,
    sun_intensity: f32,

    // Block 6: remaining params
    sun_angular_radius: f32,
    exposure: f32,
    camera_height: f32,
    _pad: f32,
};

@group(0) @binding(0) var<uniform> atmosphere: AtmosphereUniforms;
@group(1) @binding(0) var output: texture_storage_2d<rgba16float, write>;

const PI: f32 = 3.14159265359;
const TRANSMITTANCE_STEPS: i32 = 40;

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

    if (discriminant < 0.0) {
        return -1.0;
    }

    return (-b + sqrt(discriminant)) / (2.0 * a);
}

// Convert UV to (cos_zenith, altitude)
fn uv_to_transmittance_params(uv: vec2<f32>) -> vec2<f32> {
    let H = sqrt(atmosphere.atmosphere_radius * atmosphere.atmosphere_radius -
                 atmosphere.earth_radius * atmosphere.earth_radius);
    let rho = H * uv.y;
    let r = sqrt(rho * rho + atmosphere.earth_radius * atmosphere.earth_radius);
    let altitude = r - atmosphere.earth_radius;

    let d_min = atmosphere.atmosphere_radius - r;
    let d_max = rho + H;
    let d = d_min + (d_max - d_min) * uv.x;

    let cos_zenith = clamp((H * H - rho * rho - d * d) / (2.0 * r * d), -1.0, 1.0);

    return vec2<f32>(cos_zenith, altitude);
}

// Compute transmittance along a ray
fn compute_transmittance(altitude: f32, cos_zenith: f32) -> vec3<f32> {
    let r = atmosphere.earth_radius + altitude;
    let origin = vec3<f32>(0.0, r, 0.0);

    // Direction from cos_zenith (angle from zenith = vertical)
    let sin_zenith = sqrt(max(0.0, 1.0 - cos_zenith * cos_zenith));
    let dir = vec3<f32>(sin_zenith, cos_zenith, 0.0);

    // Find intersection with atmosphere top
    let t_max = ray_sphere_intersect_far(origin, dir, atmosphere.atmosphere_radius);
    if (t_max < 0.0) {
        return vec3<f32>(1.0);
    }

    let dt = t_max / f32(TRANSMITTANCE_STEPS);

    var optical_depth_rayleigh = 0.0;
    var optical_depth_mie = 0.0;
    var optical_depth_ozone = vec3<f32>(0.0);

    for (var i = 0; i < TRANSMITTANCE_STEPS; i++) {
        let t = (f32(i) + 0.5) * dt;
        let pos = origin + dir * t;
        let h = length(pos) - atmosphere.earth_radius;

        optical_depth_rayleigh += rayleigh_density(h) * dt;
        optical_depth_mie += mie_density(h) * dt;
        optical_depth_ozone += atmosphere.ozone_absorption * ozone_density(h) * dt;
    }

    let tau = atmosphere.rayleigh_scattering * optical_depth_rayleigh +
              vec3<f32>(atmosphere.mie_extinction) * optical_depth_mie +
              optical_depth_ozone;

    return exp(-tau);
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

    let params = uv_to_transmittance_params(uv);
    let transmittance = compute_transmittance(params.y, params.x);

    textureStore(output, vec2<i32>(global_id.xy), vec4<f32>(transmittance, 1.0));
}
