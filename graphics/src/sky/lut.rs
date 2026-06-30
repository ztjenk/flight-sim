// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

//! LUT (Look-Up Table) creation and compute pipeline setup for atmospheric scattering
//!
//! Creates GPU textures and compute pipelines for:
//! - Transmittance LUT
//! - Multi-scattering LUT
//! - Sky-view LUT

use super::shaders;
use super::params::{
    TRANSMITTANCE_LUT_WIDTH, TRANSMITTANCE_LUT_HEIGHT,
    MULTISCATTER_LUT_WIDTH, MULTISCATTER_LUT_HEIGHT,
    SKYVIEW_LUT_WIDTH, SKYVIEW_LUT_HEIGHT,
};

/// Create a 2D LUT texture with Rgba16Float format
pub fn create_lut_texture(
    device: &wgpu::Device,
    width: u32,
    height: u32,
    label: &str,
) -> wgpu::Texture {
    device.create_texture(&wgpu::TextureDescriptor {
        label: Some(label),
        size: wgpu::Extent3d { width, height, depth_or_array_layers: 1 },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::Rgba16Float,
        usage: wgpu::TextureUsages::STORAGE_BINDING
             | wgpu::TextureUsages::TEXTURE_BINDING,
        view_formats: &[],
    })
}

/// Create transmittance LUT compute pipeline and bind group
pub fn create_transmittance_pipeline(
    device: &wgpu::Device,
    atmosphere_layout: &wgpu::BindGroupLayout,
    output_view: &wgpu::TextureView,
) -> (wgpu::ComputePipeline, wgpu::BindGroup) {
    let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
        label: Some("Transmittance Compute Shader"),
        source: wgpu::ShaderSource::Wgsl(shaders::TRANSMITTANCE_COMPUTE.into()),
    });

    let output_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("Transmittance Output Layout"),
        entries: &[wgpu::BindGroupLayoutEntry {
            binding: 0,
            visibility: wgpu::ShaderStages::COMPUTE,
            ty: wgpu::BindingType::StorageTexture {
                access: wgpu::StorageTextureAccess::WriteOnly,
                format: wgpu::TextureFormat::Rgba16Float,
                view_dimension: wgpu::TextureViewDimension::D2,
            },
            count: None,
        }],
    });

    let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: Some("Transmittance Pipeline Layout"),
        bind_group_layouts: &[atmosphere_layout, &output_layout],
        push_constant_ranges: &[],
    });

    let pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
        label: Some("Transmittance Compute Pipeline"),
        layout: Some(&pipeline_layout),
        module: &shader,
        entry_point: Some("main"),
        compilation_options: Default::default(),
        cache: None,
    });

    let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("Transmittance Output Bind Group"),
        layout: &output_layout,
        entries: &[wgpu::BindGroupEntry {
            binding: 0,
            resource: wgpu::BindingResource::TextureView(output_view),
        }],
    });

    (pipeline, bind_group)
}

/// Create multi-scattering LUT compute pipeline and bind group
pub fn create_multiscatter_pipeline(
    device: &wgpu::Device,
    atmosphere_layout: &wgpu::BindGroupLayout,
    transmittance_view: &wgpu::TextureView,
    output_view: &wgpu::TextureView,
    sampler: &wgpu::Sampler,
) -> (wgpu::ComputePipeline, wgpu::BindGroup) {
    let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
        label: Some("Multiscatter Compute Shader"),
        source: wgpu::ShaderSource::Wgsl(shaders::MULTISCATTER_COMPUTE.into()),
    });

    let lut_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("Multiscatter LUT Layout"),
        entries: &[
            // Transmittance input
            wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::COMPUTE,
                ty: wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Float { filterable: true },
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            },
            // Sampler
            wgpu::BindGroupLayoutEntry {
                binding: 1,
                visibility: wgpu::ShaderStages::COMPUTE,
                ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                count: None,
            },
            // Output
            wgpu::BindGroupLayoutEntry {
                binding: 2,
                visibility: wgpu::ShaderStages::COMPUTE,
                ty: wgpu::BindingType::StorageTexture {
                    access: wgpu::StorageTextureAccess::WriteOnly,
                    format: wgpu::TextureFormat::Rgba16Float,
                    view_dimension: wgpu::TextureViewDimension::D2,
                },
                count: None,
            },
        ],
    });

    let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: Some("Multiscatter Pipeline Layout"),
        bind_group_layouts: &[atmosphere_layout, &lut_layout],
        push_constant_ranges: &[],
    });

    let pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
        label: Some("Multiscatter Compute Pipeline"),
        layout: Some(&pipeline_layout),
        module: &shader,
        entry_point: Some("main"),
        compilation_options: Default::default(),
        cache: None,
    });

    let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("Multiscatter LUT Bind Group"),
        layout: &lut_layout,
        entries: &[
            wgpu::BindGroupEntry {
                binding: 0,
                resource: wgpu::BindingResource::TextureView(transmittance_view),
            },
            wgpu::BindGroupEntry {
                binding: 1,
                resource: wgpu::BindingResource::Sampler(sampler),
            },
            wgpu::BindGroupEntry {
                binding: 2,
                resource: wgpu::BindingResource::TextureView(output_view),
            },
        ],
    });

    (pipeline, bind_group)
}

/// Create sky-view LUT compute pipeline and bind group
pub fn create_skyview_pipeline(
    device: &wgpu::Device,
    atmosphere_layout: &wgpu::BindGroupLayout,
    transmittance_view: &wgpu::TextureView,
    multiscatter_view: &wgpu::TextureView,
    output_view: &wgpu::TextureView,
    sampler: &wgpu::Sampler,
) -> (wgpu::ComputePipeline, wgpu::BindGroup) {
    let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
        label: Some("Skyview Compute Shader"),
        source: wgpu::ShaderSource::Wgsl(shaders::SKYVIEW_COMPUTE.into()),
    });

    let lut_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("Skyview LUT Layout"),
        entries: &[
            // Transmittance
            wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::COMPUTE,
                ty: wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Float { filterable: true },
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            },
            // Multiscatter
            wgpu::BindGroupLayoutEntry {
                binding: 1,
                visibility: wgpu::ShaderStages::COMPUTE,
                ty: wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Float { filterable: true },
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            },
            // Sampler
            wgpu::BindGroupLayoutEntry {
                binding: 2,
                visibility: wgpu::ShaderStages::COMPUTE,
                ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                count: None,
            },
            // Output
            wgpu::BindGroupLayoutEntry {
                binding: 3,
                visibility: wgpu::ShaderStages::COMPUTE,
                ty: wgpu::BindingType::StorageTexture {
                    access: wgpu::StorageTextureAccess::WriteOnly,
                    format: wgpu::TextureFormat::Rgba16Float,
                    view_dimension: wgpu::TextureViewDimension::D2,
                },
                count: None,
            },
        ],
    });

    let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: Some("Skyview Pipeline Layout"),
        bind_group_layouts: &[atmosphere_layout, &lut_layout],
        push_constant_ranges: &[],
    });

    let pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
        label: Some("Skyview Compute Pipeline"),
        layout: Some(&pipeline_layout),
        module: &shader,
        entry_point: Some("main"),
        compilation_options: Default::default(),
        cache: None,
    });

    let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("Skyview LUT Bind Group"),
        layout: &lut_layout,
        entries: &[
            wgpu::BindGroupEntry {
                binding: 0,
                resource: wgpu::BindingResource::TextureView(transmittance_view),
            },
            wgpu::BindGroupEntry {
                binding: 1,
                resource: wgpu::BindingResource::TextureView(multiscatter_view),
            },
            wgpu::BindGroupEntry {
                binding: 2,
                resource: wgpu::BindingResource::Sampler(sampler),
            },
            wgpu::BindGroupEntry {
                binding: 3,
                resource: wgpu::BindingResource::TextureView(output_view),
            },
        ],
    });

    (pipeline, bind_group)
}

/// Dispatch transmittance LUT compute pass
pub fn dispatch_transmittance(
    encoder: &mut wgpu::CommandEncoder,
    pipeline: &wgpu::ComputePipeline,
    atmosphere_bind_group: &wgpu::BindGroup,
    output_bind_group: &wgpu::BindGroup,
) {
    let mut pass = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor {
        label: Some("Transmittance Compute Pass"),
        timestamp_writes: None,
    });
    pass.set_pipeline(pipeline);
    pass.set_bind_group(0, atmosphere_bind_group, &[]);
    pass.set_bind_group(1, output_bind_group, &[]);

    let workgroups_x = TRANSMITTANCE_LUT_WIDTH.div_ceil(8);
    let workgroups_y = TRANSMITTANCE_LUT_HEIGHT.div_ceil(8);
    pass.dispatch_workgroups(workgroups_x, workgroups_y, 1);
}

/// Dispatch multi-scattering LUT compute pass
pub fn dispatch_multiscatter(
    encoder: &mut wgpu::CommandEncoder,
    pipeline: &wgpu::ComputePipeline,
    atmosphere_bind_group: &wgpu::BindGroup,
    lut_bind_group: &wgpu::BindGroup,
) {
    let mut pass = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor {
        label: Some("Multiscatter Compute Pass"),
        timestamp_writes: None,
    });
    pass.set_pipeline(pipeline);
    pass.set_bind_group(0, atmosphere_bind_group, &[]);
    pass.set_bind_group(1, lut_bind_group, &[]);

    let workgroups_x = MULTISCATTER_LUT_WIDTH.div_ceil(8);
    let workgroups_y = MULTISCATTER_LUT_HEIGHT.div_ceil(8);
    pass.dispatch_workgroups(workgroups_x, workgroups_y, 1);
}

/// Dispatch sky-view LUT compute pass
pub fn dispatch_skyview(
    encoder: &mut wgpu::CommandEncoder,
    pipeline: &wgpu::ComputePipeline,
    atmosphere_bind_group: &wgpu::BindGroup,
    lut_bind_group: &wgpu::BindGroup,
) {
    let mut pass = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor {
        label: Some("Skyview Compute Pass"),
        timestamp_writes: None,
    });
    pass.set_pipeline(pipeline);
    pass.set_bind_group(0, atmosphere_bind_group, &[]);
    pass.set_bind_group(1, lut_bind_group, &[]);

    let workgroups_x = SKYVIEW_LUT_WIDTH.div_ceil(8);
    let workgroups_y = SKYVIEW_LUT_HEIGHT.div_ceil(8);
    pass.dispatch_workgroups(workgroups_x, workgroups_y, 1);
}
