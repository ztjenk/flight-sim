// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

//! WGSL shader source code
//!
//! Shader files are stored in `src/shaders/` for editor tooling support.

/// Terrain vertex and fragment shader
pub const TERRAIN_SHADER: &str = include_str!("../shaders/terrain.wgsl");

/// Mesh (aircraft) vertex and fragment shader
pub const MESH_SHADER: &str = include_str!("../shaders/mesh.wgsl");

/// Grid shader with alpha blending for ground grid
/// Uses MeshVertex format (position, normal, color with alpha)
pub const GRID_SHADER: &str = include_str!("../shaders/grid.wgsl");
