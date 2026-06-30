// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

use super::quadtree::Bounds;
use std::fmt;
use std::time::Instant;

// unique identifier for a terrain tile
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct TileKey(pub String);

impl TileKey {
    pub fn new(tx: i32, ty: i32) -> Self {
        Self(format!("{}_{}", tx, ty))
    }

    pub fn from_string(key: String) -> Self {
        Self(key)
    }
}

impl fmt::Display for TileKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

// a terrain tile loaded on the GPU
pub struct GpuTile {
    pub dem_bounds: Bounds,  // used for vertex positions and distance calculations

    pub vertex_buffer: wgpu::Buffer,
    pub index_buffer: wgpu::Buffer,
    pub index_count: u32,

    pub bind_group: wgpu::BindGroup,
    #[allow(dead_code)]
    texture: wgpu::Texture,  // kept alive for bind group lifetime

    pub last_used: Instant,
    pub distance_to_camera: f32,
}

impl GpuTile {
    pub fn new(
        dem_bounds: Bounds,
        vertex_buffer: wgpu::Buffer,
        index_buffer: wgpu::Buffer,
        index_count: u32,
        bind_group: wgpu::BindGroup,
        texture: wgpu::Texture,
    ) -> Self {
        Self {
            dem_bounds,
            vertex_buffer,
            index_buffer,
            index_count,
            bind_group,
            texture,
            last_used: Instant::now(),
            distance_to_camera: 0.0,
        }
    }
}