// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

//! Procedural ground grid rendering
//!
//! Renders an infinite ground grid using a single full-screen quad and fwidth()-based
//! anti-aliasing in the fragment shader. Grid lines maintain consistent 1-pixel width
//! regardless of camera distance or altitude.

use crate::config_m::parse_color;
use crate::constants_m::{
    GRID_FAR_FADE_START_RATIO, GRID_FAR_FADE_END_RATIO,
    GRID_DEFAULT_MAX_DISTANCE, GRID_DEFAULT_COLOR,
};
use crate::renderer::bind_groups::BindGroupLayouts;
use nalgebra::Vector3;
use wgpu::util::DeviceExt;

// GPU uniform matching the GridParams struct in grid.wgsl (40 bytes, all f32)
#[repr(C)]
#[derive(Copy, Clone, bytemuck::Pod, bytemuck::Zeroable)]
struct GridParamsUniform {
    ground_z_rel: f32,   // ground altitude - camera altitude (camera-relative Z)
    grid_scale:   f32,   // primary grid line spacing (world units)
    fade_start:   f32,   // horizontal distance where fade begins
    fade_end:     f32,   // horizontal distance where fully transparent
    quad_half:    f32,   // half-extent of the ground-plane quad
    line_width:   f32,   // line half-width in pixels
    color_r:      f32,
    color_g:      f32,
    color_b:      f32,
    _pad:         f32,
}

/// Procedural ground grid — updates a tiny params buffer each frame, no mesh required.
pub struct GroundGrid {
    pub params_bind_group: wgpu::BindGroup,
    params_buffer: wgpu::Buffer,

    ground_z:   f64,
    grid_scale: f32,
    fade_start: f32,
    fade_end:   f32,
    quad_half:  f32,
    line_width: f32,
    color:      [f32; 3],
}

impl GroundGrid {
    pub fn new(
        device: &wgpu::Device,
        layouts: &BindGroupLayouts,
        ground_z: f64,
        grid_scale: f64,
        max_distance: Option<f64>,
        color: [f32; 3],
    ) -> Self {
        let max_dist = max_distance.unwrap_or(GRID_DEFAULT_MAX_DISTANCE) as f32;
        let fade_start = max_dist * GRID_FAR_FADE_START_RATIO;
        let fade_end   = max_dist * GRID_FAR_FADE_END_RATIO;
        // Make the quad slightly larger than the fade radius so fragments at the edge
        // always get a chance to discard rather than getting clipped by the quad edge.
        let quad_half  = max_dist * 1.05;
        // Half-width in pixels of the AA falloff. The shader uses
        // clamp(half_width - dist_px, 0, 1) for coverage. 1.25 gives a 2.5-px
        // line with a 0.5-px solid core — crisp without looking washed out at
        // low DPI. Drop to 1.0 for thinner, bump to 1.5 for slightly thicker.
        let line_width = 1.25_f32;

        let initial_params = GridParamsUniform {
            ground_z_rel: 0.0,
            grid_scale: grid_scale as f32,
            fade_start,
            fade_end,
            quad_half,
            line_width,
            color_r: color[0],
            color_g: color[1],
            color_b: color[2],
            _pad: 0.0,
        };

        let params_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Grid Params Buffer"),
            contents: bytemuck::cast_slice(&[initial_params]),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        });

        let params_bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Grid Params Bind Group"),
            layout: &layouts.grid_params_layout,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: params_buffer.as_entire_binding(),
            }],
        });

        Self {
            params_bind_group,
            params_buffer,
            ground_z,
            grid_scale: grid_scale as f32,
            fade_start,
            fade_end,
            quad_half,
            line_width,
            color,
        }
    }

    /// Update the grid params buffer with the current camera position.
    /// Call once per frame before rendering.
    pub fn update(&self, queue: &wgpu::Queue, cam_pos: &Vector3<f64>) {
        let params = GridParamsUniform {
            ground_z_rel: (self.ground_z - cam_pos.z) as f32,
            grid_scale: self.grid_scale,
            fade_start: self.fade_start,
            fade_end:   self.fade_end,
            quad_half:  self.quad_half,
            line_width: self.line_width,
            color_r:    self.color[0],
            color_g:    self.color[1],
            color_b:    self.color[2],
            _pad: 0.0,
        };
        queue.write_buffer(&self.params_buffer, 0, bytemuck::cast_slice(&[params]));
    }
}

/// Parse a color string into RGB components
pub fn parse_ground_color(color: &str) -> [f32; 3] {
    parse_color(color, 1.0)
        .map(|c| [c[0], c[1], c[2]])
        .unwrap_or_else(|_| {
            tracing::warn!(color = color, "Invalid ground grid color, using default");
            GRID_DEFAULT_COLOR
        })
}
