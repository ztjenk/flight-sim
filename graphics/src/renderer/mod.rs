// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

mod context;
pub mod pipeline;
pub mod bind_groups;
mod shaders;

pub use context::WgpuContext;
pub use pipeline::{TerrainPipeline, MeshPipeline, GridPipeline};
pub use bind_groups::{BindGroupLayouts, GlobalBindGroup};

use crate::config_m::{Config, GroundMode};
use crate::camera_m::CameraUniform;
use crate::constants_m::{DEFAULT_LIGHT_AIRCRAFT_INTENSITY, DEFAULT_LIGHT_GROUND_INTENSITY, DEFAULT_LIGHT_AMBIENT};

use wgpu::util::DeviceExt;  // extends Device with create_buffer_init()

// light uniform data - must match WGSL struct alignment (48 bytes total)
// wgsl vec3<f32> requires 16-byte alignment
#[repr(C)]
#[derive(Debug, Copy, Clone, bytemuck::Pod, bytemuck::Zeroable)]
pub struct LightUniform {
    pub direction: [f32; 3],       // bytes 0-11, normalized direction from light source
    pub aircraft_intensity: f32,   // bytes 12-15
    pub ground_intensity: f32,     // bytes 16-19
    pub ambient: f32,              // bytes 20-23
    pub _pad1: [f32; 2],           // bytes 24-31
    pub _padding: [f32; 3],        // bytes 32-43
    pub _struct_pad: f32,          // bytes 44-47
}

// main renderer struct - owns all GPU resources
pub struct WgpuRenderer {
    pub context: WgpuContext,
    pub terrain_pipeline: Option<TerrainPipeline>,  // None when ground mode is grid-only
    pub mesh_pipeline: MeshPipeline,
    pub grid_pipeline: Option<GridPipeline>,         // None when ground mode is streaming-only
    pub global_bind_group: GlobalBindGroup,
    pub camera_buffer: wgpu::Buffer,
    pub depth_texture: wgpu::TextureView,
}

/// GPU pipeline/buffer components built independently of the surface.
/// Created on a background thread, then combined with a WgpuContext on the main thread.
pub struct RendererComponents {
    pub terrain_pipeline: Option<TerrainPipeline>,
    pub mesh_pipeline: MeshPipeline,
    pub grid_pipeline: Option<GridPipeline>,
    pub bind_group_layouts: BindGroupLayouts,
    pub global_bind_group: GlobalBindGroup,
    pub camera_buffer: wgpu::Buffer,
}

impl WgpuRenderer {
    /// Build renderer components on any thread (does not need a Surface).
    /// Only compiles pipelines needed for the current ground mode to minimize startup time.
    /// Call `assemble()` on the main thread to combine with a WgpuContext.
    pub fn build_components(
        device: &wgpu::Device,
        surface_format: wgpu::TextureFormat,
        config: &Config,
    ) -> RendererComponents {
        let bind_group_layouts = BindGroupLayouts::new(device);

        let use_streaming = config.use_streaming_terrain();
        let use_grid = !use_streaming && config.ground.mode == GroundMode::Grid;

        let t = std::time::Instant::now();
        let terrain_pipeline = if use_streaming {
            let p = TerrainPipeline::new(device, surface_format, &bind_group_layouts);
            tracing::info!(ms = t.elapsed().as_millis(), "  TerrainPipeline compiled");
            Some(p)
        } else { None };

        let t = std::time::Instant::now();
        let mesh_pipeline = MeshPipeline::new(device, surface_format, &bind_group_layouts);
        tracing::info!(ms = t.elapsed().as_millis(), "  MeshPipeline compiled");

        let t = std::time::Instant::now();
        let grid_pipeline = if use_grid {
            let p = GridPipeline::new(device, surface_format, &bind_group_layouts);
            tracing::info!(ms = t.elapsed().as_millis(), "  GridPipeline compiled");
            Some(p)
        } else { None };

        let camera_uniform = CameraUniform::default();
        let camera_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Camera Buffer"),
            contents: bytemuck::cast_slice(&[camera_uniform]),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        });

        let (light_dir, aircraft_intensity, ground_intensity, ambient) = if let Some(ref lighting) = config.lighting {
            (lighting.direction_world, lighting.aircraft_sun_intensity as f32, lighting.ground_sun_intensity as f32, lighting.ambient as f32)
        } else if let Some(ref sky) = config.sky {
            let sd = sky.sun_direction;
            ([-sd[0], -sd[1], -sd[2]], DEFAULT_LIGHT_AIRCRAFT_INTENSITY as f32, DEFAULT_LIGHT_GROUND_INTENSITY as f32, DEFAULT_LIGHT_AMBIENT as f32)
        } else {
            ([0.5, 0.0, 0.7], DEFAULT_LIGHT_AIRCRAFT_INTENSITY as f32, DEFAULT_LIGHT_GROUND_INTENSITY as f32, 0.2)
        };

        let light_mag = (light_dir[0].powi(2) + light_dir[1].powi(2) + light_dir[2].powi(2)).sqrt().max(f64::EPSILON);
        let light_uniform = LightUniform {
            direction: [(light_dir[0] / light_mag) as f32, (light_dir[1] / light_mag) as f32, (light_dir[2] / light_mag) as f32],
            aircraft_intensity, ground_intensity, ambient,
            _pad1: [0.0; 2], _padding: [0.0; 3], _struct_pad: 0.0,
        };
        let light_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Light Buffer"),
            contents: bytemuck::cast_slice(&[light_uniform]),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        });

        let global_bind_group = GlobalBindGroup::new(device, &bind_group_layouts, &camera_buffer, &light_buffer);

        RendererComponents {
            terrain_pipeline, mesh_pipeline, grid_pipeline,
            bind_group_layouts, global_bind_group, camera_buffer,
        }
    }

    /// Assemble a complete renderer from a context (main thread) and pre-built components (background thread).
    pub fn assemble(context: WgpuContext, c: RendererComponents) -> Self {
        let depth_texture = Self::create_depth_texture(
            &context.device, context.surface_config.width, context.surface_config.height,
        );
        Self {
            context,
            terrain_pipeline: c.terrain_pipeline,
            mesh_pipeline: c.mesh_pipeline,
            grid_pipeline: c.grid_pipeline,
            global_bind_group: c.global_bind_group,
            camera_buffer: c.camera_buffer,
            depth_texture,
        }
    }

    fn create_depth_texture(device: &wgpu::Device, width: u32, height: u32) -> wgpu::TextureView {
        let size = wgpu::Extent3d {
            width,
            height,
            depth_or_array_layers: 1,
        };

        let texture = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("Depth Texture"),
            size,
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Depth32Float,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        });

        texture.create_view(&wgpu::TextureViewDescriptor::default())
    }

    pub fn resize(&mut self, new_size: winit::dpi::PhysicalSize<u32>) {
        if new_size.width > 0 && new_size.height > 0 {
            self.context.surface_config.width = new_size.width;
            self.context.surface_config.height = new_size.height;
            self.context.surface.configure(&self.context.device, &self.context.surface_config);

            self.depth_texture = Self::create_depth_texture(
                &self.context.device,
                new_size.width,
                new_size.height,
            );
        }
    }

    pub fn update_camera(&self, uniform: &CameraUniform) {
        self.context.queue.write_buffer(
            &self.camera_buffer,
            0,
            bytemuck::cast_slice(&[*uniform]),
        );
    }

}