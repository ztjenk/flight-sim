// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

//! UTM (Universal Transverse Mercator) coordinate conversions
//!
//! Converts between latitude/longitude (WGS84) and UTM coordinates.

/// Convert latitude/longitude to UTM coordinates
/// Returns (easting, northing, zone, is_northern_hemisphere)
pub fn lat_lon_to_utm(lat: f64, lon: f64) -> (f64, f64, u32, bool) {
    let mut zone = ((lon + 180.0) / 6.0).floor() as u32 + 1;

    // Norway/Svalbard exceptions
    if (56.0..64.0).contains(&lat) && (3.0..12.0).contains(&lon) {
        zone = 32;
    } else if (72.0..84.0).contains(&lat) {
        if (0.0..9.0).contains(&lon) { zone = 31; }
        else if (9.0..21.0).contains(&lon) { zone = 33; }
        else if (21.0..33.0).contains(&lon) { zone = 35; }
        else if (33.0..42.0).contains(&lon) { zone = 37; }
    }

    let northern = lat >= 0.0;
    const A: f64 = 6378137.0;           // WGS84 semi-major axis
    const F: f64 = 1.0 / 298.257223563; // WGS84 flattening
    const K0: f64 = 0.9996;             // UTM scale factor

    let e2 = 2.0 * F - F * F;
    let ep2 = e2 / (1.0 - e2);

    let lat_r = lat.to_radians();
    let lon_r = lon.to_radians();
    let lon0 = ((zone as f64 - 1.0) * 6.0 - 180.0 + 3.0).to_radians();

    let n = A / (1.0 - e2 * lat_r.sin().powi(2)).sqrt();
    let t = lat_r.tan().powi(2);
    let c = ep2 * lat_r.cos().powi(2);
    let a = (lon_r - lon0) * lat_r.cos();

    let m = A * (
        (1.0 - e2 / 4.0 - 3.0 * e2.powi(2) / 64.0 - 5.0 * e2.powi(3) / 256.0) * lat_r
        - (3.0 * e2 / 8.0 + 3.0 * e2.powi(2) / 32.0 + 45.0 * e2.powi(3) / 1024.0) * (2.0 * lat_r).sin()
        + (15.0 * e2.powi(2) / 256.0 + 45.0 * e2.powi(3) / 1024.0) * (4.0 * lat_r).sin()
        - (35.0 * e2.powi(3) / 3072.0) * (6.0 * lat_r).sin()
    );

    let easting = K0 * n * (
        a + (1.0 - t + c) * a.powi(3) / 6.0
        + (5.0 - 18.0 * t + t.powi(2) + 72.0 * c - 58.0 * ep2) * a.powi(5) / 120.0
    ) + 500000.0;

    let mut northing = K0 * (
        m + n * lat_r.tan() * (
            a.powi(2) / 2.0
            + (5.0 - t + 9.0 * c + 4.0 * c.powi(2)) * a.powi(4) / 24.0
            + (61.0 - 58.0 * t + t.powi(2) + 600.0 * c - 330.0 * ep2) * a.powi(6) / 720.0
        )
    );

    if !northern {
        northing += 10000000.0;
    }

    (easting, northing, zone, northern)
}
