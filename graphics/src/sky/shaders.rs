// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

//! WGSL Shaders for Precomputed Atmospheric Scattering
//!
//! Based on Bruneton 2008 and Hillaire 2020 papers.
//! All shaders share common atmosphere parameter definitions.
//!
//! Shader files are stored in `src/shaders/` for editor tooling support.

/// Transmittance LUT compute shader
/// Computes optical depth along a ray through the atmosphere
pub const TRANSMITTANCE_COMPUTE: &str = include_str!("../shaders/sky_transmittance.wgsl");

/// Multi-scattering LUT compute shader
/// Approximates contribution of 2nd+ order scattering
pub const MULTISCATTER_COMPUTE: &str = include_str!("../shaders/sky_multiscatter.wgsl");

/// Sky-view LUT compute shader
/// Computes final sky color for each view direction
pub const SKYVIEW_COMPUTE: &str = include_str!("../shaders/sky_view.wgsl");

/// Sky rendering shader (fullscreen triangle with sun disk)
pub const SKY_RENDER: &str = include_str!("../shaders/sky_render.wgsl");
