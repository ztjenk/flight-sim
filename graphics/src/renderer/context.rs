// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

use std::sync::Arc;
use tracing::{info, warn};

// core wgpu context - owns GPU resources shared across the application
pub struct WgpuContext {
    pub surface: wgpu::Surface<'static>,
    pub device: Arc<wgpu::Device>,      // Arc for sharing with terrain loader threads
    pub queue: Arc<wgpu::Queue>,
    pub surface_config: wgpu::SurfaceConfiguration,
}


impl WgpuContext {
    /// Create adapter + device from pre-created instance + surface.
    /// This is the slow part (adapter enumeration + device creation) and
    /// should run on a background thread.
    pub fn from_parts(
        instance: wgpu::Instance,
        surface: wgpu::Surface<'static>,
        window_size: winit::dpi::PhysicalSize<u32>,
    ) -> Result<Self, String> {
        use std::time::Instant;

        let t = Instant::now();
        let adapter = pollster::block_on(
            instance.request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::HighPerformance,
                compatible_surface: Some(&surface),
                force_fallback_adapter: false,
            })
        ).map_err(|e| format!("Failed to find a suitable GPU adapter: {}", e))?;

        let adapter_info = adapter.get_info();
        info!(ms = t.elapsed().as_millis(), gpu = %adapter_info.name, backend = ?adapter_info.backend, "GPU adapter selected");

        let mut required_features = wgpu::Features::empty();
        if adapter.features().contains(wgpu::Features::TEXTURE_COMPRESSION_BC) {
            required_features |= wgpu::Features::TEXTURE_COMPRESSION_BC;
        } else {
            warn!("GPU does not support BC texture compression — terrain textures will be decompressed on CPU (higher memory usage)");
        }

        let t = Instant::now();
        let (device, queue) = pollster::block_on(
            adapter.request_device(&wgpu::DeviceDescriptor {
                label: Some("Flight Simulator GPU"),
                required_features,
                required_limits: wgpu::Limits::default(),
                memory_hints: wgpu::MemoryHints::Performance,
                trace: wgpu::Trace::Off,
                experimental_features: wgpu::ExperimentalFeatures::default(),
            })
        ).map_err(|e| format!("Failed to create device: {}", e))?;
        info!(ms = t.elapsed().as_millis(), "Device created");

        let size = window_size;

        let t = Instant::now();
        let surface_caps = surface.get_capabilities(&adapter);
        info!(ms = t.elapsed().as_millis(), "Surface capabilities queried");

        let surface_format = surface_caps
            .formats
            .iter()
            .copied()
            .find(|f| f.is_srgb())
            .unwrap_or(surface_caps.formats[0]);

        let surface_config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format: surface_format,
            width: size.width.max(1),
            height: size.height.max(1),
            present_mode: wgpu::PresentMode::AutoVsync,
            alpha_mode: surface_caps.alpha_modes[0],
            view_formats: vec![],
            desired_maximum_frame_latency: 2,
        };

        let t = Instant::now();
        surface.configure(&device, &surface_config);
        info!(ms = t.elapsed().as_millis(), "Surface configured");

        Ok(Self {
            surface,
            device: Arc::new(device),
            queue: Arc::new(queue),
            surface_config,
        })
    }

    pub fn size(&self) -> (u32, u32) {
        (self.surface_config.width, self.surface_config.height)
    }
}
