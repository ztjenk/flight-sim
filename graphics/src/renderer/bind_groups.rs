// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

use crate::constants_m::{LOD_MIN_CLAMP, LOD_MAX_CLAMP};

// collection of all bind group layouts used by the renderer
pub struct BindGroupLayouts {
    pub global_layout: wgpu::BindGroupLayout,       // group 0: camera + light uniforms
    pub tile_layout: wgpu::BindGroupLayout,         // group 1 for terrain: texture + sampler
    pub model_layout: wgpu::BindGroupLayout,        // group 1 for meshes: model matrix
    pub grid_params_layout: wgpu::BindGroupLayout,  // group 1 for procedural grid: GridParams
}

impl BindGroupLayouts {
    pub fn new(device: &wgpu::Device) -> Self {
        // group 0: global uniforms shared by all draw calls
        let global_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("Global Bind Group Layout"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::VERTEX | wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
            ],
        });

        // group 1 for terrain: texture (BC compressed or RGBA) + sampler
        let tile_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("Tile Bind Group Layout"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        multisampled: false,
                        view_dimension: wgpu::TextureViewDimension::D2,
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
            ],
        });

        // group 1 for meshes: model matrix uniform
        let model_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("Model Bind Group Layout"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::VERTEX,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
            ],
        });

        // group 1 for procedural grid: GridParams uniform (vertex + fragment visible)
        let grid_params_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("Grid Params Bind Group Layout"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::VERTEX | wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            }],
        });

        Self {
            global_layout,
            tile_layout,
            model_layout,
            grid_params_layout,
        }
    }
}

// global bind group instance (camera + light buffers)
pub struct GlobalBindGroup {
    pub bind_group: wgpu::BindGroup,
}

impl GlobalBindGroup {
    pub fn new(
        device: &wgpu::Device,
        layouts: &BindGroupLayouts,
        camera_buffer: &wgpu::Buffer,
        light_buffer: &wgpu::Buffer,
    ) -> Self {
        let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Global Bind Group"),
            layout: &layouts.global_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: camera_buffer.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: light_buffer.as_entire_binding(),
                },
            ],
        });

        Self { bind_group }
    }
}

// sampler with trilinear filtering and anisotropy for terrain textures
pub fn create_terrain_sampler(device: &wgpu::Device) -> wgpu::Sampler {
    device.create_sampler(&wgpu::SamplerDescriptor {
        label: Some("Terrain Sampler"),
        address_mode_u: wgpu::AddressMode::ClampToEdge,
        address_mode_v: wgpu::AddressMode::ClampToEdge,
        address_mode_w: wgpu::AddressMode::ClampToEdge,
        mag_filter: wgpu::FilterMode::Linear,
        min_filter: wgpu::FilterMode::Linear,
        mipmap_filter: wgpu::FilterMode::Linear,  // trilinear for smooth mip transitions
        lod_min_clamp: LOD_MIN_CLAMP,
        lod_max_clamp: LOD_MAX_CLAMP,
        compare: None,
        anisotropy_clamp: 16,  // 16x anisotropic filtering
        border_color: None,
    })
}