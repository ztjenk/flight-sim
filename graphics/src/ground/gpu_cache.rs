// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

//! GPU memory budget and tile cache management
//!
//! Provides memory-aware caching for terrain tiles with LRU eviction.

use super::tile::{GpuTile, TileKey};

use std::collections::HashMap;

// ============================================================================
// Memory estimation
// ============================================================================

/// Bytes per pixel for different texture formats
pub mod format_sizes {
    pub const RGBA8: usize = 4;
    pub const BC1: usize = 8;   // 8 bytes per 4x4 block = 0.5 bytes/pixel
    pub const BC7: usize = 16;  // 16 bytes per 4x4 block = 1 byte/pixel
}

/// Estimate texture memory in bytes including all mip levels
pub fn estimate_texture_memory(width: u32, height: u32, is_compressed: bool, is_bc7: bool) -> usize {
    let base_size = (width as usize) * (height as usize);

    // For compressed textures, calculate block-based size
    let bytes_per_level = if is_compressed {
        let blocks_wide = (width as usize).div_ceil(4);
        let blocks_high = (height as usize).div_ceil(4);
        let block_size = if is_bc7 { format_sizes::BC7 } else { format_sizes::BC1 };
        blocks_wide * blocks_high * block_size
    } else {
        base_size * format_sizes::RGBA8
    };

    // Account for mip chain (sum of 1 + 1/4 + 1/16 + ... ≈ 1.33x)
    // For compressed textures, we typically store full mip chain
    (bytes_per_level as f64 * 1.34) as usize
}

/// Estimate vertex buffer memory in bytes
pub fn estimate_vertex_buffer_memory(vertex_count: usize) -> usize {
    // TerrainVertex: position(3 floats) + uv(2 floats) + normal(3 floats) = 8 floats = 32 bytes
    vertex_count * 32
}

/// Estimate index buffer memory in bytes
pub fn estimate_index_buffer_memory(index_count: usize) -> usize {
    // u32 indices = 4 bytes each
    index_count * 4
}

/// Total tile memory estimate
#[allow(dead_code)]
pub fn estimate_tile_memory(
    tex_width: u32,
    tex_height: u32,
    is_compressed: bool,
    is_bc7: bool,
    mesh_resolution: usize,
) -> usize {
    let texture_mem = estimate_texture_memory(tex_width, tex_height, is_compressed, is_bc7);

    let vertex_count = mesh_resolution * mesh_resolution;
    let vertex_mem = estimate_vertex_buffer_memory(vertex_count);

    let quad_count = (mesh_resolution - 1) * (mesh_resolution - 1);
    let index_count = quad_count * 6; // 2 triangles per quad, 3 indices per triangle
    let index_mem = estimate_index_buffer_memory(index_count);

    texture_mem + vertex_mem + index_mem
}

// ============================================================================
// GPU Memory Budget
// ============================================================================

/// Configuration for GPU memory budgeting
#[derive(Debug, Clone)]
pub struct GpuMemoryConfig {
    /// Maximum GPU memory budget in bytes (0 = unlimited, use tile count)
    pub budget_bytes: usize,
    /// Maximum number of tiles (fallback when budget_bytes is 0)
    pub max_tiles: usize,
    /// Minimum tiles to keep even if over budget (critical zone protection)
    pub min_tiles: usize,
}

impl Default for GpuMemoryConfig {
    fn default() -> Self {
        Self {
            budget_bytes: 512 * 1024 * 1024, // 512 MB default
            max_tiles: 128,
            min_tiles: 16,
        }
    }
}

impl GpuMemoryConfig {
    /// Create config with specific memory budget in megabytes
    #[allow(dead_code)]
    pub fn with_budget_mb(budget_mb: usize) -> Self {
        Self {
            budget_bytes: budget_mb * 1024 * 1024,
            ..Default::default()
        }
    }

    /// Create config with tile count limit only (no memory budgeting)
    pub fn with_tile_limit(max_tiles: usize) -> Self {
        Self {
            budget_bytes: 0,
            max_tiles,
            min_tiles: max_tiles.min(16),
        }
    }
}

// ============================================================================
// Tile Memory Info
// ============================================================================

/// Tracks memory usage for a single tile
#[derive(Debug, Clone)]
pub struct TileMemoryInfo {
    pub texture_bytes: usize,
    pub vertex_buffer_bytes: usize,
    pub index_buffer_bytes: usize,
}

impl TileMemoryInfo {
    pub fn new(
        tex_width: u32,
        tex_height: u32,
        is_compressed: bool,
        is_bc7: bool,
        vertex_count: usize,
        index_count: usize,
    ) -> Self {
        Self {
            texture_bytes: estimate_texture_memory(tex_width, tex_height, is_compressed, is_bc7),
            vertex_buffer_bytes: estimate_vertex_buffer_memory(vertex_count),
            index_buffer_bytes: estimate_index_buffer_memory(index_count),
        }
    }

    pub fn total_bytes(&self) -> usize {
        self.texture_bytes + self.vertex_buffer_bytes + self.index_buffer_bytes
    }
}

// ============================================================================
// GPU Tile Cache
// ============================================================================

/// Entry in the GPU tile cache with memory tracking and LOD info
pub struct CachedTile {
    pub tile: GpuTile,
    pub memory_info: TileMemoryInfo,
    /// The mip level this tile was loaded at (0 = highest resolution)
    pub loaded_mip_level: usize,
}

/// GPU tile cache with memory budget management
pub struct GpuTileCache {
    tiles: HashMap<TileKey, CachedTile>,
    config: GpuMemoryConfig,
    total_memory_bytes: usize,
}

#[allow(dead_code)]
impl GpuTileCache {
    pub fn new(config: GpuMemoryConfig) -> Self {
        Self {
            tiles: HashMap::new(),
            config,
            total_memory_bytes: 0,
        }
    }

    /// Insert a tile into the cache with its loaded mip level
    pub fn insert(&mut self, key: TileKey, tile: GpuTile, memory_info: TileMemoryInfo, loaded_mip_level: usize) {
        let mem_size = memory_info.total_bytes();

        // Remove old tile if exists (happens during upgrade/downgrade)
        if let Some(old) = self.tiles.remove(&key) {
            self.total_memory_bytes = self.total_memory_bytes.saturating_sub(old.memory_info.total_bytes());
        }

        self.tiles.insert(key, CachedTile { tile, memory_info, loaded_mip_level });
        self.total_memory_bytes += mem_size;
    }

    /// Get the loaded mip level for a tile
    pub fn get_mip_level(&self, key: &TileKey) -> Option<usize> {
        self.tiles.get(key).map(|c| c.loaded_mip_level)
    }

    /// Remove a tile from the cache
    pub fn remove(&mut self, key: &TileKey) -> Option<CachedTile> {
        if let Some(cached) = self.tiles.remove(key) {
            self.total_memory_bytes = self.total_memory_bytes.saturating_sub(cached.memory_info.total_bytes());
            Some(cached)
        } else {
            None
        }
    }

    /// Get a reference to a tile
    pub fn get(&self, key: &TileKey) -> Option<&GpuTile> {
        self.tiles.get(key).map(|c| &c.tile)
    }

    /// Get a mutable reference to a tile
    pub fn get_mut(&mut self, key: &TileKey) -> Option<&mut GpuTile> {
        self.tiles.get_mut(key).map(|c| &mut c.tile)
    }

    /// Check if cache contains a tile
    pub fn contains_key(&self, key: &TileKey) -> bool {
        self.tiles.contains_key(key)
    }

    /// Get number of tiles in cache
    pub fn len(&self) -> usize {
        self.tiles.len()
    }

    /// Check if cache is empty
    pub fn is_empty(&self) -> bool {
        self.tiles.is_empty()
    }

    /// Get total memory usage in bytes
    pub fn total_memory_bytes(&self) -> usize {
        self.total_memory_bytes
    }

    /// Get total memory usage in megabytes
    pub fn total_memory_mb(&self) -> f64 {
        self.total_memory_bytes as f64 / (1024.0 * 1024.0)
    }

    /// Get memory budget in bytes (0 = unlimited)
    pub fn budget_bytes(&self) -> usize {
        self.config.budget_bytes
    }

    /// Check if cache is over budget
    pub fn is_over_budget(&self) -> bool {
        if self.config.budget_bytes > 0 {
            self.total_memory_bytes > self.config.budget_bytes
        } else {
            self.tiles.len() > self.config.max_tiles
        }
    }

    /// Get amount over budget in bytes (0 if under budget)
    pub fn over_budget_bytes(&self) -> usize {
        if self.config.budget_bytes > 0 {
            self.total_memory_bytes.saturating_sub(self.config.budget_bytes)
        } else {
            0
        }
    }

    /// Iterate over all tiles
    pub fn values(&self) -> impl Iterator<Item = &GpuTile> {
        self.tiles.values().map(|c| &c.tile)
    }

    /// Iterate over all tiles mutably
    pub fn values_mut(&mut self) -> impl Iterator<Item = &mut GpuTile> {
        self.tiles.iter_mut().map(|(_, c)| &mut c.tile)
    }

    /// Iterate over all key-tile pairs
    pub fn iter(&self) -> impl Iterator<Item = (&TileKey, &GpuTile)> {
        self.tiles.iter().map(|(k, c)| (k, &c.tile))
    }

    /// Iterate over all key-tile pairs mutably
    pub fn iter_mut(&mut self) -> impl Iterator<Item = (&TileKey, &mut GpuTile)> {
        self.tiles.iter_mut().map(|(k, c)| (k, &mut c.tile))
    }

    /// Get eviction candidates sorted by priority (highest eviction score first)
    ///
    /// Returns tiles that should be evicted, excluding protected tiles.
    /// The eviction score considers:
    /// - Distance from camera (farther = higher eviction priority)
    /// - Time since last use (older = higher eviction priority)
    /// - Memory size (larger = slightly higher eviction priority to free more memory faster)
    pub fn get_eviction_candidates(
        &self,
        cam_utm: (f64, f64),
        velocity_dir: Option<[f64; 2]>,
        critical_radius_ft: f64,
    ) -> Vec<(TileKey, f64, usize)> {
        use crate::constants_m::M_TO_FT;

        let mut candidates: Vec<(TileKey, f64, usize)> = Vec::new();

        for (key, cached) in &self.tiles {
            let tile = &cached.tile;
            let bounds = &tile.dem_bounds;
            let (cx, cy) = bounds.center();
            let dx = cx - cam_utm.0;
            let dy = cy - cam_utm.1;
            let distance_m = (dx * dx + dy * dy).sqrt();
            let distance_ft = distance_m * M_TO_FT;

            // Check if camera is within the tile itself (protected)
            // Use small margin (10% of tile size or 100m min) for edge cases
            let tile_width = bounds.max_x - bounds.min_x;
            let tile_height = bounds.max_y - bounds.min_y;
            let margin = (tile_width.min(tile_height) * 0.1).max(100.0);

            let cam_in_tile = cam_utm.0 >= bounds.min_x - margin
                && cam_utm.0 <= bounds.max_x + margin
                && cam_utm.1 >= bounds.min_y - margin
                && cam_utm.1 <= bounds.max_y + margin;

            if cam_in_tile {
                continue; // Never evict tile we're currently on
            }

            // Critical zone protection
            if distance_ft < critical_radius_ft {
                continue;
            }

            // Calculate eviction score (higher = evict first)

            // Distance score: farther tiles get higher eviction priority
            let distance_score = (distance_ft / 10000.0).min(5.0);

            // Direction score: tiles behind the aircraft get evicted first
            let direction_score = if let Some(vel) = velocity_dir {
                let vel_len = (vel[0] * vel[0] + vel[1] * vel[1]).sqrt();
                if vel_len > 0.01 && distance_m > 1.0 {
                    let vel_n = [vel[0] / vel_len, vel[1] / vel_len];
                    let tile_dir_x = dx / distance_m;
                    let tile_dir_y = dy / distance_m;
                    let dot = vel_n[0] * tile_dir_y + vel_n[1] * tile_dir_x;
                    // Behind (dot=-1) -> 8.0, ahead (dot=1) -> 0.0
                    4.0 * (1.0 - dot)
                } else {
                    2.0
                }
            } else {
                2.0
            };

            // Age score: tiles not recently used are candidates for eviction
            let age_secs = tile.last_used.elapsed().as_secs_f64();
            let age_score = (age_secs * 0.5).min(3.0);

            // Memory score: slightly prefer evicting larger tiles to free more memory
            let memory_mb = cached.memory_info.total_bytes() as f64 / (1024.0 * 1024.0);
            let memory_score = (memory_mb * 0.1).min(1.0);

            let total_score = distance_score + direction_score + age_score + memory_score;
            let mem_size = cached.memory_info.total_bytes();

            candidates.push((key.clone(), total_score, mem_size));
        }

        // Sort by eviction score (highest first); total_cmp handles NaN safely
        candidates.sort_by(|a, b| b.1.total_cmp(&a.1));

        candidates
    }

    /// Evict tiles until under budget, respecting min_tiles limit
    ///
    /// Returns the keys of evicted tiles.
    pub fn evict_to_budget(
        &mut self,
        cam_utm: (f64, f64),
        velocity_dir: Option<[f64; 2]>,
        critical_radius_ft: f64,
    ) -> Vec<TileKey> {
        if !self.is_over_budget() {
            return Vec::new();
        }

        let tile_count_before = self.tiles.len();
        let candidates = self.get_eviction_candidates(cam_utm, velocity_dir, critical_radius_ft);
        let candidate_count = candidates.len();
        let mut evicted = Vec::new();

        for (key, _score, _mem_size) in candidates {
            // Stop if we're under budget
            if !self.is_over_budget() {
                break;
            }

            // Respect minimum tile count
            if self.tiles.len() <= self.config.min_tiles {
                break;
            }

            // Evict the tile
            self.remove(&key);
            evicted.push(key);
        }

        // Log warning if we couldn't evict enough tiles
        if self.is_over_budget() && evicted.is_empty() && candidate_count == 0 {
            tracing::warn!(
                tiles = tile_count_before,
                max_tiles = self.config.max_tiles,
                memory_mb = format!("{:.1}", self.total_memory_mb()),
                "Cache over budget but no eviction candidates - all tiles protected!"
            );
        } else if !evicted.is_empty() {
            tracing::debug!(
                evicted = evicted.len(),
                remaining = self.tiles.len(),
                memory_mb = format!("{:.1}", self.total_memory_mb()),
                "Evicted tiles from GPU cache"
            );
        }

        evicted
    }

    /// Get debug info about cache state
    pub fn debug_info(&self) -> String {
        let budget_mb = self.config.budget_bytes as f64 / (1024.0 * 1024.0);
        let used_mb = self.total_memory_mb();
        let usage_pct = if self.config.budget_bytes > 0 {
            (used_mb / budget_mb) * 100.0
        } else {
            0.0
        };

        if self.config.budget_bytes > 0 {
            format!(
                "GPU Cache: {:.1}/{:.1} MB ({:.0}%), {} tiles",
                used_mb, budget_mb, usage_pct, self.tiles.len()
            )
        } else {
            format!(
                "GPU Cache: {:.1} MB, {}/{} tiles",
                used_mb, self.tiles.len(), self.config.max_tiles
            )
        }
    }

    /// Get tiles that need LOD upgrade (higher resolution) or downgrade (lower resolution)
    /// based on their current distance vs loaded mip level.
    ///
    /// Returns: Vec<(TileKey, current_mip, desired_mip, priority)>
    /// - Upgrade candidates: current_mip > desired_mip (need higher res)
    /// - Downgrade candidates: current_mip < desired_mip (can use lower res)
    ///
    /// The `get_mip_for_distance` closure should return the ideal mip level for a given distance.
    pub fn get_lod_change_candidates<F>(
        &self,
        cam_utm: (f64, f64),
        get_mip_for_distance: F,
    ) -> Vec<(TileKey, usize, usize, f64)>
    where
        F: Fn(f64) -> usize,
    {
        use crate::constants_m::M_TO_FT;

        let mut candidates = Vec::new();

        for (key, cached) in &self.tiles {
            let tile = &cached.tile;
            let bounds = &tile.dem_bounds;
            let (cx, cy) = bounds.center();
            let dx = cx - cam_utm.0;
            let dy = cy - cam_utm.1;
            let distance_m = (dx * dx + dy * dy).sqrt();
            let distance_ft = distance_m * M_TO_FT;

            let current_mip = cached.loaded_mip_level;
            let desired_mip = get_mip_for_distance(distance_ft);

            // Only consider changes of at least 1 mip level
            if current_mip != desired_mip {
                // Priority: closer tiles and larger mip differences get higher priority
                let mip_diff = (current_mip as i32 - desired_mip as i32).abs() as f64;
                let distance_priority = 1.0 / (1.0 + distance_ft / 5000.0);
                let priority = mip_diff * 10.0 + distance_priority * 5.0;

                // Upgrades (need higher res) get extra priority
                let priority = if current_mip > desired_mip {
                    priority * 2.0  // Upgrades are more important
                } else {
                    priority * 0.5  // Downgrades are less urgent
                };

                candidates.push((key.clone(), current_mip, desired_mip, priority));
            }
        }

        // Sort by priority (highest first); total_cmp handles NaN safely
        candidates.sort_by(|a, b| b.3.total_cmp(&a.3));

        candidates
    }

    /// Get count of tiles that need upgrading (currently at lower res than needed)
    pub fn upgrade_needed_count<F>(&self, cam_utm: (f64, f64), get_mip_for_distance: F) -> usize
    where
        F: Fn(f64) -> usize,
    {
        self.get_lod_change_candidates(cam_utm, get_mip_for_distance)
            .iter()
            .filter(|(_, current, desired, _)| current > desired)
            .count()
    }
}
