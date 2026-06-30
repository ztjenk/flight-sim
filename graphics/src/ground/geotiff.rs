// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

use std::path::Path;

use super::quadtree::Bounds;

// global DEM data loaded from a binary file
pub struct GlobalDem {
    pub data: Vec<f32>,         // elevation data in row-major order (top to bottom, left to right)
    pub width: usize,
    pub height: usize,
    pub bounds: Bounds,         // geographic bounds in UTM coordinates
    pub pixel_size: (f64, f64), // meters per pixel (x, y)
    pub nodata: f32,
}

impl GlobalDem {
    // load a binary DEM file
    // bounds and pixel_size must be provided from quadtree_index.json
    pub fn load(
        path: &Path,
        bounds: Bounds,
        pixel_size: (f64, f64),
        nodata: f32,
    ) -> Result<Self, String> {
        // Read the entire file in one bulk transfer, then parse from memory.
        // The previous per-value BufReader loop did thousands of small reads;
        // over a network drive each refill is a round-trip and the stacked
        // latency makes a 52 MB DEM appear to hang. One std::fs::read is a
        // single sequential transfer.
        let raw = std::fs::read(path)
            .map_err(|e| format!("Cannot open DEM file '{}': {}", path.display(), e))?;

        if raw.len() < 8 {
            return Err(format!("DEM file '{}' too small for header", path.display()));
        }

        let width = u32::from_le_bytes([raw[0], raw[1], raw[2], raw[3]]) as usize;
        let height = u32::from_le_bytes([raw[4], raw[5], raw[6], raw[7]]) as usize;

        let expected_size = width * height;
        let payload = &raw[8..];
        if payload.len() < expected_size * 4 {
            return Err(format!(
                "DEM file '{}' truncated: expected {} values ({} bytes), found {} bytes",
                path.display(), expected_size, expected_size * 4, payload.len()
            ));
        }

        let data: Vec<f32> = payload[..expected_size * 4]
            .chunks_exact(4)
            .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            .collect();

        Ok(Self {
            data,
            width,
            height,
            bounds,
            pixel_size,
            nodata,
        })
    }

    // sample elevation at a UTM coordinate with bilinear interpolation
    pub fn sample(&self, utm_x: f64, utm_y: f64) -> Option<f32> {
        // convert UTM to pixel coordinates
        let px = (utm_x - self.bounds.min_x) / self.pixel_size.0;
        let py = (self.bounds.max_y - utm_y) / self.pixel_size.1;

        if px < 0.0 || py < 0.0 || px >= self.width as f64 || py >= self.height as f64 {
            return None;
        }

        // bilinear interpolation
        let x0 = (px.floor() as usize).min(self.width.saturating_sub(2));
        let y0 = (py.floor() as usize).min(self.height.saturating_sub(2));
        let x1 = (x0 + 1).min(self.width - 1);
        let y1 = (y0 + 1).min(self.height - 1);

        let fx = (px - px.floor()) as f32;
        let fy = (py - py.floor()) as f32;

        let v00 = self.data[y0 * self.width + x0];
        let v10 = self.data[y0 * self.width + x1];
        let v01 = self.data[y1 * self.width + x0];
        let v11 = self.data[y1 * self.width + x1];

        // if any corner is nodata, return first valid value or None
        if self.is_nodata(v00) || self.is_nodata(v10) ||
           self.is_nodata(v01) || self.is_nodata(v11) {
            for v in [v00, v10, v01, v11] {
                if !self.is_nodata(v) {
                    return Some(v);
                }
            }
            return None;
        }

        let v0 = v00 * (1.0 - fx) + v10 * fx;
        let v1 = v01 * (1.0 - fx) + v11 * fx;
        Some(v0 * (1.0 - fy) + v1 * fy)
    }

    #[inline]
    pub fn is_nodata(&self, v: f32) -> bool {
        v <= self.nodata + 1.0 || v.is_nan()
    }
}