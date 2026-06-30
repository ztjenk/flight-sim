// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

// Procedural ground grid using fwidth()-based anti-aliasing.
//
// Six vertices are generated from vertex_index — no vertex buffer required.
// The quad is centered on the camera's XY position so the grid always covers
// the visible ground. Grid lines are drawn analytically giving consistent
// 1-pixel width regardless of view distance (no thickness scaling needed).

struct CameraUniform {
    view_proj: mat4x4<f32>,
    camera_pos: vec3<f32>,
    _padding: f32,
};

// Grid parameters written by CPU each frame
struct GridParams {
    ground_z_rel: f32,   // ground altitude minus camera altitude (camera-relative Z)
    grid_scale:   f32,   // primary grid line spacing (world units)
    fade_start:   f32,   // horizontal distance where alpha fade begins
    fade_end:     f32,   // horizontal distance where grid is fully transparent
    quad_half:    f32,   // half-extent of the ground quad (world units)
    line_width:   f32,   // anti-aliased line half-width in pixels (1.0 = 2px, 1.5 = 3px)
    color_r:      f32,
    color_g:      f32,
    color_b:      f32,
    _pad:         f32,
};

@group(0) @binding(0) var<uniform> camera: CameraUniform;
@group(1) @binding(0) var<uniform> params: GridParams;

struct VertexOutput {
    @builtin(position) clip_pos:   vec4<f32>,
    @location(0)       world_xy:   vec2<f32>,   // absolute world XY (for grid modulo)
    @location(1)       cam_rel_xy: vec2<f32>,   // camera-relative XY (for fade distance)
};

@vertex
fn vs_main(@builtin(vertex_index) idx: u32) -> VertexOutput {
    // Two triangles covering a large quad on the ground plane
    var corners = array<vec2<f32>, 6>(
        vec2<f32>(-1.0, -1.0), vec2<f32>( 1.0, -1.0), vec2<f32>( 1.0,  1.0),
        vec2<f32>(-1.0, -1.0), vec2<f32>( 1.0,  1.0), vec2<f32>(-1.0,  1.0),
    );

    // Camera-relative XY on the ground plane (camera is at origin in cam-relative space)
    let cam_rel_xy = corners[idx] * params.quad_half;

    // World XY = camera-relative XY + camera world XY
    let world_xy = cam_rel_xy + camera.camera_pos.xy;

    // Position in camera-relative world space (camera at origin)
    let pos = vec4<f32>(cam_rel_xy.x, cam_rel_xy.y, params.ground_z_rel, 1.0);

    var out: VertexOutput;
    out.clip_pos   = camera.view_proj * pos;
    out.world_xy   = world_xy;
    out.cam_rel_xy = cam_rel_xy;
    return out;
}

// Anti-aliased coverage of a grid line at `world_xy` for the given `spacing`.
// `half_width` controls the line radius in pixels (1.0 = 2px wide, 1.5 = 3px wide).
// Returns 1.0 on a line centre, 0.0 beyond `half_width` pixels.
fn grid_line(world_xy: vec2<f32>, spacing: f32, half_width: f32) -> f32 {
    let coord   = world_xy / spacing;
    let wrapped = abs(fract(coord - 0.5) - 0.5);  // 0 at line, 0.5 midway
    let deriv   = fwidth(coord);                    // pixel footprint in grid-space
    let dist_px = wrapped / deriv;                  // distance from line in pixels
    // clamp: coverage 1 within half_width px, linearly falls to 0 one pixel further
    return clamp(half_width - (min(dist_px.x, dist_px.y) - 0.0), 0.0, 1.0);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    // Compute all fwidth()-based coverage BEFORE any discard.
    // fwidth() uses quad-group derivatives — calling it after a non-uniform
    // discard forces the HLSL compiler into an expensive derivative-safe path.
    let hw = params.line_width;
    let fine   = grid_line(in.world_xy, params.grid_scale,        hw);
    let coarse = grid_line(in.world_xy, params.grid_scale * 10.0, hw);

    // Fade by horizontal distance from camera
    let dist = length(in.cam_rel_xy);
    let fade = 1.0 - smoothstep(params.fade_start, params.fade_end, dist);

    // Same alpha multiplier for both fine and coarse so all lines appear the same thickness
    let alpha = max(fine, coarse) * fade;

    if alpha < 0.005 { discard; }
    return vec4<f32>(params.color_r, params.color_g, params.color_b, alpha);
}
