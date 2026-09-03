// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

//! View frustum culling for terrain tiles
//!
//! Provides frustum-based visibility testing for streaming terrain.

// ============================================================================
// View Frustum for culling tiles
// ============================================================================

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum FrustumResult {
    Outside,
    Inside,
    Intersecting,
}

/// View frustum for culling terrain tiles
#[derive(Clone)]
pub struct ViewFrustum {
    /// Frustum planes in world space (NED coordinates)
    /// Each plane is [A, B, C, D] where Ax + By + Cz + D >= 0 is inside
    planes: [[f64; 4]; 6],
}

impl ViewFrustum {
    /// Create frustum from camera parameters
    /// camera_pos: [x, y, z] in NED world coordinates
    /// forward: normalized [x, y] heading direction (NED: x=North, y=East)
    /// fov_h: horizontal field of view in radians
    /// aspect: width/height ratio
    /// near/far: clipping distances in feet
    #[allow(dead_code)]
    pub fn new(
        camera_pos: [f64; 3],
        forward: [f64; 2],
        up: [f64; 3],
        fov_h: f64,
        aspect: f64,
        near: f64,
        far: f64,
    ) -> Self {
        let fov_v = 2.0 * ((fov_h / 2.0).tan() / aspect).atan();

        // Normalize forward to 3D (assuming mostly horizontal flight)
        let fwd_len = (forward[0] * forward[0] + forward[1] * forward[1]).sqrt();
        let fwd_3d = if fwd_len > 0.001 {
            [forward[0] / fwd_len, forward[1] / fwd_len, 0.0]
        } else {
            [1.0, 0.0, 0.0]
        };

        // Right vector (cross product of forward and up)
        let right = [
            fwd_3d[1] * up[2] - fwd_3d[2] * up[1],
            fwd_3d[2] * up[0] - fwd_3d[0] * up[2],
            fwd_3d[0] * up[1] - fwd_3d[1] * up[0],
        ];

        // Recalculate up to ensure orthogonality
        let up_corrected = [
            right[1] * fwd_3d[2] - right[2] * fwd_3d[1],
            right[2] * fwd_3d[0] - right[0] * fwd_3d[2],
            right[0] * fwd_3d[1] - right[1] * fwd_3d[0],
        ];

        let mut planes = [[0.0; 4]; 6];

        // Near plane: normal = forward
        planes[0] = Self::make_plane(fwd_3d, Self::point_along(camera_pos, fwd_3d, near));

        // Far plane: normal = -forward
        let neg_fwd = [-fwd_3d[0], -fwd_3d[1], -fwd_3d[2]];
        planes[1] = Self::make_plane(neg_fwd, Self::point_along(camera_pos, fwd_3d, far));

        // Left plane
        let left_normal = Self::rotate_around(fwd_3d, up_corrected, fov_h / 2.0);
        planes[2] = Self::make_plane(left_normal, camera_pos);

        // Right plane
        let right_normal = Self::rotate_around(fwd_3d, up_corrected, -fov_h / 2.0);
        let right_normal = [-right_normal[0], -right_normal[1], -right_normal[2]];
        planes[3] = Self::make_plane(right_normal, camera_pos);

        // Top plane
        let top_normal = Self::rotate_around(fwd_3d, right, -fov_v / 2.0);
        planes[4] = Self::make_plane(top_normal, camera_pos);

        // Bottom plane
        let bottom_normal = Self::rotate_around(fwd_3d, right, fov_v / 2.0);
        let bottom_normal = [-bottom_normal[0], -bottom_normal[1], -bottom_normal[2]];
        planes[5] = Self::make_plane(bottom_normal, camera_pos);

        Self { planes }
    }

    /// Create a simple frustum for 2D terrain culling (horizontal plane only)
    /// This is faster and sufficient for terrain tile selection
    pub fn new_simple(
        camera_pos: [f64; 3],
        forward: [f64; 2],
        fov_h: f64,
        max_distance: f64,
    ) -> Self {
        let fwd_len = (forward[0] * forward[0] + forward[1] * forward[1]).sqrt();
        let fwd = if fwd_len > 0.001 {
            [forward[0] / fwd_len, forward[1] / fwd_len]
        } else {
            [1.0, 0.0]
        };

        // Perpendicular (right) vector in 2D for NED coordinates
        // In NED: X=North, Y=East. Right of North is East.
        // For fwd=[1,0] (North), right should be [0,1] (East)
        // 90° CW rotation: [-fwd[1], fwd[0]] gives [0, 1] for [1, 0] ✓
        let right = [-fwd[1], fwd[0]];

        // Widen FOV for terrain loading (load tiles before they enter strict camera FOV)
        let terrain_fov = fov_h + 0.5; // Add ~30 degrees of margin
        let half_fov = terrain_fov / 2.0;
        let cos_half = half_fov.cos();
        let sin_half = half_fov.sin();

        // Left frustum edge direction (forward rotated left by half FOV)
        let left_dir = [
            fwd[0] * cos_half - right[0] * sin_half,
            fwd[1] * cos_half - right[1] * sin_half,
        ];

        // Right frustum edge direction (forward rotated right by half FOV)
        let right_dir = [
            fwd[0] * cos_half + right[0] * sin_half,
            fwd[1] * cos_half + right[1] * sin_half,
        ];

        let mut planes = [[0.0; 4]; 6];

        // For a plane with normal N passing through point P: N·X + D = 0, where D = -N·P
        // Points are "inside" if N·X + D >= 0
        //
        // `right` above is the +90° rotation of `fwd` ([-b, a]), so the wedge runs from
        // left_dir (fwd rotated -half_fov) to right_dir (fwd rotated +half_fov). Each
        // boundary's inward normal must therefore point *back toward* fwd:
        //   - at left_dir  (the -half_fov edge), inward is the +90° rotation: [-b, a]
        //   - at right_dir (the +half_fov edge), inward is the -90° rotation: [b, -a]
        // These were previously swapped, which negated both normals and pointed the whole
        // wedge backwards — terrain ahead of the aircraft tested Outside and was culled,
        // and (because only drawn tiles refresh `last_used`) then aged out of the GPU cache.

        // Left plane: inward normal is the +90° rotation of left_dir
        let left_normal = [-left_dir[1], left_dir[0]];
        planes[0] = [
            left_normal[0],
            left_normal[1],
            0.0,
            -(left_normal[0] * camera_pos[0] + left_normal[1] * camera_pos[1])
        ];

        // Right plane: inward normal is the -90° rotation of right_dir
        let right_normal = [right_dir[1], -right_dir[0]];
        planes[1] = [
            right_normal[0],
            right_normal[1],
            0.0,
            -(right_normal[0] * camera_pos[0] + right_normal[1] * camera_pos[1])
        ];

        // Far plane: normal points back toward camera (-forward)
        let far_point = [
            camera_pos[0] + fwd[0] * max_distance,
            camera_pos[1] + fwd[1] * max_distance,
        ];
        planes[2] = [
            -fwd[0],
            -fwd[1],
            0.0,
            -(-fwd[0] * far_point[0] - fwd[1] * far_point[1])
        ];

        // Near plane: normal points forward, but placed behind camera
        // This ensures tiles under/behind the aircraft are still considered
        let near_dist = -5000.0; // Well behind camera to catch nearby tiles
        let near_point = [
            camera_pos[0] + fwd[0] * near_dist,
            camera_pos[1] + fwd[1] * near_dist,
        ];
        planes[3] = [
            fwd[0],
            fwd[1],
            0.0,
            -(fwd[0] * near_point[0] + fwd[1] * near_point[1])
        ];

        // Unused planes (set to always pass)
        planes[4] = [0.0, 0.0, 1.0, 1e10];
        planes[5] = [0.0, 0.0, -1.0, 1e10];

        Self { planes }
    }

    fn make_plane(normal: [f64; 3], point: [f64; 3]) -> [f64; 4] {
        let d = -(normal[0] * point[0] + normal[1] * point[1] + normal[2] * point[2]);
        [normal[0], normal[1], normal[2], d]
    }

    fn point_along(origin: [f64; 3], dir: [f64; 3], dist: f64) -> [f64; 3] {
        [
            origin[0] + dir[0] * dist,
            origin[1] + dir[1] * dist,
            origin[2] + dir[2] * dist,
        ]
    }

    fn rotate_around(v: [f64; 3], axis: [f64; 3], angle: f64) -> [f64; 3] {
        let c = angle.cos();
        let s = angle.sin();
        let dot = v[0] * axis[0] + v[1] * axis[1] + v[2] * axis[2];
        let cross = [
            axis[1] * v[2] - axis[2] * v[1],
            axis[2] * v[0] - axis[0] * v[2],
            axis[0] * v[1] - axis[1] * v[0],
        ];
        [
            v[0] * c + cross[0] * s + axis[0] * dot * (1.0 - c),
            v[1] * c + cross[1] * s + axis[1] * dot * (1.0 - c),
            v[2] * c + cross[2] * s + axis[2] * dot * (1.0 - c),
        ]
    }

    /// Test if a 2D bounding box (terrain tile) intersects the frustum
    /// margin: extra padding around the tile for early loading
    pub fn test_tile_2d(&self, min_x: f64, min_y: f64, max_x: f64, max_y: f64, margin: f64) -> FrustumResult {
        let min_x = min_x - margin;
        let min_y = min_y - margin;
        let max_x = max_x + margin;
        let max_y = max_y + margin;

        let mut all_inside = true;

        for plane in &self.planes {
            // Find the corner most in the direction of the plane normal (2D only)
            let px = if plane[0] >= 0.0 { max_x } else { min_x };
            let py = if plane[1] >= 0.0 { max_y } else { min_y };

            // If the "positive" corner is outside, the whole box is outside
            if plane[0] * px + plane[1] * py + plane[3] < 0.0 {
                return FrustumResult::Outside;
            }

            // Check the "negative" corner to see if fully inside this plane
            let nx = if plane[0] >= 0.0 { min_x } else { max_x };
            let ny = if plane[1] >= 0.0 { min_y } else { max_y };

            if plane[0] * nx + plane[1] * ny + plane[3] < 0.0 {
                all_inside = false;
            }
        }

        if all_inside {
            FrustumResult::Inside
        } else {
            FrustumResult::Intersecting
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FOV: f64 = std::f64::consts::FRAC_PI_3; // 60 deg
    const FAR: f64 = 300_000.0;

    /// A small tile straight down the boresight must be visible at every range
    /// inside the far plane. The inward normals were previously negated, which
    /// pointed the wedge backwards and culled terrain ahead of the aircraft.
    #[test]
    fn tile_straight_ahead_is_visible_at_all_ranges() {
        for &(fx, fy) in &[(1.0, 0.0), (0.0, 1.0), (-1.0, 0.0), (0.0, -1.0), (0.6, 0.8)] {
            let f = ViewFrustum::new_simple([0.0, 0.0, 0.0], [fx, fy], FOV, FAR);
            for d in [500.0, 5_000.0, 50_000.0, 200_000.0] {
                let (cx, cy) = (fx * d, fy * d);
                let r = f.test_tile_2d(cx - 100.0, cy - 100.0, cx + 100.0, cy + 100.0, 0.0);
                assert_ne!(r, FrustumResult::Outside,
                    "tile {d} ahead of forward ({fx},{fy}) was culled");
            }
        }
    }

    /// The wedge must open forwards: far-field lateral coverage grows with range.
    #[test]
    fn wedge_widens_ahead_not_behind() {
        let f = ViewFrustum::new_simple([0.0, 0.0, 0.0], [0.0, 1.0], FOV, FAR);
        let width_at = |y: f64| -> i32 {
            (-60..=60).filter(|i| {
                let x = *i as f64 * 1000.0;
                f.test_tile_2d(x - 50.0, y - 50.0, x + 50.0, y + 50.0, 0.0) != FrustumResult::Outside
            }).count() as i32
        };
        assert!(width_at(60_000.0) > width_at(20_000.0), "wedge should widen ahead");
        assert!(width_at(20_000.0) > width_at(-20_000.0), "wedge should not open behind");
    }

    /// Something well outside the wedge still has to be culled - the fix must not
    /// simply make everything visible.
    #[test]
    fn tile_behind_is_culled() {
        let f = ViewFrustum::new_simple([0.0, 0.0, 0.0], [0.0, 1.0], FOV, FAR);
        let r = f.test_tile_2d(-100.0, -80_000.0, 100.0, -79_800.0, 0.0);
        assert_eq!(r, FrustumResult::Outside, "tile far behind should be culled");
    }
}
