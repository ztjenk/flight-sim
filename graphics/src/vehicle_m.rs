// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

//! Vehicle module - manages multi-part aircraft with control surfaces
//!
//! Handles loading STL parts, applying physics transforms to main body,
//! and rotating control surfaces about their hinge lines.

use std::collections::HashMap;
use nalgebra::{Matrix3, Vector3};
use tracing::info;
use crate::config_m::VehicleConfig;
use crate::math_m;
use crate::mesh::{GpuMesh, create_gpu_mesh, load_stl_mesh, make_material};
use crate::renderer::bind_groups::BindGroupLayouts;
use crate::udp_m::ControlSurfaces;

/// Runtime data for a single vehicle part
pub struct VehiclePart {
    pub name: String,
    pub mesh: GpuMesh,
    pub is_main: bool,
    /// Control surface mapping: list of (surface_name, coefficient) pairs
    /// The total deflection is the sum of each surface's value times its coefficient
    /// e.g., [("elevsym", 1.0), ("elevasym", 1.0)] means elevsym + elevasym
    pub control_surface_mapping: Option<Vec<(String, f64)>>,
    /// Deflection multiplier: -1 for right side, 1 for left/symmetric
    pub side_multiplier: f64,
    /// Hinge point in body coordinates (for rotation)
    pub hinge_point: Option<[f64; 3]>,
    /// Hinge axis direction (normalized)
    pub hinge_axis: Option<[f64; 3]>,
    /// Name of the parent part this connects to (e.g., "main", "bireemp")
    pub connect_to: Option<String>,
}

/// Complete vehicle with all parts
pub struct Vehicle {
    pub parts: Vec<VehiclePart>,
    pub scale: f32,
    /// If true, control surface values from physics are in degrees and need conversion
    pub use_degrees: bool,
}

/// Compute combined control surface deflection from a mapping
/// Sums each surface's value times its coefficient
fn get_combined_deflection(
    control_surfaces: &ControlSurfaces,
    mapping: &[(String, f64)],
) -> f32 {
    mapping.iter()
        .map(|(name, coeff)| {
            let value = *control_surfaces.get(name).unwrap_or(&0.0);
            value * (*coeff as f32)
        })
        .sum()
}

impl Vehicle {
    /// Topologically sort parts so parents come before children.
    /// Parts connecting to "main" come first, then parts connecting to those, etc.
    fn topological_sort(parts: Vec<VehiclePart>) -> Vec<VehiclePart> {
        let mut sorted = Vec::with_capacity(parts.len());
        let mut remaining = parts;

        // Build a set of part names that have been placed
        let mut placed: std::collections::HashSet<String> = std::collections::HashSet::new();

        // First, place all main parts
        let (main_parts, non_main): (Vec<_>, Vec<_>) = remaining.into_iter()
            .partition(|p| p.is_main);

        for part in main_parts {
            placed.insert(part.name.clone());
            sorted.push(part);
        }
        remaining = non_main;

        // Iteratively place parts whose parent is already placed
        let max_iterations = remaining.len() + 1;
        for _ in 0..max_iterations {
            if remaining.is_empty() {
                break;
            }

            let (ready, not_ready): (Vec<_>, Vec<_>) = remaining.into_iter()
                .partition(|p| {
                    match &p.connect_to {
                        Some(parent) => placed.contains(parent),
                        None => true, // No parent means it can be placed
                    }
                });

            if ready.is_empty() && !not_ready.is_empty() {
                // Circular dependency or missing parent - just append remaining
                for part in not_ready {
                    sorted.push(part);
                }
                break;
            }

            for part in ready {
                placed.insert(part.name.clone());
                sorted.push(part);
            }
            remaining = not_ready;
        }

        sorted
    }

    /// Load vehicle from config
    pub fn load(
        device: &wgpu::Device,
        layouts: &BindGroupLayouts,
        config: &VehicleConfig,
    ) -> Result<Self, String> {
        // Validate config first
        config.validate()?;

        let material = make_material(&config.color);
        let scale = config.scale.unwrap_or(1.0) as f32;
        let use_degrees = config.control_surface_units.to_lowercase() == "degrees";

        let mut parts = Vec::new();

        // Load each part
        for (name, part_config) in &config.stl_files {
            // Skip entries without file (notes)
            let file_path = match &part_config.file {
                Some(f) => f,
                None => continue,
            };

            info!(part = %name, file = %file_path, "Loading vehicle part");

            let (vertices, faces) = load_stl_mesh(file_path)?;

            let mesh = create_gpu_mesh(
                device,
                layouts,
                vertices,
                faces,
                material.clone(),
                scale,
            );

            let side_multiplier = VehicleConfig::get_side_multiplier(part_config);

            // Extract control surface mapping (list of surface names and coefficients)
            let control_surface_mapping = part_config.control_surface.as_ref()
                .map(|mapping| mapping.surfaces.clone());

            parts.push(VehiclePart {
                name: name.clone(),
                mesh,
                is_main: part_config.is_main,
                control_surface_mapping,
                side_multiplier,
                hinge_point: part_config.hinge_point,
                hinge_axis: part_config.hinge_line,
                connect_to: part_config.connect_to.clone(),
            });
        }

        // Sort parts in topological order: main first, then parts connecting to main,
        // then parts connecting to those, etc. This ensures parents are processed before children.
        parts = Self::topological_sort(parts);

        info!(parts = parts.len(), units = if use_degrees { "degrees" } else { "radians" }, "Vehicle loaded");

        Ok(Self {
            parts,
            scale,
            use_degrees,
        })
    }


    /// Compute the local hinge transform for a part (rotation about hinge point/axis)
    fn compute_hinge_transform(
        part: &VehiclePart,
        control_surfaces: &ControlSurfaces,
        scale: f32,
        use_degrees: bool,
    ) -> glam::Mat4 {
        // Get deflection angle from control surface mapping
        let deflection_rad = if let Some(ref mapping) = part.control_surface_mapping {
            let raw_deflection = get_combined_deflection(control_surfaces, mapping) as f64;
            let deflection = if use_degrees {
                raw_deflection.to_radians()
            } else {
                raw_deflection
            };
            deflection * part.side_multiplier
        } else {
            0.0
        };

        // Get hinge parameters (scaled)
        let hinge_point_raw = part.hinge_point.unwrap_or([0.0, 0.0, 0.0]);
        let hp = math_m::arr3_to_glam(hinge_point_raw) * scale;
        let hinge_axis = part.hinge_axis.unwrap_or([1.0, 0.0, 0.0]);
        let axis = math_m::arr3_to_glam(hinge_axis).normalize();

        // Build hinge transform: translate to origin, rotate, translate back
        let t_to_origin = glam::Mat4::from_translation(-hp);
        let r_hinge = glam::Mat4::from_quat(glam::Quat::from_axis_angle(axis, deflection_rad as f32));
        let t_from_origin = glam::Mat4::from_translation(hp);

        t_from_origin * r_hinge * t_to_origin
    }

    /// Update all part transforms based on physics state and control surfaces.
    /// Handles hierarchical parent-child relationships: parts connected to non-main
    /// parents will rotate with their parent before applying their own hinge rotation.
    pub fn update_transforms(
        &mut self,
        queue: &wgpu::Queue,
        body_rotation: &Matrix3<f64>,
        body_position: &Vector3<f64>,
        control_surfaces: &ControlSurfaces,
    ) {
        // Pre-compute body transform components
        let body_to_world = body_rotation.transpose();
        let body_rot_glam = math_m::mat3_to_glam(&body_to_world);
        let t_body_pos = glam::Mat4::from_translation(math_m::vec3_to_glam(body_position));

        // Body transform: position * rotation. Scale is NOT applied here — `mesh::create_gpu_mesh`
        // is the single owner of scale (it pre-scales the vertices) and the hinge points above are
        // scaled once at line ~199, so the two are mutually consistent. Baking scale_mat in here too
        // would render any vehicle.scale != 1.0 at scale².
        let body_transform = t_body_pos * body_rot_glam;

        // Store accumulated hinge transforms for each part (product of all ancestor hinge transforms)
        // For main: identity. For non-main: parent_accumulated * own_hinge
        let mut accumulated_hinge: HashMap<String, glam::Mat4> = HashMap::new();

        // Parts are already in topological order (parents before children)
        for part in &mut self.parts {
            if part.is_main {
                // Main body: no hinge transform, just body transform
                accumulated_hinge.insert(part.name.clone(), glam::Mat4::IDENTITY);
                part.mesh.update_transform(queue, body_transform);
            } else {
                // Compute this part's local hinge transform
                let local_hinge = Self::compute_hinge_transform(part, control_surfaces, self.scale, self.use_degrees);

                // Get parent's accumulated hinge transform
                let parent_accumulated = part.connect_to.as_ref()
                    .and_then(|parent_name| accumulated_hinge.get(parent_name))
                    .copied()
                    .unwrap_or(glam::Mat4::IDENTITY);

                // This part's accumulated hinge = parent's accumulated * own hinge
                let this_accumulated = parent_accumulated * local_hinge;
                accumulated_hinge.insert(part.name.clone(), this_accumulated);

                // World transform = body_transform * accumulated_hinge
                let transform = body_transform * this_accumulated;
                part.mesh.update_transform(queue, transform);
            }
        }
    }

    /// Render all parts
    pub fn render<'a>(&'a self, render_pass: &mut wgpu::RenderPass<'a>) {
        for part in &self.parts {
            render_pass.set_bind_group(1, &part.mesh.model_bind_group, &[]);
            render_pass.set_vertex_buffer(0, part.mesh.vertex_buffer.slice(..));
            render_pass.set_index_buffer(
                part.mesh.index_buffer.slice(..),
                wgpu::IndexFormat::Uint32,
            );
            render_pass.draw_indexed(0..part.mesh.index_count, 0, 0..1);
        }
    }
}