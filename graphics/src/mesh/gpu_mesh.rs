// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

use glam::Mat4;

// model matrix uniform for GPU (must match shader layout)
#[repr(C)]
#[derive(Copy, Clone, Debug, bytemuck::Pod, bytemuck::Zeroable)]
pub struct ModelUniform {
    pub model: [[f32; 4]; 4],
}

impl Default for ModelUniform {
    fn default() -> Self {
        Self {
            model: Mat4::IDENTITY.to_cols_array_2d(),
        }
    }
}

// a mesh loaded on the GPU
pub struct GpuMesh {
    pub vertex_buffer: wgpu::Buffer,
    pub index_buffer: wgpu::Buffer,
    pub index_count: u32,
    pub model_buffer: wgpu::Buffer,
    pub model_bind_group: wgpu::BindGroup,
}

impl GpuMesh {
    pub fn update_transform(&self, queue: &wgpu::Queue, transform: Mat4) {
        let uniform = ModelUniform {
            model: transform.to_cols_array_2d(),
        };
        queue.write_buffer(&self.model_buffer, 0, bytemuck::cast_slice(&[uniform]));
    }
}