// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

// Terrain vertex and fragment shader

struct CameraUniform {
    view_proj: mat4x4<f32>,
    camera_pos: vec3<f32>,
    _padding: f32,
};

struct LightUniform {
    direction: vec3<f32>,
    aircraft_intensity: f32,
    ground_intensity: f32,
    ambient: f32,
    _pad1: vec2<f32>,
    _padding: vec3<f32>,
    _struct_pad: f32,
};

@group(0) @binding(0) var<uniform> camera: CameraUniform;
@group(0) @binding(1) var<uniform> light: LightUniform;

@group(1) @binding(0) var t_terrain: texture_2d<f32>;
@group(1) @binding(1) var s_terrain: sampler;

struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) uv: vec2<f32>,
    @location(2) normal: vec3<f32>,
};

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) world_position: vec3<f32>,
    @location(1) uv: vec2<f32>,
    @location(2) normal: vec3<f32>,
    @location(3) view_distance: f32,
};

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;

    // camera-relative position for precision at large distances
    let world_pos = in.position - camera.camera_pos;

    out.clip_position = camera.view_proj * vec4<f32>(world_pos, 1.0);
    out.world_position = in.position;
    out.uv = in.uv;
    out.normal = in.normal;
    out.view_distance = length(world_pos);

    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    // GPU auto-selects mip level based on screen-space derivatives
    let albedo = textureSample(t_terrain, s_terrain, in.uv);

    // Lambertian terrain lighting: sun N·L diffuse + ambient fill. Uses the DEM normals computed in
    // loader.rs::compute_mesh_normals. Output is linear — the sRGB surface format gamma-encodes.
    let n = normalize(in.normal);
    let l = normalize(-light.direction);
    let ndotl = max(dot(n, l), 0.0);
    let diffuse = albedo.rgb * ndotl * light.ground_intensity;
    let ambient_color = albedo.rgb * light.ambient;
    return vec4<f32>(diffuse + ambient_color, albedo.a);
}
