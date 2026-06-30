// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

//! Atmosphere parameters and GPU uniform structures
//!
//! Constants based on Earth's atmosphere for physically-based sky rendering.

use crate::config_m::SkyConfig;
use crate::constants_m::DEG_TO_RAD;

// ============================================================================
// Atmosphere Parameters (Earth-like)
// ============================================================================

/// Earth radius in meters
pub const EARTH_RADIUS_M: f32 = 6_371_000.0;

/// Atmosphere top altitude in meters (where density approaches zero)
pub const ATMOSPHERE_HEIGHT_M: f32 = 100_000.0;

/// Total radius from Earth center to atmosphere top
pub const ATMOSPHERE_RADIUS_M: f32 = EARTH_RADIUS_M + ATMOSPHERE_HEIGHT_M;

/// Rayleigh scattering coefficients at sea level (per meter, wavelength-dependent)
/// These give the blue sky color - shorter wavelengths scatter more
/// Values for wavelengths: ~680nm (R), ~550nm (G), ~440nm (B)
pub const RAYLEIGH_SCATTERING: [f32; 3] = [5.802e-6, 13.558e-6, 33.1e-6];

/// Rayleigh scale height in meters (density falls to 1/e at this altitude)
pub const RAYLEIGH_SCALE_HEIGHT_M: f32 = 8_500.0;

/// Mie scattering coefficient at sea level (per meter, wavelength-independent)
/// Mie scattering from aerosols - gives hazy white near horizon
pub const MIE_SCATTERING: f32 = 3.996e-6;

/// Mie absorption coefficient at sea level
pub const MIE_ABSORPTION: f32 = 4.4e-6;

/// Mie extinction = scattering + absorption
pub const MIE_EXTINCTION: f32 = MIE_SCATTERING + MIE_ABSORPTION;

/// Mie scale height in meters (aerosols concentrated lower in atmosphere)
pub const MIE_SCALE_HEIGHT_M: f32 = 1_200.0;

/// Mie phase function asymmetry parameter (0 = isotropic, 1 = full forward scatter)
/// ~0.8 gives realistic sun halo effect
pub const MIE_ASYMMETRY_G: f32 = 0.8;

/// Ozone absorption coefficients (Dobson units equivalent)
/// Ozone layer absorbs UV and some visible light, affecting sunset colors
pub const OZONE_ABSORPTION: [f32; 3] = [0.65e-6, 1.881e-6, 0.085e-6];

/// Ozone layer center altitude in meters
pub const OZONE_CENTER_HEIGHT_M: f32 = 25_000.0;

/// Ozone layer thickness in meters
pub const OZONE_WIDTH_M: f32 = 15_000.0;

// ============================================================================
// LUT Dimensions
// ============================================================================

/// Transmittance LUT: maps (cos_zenith, altitude) -> RGB transmittance
pub const TRANSMITTANCE_LUT_WIDTH: u32 = 256;
pub const TRANSMITTANCE_LUT_HEIGHT: u32 = 64;

/// Multi-scattering LUT: maps (cos_sun_zenith, altitude) -> RGB luminance
pub const MULTISCATTER_LUT_WIDTH: u32 = 32;
pub const MULTISCATTER_LUT_HEIGHT: u32 = 32;

/// Sky-view LUT: maps (azimuth, elevation) -> RGB sky color
/// Computed per-frame from camera position
pub const SKYVIEW_LUT_WIDTH: u32 = 192;
pub const SKYVIEW_LUT_HEIGHT: u32 = 108;

// ============================================================================
// GPU Uniform Structures
// ============================================================================

/// Sky camera uniform - inverse view matrix for ray direction calculation
#[repr(C)]
#[derive(Copy, Clone, Debug, bytemuck::Pod, bytemuck::Zeroable)]
pub struct SkyCameraUniform {
    /// Inverse view matrix (rotation only, 3x3 stored as 3 vec4 columns for alignment)
    pub inv_view_col0: [f32; 4],
    pub inv_view_col1: [f32; 4],
    pub inv_view_col2: [f32; 4],
    /// Camera FOV and aspect ratio for proper ray generation
    pub fov_y: f32,
    pub aspect_ratio: f32,
    pub _pad: [f32; 2],
}

impl Default for SkyCameraUniform {
    fn default() -> Self {
        Self {
            inv_view_col0: [1.0, 0.0, 0.0, 0.0],
            inv_view_col1: [0.0, 1.0, 0.0, 0.0],
            inv_view_col2: [0.0, 0.0, 1.0, 0.0],
            fov_y: std::f32::consts::FRAC_PI_4, // 45 degrees
            aspect_ratio: 16.0 / 9.0,
            _pad: [0.0; 2],
        }
    }
}

/// Atmosphere parameters passed to shaders
/// Layout designed for WGSL alignment: vec3<f32> requires 16-byte alignment
/// Each vec3 is followed by an f32 to pack into exactly 16 bytes
#[repr(C)]
#[derive(Copy, Clone, Debug, bytemuck::Pod, bytemuck::Zeroable)]
pub struct AtmosphereUniforms {
    // Block 1: 16 bytes - radii and scale heights
    pub earth_radius: f32,
    pub atmosphere_radius: f32,
    pub rayleigh_scale_height: f32,
    pub mie_scale_height: f32,

    // Block 2: 16 bytes - rayleigh (vec3) + mie scattering
    pub rayleigh_scattering: [f32; 3],
    pub mie_scattering: f32,

    // Block 3: 16 bytes - mie params + ozone params
    pub mie_extinction: f32,
    pub mie_asymmetry_g: f32,
    pub ozone_center_height: f32,
    pub ozone_width: f32,

    // Block 4: 16 bytes - ozone absorption (vec3) + ground albedo
    pub ozone_absorption: [f32; 3],
    pub ground_albedo: f32,

    // Block 5: 16 bytes - sun direction (vec3) + sun intensity
    pub sun_direction: [f32; 3],
    pub sun_intensity: f32,

    // Block 6: 16 bytes - remaining params
    pub sun_angular_radius: f32,
    pub exposure: f32,
    pub camera_height: f32,
    pub _pad: f32,
}

impl Default for AtmosphereUniforms {
    fn default() -> Self {
        Self {
            earth_radius: EARTH_RADIUS_M,
            atmosphere_radius: ATMOSPHERE_RADIUS_M,
            rayleigh_scale_height: RAYLEIGH_SCALE_HEIGHT_M,
            mie_scale_height: MIE_SCALE_HEIGHT_M,

            rayleigh_scattering: RAYLEIGH_SCATTERING,
            mie_scattering: MIE_SCATTERING,

            mie_extinction: MIE_EXTINCTION,
            mie_asymmetry_g: MIE_ASYMMETRY_G,
            ozone_center_height: OZONE_CENTER_HEIGHT_M,
            ozone_width: OZONE_WIDTH_M,

            ozone_absorption: OZONE_ABSORPTION,
            ground_albedo: 0.3,

            sun_direction: [0.5, 0.0, -0.866], // 60 deg elevation
            sun_intensity: 20.0,

            sun_angular_radius: 0.00925, // 0.53 degrees in radians
            exposure: 10.0,
            camera_height: 1000.0,
            _pad: 0.0,
        }
    }
}

impl AtmosphereUniforms {
    pub fn from_config(config: &SkyConfig) -> Self {
        let mut uniforms = Self::default();

        // Normalize sun direction
        let sd = config.sun_direction;
        let len = (sd[0] * sd[0] + sd[1] * sd[1] + sd[2] * sd[2]).sqrt();
        uniforms.sun_direction = [
            (sd[0] / len) as f32,
            (sd[1] / len) as f32,
            (sd[2] / len) as f32,
        ];

        uniforms.sun_intensity = config.sun_intensity as f32;
        uniforms.sun_angular_radius = (config.sun_angular_radius_deg * DEG_TO_RAD) as f32;
        uniforms.ground_albedo = config.ground_albedo as f32;
        uniforms.exposure = config.exposure as f32;

        uniforms
    }
}
