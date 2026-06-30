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
