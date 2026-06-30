// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

//! Streaming terrain manager for loading and managing terrain tiles

use super::bc_texture::BcFormat;
use super::geotiff::GlobalDem;
use super::gpu_cache::{GpuTileCache, GpuMemoryConfig, TileMemoryInfo};
use super::loader::{TileLoadRequest, TileLoadResult, TileLoadOutcome, TileLoader, MeshConfig, RegionalDemRef};
use super::quadtree::{QuadtreeIndex, QuadtreeNode, Bounds};
use super::tile::{GpuTile, TileKey};
use super::visibility::ViewFrustum;
use super::terrain_config::{TerrainConfig, TileCandidate, LoadingTileInfo, LeafTileInfo};
use super::utm::lat_lon_to_utm;

use crate::constants_m::{
    M_TO_FT, FT_TO_M,
    TERRAIN_MAX_UPGRADES_PER_FRAME,
    TERRAIN_CACHE_LOG_INTERVAL_SECS, TERRAIN_CRITICAL_RADIUS_FT,
    TERRAIN_STALE_REQUEST_MS,
};
use crate::renderer::{BindGroupLayouts, bind_groups};

use std::collections::HashMap;
use std::time::{Duration, Instant};
use std::sync::Arc;
use crossbeam_channel::{Sender, Receiver, bounded};
use tracing::{info, warn, error};
use wgpu::util::DeviceExt;

// ============================================================================
// Regional DEM support
// ============================================================================

struct RegionalDem {
    dem: Arc<GlobalDem>,
    bounds: Bounds,
}

/// Tracks failed tile loads for retry logic
struct FailedTileInfo {
    retry_count: u32,
    last_attempt: Instant,
    is_retryable: bool,
}

impl FailedTileInfo {
    /// Calculate backoff duration based on retry count (exponential backoff)
    fn backoff_duration(&self) -> Duration {
        // 1s, 2s, 4s, 8s, 16s, max 30s
        let secs = (1u64 << self.retry_count.min(4)).min(30);
        Duration::from_secs(secs)
    }

    /// Returns true if enough time has passed since last attempt
    fn can_retry(&self) -> bool {
        self.is_retryable && self.last_attempt.elapsed() >= self.backoff_duration()
    }
}

// ============================================================================
// Main streaming terrain manager
// ============================================================================

pub struct StreamingTerrainManager {
    config: TerrainConfig,
    index: Option<QuadtreeIndex>,
    origin_utm: Option<[f64; 2]>,

    regional_dems: Vec<RegionalDem>,
    dem_nodata: f32,  // DEM nodata value for mesh generation
    /// Regional DEMs packaged for worker threads (built once after DEM load)
    regional_dems_for_mesh: Arc<Vec<RegionalDemRef>>,

    device: Arc<wgpu::Device>,
    queue: Arc<wgpu::Queue>,
    bind_group_layouts: BindGroupLayouts,
    sampler: wgpu::Sampler,

    gpu_cache: GpuTileCache,
    loading_keys: HashMap<TileKey, LoadingTileInfo>,
    failed_tiles: HashMap<TileKey, FailedTileInfo>,
    /// Tiles that are being upgraded/downgraded (key -> target mip level)
    upgrading_keys: HashMap<TileKey, usize>,
    /// Tracks when we last uploaded a texture (for cooldown between uploads)
    last_upload: Instant,
    /// Deferred uploads - tiles that have been loaded but are waiting for cooldown to expire
    /// These are kept here to avoid re-requesting them from workers
    deferred_uploads: Vec<TileLoadResult>,

    load_tx: Sender<TileLoadRequest>,
    result_rx: Receiver<TileLoadOutcome>,
    _loader: TileLoader,

    leaf_tiles: Vec<LeafTileInfo>,
    max_texture_size: u32,

    last_cam_utm: Option<(f64, f64)>,
    last_cam_world: Option<[f64; 3]>,
    last_velocity_dir: Option<[f64; 2]>,
    last_frustum: Option<ViewFrustum>,

    /// Reusable buffer for tile candidates (avoids per-frame allocations)
    candidate_buffer: Vec<TileCandidate>,

    /// Last time we logged cache status (for periodic logging)
    last_cache_log: Instant,

    /// Auto-computed LOD transition distances (recomputed on window resize)
    lod_distances_ft: Vec<f64>,
    /// Last screen height used for LOD computation (to detect resize)
    last_screen_height: u32,
}

impl StreamingTerrainManager {
    pub fn new(
        device: Arc<wgpu::Device>,
        queue: Arc<wgpu::Queue>,
        bind_group_layouts: BindGroupLayouts,
        config: TerrainConfig,
        supports_bc: bool,
    ) -> Self {
        // Use bounded channels to prevent unbounded memory growth if workers can't keep up
        // Request queue: limit to 2x max_gpu_tiles to allow some buffering
        // Result queue: limit to max_gpu_tiles since we process results each frame
        let channel_capacity = config.max_gpu_tiles.max(32);
        let (load_tx, load_rx) = bounded::<TileLoadRequest>(channel_capacity * 2);
        let (result_tx, result_rx) = bounded::<TileLoadOutcome>(channel_capacity);

        let loader = TileLoader::new(
            config.tiles_dir.clone(),
            config.num_workers,
            load_rx,
            result_tx,
            supports_bc,
        );

        let sampler = bind_groups::create_terrain_sampler(&device);
        let max_texture_size = device.limits().max_texture_dimension_2d;

        let origin_utm = config.origin_lat_lon.map(|ll| {
            let (easting, northing, zone, northern) = lat_lon_to_utm(ll[0], ll[1]);
            info!(
                lat = ll[0], lon = ll[1], zone = zone, hemisphere = if northern { "N" } else { "S" },
                "Origin converted to UTM"
            );
            [easting, northing]
        });

        // Create GPU cache with memory budget based on config
        // Use 512MB default or tile count limit if max_gpu_tiles is set
        let gpu_cache_config = if config.max_gpu_tiles > 0 {
            GpuMemoryConfig::with_tile_limit(config.max_gpu_tiles)
        } else {
            GpuMemoryConfig::default()
        };
        let gpu_cache = GpuTileCache::new(gpu_cache_config);

        Self {
            config, index: None, origin_utm,
            regional_dems: Vec::new(),
            dem_nodata: -9999.0,  // Default, updated when DEM is loaded
            regional_dems_for_mesh: Arc::new(Vec::new()),  // Built after DEM load
            device, queue, bind_group_layouts, sampler,
            gpu_cache,
            loading_keys: HashMap::new(),
            failed_tiles: HashMap::new(),
            upgrading_keys: HashMap::new(),
            last_upload: Instant::now(),
            deferred_uploads: Vec::new(),
            load_tx, result_rx, _loader: loader,
            leaf_tiles: Vec::new(),
            max_texture_size,
            last_cam_utm: None,
            last_cam_world: None,
            last_velocity_dir: None,
            last_frustum: None,
            candidate_buffer: Vec::with_capacity(256), // Pre-allocate for reuse
            last_cache_log: Instant::now(),
            lod_distances_ft: Vec::new(),
            last_screen_height: 0,
        }
    }

    /// Create mesh configuration for worker threads
    fn create_mesh_config(&self) -> MeshConfig {
        MeshConfig {
            mesh_resolution: self.config.mesh_resolution,
            vertical_scale: self.config.vertical_scale,
            origin_utm: self.origin_utm,
            dem_nodata: self.dem_nodata,
            regional_dems: Arc::clone(&self.regional_dems_for_mesh),
        }
    }

    /// Build regional DEM refs for worker threads (called after DEMs are loaded)
    fn build_regional_dems_for_mesh(&mut self) {
        let refs: Vec<RegionalDemRef> = self.regional_dems.iter().map(|rd| {
            RegionalDemRef {
                dem: Arc::clone(&rd.dem),
                bounds: rd.bounds,
            }
        }).collect();
        self.regional_dems_for_mesh = Arc::new(refs);
    }

    pub fn load_index(&mut self) -> Result<(), String> {
        let index_path = self.config.tiles_dir.join("quadtree_index.json");
        // Read the whole file into memory first, then parse. serde_json::from_reader
        // reads one byte per syscall (no buffering); over a network drive (e.g. Y:)
        // that is hundreds of thousands of round-trips and effectively hangs.
        let bytes = std::fs::read(&index_path)
            .map_err(|e| format!("Cannot open quadtree index: {}", e))?;
        let index: QuadtreeIndex = serde_json::from_slice(&bytes)
            .map_err(|e| format!("Cannot parse quadtree index: {}", e))?;

        info!(tile_count = index.tile_count, "Terrain index loaded");

        // multi-region support: load DEMs from regions array if present
        if !index.regions.is_empty() {
            info!(count = index.regions.len(), "Loading terrain regions");
            // Each region's DEM is an independent ~50 MB read; over a network drive
            // they are I/O-bound, so load them concurrently (one thread per region)
            // instead of sequentially. Results are collected in index order.
            let tiles_dir = &self.config.tiles_dir;
            let loaded: Vec<(usize, Result<GlobalDem, String>)> = std::thread::scope(|scope| {
                let handles: Vec<_> = index.regions.iter().enumerate().map(|(i, region)| {
                    let dem_path = tiles_dir.join(&region.dem_file);
                    let bounds = region.dem_bounds;
                    let pixel_size = (region.dem_pixel_size[0], region.dem_pixel_size[1]);
                    let nodata = region.dem_nodata;
                    scope.spawn(move || {
                        if !dem_path.exists() {
                            return (i, Err(format!("DEM file not found: {}", dem_path.display())));
                        }
                        (i, GlobalDem::load(&dem_path, bounds, pixel_size, nodata))
                    })
                }).collect();
                handles.into_iter().map(|h| h.join().expect("DEM load thread panicked")).collect()
            });

            for (i, result) in loaded {
                let region = &index.regions[i];
                match result {
                    Ok(dem) => {
                        info!(
                            region = %region.name, width = dem.width, height = dem.height, tiles = region.tile_count,
                            "Loaded DEM region"
                        );
                        // Store nodata from first loaded DEM (for mesh config)
                        if self.regional_dems.is_empty() {
                            self.dem_nodata = region.dem_nodata;
                        }
                        self.regional_dems.push(RegionalDem {
                            dem: Arc::new(dem),
                            bounds: region.dem_bounds,
                        });
                    }
                    Err(e) => {
                        error!(region = %region.name, error = %e, "Failed to load DEM");
                    }
                }
            }
        } else if let Some(ref dem_file) = index.dem_file {
            // backward compatibility: single DEM file (old format)
            let dem_path = self.config.tiles_dir.join(dem_file);
            if dem_path.exists() {
                let bounds = index.dem_bounds;
                let pixel_size = (index.dem_pixel_size[0], index.dem_pixel_size[1]);
                let nodata = index.dem_nodata;

                match GlobalDem::load(&dem_path, bounds, pixel_size, nodata) {
                    Ok(dem) => {
                        info!(width = dem.width, height = dem.height, "Global DEM loaded");
                        self.dem_nodata = nodata;  // Store for mesh config
                        self.regional_dems.push(RegionalDem {
                            dem: Arc::new(dem),
                            bounds,
                        });
                    }
                    Err(e) => {
                        error!(error = %e, "Failed to load global DEM");
                    }
                }
            } else {
                warn!(path = %dem_path.display(), "DEM file not found");
            }
        }

        self.leaf_tiles = self.collect_leaf_tiles(&index.quadtree);
        self.index = Some(index);

        // Build regional DEM refs for worker thread mesh generation
        self.build_regional_dems_for_mesh();

        Ok(())
    }

    fn collect_leaf_tiles(&self, node: &QuadtreeNode) -> Vec<LeafTileInfo> {
        collect_leaf_tiles_recursive(node)
    }

    fn world_to_utm(&self, world_x: f64, world_y: f64) -> (f64, f64) {
        // physics NED: world_x=North, world_y=East
        // UTM: easting (E-W), northing (N-S)
        if let Some(origin) = self.origin_utm {
            (origin[0] + world_y * FT_TO_M, origin[1] + world_x * FT_TO_M)
        } else {
            (world_y * FT_TO_M, world_x * FT_TO_M)
        }
    }

    #[allow(dead_code)]
    fn utm_to_world(&self, utm_e: f64, utm_n: f64) -> (f64, f64) {
        // Inverse of world_to_utm
        if let Some(origin) = self.origin_utm {
            let world_y = (utm_e - origin[0]) * M_TO_FT;
            let world_x = (utm_n - origin[1]) * M_TO_FT;
            (world_x, world_y)
        } else {
            (utm_n * M_TO_FT, utm_e * M_TO_FT)
        }
    }

    // sample terrain elevation at world coordinates (NED feet)
    // returns elevation in feet MSL, or None if outside DEM coverage
    pub fn sample_elevation(&self, world_x: f64, world_y: f64) -> Option<f64> {
        let (utm_e, utm_n) = self.world_to_utm(world_x, world_y);
        self.sample_elevation_utm(utm_e, utm_n).map(|m| m as f64 * M_TO_FT)
    }

    // sample elevation from UTM coordinates, returns meters
    // searches through all regional DEMs to find one containing the point
    fn sample_elevation_utm(&self, utm_e: f64, utm_n: f64) -> Option<f32> {
        // first pass: check bounds
        for regional_dem in &self.regional_dems {
            if regional_dem.bounds.contains(utm_e, utm_n) {
                if let Some(elev_m) = regional_dem.dem.sample(utm_e, utm_n) {
                    return Some(elev_m);
                }
            }
        }
        // fallback: try all DEMs even if point is technically outside bounds
        for regional_dem in &self.regional_dems {
            if let Some(elev_m) = regional_dem.dem.sample(utm_e, utm_n) {
                return Some(elev_m);
            }
        }
        None
    }

    /// Compute LOD transition distances based on screen resolution, FOV, and tile data.
    /// Called on first frame and whenever the window is resized.
    ///
    /// At distance d, a tile of world-size S ft with texture resolution T texels covers
    /// (S/d) × pixels_per_radian screen pixels. Aliasing occurs when T > screen pixels.
    /// The transition distance for mip level n (texture = T/2^n) is:
    ///   d_n = S × pixels_per_radian / (T / 2^n)
    fn compute_auto_lod(&mut self, fov_y: f64, screen_height: u32) {
        if self.leaf_tiles.is_empty() {
            warn!("No leaf tiles available for auto LOD computation");
            self.lod_distances_ft = vec![5000.0, 10000.0, 20000.0, 50000.0];
            return;
        }

        let avg_tile_size_m: f64 = self.leaf_tiles.iter()
            .map(|t| {
                let w = t.bounds.max_x - t.bounds.min_x;
                let h = t.bounds.max_y - t.bounds.min_y;
                w.max(h)
            })
            .sum::<f64>() / self.leaf_tiles.len() as f64;

        let avg_tile_size_ft = avg_tile_size_m * M_TO_FT;
        let tex_size = self.config.reference_texture_size as f64;
        let screen_h = screen_height as f64;
        let pixels_per_radian = screen_h / (2.0 * (fov_y / 2.0).tan());

        // Generate 4 transition distances (5 mip tiers: 0..4)
        let num_mips = 4;
        let mut distances = Vec::with_capacity(num_mips);

        for n in 0..num_mips {
            let mip_tex_size = tex_size / (1 << n) as f64;
            let transition_ft = avg_tile_size_ft * pixels_per_radian / mip_tex_size;
            distances.push(transition_ft);
        }

        // Auto max draw: where coarsest mip has < 1 texel per 4 screen pixels
        let coarsest_tex = tex_size / (1 << (num_mips - 1)) as f64;
        let auto_max_draw = avg_tile_size_ft * pixels_per_radian / coarsest_tex * 4.0;

        if self.config.max_draw_distance_ft > auto_max_draw * 2.0 {
            info!(
                configured = self.config.max_draw_distance_ft,
                resolution_limit = auto_max_draw as i64,
                "max_draw_distance exceeds screen resolution limit (distant tiles will be low-res)"
            );
        }

        info!(
            distances = ?distances.iter().map(|d| *d as i64).collect::<Vec<_>>(),
            max_draw = self.config.max_draw_distance_ft as i64,
            tile_size_ft = avg_tile_size_ft as i64,
            tex_size = tex_size as i64,
            screen_height = screen_height,
            fov_deg = format!("{:.1}", fov_y.to_degrees()),
            "Auto-computed LOD distances"
        );

        self.lod_distances_ft = distances;
    }

    /// Single source of truth: map a camera-to-tile distance to a mip level from the LOD distance
    /// thresholds. Beyond the last threshold, returns the coarsest available mip
    /// (`thresholds.len() - 1`). Used by BOTH the initial-load path (`get_mip_for_distance`) and the
    /// LOD-upgrade decision (`request_lod_upgrades`) so the two can't disagree and load a distant
    /// tile at one mip then immediately reload it at another.
    fn mip_for_distance(distance_ft: f64, thresholds: &[f64]) -> usize {
        for (i, &threshold) in thresholds.iter().enumerate() {
            if distance_ft < threshold { return i; }
        }
        thresholds.len().saturating_sub(1)
    }

    fn get_mip_for_distance(&self, distance_ft: f64) -> usize {
        Self::mip_for_distance(distance_ft, &self.lod_distances_ft)
    }

    /// Calculate priority for a single tile
    /// Returns (priority, mip_level, should_load)
    ///
    /// This uses a robust distance + direction approach that works regardless of
    /// camera pitch/roll. Strict frustum culling is unreliable for flight sims
    /// because camera orientation changes rapidly during maneuvers.
    fn calculate_tile_priority(
        &self,
        tile_bounds: &Bounds,
        cam_utm: (f64, f64),
        cam_altitude_ft: f64,
        velocity_dir: Option<[f64; 2]>,
        _frustum: &ViewFrustum,  // Kept for API compatibility, but not used for loading
    ) -> (f64, usize, bool) {
        let (cx, cy) = tile_bounds.center();
        let tile_width = tile_bounds.max_x - tile_bounds.min_x;

        let dx = cx - cam_utm.0;
        let dy = cy - cam_utm.1;
        let distance_m = (dx * dx + dy * dy).sqrt();
        let distance_ft = distance_m * M_TO_FT;

        let max_dist = self.config.max_draw_distance_ft;

        // Quick reject: too far away
        if distance_ft > max_dist * 1.5 {
            return (0.0, 0, false);
        }

        // === Priority Calculation (no frustum culling for loading) ===
        // Flight sims need to load tiles in all directions because:
        // 1. Camera can look any direction (chase cam, cockpit view, etc.)
        // 2. Aircraft can roll/pitch rapidly, changing what's visible
        // 3. It's better to have tiles loaded than to see holes

        // 1. Distance-based priority (closer = much higher priority)
        // Use exponential falloff so nearby tiles are strongly prioritized
        let distance_priority = 1.0 / (1.0 + (distance_ft / TERRAIN_CRITICAL_RADIUS_FT).powi(2));

        // 2. Direction multiplier based on velocity
        // Tiles ahead get higher priority, but don't completely exclude tiles behind
        let direction_mult = if let Some(vel) = velocity_dir {
            let vel_len = (vel[0] * vel[0] + vel[1] * vel[1]).sqrt();
            if vel_len > 0.01 && distance_m > 1.0 {
                // Normalize velocity
                let vel_n = [vel[0] / vel_len, vel[1] / vel_len];

                // Direction from camera to tile (in UTM: dx=easting, dy=northing)
                let tile_dir_x = dx / distance_m;  // easting direction
                let tile_dir_y = dy / distance_m;  // northing direction

                // vel is NED: [0]=North (matches UTM northing), [1]=East (matches UTM easting)
                let dot = vel_n[0] * tile_dir_y + vel_n[1] * tile_dir_x;

                // Gentler weighting that doesn't completely kill tiles behind:
                // Ahead (dot=1): 4x multiplier
                // Side (dot=0): 1.5x multiplier
                // Behind (dot=-1): 0.5x multiplier (still loads, just lower priority)
                1.5 + dot * 2.5
            } else {
                // Not moving or tile very close - load everything equally
                2.0
            }
        } else {
            // No velocity info - load based on distance only
            1.5
        };

        // 3. Altitude factor: when flying high, we need tiles further out
        // Also accounts for the fact that we can see more terrain from altitude
        let altitude_factor = if cam_altitude_ft > 100.0 {
            // At higher altitudes, boost priority of distant tiles
            let alt_boost = (cam_altitude_ft / TERRAIN_CRITICAL_RADIUS_FT).clamp(1.0, 3.0);
            // Reduce the distance penalty for distant tiles when high up
            let dist_threshold = cam_altitude_ft * 2.0; // Can see ~2x altitude distance
            if distance_ft < dist_threshold {
                alt_boost
            } else {
                alt_boost * 0.5
            }
        } else {
            1.0
        };

        // 4. Screen-space importance (larger angular size = higher priority)
        let angular_priority = if distance_ft > 1.0 {
            let angular_size = (tile_width * M_TO_FT) / distance_ft;
            (angular_size * 100.0).clamp(0.1, 10.0)
        } else {
            10.0
        };

        // Combined priority
        let priority = distance_priority
            * direction_mult
            * altitude_factor
            * angular_priority
            * 100.0;  // Scale up for better precision

        let mip_level = self.get_mip_for_distance(distance_ft);

        (priority, mip_level, true)  // Always allow loading (within max_dist)
    }

    /// Main update function with frustum culling support
    /// camera_x, camera_y, camera_z: world position in NED feet
    /// velocity_dir: normalized direction of travel [North, East]
    /// fov_y: vertical field of view in radians
    /// screen_height: viewport height in pixels (used for auto LOD computation)
    /// frame_start: time when frame started (for time budgeting GPU uploads)
    pub fn update_with_frustum(
        &mut self,
        camera_pos: [f64; 3],
        velocity_dir: Option<[f64; 2]>,
        fov_y: f64,
        screen_height: u32,
        frame_start: Instant,
    ) {
        let [camera_x, camera_y, camera_z] = camera_pos;
        if self.index.is_none() { return; }

        // Recompute LOD distances when screen size changes (or on first frame)
        if screen_height != self.last_screen_height {
            self.compute_auto_lod(fov_y, screen_height);
            self.last_screen_height = screen_height;
        }

        self.process_completed_loads(frame_start);

        let (cam_utm_x, cam_utm_y) = self.world_to_utm(camera_x, camera_y);
        let cam_altitude_ft = -camera_z; // NED: Z is down, so altitude = -Z

        self.last_cam_utm = Some((cam_utm_x, cam_utm_y));
        self.last_cam_world = Some([camera_x, camera_y, camera_z]);
        self.last_velocity_dir = velocity_dir;

        // Build frustum for culling
        let forward = velocity_dir.unwrap_or([1.0, 0.0]);
        let max_dist = self.config.max_draw_distance_ft * 1.5;

        let frustum = ViewFrustum::new_simple(
            [camera_x, camera_y, camera_z],
            forward,
            fov_y,
            max_dist,
        );
        self.last_frustum = Some(frustum.clone());

        // === STEP 1: Calculate fresh priorities for all candidate tiles ===
        // Reuse the candidate buffer to avoid per-frame allocations
        self.candidate_buffer.clear();

        for tile_info in &self.leaf_tiles {
            // Skip already loaded or loading
            if self.gpu_cache.contains_key(&tile_info.key) { continue; }
            if self.loading_keys.contains_key(&tile_info.key) { continue; }

            // Skip failed tiles that can't retry yet
            if let Some(failed_info) = self.failed_tiles.get(&tile_info.key) {
                if !failed_info.can_retry() {
                    continue;
                }
            }

            let (priority, mip_level, should_load) = self.calculate_tile_priority(
                &tile_info.bounds,
                (cam_utm_x, cam_utm_y),
                cam_altitude_ft,
                velocity_dir,
                &frustum,
            );

            if should_load && priority > 0.0 {
                self.candidate_buffer.push(TileCandidate {
                    key: tile_info.key.clone(),
                    priority,
                    mip_level,
                    dem_bounds: tile_info.dem_bounds,
                    imagery_bounds: tile_info.imagery_bounds,
                    tile_path: tile_info.tile_path.clone(),
                });
            }
        }

        // === STEP 2: Sort by priority (highest first) ===
        self.candidate_buffer.sort_by(|a, b| b.cmp(a));

        // Take ownership of candidates to allow mutable access to self during iteration
        let candidates = std::mem::take(&mut self.candidate_buffer);

        // === STEP 3: Update distances for loaded tiles ===
        for tile in self.gpu_cache.values_mut() {
            let (cx, cy) = tile.dem_bounds.center();
            let distance_m = ((cam_utm_x - cx).powi(2) + (cam_utm_y - cy).powi(2)).sqrt();
            tile.distance_to_camera = (distance_m * M_TO_FT) as f32;
            tile.last_used = Instant::now();
        }

        // === STEP 4: Cancel irrelevant in-flight loads ===
        self.cancel_irrelevant_loads(&frustum, (cam_utm_x, cam_utm_y), velocity_dir);

        // === STEP 5: Issue new load requests ===
        let max_loading = self.config.num_workers * 4; // Increased to allow more parallel loads

        for candidate in &candidates {
            if self.loading_keys.len() >= max_loading {
                break;
            }

            // Double-check not already loading (could have been added by previous iteration)
            if self.loading_keys.contains_key(&candidate.key) { continue; }
            if self.gpu_cache.contains_key(&candidate.key) { continue; }

            let request = TileLoadRequest {
                key: candidate.key.clone(),
                tile_path: candidate.tile_path.clone(),
                mip_level: candidate.mip_level,
                dem_bounds: candidate.dem_bounds,
                imagery_bounds: candidate.imagery_bounds,
                max_texture_size: self.max_texture_size,
                mesh_config: self.create_mesh_config(),
            };

            if self.load_tx.send(request).is_ok() {
                // Find the tile bounds for tracking
                if let Some(tile_info) = self.leaf_tiles.iter().find(|t| t.key == candidate.key) {
                    self.loading_keys.insert(candidate.key.clone(), LoadingTileInfo {
                        bounds: tile_info.bounds,
                        request_time: Instant::now(),
                    });
                }
            }
        }

        // Put buffer back for reuse next frame (preserves capacity)
        self.candidate_buffer = candidates;

        // === STEP 6: Evict tiles if over budget ===
        self.evict_if_needed(&frustum, (cam_utm_x, cam_utm_y), velocity_dir);

        // === STEP 7: Request LOD upgrades for tiles that need higher resolution ===
        self.request_lod_upgrades((cam_utm_x, cam_utm_y));

        // === Periodic cache status logging ===
        if self.last_cache_log.elapsed() > Duration::from_secs(TERRAIN_CACHE_LOG_INTERVAL_SECS) {
            self.last_cache_log = Instant::now();
            info!(
                cache = %self.gpu_cache.debug_info(),
                loading = self.loading_keys.len(),
                deferred = self.deferred_uploads.len(),
                "Terrain cache status"
            );
        }
    }

    /// Request LOD upgrades for tiles that are at lower resolution than needed
    fn request_lod_upgrades(&mut self, cam_utm: (f64, f64)) {
        // Limit upgrades per frame to avoid overwhelming the loader

        // Borrow slice reference instead of cloning the Vec
        let lod_distances: &[f64] = &self.lod_distances_ft;

        // Get upgrade candidates (closure captures slice reference, not owned Vec).
        // Uses the SAME mapping as the initial-load path so a tile can't load at one mip then
        // immediately "upgrade" to a different one (the prior off-by-one was len vs len-1).
        let candidates = self.gpu_cache.get_lod_change_candidates(cam_utm, |distance_ft| {
            Self::mip_for_distance(distance_ft, lod_distances)
        });

        let mut upgrades_requested = 0;

        for (key, current_mip, desired_mip, _priority) in candidates {
            if upgrades_requested >= TERRAIN_MAX_UPGRADES_PER_FRAME {
                break;
            }

            // Only process upgrades (current_mip > desired_mip means need higher res)
            // We skip downgrades for now - they happen naturally via eviction
            if current_mip <= desired_mip {
                continue;
            }

            // Skip if already upgrading this tile
            if self.upgrading_keys.contains_key(&key) {
                continue;
            }

            // Skip if already loading this tile (normal or upgrade)
            if self.loading_keys.contains_key(&key) {
                continue;
            }

            // Find the leaf tile info for this key
            let tile_info = match self.leaf_tiles.iter().find(|t| t.key == key) {
                Some(info) => info,
                None => continue,
            };

            // Request the upgrade
            let request = TileLoadRequest {
                key: key.clone(),
                tile_path: tile_info.tile_path.clone(),
                mip_level: desired_mip,
                dem_bounds: tile_info.dem_bounds,
                imagery_bounds: tile_info.imagery_bounds,
                max_texture_size: self.max_texture_size,
                mesh_config: self.create_mesh_config(),
            };

            if self.load_tx.send(request).is_ok() {
                self.loading_keys.insert(key.clone(), LoadingTileInfo {
                    bounds: tile_info.bounds,
                    request_time: Instant::now(),
                });
                self.upgrading_keys.insert(key, desired_mip);
                upgrades_requested += 1;
            }
        }
    }

    /// Cancel loads for tiles that are no longer relevant
    /// Uses distance and direction, not frustum (which is unreliable during maneuvers)
    fn cancel_irrelevant_loads(
        &mut self,
        _frustum: &ViewFrustum,
        cam_utm: (f64, f64),
        velocity_dir: Option<[f64; 2]>,
    ) {
        let max_dist = self.config.max_draw_distance_ft;
        let critical_radius_ft = self.lod_distances_ft.first().copied().unwrap_or(TERRAIN_CRITICAL_RADIUS_FT);

        let mut to_cancel: Vec<TileKey> = Vec::new();

        for (key, info) in &self.loading_keys {
            let (cx, cy) = info.bounds.center();
            let dx = cx - cam_utm.0;
            let dy = cy - cam_utm.1;
            let distance_m = (dx * dx + dy * dy).sqrt();
            let distance_ft = distance_m * M_TO_FT;

            // Cancel if way too far
            if distance_ft > max_dist * 2.0 {
                to_cancel.push(key.clone());
                continue;
            }

            // Don't cancel critical zone tiles or tiles that just started loading
            if distance_ft < critical_radius_ft {
                continue;
            }

            // Only cancel if tile is far behind AND has been loading for a while
            if let Some(vel) = velocity_dir {
                let vel_len = (vel[0] * vel[0] + vel[1] * vel[1]).sqrt();
                if vel_len > 0.01 && distance_m > 1.0 {
                    let vel_n = [vel[0] / vel_len, vel[1] / vel_len];
                    let tile_dir_x = dx / distance_m;
                    let tile_dir_y = dy / distance_m;
                    let dot = vel_n[0] * tile_dir_y + vel_n[1] * tile_dir_x;

                    // Only cancel if significantly behind AND loading for >1 second
                    // Be conservative - it's better to finish a load than waste the work
                    if dot < -0.7 && info.request_time.elapsed().as_millis() > TERRAIN_STALE_REQUEST_MS as u128 {
                        to_cancel.push(key.clone());
                    }
                }
            }
        }

        for key in to_cancel {
            self.loading_keys.remove(&key);
            self.upgrading_keys.remove(&key);  // Also clear upgrade tracking
        }
    }

    /// Process completed tile loads with per-frame limit and cooldown.
    /// After each upload, a configurable cooldown prevents back-to-back GPU stalls.
    /// Tiles that arrive during cooldown are deferred (kept in memory) until the
    /// cooldown expires, avoiding redundant re-requests to worker threads.
    fn process_completed_loads(&mut self, _frame_start: Instant) {
        let upload_cooldown = Duration::from_millis(self.config.upload_cooldown_ms);
        let max_uploads = self.config.max_uploads_per_frame;
        let max_deferred = self.config.max_deferred_uploads;
        let mut uploads_this_frame = 0;

        // Check if we're in cooldown from a recent upload
        let in_cooldown = self.last_upload.elapsed() < upload_cooldown;

        // Helper closure to upload a tile
        let upload_tile = |this: &mut Self, result: TileLoadResult| -> bool {
            let is_upgrade = this.upgrading_keys.remove(&result.key).is_some();
            this.failed_tiles.remove(&result.key);

            match this.create_gpu_tile(&result) {
                Ok((gpu_tile, memory_info)) => {
                    this.gpu_cache.insert(
                        result.key.clone(),
                        gpu_tile,
                        memory_info,
                        result.mip_level,
                    );
                    if is_upgrade {
                        tracing::debug!(tile = %result.key, mip = result.mip_level, "Tile LOD upgraded");
                    }
                    true
                }
                Err(e) => {
                    error!(tile = %result.key, error = %e, "Failed to create GPU tile");
                    this.failed_tiles.insert(result.key.clone(), FailedTileInfo {
                        retry_count: 0,
                        last_attempt: Instant::now(),
                        is_retryable: true,
                    });
                    false
                }
            }
        };

        // FIRST: Process deferred tiles when cooldown has expired
        // These tiles have already been loaded from disk, don't waste that work!
        // Deferred tiles are still in loading_keys to prevent re-requesting
        if !in_cooldown && !self.deferred_uploads.is_empty() {
            // Upload ONE deferred tile per frame to limit impact
            let result = self.deferred_uploads.remove(0);

            // Check if tile was cancelled while deferred (remove from loading_keys now)
            if self.loading_keys.remove(&result.key).is_none() {
                tracing::debug!(tile = %result.key, "Deferred tile was cancelled, discarding");
                // Don't return - continue to process more tiles this frame
            } else {
                tracing::debug!(
                    tile = %result.key,
                    deferred_remaining = self.deferred_uploads.len(),
                    "Uploading deferred tile"
                );

                if upload_tile(self, result) {
                    uploads_this_frame += 1;
                    self.last_upload = Instant::now();
                }
            }
        }

        // SECOND: Process new tiles from the worker channel
        loop {
            if uploads_this_frame >= max_uploads {
                break;
            }

            match self.result_rx.try_recv() {
                Ok(outcome) => {
                    match outcome {
                        TileLoadOutcome::Success(result) => {
                            // Check if tile was cancelled (but don't remove from loading_keys yet!)
                            if !self.loading_keys.contains_key(&result.key) {
                                // Tile was cancelled, skip it
                                continue;
                            }

                            // If we're in cooldown, defer the tile instead of uploading now —
                            // uploading would cause exactly the back-to-back GPU stall the cooldown
                            // exists to prevent. KEEP in loading_keys to prevent re-requesting!
                            if in_cooldown {
                                tracing::debug!(
                                    tile = %result.key,
                                    tex_size = format!("{}x{}", result.imagery_width, result.imagery_height),
                                    deferred_count = self.deferred_uploads.len() + 1,
                                    "Deferring tile during cooldown (stays in loading_keys)"
                                );
                                self.deferred_uploads.push(result);
                                // If the deferred buffer is now full, stop draining the channel this
                                // frame; remaining results wait in the bounded crossbeam channel until
                                // cooldown expires. (Previously, a full buffer fell through and the
                                // tile uploaded immediately, defeating the cooldown.)
                                if self.deferred_uploads.len() >= max_deferred {
                                    break;
                                }
                                continue;
                            }

                            // Not in cooldown: upload now. Remove from loading_keys first.
                            self.loading_keys.remove(&result.key);

                            // Upload the tile
                            if upload_tile(self, result) {
                                uploads_this_frame += 1;
                                self.last_upload = Instant::now();
                            }
                        }
                        TileLoadOutcome::Error { key, error } => {
                            self.loading_keys.remove(&key);
                            self.upgrading_keys.remove(&key);

                            let is_retryable = error.is_retryable();
                            if let Some(info) = self.failed_tiles.get_mut(&key) {
                                info.retry_count += 1;
                                info.last_attempt = Instant::now();
                                warn!(tile = %key, error = %error, retries = info.retry_count, "Tile load failed");
                            } else {
                                self.failed_tiles.insert(key.clone(), FailedTileInfo {
                                    retry_count: 0,
                                    last_attempt: Instant::now(),
                                    is_retryable,
                                });
                                warn!(tile = %key, error = %error, "Tile load failed (first attempt)");
                            }
                        }
                    }
                }
                Err(crossbeam_channel::TryRecvError::Empty) => break,
                Err(crossbeam_channel::TryRecvError::Disconnected) => break,
            }
        }
    }

    fn create_gpu_tile(&self, result: &TileLoadResult) -> Result<(GpuTile, TileMemoryInfo), String> {
        let total_start = Instant::now();

        let t0 = Instant::now();
        let texture = self.create_texture(
            &result.imagery_data,
            result.imagery_width as u32,
            result.imagery_height as u32,
            result.bc_format,
            &result.mip_offsets,
        )?;
        let texture_time = t0.elapsed();

        let t1 = Instant::now();
        let texture_view = texture.create_view(&wgpu::TextureViewDescriptor::default());

        let bind_group = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some(&format!("terrain_tile_{}", result.key)),
            layout: &self.bind_group_layouts.tile_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(&texture_view),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::Sampler(&self.sampler),
                },
            ],
        });
        let bind_time = t1.elapsed();

        // Mesh is now pre-computed on worker threads - just create GPU buffers
        let t2 = Instant::now();
        let vertex_buffer = self.device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some(&format!("terrain_vb_{}", result.key)),
            contents: bytemuck::cast_slice(&result.vertices),
            usage: wgpu::BufferUsages::VERTEX,
        });

        let index_buffer = self.device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some(&format!("terrain_ib_{}", result.key)),
            contents: bytemuck::cast_slice(&result.indices),
            usage: wgpu::BufferUsages::INDEX,
        });
        let buffer_time = t2.elapsed();

        let total_time = total_start.elapsed();

        // Log timing if any operation took more than 10ms (indicates a problem)
        if total_time.as_millis() > 10 {
            warn!(
                tile = %result.key,
                total_ms = total_time.as_millis(),
                texture_ms = texture_time.as_millis(),
                bind_ms = bind_time.as_millis(),
                buffer_ms = buffer_time.as_millis(),
                tex_size = format!("{}x{}", result.imagery_width, result.imagery_height),
                "Slow tile upload detected"
            )
        }

        // Calculate memory info for GPU cache tracking
        let is_compressed = result.bc_format != BcFormat::None;
        let is_bc7 = result.bc_format == BcFormat::Bc7;
        let memory_info = TileMemoryInfo::new(
            result.imagery_width as u32,
            result.imagery_height as u32,
            is_compressed,
            is_bc7,
            result.vertices.len(),
            result.indices.len(),
        );

        let tile = GpuTile::new(
            result.dem_bounds,
            vertex_buffer,
            index_buffer,
            result.indices.len() as u32,
            bind_group,
            texture,
        );

        Ok((tile, memory_info))
    }

    /// Upload texture data via a staging buffer + GPU-side copy.
    /// Unlike queue.write_texture() which can stall the CPU waiting for the GPU,
    /// this records a copy command that the GPU processes asynchronously.
    fn create_texture(
        &self,
        data: &[u8],
        tex_width: u32,
        tex_height: u32,
        bc_format: BcFormat,
        mip_offsets: &[(u64, u32)],
    ) -> Result<wgpu::Texture, String> {
        let (format, is_compressed) = match bc_format {
            BcFormat::Bc1 => (wgpu::TextureFormat::Bc1RgbaUnormSrgb, true),
            BcFormat::Bc7 => (wgpu::TextureFormat::Bc7RgbaUnormSrgb, true),
            BcFormat::None => (wgpu::TextureFormat::Rgba8UnormSrgb, false),
        };

        let mip_count = if is_compressed { mip_offsets.len() as u32 } else { 1 };

        // For BC formats, round up texture dimensions to block size (4) so that
        // physical mip extents are block-aligned and copy extents don't exceed them.
        let (create_width, create_height) = if is_compressed {
            ((tex_width + 3) & !3, (tex_height + 3) & !3)
        } else {
            (tex_width, tex_height)
        };

        let texture = self.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("terrain_texture"),
            size: wgpu::Extent3d {
                width: create_width,
                height: create_height,
                depth_or_array_layers: 1,
            },
            mip_level_count: mip_count,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });

        let mut encoder = self.device.create_command_encoder(
            &wgpu::CommandEncoderDescriptor { label: Some("texture_upload") },
        );

        if is_compressed {
            let block_size: u32 = match bc_format {
                BcFormat::Bc1 => 8,
                BcFormat::Bc7 => 16,
                BcFormat::None => unreachable!(),
            };

            for (mip_level, &(offset, size)) in mip_offsets.iter().enumerate() {
                let mip_width = (tex_width >> mip_level).max(1);
                let mip_height = (tex_height >> mip_level).max(1);
                let blocks_wide = mip_width.div_ceil(4);
                let blocks_high = mip_height.div_ceil(4);

                let start = offset as usize;
                let end = start + size as usize;
                if end > data.len() { continue; }

                let bytes_per_row = blocks_wide * block_size;
                // wgpu requires bytes_per_row to be a multiple of 256 for buffer->texture copies
                let padded_bytes_per_row = (bytes_per_row + 255) & !255;

                let staging = if padded_bytes_per_row == bytes_per_row {
                    // No padding needed — upload data directly
                    self.device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
                        label: Some("staging_mip"),
                        contents: &data[start..end],
                        usage: wgpu::BufferUsages::COPY_SRC,
                    })
                } else {
                    // Pad each row to meet the 256-byte alignment requirement
                    let rows = blocks_high;
                    let mut padded = Vec::with_capacity((padded_bytes_per_row * rows) as usize);
                    for row in 0..rows as usize {
                        let row_start = start + row * bytes_per_row as usize;
                        let row_end = row_start + bytes_per_row as usize;
                        if row_end > data.len() { break; }
                        padded.extend_from_slice(&data[row_start..row_end]);
                        padded.resize(padded.len() + (padded_bytes_per_row - bytes_per_row) as usize, 0);
                    }
                    self.device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
                        label: Some("staging_mip_padded"),
                        contents: &padded,
                        usage: wgpu::BufferUsages::COPY_SRC,
                    })
                };

                // BC formats require copy extent to be a multiple of block size (4).
                // The staging buffer already has full blocks (blocks_wide * 4 pixels),
                // so rounding up is safe and matches the physical texture mip extent.
                let copy_width = (mip_width + 3) & !3;
                let copy_height = (mip_height + 3) & !3;

                encoder.copy_buffer_to_texture(
                    wgpu::TexelCopyBufferInfo {
                        buffer: &staging,
                        layout: wgpu::TexelCopyBufferLayout {
                            offset: 0,
                            bytes_per_row: Some(padded_bytes_per_row),
                            rows_per_image: Some(blocks_high),
                        },
                    },
                    wgpu::TexelCopyTextureInfo {
                        texture: &texture,
                        mip_level: mip_level as u32,
                        origin: wgpu::Origin3d::ZERO,
                        aspect: wgpu::TextureAspect::All,
                    },
                    wgpu::Extent3d {
                        width: copy_width,
                        height: copy_height,
                        depth_or_array_layers: 1,
                    },
                );
            }
        } else {
            let bytes_per_row = tex_width * 4;
            let padded_bytes_per_row = (bytes_per_row + 255) & !255;

            let staging = if padded_bytes_per_row == bytes_per_row {
                self.device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
                    label: Some("staging_rgba"),
                    contents: data,
                    usage: wgpu::BufferUsages::COPY_SRC,
                })
            } else {
                let mut padded = Vec::with_capacity((padded_bytes_per_row * tex_height) as usize);
                for row in 0..tex_height as usize {
                    let row_start = row * bytes_per_row as usize;
                    let row_end = row_start + bytes_per_row as usize;
                    if row_end > data.len() { break; }
                    padded.extend_from_slice(&data[row_start..row_end]);
                    padded.resize(padded.len() + (padded_bytes_per_row - bytes_per_row) as usize, 0);
                }
                self.device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
                    label: Some("staging_rgba_padded"),
                    contents: &padded,
                    usage: wgpu::BufferUsages::COPY_SRC,
                })
            };

            encoder.copy_buffer_to_texture(
                wgpu::TexelCopyBufferInfo {
                    buffer: &staging,
                    layout: wgpu::TexelCopyBufferLayout {
                        offset: 0,
                        bytes_per_row: Some(padded_bytes_per_row),
                        rows_per_image: Some(tex_height),
                    },
                },
                wgpu::TexelCopyTextureInfo {
                    texture: &texture,
                    mip_level: 0,
                    origin: wgpu::Origin3d::ZERO,
                    aspect: wgpu::TextureAspect::All,
                },
                wgpu::Extent3d {
                    width: tex_width,
                    height: tex_height,
                    depth_or_array_layers: 1,
                },
            );
        }

        // Submit the copy commands — GPU processes asynchronously
        self.queue.submit(std::iter::once(encoder.finish()));

        Ok(texture)
    }

    /// Eviction strategy optimized for flight sims using GPU memory budget
    /// Prioritizes keeping tiles that are:
    /// 1. Close to the aircraft (always needed for ground reference)
    /// 2. In the direction of travel (will be needed soon)
    /// 3. Recently used (temporal coherence)
    /// 4. Smaller memory footprint (when memory-constrained)
    fn evict_if_needed(
        &mut self,
        _frustum: &ViewFrustum,  // Not used - frustum unreliable for eviction during maneuvers
        cam_utm: (f64, f64),
        velocity_dir: Option<[f64; 2]>,
    ) {
        // Use cache's built-in eviction with memory budget awareness
        let critical_radius_ft = self.lod_distances_ft.first().copied().unwrap_or(TERRAIN_CRITICAL_RADIUS_FT);
        let _evicted = self.gpu_cache.evict_to_budget(cam_utm, velocity_dir, critical_radius_ft);
    }

    pub fn get_visible_tiles(&self) -> impl Iterator<Item = &GpuTile> {
        self.gpu_cache.values()
    }

    #[allow(dead_code)]
    pub fn loaded_count(&self) -> usize {
        self.gpu_cache.len()
    }

    #[allow(dead_code)]
    pub fn loading_count(&self) -> usize {
        self.loading_keys.len()
    }

    /// Get debug info about tile streaming state
    #[allow(dead_code)]
    pub fn debug_info(&self) -> String {
        let failed_retryable = self.failed_tiles.values().filter(|f| f.is_retryable).count();
        let upgrading = self.upgrading_keys.len();
        if upgrading > 0 {
            format!(
                "Terrain: {} | {} loading ({} upgrading), {} failed ({} retryable), {} total tiles",
                self.gpu_cache.debug_info(),
                self.loading_keys.len(),
                upgrading,
                self.failed_tiles.len(),
                failed_retryable,
                self.leaf_tiles.len()
            )
        } else {
            format!(
                "Terrain: {} | {} loading, {} failed ({} retryable), {} total tiles",
                self.gpu_cache.debug_info(),
                self.loading_keys.len(),
                self.failed_tiles.len(),
                failed_retryable,
                self.leaf_tiles.len()
            )
        }
    }

    /// Get count of permanently failed tiles (non-retryable errors)
    #[allow(dead_code)]
    pub fn failed_count(&self) -> usize {
        self.failed_tiles.len()
    }
}

fn collect_leaf_tiles_recursive(node: &QuadtreeNode) -> Vec<LeafTileInfo> {
    let mut tiles = Vec::new();
    if let Some(ref path) = node.tile_path {
        if node.has_imagery || node.has_dem {
            let key = if !node.key.is_empty() {
                TileKey::from_string(node.key.clone())
            } else {
                TileKey::new(node.tx, node.ty)
            };
            tiles.push(LeafTileInfo {
                key,
                bounds: node.bounds,
                dem_bounds: node.dem_bounds,
                imagery_bounds: node.imagery_bounds,
                tile_path: path.clone(),
            });
        }
    }
    if let Some(ref children) = node.children {
        for child in children {
            tiles.extend(collect_leaf_tiles_recursive(child));
        }
    }
    tiles
}
