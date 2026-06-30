// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

use super::bc_texture::{BcFormat, load_dds_raw, decompress_bc1};
use super::geotiff::GlobalDem;
use super::quadtree::{Bounds, TileMetadata};
use super::tile::TileKey;

use crate::constants_m::{M_TO_FT, TERRAIN_TILE_LOAD_TIMEOUT_MS, EPSILON_NORMALIZE};
use crate::renderer::pipeline::TerrainVertex;

use std::fmt;
use std::fs::File;
use std::io::BufReader;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use byteorder::{LittleEndian, ReadBytesExt};
use crossbeam_channel::{Receiver, Sender};
use lazy_static::lazy_static;
use tracing::{error, warn};

// ============================================================================
// Error Types
// ============================================================================

/// Categorized tile loading errors for better error handling and retry logic
#[derive(Debug, Clone)]
pub enum TileLoadError {
    /// Metadata file could not be opened (file not found, permissions, etc.)
    MetadataOpen(String),
    /// Metadata file could not be parsed (invalid JSON)
    MetadataParse(String),
    /// DEM file could not be opened
    DemOpen(String),
    /// DEM file had invalid header or data
    DemRead(String),
}

impl fmt::Display for TileLoadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TileLoadError::MetadataOpen(e) => write!(f, "metadata open: {}", e),
            TileLoadError::MetadataParse(e) => write!(f, "metadata parse: {}", e),
            TileLoadError::DemOpen(e) => write!(f, "DEM open: {}", e),
            TileLoadError::DemRead(e) => write!(f, "DEM read: {}", e),
        }
    }
}

impl TileLoadError {
    /// Returns true if this error type is likely recoverable with a retry
    pub fn is_retryable(&self) -> bool {
        match self {
            // File access errors may be transient (locks, network drives)
            TileLoadError::MetadataOpen(_) => true,
            TileLoadError::DemOpen(_) => true,
            // Parse errors are permanent - file is corrupt
            TileLoadError::MetadataParse(_) => false,
            TileLoadError::DemRead(_) => false,
        }
    }
}

/// Result of a tile load attempt - either success or categorized error
pub enum TileLoadOutcome {
    Success(TileLoadResult),
    Error {
        key: TileKey,
        error: TileLoadError,
    },
}

lazy_static! {
    /// Pre-computed 64x64 terrain green fallback texture (16KB, computed once)
    static ref GROUND_FALLBACK_TEXTURE: Vec<u8> = {
        const SIZE: usize = 64 * 64 * 4;
        let (r, g, b, a): (u8, u8, u8, u8) = (187, 218, 164, 255);
        let mut data = Vec::with_capacity(SIZE);
        for _ in 0..(64 * 64) {
            data.extend_from_slice(&[r, g, b, a]);
        }
        data
    };
}

/// Regional DEM reference for elevation sampling (thread-safe)
#[derive(Clone)]
pub struct RegionalDemRef {
    pub dem: Arc<GlobalDem>,
    pub bounds: Bounds,
}

/// Mesh generation configuration passed to worker threads
#[derive(Clone)]
pub struct MeshConfig {
    pub mesh_resolution: usize,
    pub vertical_scale: f32,
    pub origin_utm: Option<[f64; 2]>,
    pub dem_nodata: f32,
    /// Regional DEMs for elevation sampling (shared across threads)
    pub regional_dems: Arc<Vec<RegionalDemRef>>,
}

#[derive(Clone)]
pub struct TileLoadRequest {
    pub key: TileKey,
    pub tile_path: String,
    pub mip_level: usize,
    pub dem_bounds: Option<Bounds>,
    pub imagery_bounds: Option<Bounds>,
    pub max_texture_size: u32,
    pub mesh_config: MeshConfig,
}

pub struct TileLoadResult {
    pub key: TileKey,
    pub mip_level: usize,
    pub dem_bounds: Bounds,      // used for vertex positions

    pub imagery_data: Vec<u8>,
    pub imagery_width: usize,
    pub imagery_height: usize,
    pub bc_format: BcFormat,
    pub mip_offsets: Vec<(u64, u32)>,

    // Pre-computed mesh data (generated on worker thread)
    pub vertices: Vec<TerrainVertex>,
    pub indices: Vec<u32>,
}

// tile loader managing worker threads
pub struct TileLoader {
    handles: Vec<JoinHandle<()>>,
}

impl TileLoader {
    pub fn new(
        tiles_dir: PathBuf,
        num_workers: usize,
        request_rx: Receiver<TileLoadRequest>,
        result_tx: Sender<TileLoadOutcome>,
        supports_bc: bool,
    ) -> Self {
        let mut handles = Vec::with_capacity(num_workers);

        for i in 0..num_workers {
            let dir = tiles_dir.clone();
            let rx = request_rx.clone();
            let tx = result_tx.clone();
            let bc = supports_bc;

            let handle = thread::Builder::new()
                .name(format!("tile-loader-{}", i))
                .spawn(move || {
                    loader_thread(dir, rx, tx, bc);
                })
                .expect("Failed to spawn loader thread");

            handles.push(handle);
        }

        Self { handles }
    }
}

impl Drop for TileLoader {
    fn drop(&mut self) {
        // Threads exit when the sender (load_tx in StreamingTerrainManager) is dropped.
        // Since load_tx is dropped before _loader due to field order, threads should be
        // exiting by now. Join them to ensure clean shutdown.
        for handle in self.handles.drain(..) {
            let _ = handle.join();
        }
    }
}

fn loader_thread(
    tiles_dir: PathBuf,
    rx: Receiver<TileLoadRequest>,
    tx: Sender<TileLoadOutcome>,
    supports_bc: bool,
) {
    use std::time::Duration;

    loop {
        // Use timeout so thread can exit quickly when channel is closed
        match rx.recv_timeout(Duration::from_millis(TERRAIN_TILE_LOAD_TIMEOUT_MS)) {
            Ok(request) => {
                let outcome = match load_tile(&tiles_dir, &request, supports_bc) {
                    Ok(result) => TileLoadOutcome::Success(result),
                    Err(e) => {
                        error!(tile = %request.key, error = %e, "Failed to load tile");
                        TileLoadOutcome::Error {
                            key: request.key,
                            error: e,
                        }
                    }
                };

                if tx.send(outcome).is_err() {
                    break;
                }
            }
            Err(crossbeam_channel::RecvTimeoutError::Timeout) => continue,
            Err(crossbeam_channel::RecvTimeoutError::Disconnected) => break,
        }
    }
}

fn load_tile(
    tiles_dir: &Path,
    request: &TileLoadRequest,
    supports_bc: bool,
) -> Result<TileLoadResult, TileLoadError> {
    let tile_dir = tiles_dir.join(&request.tile_path);
    let meta_path = tile_dir.join("metadata.json");

    let metadata: TileMetadata = {
        // Read fully then parse: serde_json::from_reader is unbuffered (1 byte/syscall),
        // which is pathologically slow over a network drive. See load_index() note.
        let bytes = std::fs::read(&meta_path)
            .map_err(|e| TileLoadError::MetadataOpen(e.to_string()))?;
        serde_json::from_slice(&bytes)
            .map_err(|e| TileLoadError::MetadataParse(e.to_string()))?
    };

    // get bounds from metadata, falling back to request bounds
    let dem_bounds = metadata.dem_bounds
        .or(request.dem_bounds)
        .unwrap_or(metadata.bounds);

    let imagery_bounds = metadata.imagery_bounds
        .or(request.imagery_bounds)
        .unwrap_or(metadata.bounds);

    let (dem_data, dem_width, dem_height) = load_dem(&tile_dir, &metadata, request.mip_level)?;

    let (imagery_data, imagery_width, imagery_height, bc_format, mip_offsets) =
        load_imagery(&tile_dir, &metadata, request.mip_level, supports_bc, request.max_texture_size)?;

    // Generate mesh on worker thread (this is the expensive operation)
    let (vertices, indices) = generate_tile_mesh(
        &request.mesh_config,
        request.mip_level,
        &dem_bounds,
        &imagery_bounds,
        &dem_data,
        dem_width,
        dem_height,
    );

    Ok(TileLoadResult {
        key: request.key.clone(),
        mip_level: request.mip_level,
        dem_bounds,
        imagery_data,
        imagery_width,
        imagery_height,
        bc_format,
        mip_offsets,
        vertices,
        indices,
    })
}

fn load_dem(
    tile_dir: &Path,
    metadata: &TileMetadata,
    mip_level: usize,
) -> Result<(Vec<f32>, usize, usize), TileLoadError> {
    let dem_mip = metadata.dem_mips.iter()
        .filter(|m| m.level <= mip_level)
        .max_by_key(|m| m.level);

    if let Some(dm) = dem_mip {
        // extract just the filename (path may include tile dir prefix)
        let filename = std::path::Path::new(&dm.path)
            .file_name()
            .map(|f| f.to_string_lossy().to_string())
            .unwrap_or_else(|| dm.path.clone());
        let dem_path = tile_dir.join(&filename);
        let file = File::open(&dem_path)
            .map_err(|e| TileLoadError::DemOpen(e.to_string()))?;
        let mut reader = BufReader::new(file);

        let width = reader.read_u32::<LittleEndian>()
            .map_err(|e| TileLoadError::DemRead(format!("header: {}", e)))? as usize;
        let height = reader.read_u32::<LittleEndian>()
            .map_err(|e| TileLoadError::DemRead(format!("header: {}", e)))? as usize;

        let expected_size = width * height;
        let mut data = Vec::with_capacity(expected_size);

        for _ in 0..expected_size {
            let val = reader.read_f32::<LittleEndian>()
                .map_err(|e| TileLoadError::DemRead(format!("data: {}", e)))?;
            data.push(val);
        }

        Ok((data, width, height))
    } else {
        Ok((vec![0.0f32; 64 * 64], 64, 64))
    }
}

/// Returns terrain green fallback texture for areas without imagery.
/// Uses pre-computed static data to avoid repeated allocation overhead.
fn create_ground_color_texture() -> Vec<u8> {
    GROUND_FALLBACK_TEXTURE.clone()
}

type ImageryResult = (Vec<u8>, usize, usize, BcFormat, Vec<(u64, u32)>);

fn load_imagery(
    tile_dir: &Path,
    metadata: &TileMetadata,
    mip_level: usize,
    supports_bc: bool,
    max_texture_size: u32,
) -> Result<ImageryResult, TileLoadError> {
    if metadata.imagery_mips.is_empty() {
        let ground = create_ground_color_texture();
        return Ok((ground, 64, 64, BcFormat::None, vec![(0, 64 * 64 * 4)]));
    }

    let max_size = max_texture_size as usize;
    let valid_mips: Vec<_> = metadata.imagery_mips.iter()
        .filter(|m| m.width <= max_size && m.height <= max_size)
        .collect();

    if valid_mips.is_empty() {
        let ground = create_ground_color_texture();
        return Ok((ground, 64, 64, BcFormat::None, vec![(0, 64 * 64 * 4)]));
    }

    // prefer RGBA, then BC7, then BC1
    let rgba_match = valid_mips.iter()
        .filter(|m| m.format == "rgba")
        .min_by_key(|m| (m.level as i32 - mip_level as i32).abs())
        .copied();

    let img_mip = if rgba_match.is_some() {
        rgba_match
    } else if supports_bc {
        valid_mips.iter()
            .filter(|m| m.format == "bc7" || m.format == "bc1")
            .min_by_key(|m| (m.level as i32 - mip_level as i32).abs())
            .copied()
    } else {
        valid_mips.iter()
            .filter(|m| m.format == "bc1")
            .min_by_key(|m| (m.level as i32 - mip_level as i32).abs())
            .copied()
    };

    if let Some(im) = img_mip {
        let filename = std::path::Path::new(&im.path)
            .file_name()
            .map(|f| f.to_string_lossy().to_string())
            .unwrap_or_else(|| im.path.clone());
        let img_path = tile_dir.join(&filename);

        if im.format == "rgba" {
            match std::fs::read(&img_path) {
                Ok(data) => {
                    let expected = im.width * im.height * 4;
                    if data.len() == expected {
                        return Ok((data, im.width, im.height, BcFormat::None, vec![(0, expected as u32)]));
                    }
                }
                Err(e) => warn!(error = %e, "Failed to load RGBA imagery"),
            }
            let ground = create_ground_color_texture();
            return Ok((ground, 64, 64, BcFormat::None, vec![(0, 64 * 64 * 4)]));
        }

        match load_dds_raw(&img_path) {
            Ok(dds) => {
                if supports_bc {
                    Ok((dds.data, dds.width as usize, dds.height as usize, dds.format, dds.mip_offsets))
                } else if dds.format == BcFormat::Bc1 {
                    // CPU decompress BC1 when GPU doesn't support it
                    let (offset, size) = dds.mip_offsets[0];
                    let compressed = &dds.data[offset as usize..(offset as usize + size as usize)];
                    let decompressed = decompress_bc1(compressed, dds.width as usize, dds.height as usize);
                    Ok((decompressed, dds.width as usize, dds.height as usize, BcFormat::None, vec![(0, dds.width * dds.height * 4)]))
                } else {
                    let ground = create_ground_color_texture();
                    Ok((ground, 64, 64, BcFormat::None, vec![(0, 64 * 64 * 4)]))
                }
            }
            Err(e) => {
                warn!(error = %e, "Failed to load DDS texture");
                let ground = create_ground_color_texture();
                Ok((ground, 64, 64, BcFormat::None, vec![(0, 64 * 64 * 4)]))
            }
        }
    } else {
        let ground = create_ground_color_texture();
        Ok((ground, 64, 64, BcFormat::None, vec![(0, 64 * 64 * 4)]))
    }
}

// ============================================================================
// Mesh Generation (runs on worker threads)
// ============================================================================

/// Generate tile mesh with vertices and indices
/// This is the expensive operation that was previously blocking the main thread
fn generate_tile_mesh(
    config: &MeshConfig,
    mip_level: usize,
    dem_bounds: &Bounds,
    imagery_bounds: &Bounds,
    dem_data: &[f32],
    dem_width: usize,
    dem_height: usize,
) -> (Vec<TerrainVertex>, Vec<u32>) {
    // Adjust mesh resolution based on mip level
    let base_res = config.mesh_resolution.min(512);
    let res = match mip_level {
        0 => base_res,
        1 => base_res.max(32),
        2 => (base_res / 2).max(16),
        3 => (base_res / 4).max(8),
        _ => 8,
    };

    let (offset_x, offset_y) = config.origin_utm
        .map(|o| (-o[0] * M_TO_FT, -o[1] * M_TO_FT))
        .unwrap_or((0.0, 0.0));

    let nodata = config.dem_nodata;
    let fallback_elev = 0.0_f32;

    let dem_w = dem_bounds.max_x - dem_bounds.min_x;
    let dem_h = dem_bounds.max_y - dem_bounds.min_y;

    let img_w = imagery_bounds.max_x - imagery_bounds.min_x;
    let img_h = imagery_bounds.max_y - imagery_bounds.min_y;

    let mut vertices = Vec::with_capacity(res * res);

    for j in 0..res {
        for i in 0..res {
            let t_x = i as f64 / (res - 1) as f64;
            let t_y = j as f64 / (res - 1) as f64;

            let utm_x = dem_bounds.min_x + t_x * dem_w;
            let utm_y = dem_bounds.max_y - t_y * dem_h;

            let world_x = (utm_x * M_TO_FT + offset_x) as f32;
            let world_y = (utm_y * M_TO_FT + offset_y) as f32;

            // Sample elevation from regional DEMs first, fallback to per-tile DEM
            let elev = sample_elevation_from_regional_dems(&config.regional_dems, utm_x, utm_y)
                .unwrap_or_else(|| {
                    let e = sample_dem_bilinear(dem_data, dem_width, dem_height, t_x as f32, t_y as f32);
                    if e <= nodata + 1.0 { fallback_elev } else { e }
                });

            let z = -(elev as f64 * M_TO_FT) as f32 * config.vertical_scale;

            // UV: map world position to imagery texture coordinates
            let u = ((utm_x - imagery_bounds.min_x) / img_w) as f32;
            let v = ((imagery_bounds.max_y - utm_y) / img_h) as f32;

            // swap X/Y to convert from ENU (UTM) to NED (physics frame)
            vertices.push(TerrainVertex {
                position: [world_y, world_x, z],  // NED: X=North, Y=East
                uv: [u.clamp(0.0, 1.0), v.clamp(0.0, 1.0)],
                normal: [0.0, 0.0, -1.0],
            });
        }
    }

    // Generate indices
    let mut indices = Vec::with_capacity((res - 1) * (res - 1) * 6);
    for j in 0..(res - 1) {
        for i in 0..(res - 1) {
            let idx = (j * res + i) as u32;
            // winding order reversed for X/Y swap (NED conversion)
            indices.extend_from_slice(&[
                idx,
                idx + res as u32,
                idx + 1,
                idx + 1,
                idx + res as u32,
                idx + res as u32 + 1,
            ]);
        }
    }

    // Compute normals
    compute_mesh_normals(&mut vertices, &indices);

    (vertices, indices)
}

/// Sample elevation from regional DEMs (same logic as streaming_terrain_m.rs)
fn sample_elevation_from_regional_dems(
    regional_dems: &[RegionalDemRef],
    utm_x: f64,
    utm_y: f64,
) -> Option<f32> {
    // First pass: check bounds
    for regional_dem in regional_dems {
        if regional_dem.bounds.contains(utm_x, utm_y) {
            if let Some(elev_m) = regional_dem.dem.sample(utm_x, utm_y) {
                return Some(elev_m);
            }
        }
    }
    // Fallback: try all DEMs even if point is technically outside bounds
    for regional_dem in regional_dems {
        if let Some(elev_m) = regional_dem.dem.sample(utm_x, utm_y) {
            return Some(elev_m);
        }
    }
    None
}

/// Bilinear interpolation for DEM sampling
fn sample_dem_bilinear(data: &[f32], width: usize, height: usize, u: f32, v: f32) -> f32 {
    let u = u.clamp(0.0, 1.0);
    let v = v.clamp(0.0, 1.0);

    let px = u * (width - 1) as f32;
    let py = v * (height - 1) as f32;

    let x0 = (px.floor() as usize).min(width.saturating_sub(2));
    let y0 = (py.floor() as usize).min(height.saturating_sub(2));
    let x1 = (x0 + 1).min(width - 1);
    let y1 = (y0 + 1).min(height - 1);

    let fx = px - px.floor();
    let fy = py - py.floor();

    let v00 = data.get(y0 * width + x0).copied().unwrap_or(0.0);
    let v10 = data.get(y0 * width + x1).copied().unwrap_or(0.0);
    let v01 = data.get(y1 * width + x0).copied().unwrap_or(0.0);
    let v11 = data.get(y1 * width + x1).copied().unwrap_or(0.0);

    let v0 = v00 * (1.0 - fx) + v10 * fx;
    let v1 = v01 * (1.0 - fx) + v11 * fx;
    v0 * (1.0 - fy) + v1 * fy
}

/// Compute smooth normals for mesh vertices
fn compute_mesh_normals(vertices: &mut [TerrainVertex], indices: &[u32]) {
    // Reset all normals
    for v in vertices.iter_mut() {
        v.normal = [0.0, 0.0, 0.0];
    }

    // Accumulate face normals to each vertex
    for tri in indices.chunks(3) {
        let (i0, i1, i2) = (tri[0] as usize, tri[1] as usize, tri[2] as usize);
        let (p0, p1, p2) = (vertices[i0].position, vertices[i1].position, vertices[i2].position);

        let v1 = [p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2]];
        let v2 = [p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2]];
        let n = [
            v1[1] * v2[2] - v1[2] * v2[1],
            v1[2] * v2[0] - v1[0] * v2[2],
            v1[0] * v2[1] - v1[1] * v2[0],
        ];

        for &i in &[i0, i1, i2] {
            vertices[i].normal[0] += n[0];
            vertices[i].normal[1] += n[1];
            vertices[i].normal[2] += n[2];
        }
    }

    // Normalize all normals
    for v in vertices.iter_mut() {
        let len = (v.normal[0].powi(2) + v.normal[1].powi(2) + v.normal[2].powi(2)).sqrt();
        if len > EPSILON_NORMALIZE as f32 {
            v.normal[0] /= len;
            v.normal[1] /= len;
            v.normal[2] /= len;
        } else {
            v.normal = [0.0, 0.0, -1.0];
        }
    }
}