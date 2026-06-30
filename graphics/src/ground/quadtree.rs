// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

use serde::Deserialize;

use crate::constants_m::DEM_NODATA_VALUE;

// root quadtree index loaded from quadtree_index.json
#[derive(Debug, Clone, Deserialize)]
pub struct QuadtreeIndex {
    pub dem_bounds: Bounds,
    pub dem_pixel_size: [f64; 2],
    pub tile_count: usize,
    pub quadtree: QuadtreeNode,
    #[serde(default)]
    pub dem_file: Option<String>,       // path to global DEM binary (single-region)
    #[serde(default = "default_nodata")]
    pub dem_nodata: f32,
    #[serde(default)]
    pub regions: Vec<RegionInfo>,       // multi-region terrain support
}

// information about a terrain region (multi-region support)
#[derive(Debug, Clone, Deserialize)]
pub struct RegionInfo {
    pub name: String,
    pub dem_file: String,
    pub dem_bounds: Bounds,
    pub dem_pixel_size: [f64; 2],
    #[serde(default = "default_nodata")]
    pub dem_nodata: f32,
    #[serde(default)]
    pub tile_count: usize,
}

fn default_nodata() -> f32 { DEM_NODATA_VALUE as f32 }

// node in the quadtree hierarchy
#[derive(Debug, Clone, Deserialize)]
pub struct QuadtreeNode {
    #[serde(default)]
    pub key: String,
    #[serde(default)]
    pub tx: i32,
    #[serde(default)]
    pub ty: i32,
    pub bounds: Bounds,
    #[serde(default)]
    pub dem_bounds: Option<Bounds>,
    #[serde(default)]
    pub imagery_bounds: Option<Bounds>,
    pub tile_path: Option<String>,
    pub has_imagery: bool,
    pub has_dem: bool,
    pub children: Option<Vec<QuadtreeNode>>,
}

// geographic bounds in UTM coordinates
#[derive(Debug, Clone, Copy, Deserialize, Default)]
pub struct Bounds {
    pub min_x: f64,
    pub min_y: f64,
    pub max_x: f64,
    pub max_y: f64,
}

impl Bounds {
    pub fn center(&self) -> (f64, f64) {
        ((self.min_x + self.max_x) / 2.0, (self.min_y + self.max_y) / 2.0)
    }

    pub fn contains(&self, x: f64, y: f64) -> bool {
        x >= self.min_x && x <= self.max_x && y >= self.min_y && y <= self.max_y
    }
}

// per-tile metadata loaded from tiles/{tx}_{ty}/metadata.json
#[derive(Debug, Clone, Deserialize)]
pub struct TileMetadata {
    pub bounds: Bounds,
    #[serde(default)]
    pub dem_bounds: Option<Bounds>,
    #[serde(default)]
    pub imagery_bounds: Option<Bounds>,
    #[serde(default)]
    pub imagery_mips: Vec<ImageryMip>,
    #[serde(default)]
    pub dem_mips: Vec<DemMip>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ImageryMip {
    pub level: usize,
    pub format: String,
    pub path: String,
    pub width: usize,
    pub height: usize,
}

#[derive(Debug, Clone, Deserialize)]
pub struct DemMip {
    pub level: usize,
    pub path: String,
}