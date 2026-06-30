// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

//! Terrain streaming configuration and supporting types

use crate::config_m::StreamingTerrainConfig;
use super::quadtree::Bounds;
use super::tile::TileKey;

use std::path::PathBuf;
use std::time::Instant;
use std::cmp::Ordering;

// ============================================================================
// Configuration
// ============================================================================

#[derive(Clone)]
pub struct TerrainConfig {
    pub tiles_dir: PathBuf,
    pub origin_lat_lon: Option<[f64; 2]>,
    pub max_draw_distance_ft: f64,
    pub mesh_resolution: usize,
    pub vertical_scale: f32,
    pub max_gpu_tiles: usize,
    pub num_workers: usize,
    pub max_uploads_per_frame: usize,
    pub upload_cooldown_ms: u64,
    pub max_deferred_uploads: usize,
    pub reference_texture_size: usize,
}

impl TerrainConfig {
    /// Create TerrainConfig from streaming config and parent ground config's max draw distance
    pub fn new(cfg: &StreamingTerrainConfig, max_draw_distance_ft: Option<f64>) -> Self {
        // Default to 100000 ft if not specified
        let max_dist = max_draw_distance_ft.unwrap_or(100000.0);
        Self {
            tiles_dir: cfg.tiles_dir_path().unwrap_or_default(),
            origin_lat_lon: cfg.origin_lat_lon,
            max_draw_distance_ft: max_dist,
            mesh_resolution: cfg.mesh_resolution,
            vertical_scale: cfg.vertical_scale,
            max_gpu_tiles: cfg.max_gpu_tiles,
            num_workers: cfg.num_workers,
            max_uploads_per_frame: cfg.max_uploads_per_frame,
            upload_cooldown_ms: cfg.upload_cooldown_ms,
            max_deferred_uploads: cfg.max_deferred_uploads,
            reference_texture_size: cfg.reference_texture_size,
        }
    }
}

// ============================================================================
// Tile priority calculation
// ============================================================================

pub(crate) struct TileCandidate {
    pub key: TileKey,
    pub priority: f64,
    pub mip_level: usize,
    pub dem_bounds: Option<Bounds>,
    pub imagery_bounds: Option<Bounds>,
    pub tile_path: String,
}

impl PartialEq for TileCandidate {
    fn eq(&self, other: &Self) -> bool { self.priority == other.priority }
}
impl Eq for TileCandidate {}
impl Ord for TileCandidate {
    fn cmp(&self, other: &Self) -> Ordering {
        self.priority.total_cmp(&other.priority)
    }
}
impl PartialOrd for TileCandidate {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> { Some(self.cmp(other)) }
}

// ============================================================================
// Loading info for tracking in-flight loads
// ============================================================================

pub(crate) struct LoadingTileInfo {
    pub bounds: Bounds,
    pub request_time: Instant,
}

// ============================================================================
// Leaf tile info
// ============================================================================

pub(crate) struct LeafTileInfo {
    pub key: TileKey,
    pub bounds: Bounds,
    pub dem_bounds: Option<Bounds>,
    pub imagery_bounds: Option<Bounds>,
    pub tile_path: String,
}
