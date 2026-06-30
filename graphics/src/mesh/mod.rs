// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

mod stl;
mod gpu_mesh;

pub use stl::load_stl_mesh;
pub use gpu_mesh::{GpuMesh, ModelUniform};

use crate::constants_m::{DEFAULT_MESH_COLOR, EPSILON_NORMALIZE};
use crate::renderer::pipeline::MeshVertex;
use crate::renderer::bind_groups::BindGroupLayouts;
use wgpu::util::DeviceExt;

#[derive(Clone, Debug)]
pub struct Material {
    pub face_rgba: [f32; 4],
}

// create a mesh material from a color string
pub fn make_material(color: &str) -> Material {
    let face_rgba = crate::config_m::parse_color(color, 1.0).unwrap_or_else(|_| {
        tracing::warn!(color = color, "Invalid mesh color, using default");
        DEFAULT_MESH_COLOR
    });
    Material { face_rgba }
}

// create a GPU mesh from VTK vertex/face data
pub fn create_gpu_mesh(
    device: &wgpu::Device,
    layouts: &BindGroupLayouts,
    vertices: Vec<[f32; 3]>,
    faces: Vec<[usize; 3]>,
    material: Material,
    scale: f32,
) -> GpuMesh {
    let scaled_vertices: Vec<[f32; 3]> = vertices
        .iter()
        .map(|v| [v[0] * scale, v[1] * scale, v[2] * scale])
        .collect();

    // compute smooth vertex normals by accumulating face normals
    let mut vertex_normals: Vec<[f32; 3]> = vec![[0.0, 0.0, 0.0]; scaled_vertices.len()];

    for face in &faces {
        let p0 = scaled_vertices[face[0]];
        let p1 = scaled_vertices[face[1]];
        let p2 = scaled_vertices[face[2]];

        let v1 = [p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2]];
        let v2 = [p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2]];

        // cross product for face normal
        let n = [
            v1[1] * v2[2] - v1[2] * v2[1],
            v1[2] * v2[0] - v1[0] * v2[2],
            v1[0] * v2[1] - v1[1] * v2[0],
        ];

        for &i in face {
            vertex_normals[i][0] += n[0];
            vertex_normals[i][1] += n[1];
            vertex_normals[i][2] += n[2];
        }
    }

    // normalize accumulated normals
    for n in &mut vertex_normals {
        let len = (n[0] * n[0] + n[1] * n[1] + n[2] * n[2]).sqrt();
        if len > EPSILON_NORMALIZE as f32 {
            n[0] /= len;
            n[1] /= len;
            n[2] /= len;
        }
    }

    let mesh_vertices: Vec<MeshVertex> = scaled_vertices
        .iter()
        .zip(vertex_normals.iter())
        .map(|(pos, norm)| MeshVertex {
            position: *pos,
            normal: *norm,
            color: material.face_rgba,
        })
        .collect();

    let indices: Vec<u32> = faces
        .iter()
        .flat_map(|f| [f[0] as u32, f[1] as u32, f[2] as u32])
        .collect();

    let vertex_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some("Mesh Vertex Buffer"),
        contents: bytemuck::cast_slice(&mesh_vertices),
        usage: wgpu::BufferUsages::VERTEX,
    });

    let index_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some("Mesh Index Buffer"),
        contents: bytemuck::cast_slice(&indices),
        usage: wgpu::BufferUsages::INDEX,
    });

    let model_uniform = ModelUniform::default();
    let model_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some("Mesh Model Buffer"),
        contents: bytemuck::cast_slice(&[model_uniform]),
        usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
    });

    let model_bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("Mesh Model Bind Group"),
        layout: &layouts.model_layout,
        entries: &[wgpu::BindGroupEntry {
            binding: 0,
            resource: model_buffer.as_entire_binding(),
        }],
    });

    GpuMesh {
        vertex_buffer,
        index_buffer,
        index_count: indices.len() as u32,
        model_buffer,
        model_bind_group,
    }
}