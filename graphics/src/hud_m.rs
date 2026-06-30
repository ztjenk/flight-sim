// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

use egui::{Color32, Context, Pos2, Rect, Stroke, Align2, FontId, Vec2, CornerRadius};
use std::time::Instant;

use crate::config_m::ControllerStatusConfig;
use crate::constants_m::{
    HUD_DEFAULT_FONT_SIZE, HUD_DEFAULT_OPACITY, HUD_UPDATE_INTERVAL_SECS,
    HUD_TAPE_HALF_HEIGHT, HUD_SPEED_TAPE_X_OFFSET, HUD_ALT_TAPE_X_OFFSET,
    HUD_HEADING_Y_OFFSET, HUD_SPEED_TAPE_RANGE, HUD_SPEED_TAPE_TICK_STEP,
    HUD_ALT_TAPE_RANGE, HUD_ALT_TAPE_TICK_STEP, HUD_HEADING_VISIBLE_RANGE,
    HUD_HEADING_CARDINAL_STEP, HUD_ATTITUDE_PX_PER_DEG, HUD_PITCH_LADDER_STEP,
    HUD_PITCH_LADDER_HALF_RANGE, HUD_FPV_RETICLE_RADIUS, HUD_FPV_WING_LENGTH,
    HUD_FPV_TAIL_LENGTH, HUD_CONTROLLER_STATUS_WIDTH,
};
use crate::udp_m::ControllerState;

// configuration for HUD appearance
pub struct HudConfig {
    pub enable: bool,
    pub color: Color32,
    pub opacity: f32,
    pub font_size: f32,
    pub show_speed: bool,
    pub show_altitude: bool,
    pub show_heading: bool,
    pub show_pitch_roll: bool,
    pub show_controller_status: bool,
    pub controller_status_config: Option<ControllerStatusConfig>,
}

impl Default for HudConfig {
    fn default() -> Self {
        Self {
            enable: true,
            color: Color32::from_rgb(0, 255, 0),
            opacity: HUD_DEFAULT_OPACITY,
            font_size: HUD_DEFAULT_FONT_SIZE,
            show_speed: true,
            show_altitude: true,
            show_heading: true,
            show_pitch_roll: true,
            show_controller_status: true,
            controller_status_config: None,
        }
    }
}

/// Convert [f32; 4] RGBA (0.0-1.0) to egui Color32
pub fn color_to_color32(rgba: [f32; 4]) -> Color32 {
    Color32::from_rgba_unmultiplied(
        (rgba[0] * 255.0) as u8,
        (rgba[1] * 255.0) as u8,
        (rgba[2] * 255.0) as u8,
        (rgba[3] * 255.0) as u8,
    )
}

// current flight state to display on HUD
#[derive(Clone, Copy)]
pub struct HudState {
    pub velocity_magnitude: f32,
    pub altitude: f32,        // MSL altitude in feet
    pub agl: Option<f32>,     // above ground level in feet (None if terrain unavailable)
    pub mach: f32,
    pub heading_deg: f32,     // vehicle heading for heading tape
    pub camera_roll_deg: f32, // camera roll relative to horizon (for pitch ladder tilt)
    pub camera_pitch_deg: f32,// camera pitch above horizon (for pitch ladder position)
    pub nose_offset_deg: [f32; 2],  // [x, y] offset of nose from screen center in degrees
    pub fpv_offset_deg: [f32; 2],   // [x, y] offset of FPV from screen center in degrees
}

// cached layout positions to avoid recomputation each frame
struct HudLayoutCache {
    screen_center_x: f32,
    mid_y: f32,
    speed_tape_x: f32,
    altitude_tape_x: f32,
    heading_y: f32,
    mach_y: f32,
    agl_y: f32,
}

impl HudLayoutCache {
    fn new(screen_rect: Rect) -> Self {
        let mid_y = screen_rect.center().y;
        let tape_half_height = HUD_TAPE_HALF_HEIGHT;
        Self {
            screen_center_x: screen_rect.center().x,
            mid_y,
            speed_tape_x: screen_rect.left() + HUD_SPEED_TAPE_X_OFFSET,
            altitude_tape_x: screen_rect.right() - HUD_ALT_TAPE_X_OFFSET,
            heading_y: screen_rect.bottom() - HUD_HEADING_Y_OFFSET,
            mach_y: mid_y + tape_half_height + 20.0,
            agl_y: mid_y + tape_half_height + 20.0,
        }
    }

    fn needs_update(&self, screen_rect: Rect) -> bool {
        (self.screen_center_x - screen_rect.center().x).abs() > 0.5 ||
        (self.mid_y - screen_rect.center().y).abs() > 0.5
    }
}

// HUD renderer with 30 FPS update throttling
pub struct Hud {
    config: HudConfig,
    layout_cache: Option<HudLayoutCache>,
    last_update: Instant,
    frame_interval: f64,
    cached_state: Option<HudState>,
    cached_controller: Option<ControllerState>,
}

impl Hud {
    pub fn new(config: HudConfig) -> Self {
        Self {
            config,
            layout_cache: None,
            last_update: Instant::now(),
            frame_interval: HUD_UPDATE_INTERVAL_SECS,
            cached_state: None,
            cached_controller: None,
        }
    }

    pub fn draw(&mut self, ctx: &Context, state: &HudState, controller: Option<&ControllerState>) {
        if !self.config.enable {
            return;
        }

        // throttle state updates to 30 FPS, but always render
        let now = Instant::now();
        let elapsed = now.duration_since(self.last_update).as_secs_f64();
        if elapsed >= self.frame_interval {
            self.cached_state = Some(*state);
            self.cached_controller = controller.cloned();
            self.last_update = now;
        }

        let render_state = self.cached_state.as_ref().unwrap_or(state);
        let render_controller = self.cached_controller.as_ref().or(controller);
        let screen_rect = ctx.content_rect();

        // update layout cache on window resize
        if self.layout_cache.as_ref().is_none_or(|c| c.needs_update(screen_rect)) {
            self.layout_cache = Some(HudLayoutCache::new(screen_rect));
        }
        // Safe: layout_cache was just set above if it was None
        let layout = self.layout_cache.as_ref()
            .expect("layout_cache must exist after initialization above");

        let color = self.apply_opacity(self.config.color, self.config.opacity);
        let font_id = FontId::proportional(self.config.font_size);

        // speed tape (left side)
        if self.config.show_speed {
            self.draw_vertical_tape(
                ctx,
                Pos2::new(layout.screen_center_x, layout.mid_y),
                render_state.velocity_magnitude,
                color,
                font_id.clone(),
                layout.speed_tape_x,
                HUD_SPEED_TAPE_RANGE,      // range
                HUD_SPEED_TAPE_TICK_STEP,  // tick_step
                45.0,       // box_offset
                false,      // left aligned
            );
        }

        // altitude tape (right side)
        if self.config.show_altitude {
            self.draw_vertical_tape(
                ctx,
                Pos2::new(layout.screen_center_x, layout.mid_y),
                render_state.altitude,
                color,
                font_id.clone(),
                layout.altitude_tape_x,
                HUD_ALT_TAPE_RANGE,
                HUD_ALT_TAPE_TICK_STEP,
                45.0,
                true,       // right aligned
            );

            // AGL display below altitude tape
            if let Some(agl) = render_state.agl {
                self.draw_labeled_value(
                    ctx,
                    layout.altitude_tape_x,
                    layout.agl_y,
                    "AGL",
                    agl,
                    0,
                    color,
                );
            }
        }

        // mach display below speed tape
        if self.config.show_speed {
            self.draw_labeled_value(
                ctx,
                layout.speed_tape_x,
                layout.mach_y,
                "M",
                render_state.mach,
                2,
                color,
            );
        }

        // heading tape (bottom center)
        if self.config.show_heading {
            let heading = self.normalize_angle(render_state.heading_deg);
            self.draw_heading_tape(ctx, layout.screen_center_x, layout.heading_y, heading, color, font_id.clone());
        }

        // pitch ladder and attitude indicator (center)
        if self.config.show_pitch_roll {
            let center = Pos2::new(layout.screen_center_x, layout.mid_y);
            self.draw_attitude_indicator(
                ctx,
                center,
                render_state.camera_roll_deg,
                render_state.camera_pitch_deg,
                render_state.nose_offset_deg,
                render_state.fpv_offset_deg,
                color,
            );
        }

        // controller status (top left)
        if self.config.show_controller_status {
            if let Some(ctrl) = render_controller {
                self.draw_controller_status(ctx, screen_rect.left() + 5.0, screen_rect.top() + 5.0, ctrl, color);
            }
        }
    }

    fn apply_opacity(&self, color: Color32, opacity: f32) -> Color32 {
        let [r, g, b, _] = color.to_array();
        Color32::from_rgba_premultiplied(r, g, b, (opacity * 255.0) as u8)
    }

    fn normalize_angle(&self, deg: f32) -> f32 {
        let mut normalized = deg % 360.0;
        if normalized < 0.0 {
            normalized += 360.0;
        }
        normalized
    }

    // draw a labeled value box (e.g., "R 1234" for AGL, "M 0.85" for mach)
    #[allow(clippy::too_many_arguments)]
    fn draw_labeled_value(
        &self,
        ctx: &Context,
        x: f32,
        y: f32,
        label: &str,
        value: f32,
        decimals: usize,
        color: Color32,
    ) {
        let painter = ctx.layer_painter(egui::LayerId::new(
            egui::Order::Foreground,
            egui::Id::new("hud_labeled_value"),
        ));

        let font_label = FontId::proportional(self.config.font_size * 0.9);
        let font_value = FontId::proportional(self.config.font_size * 1.1);

        let value_str = if decimals == 0 {
            format!("{:.0}", value)
        } else {
            format!("{:.1$}", value, decimals)
        };

        // Dynamic box width based on value string length
        let base_width = 70.0;  // space for label + padding
        let char_width = 10.0;  // approximate width per character
        let box_width = base_width + (value_str.len() as f32 * char_width);
        let box_height = 32.0;

        let box_x = x - box_width / 2.0;
        let bg_rect = Rect::from_min_size(
            Pos2::new(box_x, y),
            Vec2::new(box_width, box_height),
        );

        painter.rect_filled(bg_rect, CornerRadius::same(6), Color32::from_black_alpha(200));

        let center_y = y + box_height / 2.0;
        let label_x = box_x + 12.0;
        let value_x = box_x + box_width - 8.0;

        painter.text(
            Pos2::new(label_x, center_y),
            Align2::LEFT_CENTER,
            label,
            font_label,
            color,
        );

        painter.text(
            Pos2::new(value_x, center_y),
            Align2::RIGHT_CENTER,
            value_str,
            font_value,
            color,
        );
    }

    fn draw_controller_status(
        &self,
        ctx: &Context,
        x: f32,
        y: f32,
        ctrl: &ControllerState,
        color: Color32,
    ) {
        let config = match &self.config.controller_status_config {
            Some(cfg) => cfg,
            None => return, // No config, nothing to draw
        };

        let painter = ctx.layer_painter(egui::LayerId::new(
            egui::Order::Foreground,
            egui::Id::new("hud_controller_status"),
        ));
        let font_small = FontId::proportional(self.config.font_size * 0.85);
        let line_height = self.config.font_size * 1.3;

        // Calculate number of display rows (cmd + bool controllers)
        let num_rows = config.cmd.len() + config.bool_controllers.len();
        let box_width = HUD_CONTROLLER_STATUS_WIDTH;
        let box_height = line_height * (num_rows as f32 + 1.5);

        let bg_rect = Rect::from_min_size(
            Pos2::new(x, y),
            Vec2::new(box_width, box_height),
        );
        painter.rect_filled(bg_rect, CornerRadius::same(6), Color32::from_black_alpha(200));

        let text_x = x + 8.0;
        let value_x = x + box_width - 8.0;
        let mut current_y = y + line_height * 0.8;

        painter.text(
            Pos2::new(x + box_width / 2.0, current_y),
            Align2::CENTER_CENTER,
            "CONTROLLER STATUS",
            FontId::proportional(self.config.font_size * 0.9),
            color,
        );
        current_y += line_height * 1.2;

        // Build display order: cmd controllers first, then bool controllers
        // (maintaining the order they appear in the config lists)
        let mut display_order: Vec<&str> = Vec::new();
        for name in &config.cmd {
            display_order.push(name);
        }
        for name in &config.bool_controllers {
            display_order.push(name);
        }

        for name in display_order {
            let enabled = ctrl.enables.get(name).copied().unwrap_or(false);
            let status_color = if enabled {
                Color32::from_rgb(0, 255, 0)
            } else {
                Color32::from_rgb(128, 128, 128)
            };

            // Draw label
            painter.text(
                Pos2::new(text_x, current_y),
                Align2::LEFT_CENTER,
                format!("{}:", name),
                font_small.clone(),
                color,
            );

            // Draw value or status
            let value_str = if config.is_cmd(name) {
                // Command type: show value with unit or OFF
                if enabled {
                    let raw_value = ctrl.values.get(name).copied().unwrap_or(0.0);
                    let conversion = config.get_conversion_factor(name).unwrap_or(1.0);
                    let display_value = raw_value * conversion;
                    let unit = config.get_display_unit(name).unwrap_or("");
                    format!("{:+6.1} {}", display_value, unit)
                } else {
                    "OFF".to_string()
                }
            } else {
                // Boolean type: show ON or OFF
                if enabled { "ON".to_string() } else { "OFF".to_string() }
            };

            painter.text(
                Pos2::new(value_x, current_y),
                Align2::RIGHT_CENTER,
                value_str,
                font_small.clone(),
                status_color,
            );

            current_y += line_height;
        }
    }

    // convert heading degrees to cardinal direction label
    fn heading_to_cardinal(deg: f32) -> Option<&'static str> {
        let normalized = ((deg % 360.0) + 360.0) % 360.0;
        let rounded = (normalized + 0.5) as i32;
        match rounded {
            0 | 360 => Some("N"),
            45 => Some("NE"),
            90 => Some("E"),
            135 => Some("SE"),
            180 => Some("S"),
            225 => Some("SW"),
            270 => Some("W"),
            315 => Some("NW"),
            _ => None,
        }
    }

    fn draw_heading_tape(
        &self,
        ctx: &Context,
        center_x: f32,
        y: f32,
        heading_deg: f32,
        color: Color32,
        _font: FontId,
    ) {
        let painter = ctx.layer_painter(egui::LayerId::new(
            egui::Order::Foreground,
            egui::Id::new("hud_heading"),
        ));

        let tape_width = 200.0;
        let tape_height = 36.0;
        let visible_deg = HUD_HEADING_VISIBLE_RANGE;  // 180° range so W and E show when flying N
        let pixels_per_degree = tape_width / visible_deg;

        let bg_rect = Rect::from_min_size(
            Pos2::new(center_x - tape_width / 2.0, y),
            Vec2::new(tape_width, tape_height),
        );
        painter.rect_filled(bg_rect, CornerRadius::same(5), Color32::from_black_alpha(210));

        let left_edge = bg_rect.left();
        let right_edge = bg_rect.right();
        let top_edge = y + 4.0;

        // center tick (current heading indicator)
        painter.line_segment(
            [Pos2::new(center_x, top_edge), Pos2::new(center_x, y + tape_height - 3.0)],
            Stroke::new(3.0, color),
        );

        // cardinal directions at 45° intervals
        let cardinal_step = HUD_HEADING_CARDINAL_STEP;
        let half_range = visible_deg / 2.0 + 50.0;
        let mut current = ((heading_deg - half_range) / cardinal_step).floor() * cardinal_step;

        loop {
            if current > heading_deg + half_range {
                break;
            }

            let offset_deg = current - heading_deg;
            let x = center_x + offset_deg * pixels_per_degree;

            // clip to box bounds
            if x < left_edge - 5.0 || x > right_edge + 5.0 {
                current += cardinal_step;
                continue;
            }

            let normalized = self.normalize_angle(current);
            let is_center = (current - heading_deg).abs() < 0.3;

            let tick_bottom = if is_center { y + tape_height - 3.0 } else { y + 14.0 };

            if !is_center {
                painter.line_segment(
                    [Pos2::new(x, top_edge), Pos2::new(x, tick_bottom)],
                    Stroke::new(2.0, color),
                );
            }

            if !is_center {
                if let Some(label) = Self::heading_to_cardinal(normalized) {
                    painter.text(
                        Pos2::new(x, y + 15.0),
                        Align2::CENTER_TOP,
                        label,
                        FontId::proportional(self.config.font_size * 0.75),
                        color,
                    );
                }
            }

            current += cardinal_step;
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn draw_attitude_indicator(
        &self,
        ctx: &Context,
        center: Pos2,
        roll_deg: f32,
        pitch_deg: f32,
        nose_offset_deg: [f32; 2],
        fpv_offset_deg: [f32; 2],
        color: Color32,
    ) {
        let max_radius = 280.0;
        let pixels_per_degree = HUD_ATTITUDE_PX_PER_DEG;

        self.draw_pitch_ladder(ctx, center, roll_deg, pitch_deg, color, pixels_per_degree, max_radius);

        let painter = ctx.layer_painter(egui::LayerId::new(
            egui::Order::Foreground,
            egui::Id::new("hud_aircraft_symbol"),
        ));

        // aircraft symbol (yellow) - offset from screen center by nose direction relative to camera
        let nose_center = Pos2::new(
            center.x + nose_offset_deg[0] * pixels_per_degree,
            center.y + nose_offset_deg[1] * pixels_per_degree,
        );
        let wing_width = 40.0;
        painter.line_segment(
            [
                Pos2::new(nose_center.x - wing_width, nose_center.y),
                Pos2::new(nose_center.x - 10.0, nose_center.y),
            ],
            Stroke::new(3.0, Color32::from_rgb(255, 255, 0)),
        );
        painter.line_segment(
            [
                Pos2::new(nose_center.x + 10.0, nose_center.y),
                Pos2::new(nose_center.x + wing_width, nose_center.y),
            ],
            Stroke::new(3.0, Color32::from_rgb(255, 255, 0)),
        );
        painter.circle_filled(nose_center, 5.0, Color32::from_rgb(255, 255, 0));

        // flight path vector (FPV) - offset from screen center by velocity direction relative to camera
        let fpv_center = Pos2::new(
            center.x + fpv_offset_deg[0] * pixels_per_degree,
            center.y + fpv_offset_deg[1] * pixels_per_degree,
        );

        let fpv_color = Color32::from_rgb(0, 255, 180);
        let fpv_radius = HUD_FPV_RETICLE_RADIUS;
        let fpv_wing = HUD_FPV_WING_LENGTH;
        let fpv_tail = HUD_FPV_TAIL_LENGTH;

        // FPV symbol: circle with wings and tail
        painter.circle_stroke(fpv_center, fpv_radius, Stroke::new(2.5, fpv_color));

        painter.line_segment(
            [
                Pos2::new(fpv_center.x - fpv_radius, fpv_center.y),
                Pos2::new(fpv_center.x - fpv_radius - fpv_wing, fpv_center.y),
            ],
            Stroke::new(2.5, fpv_color),
        );

        painter.line_segment(
            [
                Pos2::new(fpv_center.x + fpv_radius, fpv_center.y),
                Pos2::new(fpv_center.x + fpv_radius + fpv_wing, fpv_center.y),
            ],
            Stroke::new(2.5, fpv_color),
        );

        painter.line_segment(
            [
                Pos2::new(fpv_center.x, fpv_center.y - fpv_radius),
                Pos2::new(fpv_center.x, fpv_center.y - fpv_radius - fpv_tail),
            ],
            Stroke::new(2.5, fpv_color),
        );
    }

    #[allow(clippy::too_many_arguments)]
    fn draw_pitch_ladder(
        &self,
        ctx: &Context,
        center: Pos2,
        roll_deg: f32,
        pitch_deg: f32,
        color: Color32,
        pixels_per_degree: f32,
        max_radius: f32,
    ) {
        let painter = ctx.layer_painter(egui::LayerId::new(
            egui::Order::Foreground,
            egui::Id::new("hud_pitch_ladder"),
        ));

        let roll_rad = (-roll_deg).to_radians();
        let cos_roll = roll_rad.cos();
        let sin_roll = roll_rad.sin();

        // pitch lines every 10 degrees
        let tick_step_deg = HUD_PITCH_LADDER_STEP;
        let half_range_deg = HUD_PITCH_LADDER_HALF_RANGE;
        let min_pitch = pitch_deg - half_range_deg;
        let max_pitch = pitch_deg + half_range_deg;
        let first_tick = (min_pitch / tick_step_deg).ceil() * tick_step_deg;

        let mut current_pitch = first_tick;
        loop {
            if current_pitch > max_pitch + tick_step_deg {
                break;
            }

            if current_pitch.abs() > 150.0 {
                current_pitch += tick_step_deg;
                continue;
            }

            let pitch_offset_deg = -current_pitch + pitch_deg;
            let pitch_offset_pixels = pitch_offset_deg * pixels_per_degree;

            // rotate offset by roll angle
            let dx = -pitch_offset_pixels * sin_roll;
            let dy = pitch_offset_pixels * cos_roll;

            let line_center = Pos2::new(center.x + dx, center.y + dy);

            // cull lines outside max radius
            let dist = (dx * dx + dy * dy).sqrt();
            if dist > max_radius {
                current_pitch += tick_step_deg;
                continue;
            }

            // horizon line is longer and thicker
            let half_length = if current_pitch == 0.0 { 100.0 } else { 70.0 };

            let line_start = Pos2::new(
                line_center.x + half_length * cos_roll,
                line_center.y + half_length * sin_roll,
            );
            let line_end = Pos2::new(
                line_center.x - half_length * cos_roll,
                line_center.y - half_length * sin_roll,
            );

            let stroke = if current_pitch == 0.0 {
                Stroke::new(3.0, color)
            } else if current_pitch.abs() % 20.0 == 0.0 {
                Stroke::new(2.0, color)
            } else {
                Stroke::new(1.5, color)
            };

            painter.line_segment([line_start, line_end], stroke);

            // pitch labels (except for horizon)
            if current_pitch != 0.0 {
                let label = format!("{:+.0}", current_pitch as i32);
                let label_offset = 90.0;

                let label_pos = Pos2::new(
                    line_center.x - label_offset * cos_roll,
                    line_center.y - label_offset * sin_roll,
                );

                painter.text(
                    label_pos,
                    Align2::CENTER_CENTER,
                    label,
                    FontId::proportional(self.config.font_size * 1.1),
                    color,
                );
            }

            current_pitch += tick_step_deg;
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn draw_vertical_tape(
        &self,
        ctx: &Context,
        center: Pos2,
        value: f32,
        color: Color32,
        font: FontId,
        x: f32,
        range: f32,
        tick_step: f32,
        box_offset: f32,
        right_align: bool,
    ) {
        let painter = ctx.layer_painter(egui::LayerId::new(
            egui::Order::Foreground,
            egui::Id::new("hud_vertical_tape"),
        ));

        let galley = painter.layout_no_wrap(
            format!("{:.0}", value),
            font.clone(),
            color,
        );
        let text_width = galley.rect.width();
        let tape_width = text_width + 85.0;
        let tape_height = 300.0;
        let half_h = tape_height / 2.0;

        let bg_rect = Rect::from_min_size(
            Pos2::new(x - tape_width * 0.5, center.y - half_h),
            Vec2::new(tape_width, tape_height),
        );
        painter.rect_filled(bg_rect, CornerRadius::same(8), Color32::from_black_alpha(200));

        let top = bg_rect.top();
        let bottom = bg_rect.bottom();

        // current value tick
        let tick_len = 22.0;
        let cx0 = if right_align { bg_rect.left() + 6.0 } else { bg_rect.right() - 6.0 };
        let cx1 = if right_align { cx0 + tick_len } else { cx0 - tick_len };

        painter.line_segment(
            [Pos2::new(cx0, center.y), Pos2::new(cx1, center.y)],
            Stroke::new(3.0, color),
        );

        // value readout
        let box_x = if right_align {
            cx1 + box_offset
        } else {
            cx1 - box_offset
        };

        painter.text(
            Pos2::new(box_x, center.y),
            if right_align { Align2::LEFT_CENTER } else { Align2::RIGHT_CENTER },
            format!("{:.0}", value),
            FontId::proportional(self.config.font_size * 1.2),
            color,
        );

        // tick marks and labels
        let v_min = value - range;
        let v_max = value + range;
        let first_tick = (v_min / tick_step).ceil() * tick_step;

        let mut v = first_tick;
        while v <= v_max + 0.1 {
            let offset = -(v - value) / range;
            let y = center.y + offset * half_h;

            if y >= top - 5.0 && y <= bottom + 5.0 {
                let t0 = if right_align { bg_rect.left() + 15.0 } else { bg_rect.right() - 15.0 };
                let t1 = if right_align { t0 + 12.0 } else { t0 - 12.0 };

                painter.line_segment(
                    [Pos2::new(t0, y), Pos2::new(t1, y)],
                    Stroke::new(2.0, color),
                );

                let label_gap = 8.0;
                let label_x = if right_align { t1 + label_gap } else { t1 - label_gap };

                painter.text(
                    Pos2::new(label_x, y),
                    if right_align { Align2::LEFT_CENTER } else { Align2::RIGHT_CENTER },
                    format!("{:.0}", v),
                    FontId::proportional(self.config.font_size * 0.85),
                    color,
                );
            }

            v += tick_step;
        }
    }
}


// draw a "Press Enter to Start" overlay
pub fn draw_start_overlay(ctx: &Context) {
    let screen_rect = ctx.content_rect();
    let painter = ctx.layer_painter(egui::LayerId::new(
        egui::Order::Foreground,
        egui::Id::new("start_overlay"),
    ));

    let card_width = (screen_rect.width() * 0.5).max(300.0);
    let card_height = (screen_rect.height() * 0.2).max(120.0);
    let card_rect = Rect::from_center_size(
        screen_rect.center(),
        egui::vec2(card_width, card_height),
    );

    painter.rect_filled(card_rect, CornerRadius::same(10), Color32::from_black_alpha(180));

    painter.text(
        card_rect.center() - egui::vec2(0.0, 15.0),
        Align2::CENTER_CENTER,
        "Press Enter to Start Simulation",
        FontId::proportional(24.0),
        Color32::WHITE,
    );
    painter.text(
        card_rect.center() + egui::vec2(0.0, 15.0),
        Align2::CENTER_CENTER,
        "Press Esc to End Simulation",
        FontId::proportional(24.0),
        Color32::WHITE,
    );
}