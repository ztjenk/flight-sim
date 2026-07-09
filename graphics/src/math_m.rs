// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

use nalgebra::{Matrix3, Vector3};

// ---- nalgebra (f64 physics) → glam (f32 GPU) conversions ----

pub fn vec3_to_glam(v: &Vector3<f64>) -> glam::Vec3 {
    glam::Vec3::new(v.x as f32, v.y as f32, v.z as f32)
}

pub fn arr3_to_glam(a: [f64; 3]) -> glam::Vec3 {
    glam::Vec3::new(a[0] as f32, a[1] as f32, a[2] as f32)
}

/// Convert a nalgebra 3x3 rotation matrix to a glam 4x4 homogeneous matrix.
/// Reads columns from the nalgebra matrix and packs them into Mat4 columns.
pub fn mat3_to_glam(m: &Matrix3<f64>) -> glam::Mat4 {
    glam::Mat4::from_cols(
        glam::Vec4::new(m[(0,0)] as f32, m[(1,0)] as f32, m[(2,0)] as f32, 0.0),
        glam::Vec4::new(m[(0,1)] as f32, m[(1,1)] as f32, m[(2,1)] as f32, 0.0),
        glam::Vec4::new(m[(0,2)] as f32, m[(1,2)] as f32, m[(2,2)] as f32, 0.0),
        glam::Vec4::new(0.0, 0.0, 0.0, 1.0),
    )
}

/// Extract forward and up vectors from a camera-to-world rotation matrix.
/// Returns (forward, up) as glam Vec3 for GPU use.
pub fn rotation_to_forward_up(r_cam_world: &Matrix3<f64>) -> (glam::Vec3, glam::Vec3) {
    let forward = glam::Vec3::new(
        r_cam_world[(0, 0)] as f32,
        r_cam_world[(1, 0)] as f32,
        r_cam_world[(2, 0)] as f32,
    );
    let up = glam::Vec3::new(
        -r_cam_world[(0, 2)] as f32,
        -r_cam_world[(1, 2)] as f32,
        -r_cam_world[(2, 2)] as f32,
    );
    (forward, up)
}

pub fn get_r(phi: f64, theta: f64, psi: f64) -> Matrix3<f64> {
    let (sp, cp) = phi.sin_cos();
    let (st, ct) = theta.sin_cos();
    let (ss, cs) = psi.sin_cos();

    Matrix3::new(
        ct * cs,
        ct * ss,
        -st,
        sp * st * cs - cp * ss,
        sp * st * ss + cp * cs,
        sp * ct,
        cp * st * cs + sp * ss,
        cp * st * ss - sp * cs,
        cp * ct,
    )
}

// convert Euler angles to quaternion [w, x, y, z]
pub fn euler_to_quat(euler: [f64; 3]) -> [f64; 4] {
    let (phi, theta, psi) = (euler[0], euler[1], euler[2]);

    let (sp, cp) = (phi / 2.0).sin_cos();
    let (st, ct) = (theta / 2.0).sin_cos();
    let (ss, cs) = (psi / 2.0).sin_cos();

    [
        cp * ct * cs + sp * st * ss, // w
        sp * ct * cs - cp * st * ss, // x
        cp * st * cs + sp * ct * ss, // y
        cp * ct * ss - sp * st * cs, // z
    ]
}

// convert quaternion [w, x, y, z] to Euler angles [phi, theta, psi]
pub fn quat_to_euler(q: [f64; 4]) -> [f64; 3] {
    let (w, x, y, z) = (q[0], q[1], q[2], q[3]);

    // phi
    let sinr_cosp = 2.0 * (w * x + y * z);
    let cosr_cosp = 1.0 - 2.0 * (x * x + y * y);
    let phi = sinr_cosp.atan2(cosr_cosp);

    // theta
    let sinp = 2.0 * (w * y - z * x);
    let theta = if sinp.abs() >= 1.0 {
        std::f64::consts::FRAC_PI_2.copysign(sinp) // gimbal lock
    } else {
        sinp.asin()
    };

    // psi
    let siny_cosp = 2.0 * (w * z + x * y);
    let cosy_cosp = 1.0 - 2.0 * (y * y + z * z);
    let psi = siny_cosp.atan2(cosy_cosp);

    [phi, theta, psi]
}

// build rotation matrix from quaternion [w, x, y, z]
pub fn quat_to_matrix(q: [f64; 4]) -> Matrix3<f64> {
    let (w, x, y, z) = (q[0], q[1], q[2], q[3]);

    let xx = x * x;
    let yy = y * y;
    let zz = z * z;
    let xy = x * y;
    let xz = x * z;
    let yz = y * z;
    let wx = w * x;
    let wy = w * y;
    let wz = w * z;

    Matrix3::new(
        1.0 - 2.0 * (yy + zz),
        2.0 * (xy + wz),
        2.0 * (xz - wy),
        2.0 * (xy - wz),
        1.0 - 2.0 * (xx + zz),
        2.0 * (yz + wx),
        2.0 * (xz + wy),
        2.0 * (yz - wx),
        1.0 - 2.0 * (xx + yy),
    )
}

// convert body frame velocity to earth frame using quaternion
// v_earth = R_eb * v_body where R_eb is body-to-earth rotation matrix
// Note: quat_to_matrix returns R_be (earth-to-body), so we transpose to get R_eb
pub fn body_to_earth_velocity(v_body: &Vector3<f64>, q: [f64; 4]) -> Vector3<f64> {
    let r_be = quat_to_matrix(q);
    r_be.transpose() * v_body
}

#[cfg(test)]
mod tests {
    use super::*;

    const TOL: f64 = 1e-9;

    fn deg(d: f64) -> f64 {
        d.to_radians()
    }

    // Published 3-2-1 (yaw-pitch-roll) earth-to-body DCM for phi=30°, theta=-20°, psi=45°.
    // Computed independently (numpy) from R = Rx(phi)·Ry(theta)·Rz(psi) in the same row-major
    // layout nalgebra::Matrix3::new uses. This pins get_r's convention.
    #[test]
    fn get_r_matches_published_321_dcm() {
        let e = [deg(30.0), deg(-20.0), deg(45.0)];
        let r = get_r(e[0], e[1], e[2]);
        let expected = [
            [0.664463024, 0.664463024, 0.342020143],
            [-0.733294817, 0.491450054, 0.469846310],
            [0.144109682, -0.562997099, 0.813797681],
        ];
        for i in 0..3 {
            for j in 0..3 {
                assert!(
                    (r[(i, j)] - expected[i][j]).abs() < 1e-8,
                    "R[{},{}] = {}, expected {}",
                    i, j, r[(i, j)], expected[i][j]
                );
            }
        }
    }

    // euler_to_quat then quat_to_matrix must reproduce the same 3-2-1 DCM as get_r.
    #[test]
    fn quat_matrix_agrees_with_get_r() {
        for e in [
            [deg(30.0), deg(-20.0), deg(45.0)],
            [deg(-15.0), deg(60.0), deg(-120.0)],
            [deg(0.0), deg(0.0), deg(0.0)],
        ] {
            let r_direct = get_r(e[0], e[1], e[2]);
            let r_via_quat = quat_to_matrix(euler_to_quat(e));
            let diff = (r_direct - r_via_quat).abs().max();
            assert!(diff < TOL, "DCM mismatch for {:?}: max diff {}", e, diff);
        }
    }

    // quat <-> euler round-trip recovers the original angles (away from gimbal lock).
    #[test]
    fn quat_euler_round_trip() {
        for e in [
            [deg(30.0), deg(-20.0), deg(45.0)],
            [deg(-15.0), deg(60.0), deg(-120.0)],
            [deg(5.0), deg(-85.0), deg(10.0)],
        ] {
            let back = quat_to_euler(euler_to_quat(e));
            for k in 0..3 {
                assert!(
                    (back[k] - e[k]).abs() < 1e-9,
                    "angle {} round-trip: got {}, expected {}",
                    k, back[k], e[k]
                );
            }
        }
    }

    // At the gimbal-lock pole (theta = +90°) the asin path is clamped and must not NaN.
    #[test]
    fn quat_euler_gimbal_lock_is_finite() {
        let e = [deg(0.0), deg(90.0), deg(30.0)];
        let back = quat_to_euler(euler_to_quat(e));
        assert!(back.iter().all(|a| a.is_finite()));
        assert!((back[1] - std::f64::consts::FRAC_PI_2).abs() < 1e-6);
    }
}
