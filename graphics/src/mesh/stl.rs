// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

//! STL file parser supporting both binary and ASCII formats
//! Includes vertex welding for smooth shading

use std::collections::HashMap;
use std::fs;
use tracing::{debug, warn};
use crate::constants_m::{STL_HEADER_SIZE, STL_BYTES_PER_TRIANGLE, STL_VERTEX_QUANTIZE_SCALE};

/// Load an STL mesh file and return welded vertices and triangle faces.
/// Vertex welding combines duplicate vertices so smooth normals can be computed.
#[allow(clippy::type_complexity)]
pub fn load_stl_mesh(path: &str) -> Result<(Vec<[f32; 3]>, Vec<[usize; 3]>), String> {
    let data = fs::read(path)
        .map_err(|e| format!("Failed to read STL file '{}': {}", path, e))?;

    // Try binary first, fall back to ASCII
    let triangles = if is_binary_stl(&data) {
        parse_binary_stl(&data)?
    } else {
        parse_ascii_stl(&data)?
    };

    // Weld vertices for smooth shading
    let (vertices, faces) = weld_vertices(&triangles);

    // Debug: log mesh bounding box to verify vertex positions
    if !vertices.is_empty() {
        let mut min = vertices[0];
        let mut max = vertices[0];
        for v in &vertices {
            for i in 0..3 {
                min[i] = min[i].min(v[i]);
                max[i] = max[i].max(v[i]);
            }
        }
        debug!(faces = faces.len(), min_x = min[0], min_y = min[1], min_z = min[2],
               max_x = max[0], max_y = max[1], max_z = max[2], "STL mesh loaded");
    } else {
        debug!(faces = faces.len(), "STL mesh loaded");
    }

    Ok((vertices, faces))
}

/// A triangle with 3 vertex positions
struct Triangle {
    vertices: [[f32; 3]; 3],
}

/// Check if STL data is binary format
fn is_binary_stl(data: &[u8]) -> bool {
    if data.len() < STL_HEADER_SIZE {
        return false;
    }

    // Check if it starts with "solid " (ASCII indicator)
    // But some binary files also start with "solid", so also check triangle count
    let starts_with_solid = data.len() >= 6 && &data[0..6] == b"solid ";

    if !starts_with_solid {
        return true; // Definitely binary
    }

    // Check if the file size matches binary format
    // Binary: 80 header + 4 count + (50 bytes per triangle)
    let triangle_count = u32::from_le_bytes([data[80], data[81], data[82], data[83]]) as usize;
    let expected_size = STL_HEADER_SIZE + triangle_count * STL_BYTES_PER_TRIANGLE;

    // If size matches binary format exactly, it's probably binary
    // (ASCII files would be much larger for same triangle count)
    if data.len() == expected_size {
        return true;
    }

    // Otherwise assume ASCII
    false
}

/// Parse binary STL format
fn parse_binary_stl(data: &[u8]) -> Result<Vec<Triangle>, String> {
    if data.len() < 84 {
        return Err("Binary STL file too small".to_string());
    }

    let triangle_count = u32::from_le_bytes([data[80], data[81], data[82], data[83]]) as usize;
    let expected_size = STL_HEADER_SIZE + triangle_count * STL_BYTES_PER_TRIANGLE;

    if data.len() < expected_size {
        return Err(format!(
            "Binary STL file truncated: expected {} bytes, got {}",
            expected_size, data.len()
        ));
    }

    let mut triangles = Vec::with_capacity(triangle_count);
    let mut offset = STL_HEADER_SIZE;

    for _ in 0..triangle_count {
        // Skip normal (12 bytes) - we compute smooth normals ourselves
        offset += 12;

        // Read 3 vertices (36 bytes)
        let mut vertices = [[0.0f32; 3]; 3];
        for v in &mut vertices {
            for coord in v.iter_mut() {
                *coord = f32::from_le_bytes([
                    data[offset],
                    data[offset + 1],
                    data[offset + 2],
                    data[offset + 3],
                ]);
                offset += 4;
            }
        }

        // Skip attribute byte count (2 bytes)
        offset += 2;

        triangles.push(Triangle { vertices });
    }

    Ok(triangles)
}

/// Parse ASCII STL format
fn parse_ascii_stl(data: &[u8]) -> Result<Vec<Triangle>, String> {
    let content = String::from_utf8_lossy(data);
    let mut triangles = Vec::new();
    let mut current_vertices: Vec<[f32; 3]> = Vec::new();

    for line in content.lines() {
        let line = line.trim();

        if line.starts_with("vertex ") {
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() >= 4 {
                let x: f32 = parts[1].parse().unwrap_or_else(|e| { warn!(value = parts[1], error = %e, "STL vertex parse error, using 0.0"); 0.0 });
                let y: f32 = parts[2].parse().unwrap_or_else(|e| { warn!(value = parts[2], error = %e, "STL vertex parse error, using 0.0"); 0.0 });
                let z: f32 = parts[3].parse().unwrap_or_else(|e| { warn!(value = parts[3], error = %e, "STL vertex parse error, using 0.0"); 0.0 });
                current_vertices.push([x, y, z]);
            }
        } else if line.starts_with("endfacet") {
            if current_vertices.len() >= 3 {
                triangles.push(Triangle {
                    vertices: [
                        current_vertices[0],
                        current_vertices[1],
                        current_vertices[2],
                    ],
                });
            }
            current_vertices.clear();
        }
    }

    if triangles.is_empty() {
        return Err("No triangles found in ASCII STL file".to_string());
    }

    Ok(triangles)
}

/// Weld vertices that are at the same position to enable smooth shading.
/// Returns (unique_vertices, faces_with_indices).
fn weld_vertices(triangles: &[Triangle]) -> (Vec<[f32; 3]>, Vec<[usize; 3]>) {
    // Use a hash map to find duplicate vertices
    // Key: quantized position (to handle floating point comparison)
    // Value: index in unique vertices list
    let mut vertex_map: HashMap<[i32; 3], usize> = HashMap::new();
    let mut unique_vertices: Vec<[f32; 3]> = Vec::new();
    let mut faces: Vec<[usize; 3]> = Vec::with_capacity(triangles.len());

    let scale = STL_VERTEX_QUANTIZE_SCALE as f32;

    for tri in triangles {
        let mut face_indices = [0usize; 3];

        for (i, vertex) in tri.vertices.iter().enumerate() {
            // Quantize vertex position for hash lookup
            let key = [
                (vertex[0] * scale).round() as i32,
                (vertex[1] * scale).round() as i32,
                (vertex[2] * scale).round() as i32,
            ];

            let index = *vertex_map.entry(key).or_insert_with(|| {
                let idx = unique_vertices.len();
                unique_vertices.push(*vertex);
                idx
            });

            face_indices[i] = index;
        }

        faces.push(face_indices);
    }

    (unique_vertices, faces)
}
