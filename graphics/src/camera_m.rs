// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

use glam::{Mat4, Vec3};
use nalgebra::{Matrix3, Vector3};

use crate::constants_m::{DEFAULT_FAR_CLIP_FT, EPSILON_CHANGE, EPSILON_VELOCITY};
use crate::math_m;

// camera mode determines how the camera follows the vehicle
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CameraMode {
    Body,       // camera fixed relative to aircraft body
    Velocity,   // camera follows velocity vector direction
    Fixed,      // camera fixed at world position
}

impl CameraMode {
    // parse camera mode from config string
    pub fn from_config(s: &str) -> Self {
        match s.to_lowercase().as_str() {
            "body" => Self::Body,
            "velocity" => Self::Velocity,
            _ => Self::Fixed,
        }
    }

    // toggle between body and velocity modes
    pub fn toggle(self) -> Self {
        match self {
            Self::Body => Self::Velocity,
            Self::Velocity => Self::Body,
            Self::Fixed => Self::Fixed,
        }
    }
}

// camera uniform data sent to GPU
#[repr(C)]  // #[repr(C)] ensures C-compatible memory layout for GPU
#[derive(Debug, Copy, Clone, bytemuck::Pod, bytemuck::Zeroable)]
pub struct CameraUniform {
    pub view_proj: [[f32; 4]; 4],   // view-projection matrix
    pub camera_pos: [f32; 3],       // camera position in world space (for camera-relative rendering)
    pub _padding: f32,              // GPU alignment padding
}

impl Default for CameraUniform {
    fn default() -> Self {
        Self {
            view_proj: Mat4::IDENTITY.to_cols_array_2d(),
            camera_pos: [0.0; 3],
            _padding: 0.0,
        }
    }
}

// cached camera parameters - computed once from config
pub struct CameraCache {
    pub fov_y_rad: f32,
    pub near: f32,
    pub far: f32,
}

impl CameraCache {
    pub fn new(distance_vp: f64, aspect_ratio_vp: f64, angle_vp_deg: f64, max_draw_distance: Option<f64>) -> Self {
        // `angle_vp_deg` is the vertical field of view (config_m::ViewPlane::angle_deg documents it
        // as "vertical FOV"). QW6: the old formula treated it as a horizontal half-angle and
        // re-derived fov_y through the view-plane width/aspect, which contradicted the config docs.
        // Use it directly so code and documentation agree; aspect_ratio_vp is applied at
        // projection time via the live viewport aspect in build_uniform.
        let _ = aspect_ratio_vp;
        let fov_y_rad = angle_vp_deg.to_radians();

        let near = (distance_vp * 0.5).max(1.0) as f32;
        let far = max_draw_distance.unwrap_or(DEFAULT_FAR_CLIP_FT) as f32;

        Self {
            fov_y_rad: fov_y_rad as f32,
            near,
            far,
        }
    }
}

// cached rotation matrix - avoids recomputing when euler angles unchanged
pub struct RotationCache {
    euler: [f64; 3],
    rotation: Matrix3<f64>,
}

impl RotationCache {
    pub fn new(euler: [f64; 3]) -> Self {
        let rotation = crate::math_m::get_r(euler[0], euler[1], euler[2]);
        Self { euler, rotation }
    }

    // returns true if rotation was updated
    pub fn update_if_changed(&mut self, new_euler: [f64; 3]) -> bool {
        let changed = (self.euler[0] - new_euler[0]).abs() > EPSILON_CHANGE
            || (self.euler[1] - new_euler[1]).abs() > EPSILON_CHANGE
            || (self.euler[2] - new_euler[2]).abs() > EPSILON_CHANGE;

        if changed {
            self.euler = new_euler;
            self.rotation = crate::math_m::get_r(new_euler[0], new_euler[1], new_euler[2]);
        }
        changed
    }

    pub fn rotation(&self) -> &Matrix3<f64> {
        &self.rotation
    }
}

// camera controller for different view modes
pub struct CameraController {
    pub cache: CameraCache,
    cam_rot_cache: RotationCache,
    veh_rot_cache: RotationCache,
}

impl CameraController {
    pub fn new(cache: CameraCache, cam_euler: [f64; 3], veh_euler: [f64; 3]) -> Self {
        Self {
            cache,
            cam_rot_cache: RotationCache::new(cam_euler),
            veh_rot_cache: RotationCache::new(veh_euler),
        }
    }

    // update camera for body fixed mode
    pub fn update_body_mode(
        &mut self,
        cam_euler: [f64; 3],
        vehicle_euler: [f64; 3],
        cam_location: [f64; 3],
        vehicle_loc: &Vector3<f64>,
    ) -> CameraState {
        self.cam_rot_cache.update_if_changed(cam_euler);
        self.veh_rot_cache.update_if_changed(vehicle_euler);

        let r_cam = self.cam_rot_cache.rotation() * self.veh_rot_cache.rotation();
        let offset = r_cam.transpose() * Vector3::new(cam_location[0], cam_location[1], cam_location[2]);
        let pc = vehicle_loc + offset;

        CameraState { rotation: r_cam, position: pc }
    }

    // update camera for velocity following mode
    pub fn update_velocity_mode(
        &mut self,
        v_b: &Vector3<f64>,          // velocity in body frame
        v_mag: f64,                   // velocity magnitude
        vehicle_loc: &Vector3<f64>,
        vehicle_euler: [f64; 3],
        cam_distance: f64,
    ) -> CameraState {
        self.veh_rot_cache.update_if_changed(vehicle_euler);

        // normalize velocity, default to forward if stationary
        let v_b_hat = if v_mag < EPSILON_VELOCITY {
            Vector3::new(1.0, 0.0, 0.0)
        } else {
            v_b / v_mag
        };

        // position camera behind vehicle along velocity vector
        let v_w = self.veh_rot_cache.rotation().transpose() * v_b_hat;
        let pc = vehicle_loc - v_w * cam_distance;

        // build rotation matrix looking at vehicle
        let look_dir = (vehicle_loc - pc).normalize();
        let world_up = Vector3::new(0.0, 0.0, 1.0);

        // calculate camera up vector (handle looking straight up/down)
        let mut z_cam = world_up - look_dir * world_up.dot(&look_dir);
        if z_cam.norm() < EPSILON_VELOCITY {
            z_cam = Vector3::new(0.0, 1.0, 0.0);
        }
        z_cam = z_cam.normalize();
        let y_cam = z_cam.cross(&look_dir);

        let mut r_cam = Matrix3::zeros();
        r_cam.set_column(0, &look_dir);
        r_cam.set_column(1, &y_cam);
        r_cam.set_column(2, &z_cam);
        let r_cam = r_cam.transpose();

        CameraState { rotation: r_cam, position: pc }
    }

    // update camera for fixed world mode
    pub fn update_fixed_mode(
        &mut self,
        cam_euler: [f64; 3],
        cam_location: [f64; 3],
    ) -> CameraState {
        self.cam_rot_cache.update_if_changed(cam_euler);

        let r_cam = *self.cam_rot_cache.rotation();
        let pc = Vector3::new(cam_location[0], cam_location[1], cam_location[2]);

        CameraState { rotation: r_cam, position: pc }
    }

    // build camera uniform from camera state for GPU upload
    pub fn build_uniform(&self, state: &CameraState, viewport_size: (u32, u32)) -> CameraUniform {
        let (width, height) = viewport_size;
        let aspect = width as f32 / height as f32;

        // build view matrix - camera at origin for camera-relative rendering.
        // The view rotation is derived from the SAME axes as inv_view_rotation() (see below), so the
        // sky/HUD and the world view can never drift apart.
        let (forward, up) = view_forward_up(state);
        let view = Mat4::look_to_rh(Vec3::ZERO, forward, up);
        let proj = Mat4::perspective_rh(self.cache.fov_y_rad, aspect, self.cache.near, self.cache.far);
        let view_proj = proj * view;

        let cam_pos = math_m::vec3_to_glam(&state.position);
        CameraUniform {
            view_proj: view_proj.to_cols_array_2d(),
            camera_pos: [cam_pos.x, cam_pos.y, cam_pos.z],
            _padding: 0.0,
        }
    }
}

// camera state at a point in time
pub struct CameraState {
    pub rotation: Matrix3<f64>,
    pub position: Vector3<f64>,
}

/// Camera forward/up vectors (world space) for a given state.
/// This is the single source the view matrix (`build_uniform`) and the inverse-view rotation
/// (`inv_view_rotation`) both read from, so they cannot disagree.
pub fn view_forward_up(state: &CameraState) -> (Vec3, Vec3) {
    let r_cam_world = state.rotation.transpose();
    math_m::rotation_to_forward_up(&r_cam_world)
}

/// Inverse view rotation matrix whose columns are the camera axes in world space
/// (right, up, -forward). This reproduces the axis basis that `Mat4::look_to_rh` builds
/// internally in `build_uniform`, so the sky/HUD shaders share ONE definition instead of the
/// old "must match build_uniform" hand-copy in main.rs.
pub fn inv_view_rotation(state: &CameraState) -> [[f32; 3]; 3] {
    let (forward, up) = view_forward_up(state);

    let z_axis = -forward.normalize(); // camera looks down -Z
    let x_axis = up.cross(z_axis).normalize(); // right
    let y_axis = z_axis.cross(x_axis); // up in camera space

    [
        [x_axis.x, x_axis.y, x_axis.z], // column 0: right axis
        [y_axis.x, y_axis.y, y_axis.z], // column 1: up axis
        [z_axis.x, z_axis.y, z_axis.z], // column 2: -forward axis
    ]
}

