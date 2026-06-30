// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

// Mesh (aircraft) vertex and fragment shader

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

struct ModelUniform {
    model: mat4x4<f32>,
};

@group(0) @binding(0) var<uniform> camera: CameraUniform;
@group(0) @binding(1) var<uniform> light: LightUniform;
@group(1) @binding(0) var<uniform> mesh: ModelUniform;

struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) color: vec4<f32>,
};

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) world_position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) color: vec4<f32>,
};

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;

    // model matrix includes rotation + camera-relative translation
    let world_pos = (mesh.model * vec4<f32>(in.position, 1.0)).xyz;

    out.clip_position = camera.view_proj * vec4<f32>(world_pos, 1.0);
    out.world_position = world_pos;

    // transform normal by upper-left 3x3 (rotation only)
    let normal_matrix = mat3x3<f32>(
        mesh.model[0].xyz,
        mesh.model[1].xyz,
        mesh.model[2].xyz,
    );
    out.normal = normalize(normal_matrix * in.normal);
    out.color = in.color;

    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let n = normalize(in.normal);
    let l = normalize(-light.direction);
    let ndotl = max(dot(n, l), 0.0);

    let diffuse = in.color.rgb * ndotl * light.aircraft_intensity;
    let ambient_color = in.color.rgb * light.ambient;

    return vec4<f32>(diffuse + ambient_color, in.color.a);
}
