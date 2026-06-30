// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

use super::bind_groups::BindGroupLayouts;
use super::shaders;
use crate::constants_m::TERRAIN_DEPTH_BIAS_SLOPE;

// terrain vertex: position, uv, normal
#[repr(C)]
#[derive(Copy, Clone, Debug, bytemuck::Pod, bytemuck::Zeroable)]
pub struct TerrainVertex {
    pub position: [f32; 3],
    pub uv: [f32; 2],
    pub normal: [f32; 3],
}

impl TerrainVertex {
    pub fn desc() -> wgpu::VertexBufferLayout<'static> {
        wgpu::VertexBufferLayout {
            array_stride: std::mem::size_of::<TerrainVertex>() as wgpu::BufferAddress,
            step_mode: wgpu::VertexStepMode::Vertex,
            attributes: &[
                wgpu::VertexAttribute {
                    offset: 0,
                    shader_location: 0,
                    format: wgpu::VertexFormat::Float32x3,
                },
                wgpu::VertexAttribute {
                    offset: std::mem::size_of::<[f32; 3]>() as wgpu::BufferAddress,
                    shader_location: 1,
                    format: wgpu::VertexFormat::Float32x2,
                },
                wgpu::VertexAttribute {
                    offset: std::mem::size_of::<[f32; 5]>() as wgpu::BufferAddress,
                    shader_location: 2,
                    format: wgpu::VertexFormat::Float32x3,
                },
            ],
        }
    }
}

// mesh vertex: position, normal, color (used for aircraft and grid)
#[repr(C)]
#[derive(Copy, Clone, Debug, bytemuck::Pod, bytemuck::Zeroable)]
pub struct MeshVertex {
    pub position: [f32; 3],
    pub normal: [f32; 3],
    pub color: [f32; 4],
}

impl MeshVertex {
    pub fn desc() -> wgpu::VertexBufferLayout<'static> {
        wgpu::VertexBufferLayout {
            array_stride: std::mem::size_of::<MeshVertex>() as wgpu::BufferAddress,
            step_mode: wgpu::VertexStepMode::Vertex,
            attributes: &[
                wgpu::VertexAttribute {
                    offset: 0,
                    shader_location: 0,
                    format: wgpu::VertexFormat::Float32x3,
                },
                wgpu::VertexAttribute {
                    offset: std::mem::size_of::<[f32; 3]>() as wgpu::BufferAddress,
                    shader_location: 1,
                    format: wgpu::VertexFormat::Float32x3,
                },
                wgpu::VertexAttribute {
                    offset: std::mem::size_of::<[f32; 6]>() as wgpu::BufferAddress,
                    shader_location: 2,
                    format: wgpu::VertexFormat::Float32x4,
                },
            ],
        }
    }
}

// Pipeline configuration — captures the differences between terrain/mesh/grid pipelines
pub struct PipelineConfig<'a> {
    pub label: &'a str,
    pub shader_source: &'a str,
    pub bind_group_layouts: &'a [&'a wgpu::BindGroupLayout],
    pub vertex_buffers: &'a [wgpu::VertexBufferLayout<'a>],
    pub blend: wgpu::BlendState,
    pub cull_mode: Option<wgpu::Face>,
    pub depth_write_enabled: bool,
    pub depth_bias: wgpu::DepthBiasState,
}

fn create_pipeline(
    device: &wgpu::Device,
    surface_format: wgpu::TextureFormat,
    config: &PipelineConfig,
) -> wgpu::RenderPipeline {
    let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
        label: Some(&format!("{} Shader", config.label)),
        source: wgpu::ShaderSource::Wgsl(config.shader_source.into()),
    });

    let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: Some(&format!("{} Pipeline Layout", config.label)),
        bind_group_layouts: config.bind_group_layouts,
        push_constant_ranges: &[],
    });

    device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
        label: Some(&format!("{} Pipeline", config.label)),
        layout: Some(&pipeline_layout),
        vertex: wgpu::VertexState {
            module: &shader,
            entry_point: Some("vs_main"),
            buffers: config.vertex_buffers,
            compilation_options: Default::default(),
        },
        fragment: Some(wgpu::FragmentState {
            module: &shader,
            entry_point: Some("fs_main"),
            targets: &[Some(wgpu::ColorTargetState {
                format: surface_format,
                blend: Some(config.blend),
                write_mask: wgpu::ColorWrites::ALL,
            })],
            compilation_options: Default::default(),
        }),
        primitive: wgpu::PrimitiveState {
            topology: wgpu::PrimitiveTopology::TriangleList,
            strip_index_format: None,
            front_face: wgpu::FrontFace::Ccw,
            cull_mode: config.cull_mode,
            polygon_mode: wgpu::PolygonMode::Fill,
            unclipped_depth: false,
            conservative: false,
        },
        depth_stencil: Some(wgpu::DepthStencilState {
            format: wgpu::TextureFormat::Depth32Float,
            depth_write_enabled: config.depth_write_enabled,
            depth_compare: wgpu::CompareFunction::Less,
            stencil: wgpu::StencilState::default(),
            bias: config.depth_bias,
        }),
        multisample: wgpu::MultisampleState {
            count: 1,
            mask: !0,
            alpha_to_coverage_enabled: false,
        },
        multiview: None,
        cache: None,
    })
}

// terrain render pipeline
pub struct TerrainPipeline {
    pub pipeline: wgpu::RenderPipeline,
}

impl TerrainPipeline {
    pub fn new(
        device: &wgpu::Device,
        surface_format: wgpu::TextureFormat,
        layouts: &BindGroupLayouts,
    ) -> Self {
        Self {
            pipeline: create_pipeline(device, surface_format, &PipelineConfig {
                label: "Terrain",
                shader_source: shaders::TERRAIN_SHADER,
                bind_group_layouts: &[&layouts.global_layout, &layouts.tile_layout],
                vertex_buffers: &[TerrainVertex::desc()],
                blend: wgpu::BlendState::REPLACE,
                cull_mode: None,
                depth_write_enabled: true,
                depth_bias: wgpu::DepthBiasState::default(),
            }),
        }
    }
}

// mesh (aircraft) render pipeline
pub struct MeshPipeline {
    pub pipeline: wgpu::RenderPipeline,
}

impl MeshPipeline {
    pub fn new(
        device: &wgpu::Device,
        surface_format: wgpu::TextureFormat,
        layouts: &BindGroupLayouts,
    ) -> Self {
        Self {
            pipeline: create_pipeline(device, surface_format, &PipelineConfig {
                label: "Mesh",
                shader_source: shaders::MESH_SHADER,
                bind_group_layouts: &[&layouts.global_layout, &layouts.model_layout],
                vertex_buffers: &[MeshVertex::desc()],
                blend: wgpu::BlendState::REPLACE,
                cull_mode: Some(wgpu::Face::Back),
                depth_write_enabled: true,
                depth_bias: wgpu::DepthBiasState::default(),
            }),
        }
    }
}

// Procedural grid pipeline — no vertex buffer, 6 vertices from vertex_index.
// Uses fwidth()-based anti-aliasing for consistent line width at any distance.
pub struct GridPipeline {
    pub pipeline: wgpu::RenderPipeline,
}

impl GridPipeline {
    pub fn new(
        device: &wgpu::Device,
        surface_format: wgpu::TextureFormat,
        layouts: &BindGroupLayouts,
    ) -> Self {
        Self {
            pipeline: create_pipeline(device, surface_format, &PipelineConfig {
                label: "Grid",
                shader_source: shaders::GRID_SHADER,
                bind_group_layouts: &[&layouts.global_layout, &layouts.grid_params_layout],
                vertex_buffers: &[],
                blend: wgpu::BlendState::ALPHA_BLENDING,
                cull_mode: None,
                depth_write_enabled: false,
                depth_bias: wgpu::DepthBiasState {
                    constant: -2,
                    slope_scale: TERRAIN_DEPTH_BIAS_SLOPE,
                    clamp: 0.0,
                },
            }),
        }
    }
}