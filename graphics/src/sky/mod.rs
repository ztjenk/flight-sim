// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

//! Precomputed Atmospheric Scattering (Bruneton 2008 / Hillaire 2020)
//!
//! Implements GPU-based LUT generation for real-time sky rendering:
//! - Transmittance LUT: optical depth through atmosphere
//! - Multi-scattering LUT: 2nd+ order scattering approximation
//! - Sky-view LUT: final sky color per view direction
//!
//! References:
//! - Bruneton & Neyret 2008: "Precomputed Atmospheric Scattering"
//! - Hillaire 2020: "A Scalable and Production Ready Sky and Atmosphere Rendering Technique"

mod shaders;
mod params;
mod lut;
mod renderer;

// Re-export public types (only what's actually used externally)
pub use params::{
    TRANSMITTANCE_LUT_WIDTH, TRANSMITTANCE_LUT_HEIGHT,
    MULTISCATTER_LUT_WIDTH, MULTISCATTER_LUT_HEIGHT,
    SKYVIEW_LUT_WIDTH, SKYVIEW_LUT_HEIGHT,
    SkyCameraUniform, AtmosphereUniforms,
};

use crate::config_m::SkyConfig;
use tracing::info;
use wgpu::util::DeviceExt;

// ============================================================================
// Sky Renderer
// ============================================================================

/// Manages precomputed LUTs and sky rendering
pub struct SkyRenderer {
    // Camera uniforms for sky rendering
    camera_buffer: wgpu::Buffer,
    camera_uniform: SkyCameraUniform,

    // Atmosphere uniforms
    atmosphere_buffer: wgpu::Buffer,
    #[allow(dead_code)]
    atmosphere_bind_group_layout: wgpu::BindGroupLayout,
    atmosphere_bind_group: wgpu::BindGroup,

    // Transmittance LUT (precomputed once) - kept alive for GPU
    #[allow(dead_code)]
    transmittance_texture: wgpu::Texture,
    #[allow(dead_code)]
    transmittance_view: wgpu::TextureView,
    transmittance_pipeline: wgpu::ComputePipeline,
    transmittance_bind_group: wgpu::BindGroup,

    // Multi-scattering LUT (precomputed once)
    #[allow(dead_code)]
    multiscatter_texture: wgpu::Texture,
    #[allow(dead_code)]
    multiscatter_view: wgpu::TextureView,
    multiscatter_pipeline: wgpu::ComputePipeline,
    multiscatter_bind_group: wgpu::BindGroup,

    // Sky-view LUT (per-frame)
    #[allow(dead_code)]
    skyview_texture: wgpu::Texture,
    #[allow(dead_code)]
    skyview_view: wgpu::TextureView,
    skyview_pipeline: wgpu::ComputePipeline,
    skyview_bind_group: wgpu::BindGroup,

    // Final sky rendering
    render_pipeline: wgpu::RenderPipeline,
    render_bind_group: wgpu::BindGroup,
    camera_bind_group: wgpu::BindGroup,

    // Sampler for LUT sampling
    #[allow(dead_code)]
    lut_sampler: wgpu::Sampler,

    // State
    luts_generated: bool,
    uniforms: AtmosphereUniforms,
}

impl SkyRenderer {
    pub fn new(
        device: &wgpu::Device,
        config: &SkyConfig,
        surface_format: wgpu::TextureFormat,
    ) -> Self {
        let uniforms = AtmosphereUniforms::from_config(config);
        let camera_uniform = SkyCameraUniform::default();

        // Create camera uniform buffer
        let camera_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Sky Camera Uniforms"),
            contents: bytemuck::cast_slice(&[camera_uniform]),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        });

        // Create atmosphere uniform buffer
        let atmosphere_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Atmosphere Uniforms"),
            contents: bytemuck::cast_slice(&[uniforms]),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        });

        // Bind group layout for atmosphere uniforms
        let atmosphere_bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("Atmosphere Bind Group Layout"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::COMPUTE | wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            }],
        });

        let atmosphere_bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Atmosphere Bind Group"),
            layout: &atmosphere_bind_group_layout,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: atmosphere_buffer.as_entire_binding(),
            }],
        });

        // LUT sampler with bilinear filtering
        let lut_sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("LUT Sampler"),
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            address_mode_w: wgpu::AddressMode::ClampToEdge,
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            mipmap_filter: wgpu::FilterMode::Nearest,
            ..Default::default()
        });

        // Create LUT textures
        let transmittance_texture = lut::create_lut_texture(
            device,
            TRANSMITTANCE_LUT_WIDTH,
            TRANSMITTANCE_LUT_HEIGHT,
            "Transmittance LUT",
        );
        let transmittance_view = transmittance_texture.create_view(&wgpu::TextureViewDescriptor::default());

        let multiscatter_texture = lut::create_lut_texture(
            device,
            MULTISCATTER_LUT_WIDTH,
            MULTISCATTER_LUT_HEIGHT,
            "Multiscatter LUT",
        );
        let multiscatter_view = multiscatter_texture.create_view(&wgpu::TextureViewDescriptor::default());

        let skyview_texture = lut::create_lut_texture(
            device,
            SKYVIEW_LUT_WIDTH,
            SKYVIEW_LUT_HEIGHT,
            "Skyview LUT",
        );
        let skyview_view = skyview_texture.create_view(&wgpu::TextureViewDescriptor::default());

        // Create compute pipelines and bind groups (each compiles a shader)
        let t = std::time::Instant::now();
        let (transmittance_pipeline, transmittance_bind_group) = lut::create_transmittance_pipeline(
            device, &atmosphere_bind_group_layout, &transmittance_view,
        );
        tracing::info!(ms = t.elapsed().as_millis(), "  Sky transmittance pipeline compiled");

        let t = std::time::Instant::now();
        let (multiscatter_pipeline, multiscatter_bind_group) = lut::create_multiscatter_pipeline(
            device, &atmosphere_bind_group_layout, &transmittance_view, &multiscatter_view, &lut_sampler,
        );
        tracing::info!(ms = t.elapsed().as_millis(), "  Sky multiscatter pipeline compiled");

        let t = std::time::Instant::now();
        let (skyview_pipeline, skyview_bind_group) = lut::create_skyview_pipeline(
            device, &atmosphere_bind_group_layout, &transmittance_view, &multiscatter_view, &skyview_view, &lut_sampler,
        );
        tracing::info!(ms = t.elapsed().as_millis(), "  Sky skyview pipeline compiled");

        let t = std::time::Instant::now();
        let (render_pipeline, render_bind_group, camera_bind_group) = renderer::create_render_pipeline(
            device, surface_format, &atmosphere_bind_group_layout, &skyview_view, &transmittance_view, &lut_sampler, &camera_buffer,
        );
        tracing::info!(ms = t.elapsed().as_millis(), "  Sky render pipeline compiled");

        Self {
            camera_buffer,
            camera_uniform,
            atmosphere_buffer,
            atmosphere_bind_group_layout,
            atmosphere_bind_group,
            transmittance_texture,
            transmittance_view,
            transmittance_pipeline,
            transmittance_bind_group,
            multiscatter_texture,
            multiscatter_view,
            multiscatter_pipeline,
            multiscatter_bind_group,
            skyview_texture,
            skyview_view,
            skyview_pipeline,
            skyview_bind_group,
            render_pipeline,
            render_bind_group,
            camera_bind_group,
            lut_sampler,
            luts_generated: false,
            uniforms,
        }
    }

    /// Generate static LUTs (transmittance and multiscatter) - call once at startup
    pub fn generate_static_luts(&mut self, encoder: &mut wgpu::CommandEncoder) {
        if self.luts_generated {
            return;
        }

        // Transmittance LUT
        lut::dispatch_transmittance(
            encoder,
            &self.transmittance_pipeline,
            &self.atmosphere_bind_group,
            &self.transmittance_bind_group,
        );

        // Multi-scattering LUT (depends on transmittance)
        lut::dispatch_multiscatter(
            encoder,
            &self.multiscatter_pipeline,
            &self.atmosphere_bind_group,
            &self.multiscatter_bind_group,
        );

        self.luts_generated = true;
        info!(sun_dir = ?self.uniforms.sun_direction, exposure = self.uniforms.exposure,
              "Generated transmittance and multiscatter LUTs");
    }

    /// Update sky-view LUT for current camera/sun position - call each frame
    pub fn update_skyview(&self, encoder: &mut wgpu::CommandEncoder) {
        lut::dispatch_skyview(
            encoder,
            &self.skyview_pipeline,
            &self.atmosphere_bind_group,
            &self.skyview_bind_group,
        );
    }

    /// Update atmosphere uniforms (sun direction, camera height, etc.)
    pub fn update_uniforms(&mut self, queue: &wgpu::Queue, camera_height_m: f32, sun_direction: [f32; 3]) {
        self.uniforms.camera_height = camera_height_m;

        // Normalize sun direction
        let len = (sun_direction[0].powi(2) + sun_direction[1].powi(2) + sun_direction[2].powi(2)).sqrt();
        self.uniforms.sun_direction = [
            sun_direction[0] / len,
            sun_direction[1] / len,
            sun_direction[2] / len,
        ];

        queue.write_buffer(&self.atmosphere_buffer, 0, bytemuck::cast_slice(&[self.uniforms]));
    }

    /// Update camera uniforms for sky rendering
    /// inv_view_rotation: 3x3 inverse view rotation matrix (column-major)
    /// fov_y: vertical field of view in radians
    /// aspect_ratio: width / height
    pub fn update_camera(
        &mut self,
        queue: &wgpu::Queue,
        inv_view_rotation: [[f32; 3]; 3],
        fov_y: f32,
        aspect_ratio: f32,
    ) {
        self.camera_uniform.inv_view_col0 = [inv_view_rotation[0][0], inv_view_rotation[0][1], inv_view_rotation[0][2], 0.0];
        self.camera_uniform.inv_view_col1 = [inv_view_rotation[1][0], inv_view_rotation[1][1], inv_view_rotation[1][2], 0.0];
        self.camera_uniform.inv_view_col2 = [inv_view_rotation[2][0], inv_view_rotation[2][1], inv_view_rotation[2][2], 0.0];
        self.camera_uniform.fov_y = fov_y;
        self.camera_uniform.aspect_ratio = aspect_ratio;

        queue.write_buffer(&self.camera_buffer, 0, bytemuck::cast_slice(&[self.camera_uniform]));
    }

    /// Render sky as fullscreen quad behind all geometry
    pub fn render<'a>(&'a self, render_pass: &mut wgpu::RenderPass<'a>) {
        render_pass.set_pipeline(&self.render_pipeline);
        render_pass.set_bind_group(0, &self.atmosphere_bind_group, &[]);
        render_pass.set_bind_group(1, &self.render_bind_group, &[]);
        render_pass.set_bind_group(2, &self.camera_bind_group, &[]);
        render_pass.draw(0..3, 0..1); // Fullscreen triangle
    }

    /// Get current sun direction
    pub fn get_sun_direction(&self) -> [f32; 3] {
        self.uniforms.sun_direction
    }
}
