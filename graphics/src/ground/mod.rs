// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

// Ground grid module
mod ground_grid_m;

// Streaming terrain submodules
mod bc_texture;
mod geotiff;
mod gpu_cache;
mod loader;
mod quadtree;
mod tile;
mod visibility;
mod terrain_config;
mod utm;
mod streaming_terrain_m;

// Public re-exports
pub use ground_grid_m::{GroundGrid, parse_ground_color};
pub use streaming_terrain_m::StreamingTerrainManager;
pub use terrain_config::TerrainConfig;
