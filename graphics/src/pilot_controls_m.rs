// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

use std::net::UdpSocket;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use byteorder::{LittleEndian, WriteBytesExt};
use gilrs::{Event, EventType, Gilrs};
use tracing::{info, warn, error};

use crate::constants_m::{
    GAMEPAD_DEFAULT_RATE_HZ, GAMEPAD_DEFAULT_DEADZONE,
    GAMEPAD_TRIGGER_PRESS_THRESHOLD, GAMEPAD_TRIGGER_RELEASE_THRESHOLD,
};

const BUTTON_MAP: &[(gilrs::Button, u32)] = &[
    (gilrs::Button::South, 0),         // Cross/A
    (gilrs::Button::East, 1),          // Circle/B
    (gilrs::Button::West, 2),          // Square/X
    (gilrs::Button::North, 3),         // Triangle/Y
    (gilrs::Button::Select, 4),        // Share
    (gilrs::Button::Start, 6),         // Options
    (gilrs::Button::LeftThumb, 7),     // L3
    (gilrs::Button::RightThumb, 8),    // R3
    (gilrs::Button::LeftTrigger, 9),   // L1
    (gilrs::Button::RightTrigger, 10), // R1
    (gilrs::Button::DPadUp, 11),
    (gilrs::Button::DPadDown, 12),
    (gilrs::Button::DPadLeft, 13),
    (gilrs::Button::DPadRight, 14),
];

fn button_to_bit(btn: gilrs::Button) -> Option<u32> {
    BUTTON_MAP.iter().find(|(b, _)| *b == btn).map(|(_, bit)| *bit)
}

pub struct GamepadController {
    host: String,
    port: u16,
    rate_hz: f32,
    deadzone: f32,
    running: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl GamepadController {
    pub fn new(host: String, port: u16, rate_hz: f32) -> Self {
        Self {
            host,
            port,
            rate_hz: if rate_hz <= 0.0 { GAMEPAD_DEFAULT_RATE_HZ } else { rate_hz },
            deadzone: GAMEPAD_DEFAULT_DEADZONE,
            running: Arc::new(AtomicBool::new(false)),
            thread: None,
        }
    }

    pub fn start(&mut self) -> bool {
        if self.thread.is_some() {
            return true;
        }

        let gilrs = match Gilrs::new() {
            Ok(g) => g,
            Err(e) => {
                error!(error = %e, "Failed to initialize gamepad library");
                return false;
            }
        };

        info!(os = std::env::consts::OS, "Gamepad controller starting");
        info!(count = gilrs.gamepads().count(), "Gamepads detected");

        let host = self.host.clone();
        let port = self.port;
        let rate_hz = self.rate_hz;
        let deadzone = self.deadzone;
        let running = self.running.clone();

        // Set running flag BEFORE spawning thread to avoid race condition
        self.running.store(true, Ordering::SeqCst);

        let handle = thread::spawn(move || {
            Self::controller_loop(gilrs, host, port, rate_hz, deadzone, running);
        });

        self.thread = Some(handle);
        true
    }

    fn controller_loop(
        mut gilrs: Gilrs,
        host: String,
        port: u16,
        rate_hz: f32,
        deadzone: f32,
        running: Arc<AtomicBool>,
    ) {
        let socket = match UdpSocket::bind("0.0.0.0:0") {
            Ok(s) => s,
            Err(e) => {
                error!(error = %e, "Failed to bind UDP socket");
                return;
            }
        };

        let dt = Duration::from_secs_f32(1.0 / rate_hz);

        // State variables
        let mut throttle: f32 = 0.0;
        let mut yaw: f32 = 0.0;
        let mut pitch: f32 = 0.0;
        let mut roll: f32 = 0.0;
        let mut l2: f32 = 0.0;
        let mut r2: f32 = 0.0;
        let mut buttons_mask: u32 = 0;

        let apply_deadzone = |v: f32, dz: f32| -> f32 {
            if v.abs() < dz { 0.0 } else { v }
        };

        // Map trigger axis value to 0..1 range
        let trigger_to_01 = |v: f32, rest: f32| -> f32 {
            if rest < 0.0 {
                // Trigger goes from -1 (rest) to 1 (pressed)
                ((v + 1.0) * 0.5).clamp(0.0, 1.0)
            } else {
                // Trigger goes from 0 (rest) to 1 (pressed)
                v.clamp(0.0, 1.0)
            }
        };

        while running.load(Ordering::SeqCst) {
            let loop_start = Instant::now();

            while let Some(Event { event, .. }) = gilrs.next_event() {
                match event {
                    EventType::AxisChanged(axis, value, _code) => {
                        // Use gilrs standard axis types - these work reliably for known controllers
                        // (PS4, Xbox, etc.) because gilrs has built-in mappings for them
                        match axis {
                            gilrs::Axis::LeftStickX => {
                                yaw = apply_deadzone(value, deadzone);
                            }
                            gilrs::Axis::LeftStickY => {
                                let v = apply_deadzone(value, deadzone);
                                throttle = (v + 1.0) * 0.5;
                            }
                            gilrs::Axis::RightStickX => {
                                roll = apply_deadzone(value, deadzone);
                            }
                            gilrs::Axis::RightStickY => {
                                pitch = -apply_deadzone(value, deadzone);
                            }
                            gilrs::Axis::LeftZ => {
                                l2 = trigger_to_01(value, -1.0);
                            }
                            gilrs::Axis::RightZ => {
                                r2 = trigger_to_01(value, -1.0);
                            }
                            other => {
                                warn!(axis = ?other, value, code = ?_code, "Unmapped gamepad axis");
                            }
                        }
                    }
                    EventType::ButtonPressed(btn, _code) => {
                        if let Some(bit) = button_to_bit(btn) {
                            buttons_mask |= 1 << bit;
                        }
                        match btn {
                            gilrs::Button::LeftTrigger2 => {
                                if l2 < GAMEPAD_TRIGGER_PRESS_THRESHOLD { l2 = 1.0; }
                            }
                            gilrs::Button::RightTrigger2 => {
                                if r2 < GAMEPAD_TRIGGER_PRESS_THRESHOLD { r2 = 1.0; }
                            }
                            _ => {}
                        }
                    }
                    EventType::ButtonReleased(btn, _code) => {
                        if let Some(bit) = button_to_bit(btn) {
                            buttons_mask &= !(1 << bit);
                        }
                        match btn {
                            gilrs::Button::LeftTrigger2 => {
                                if l2 > GAMEPAD_TRIGGER_RELEASE_THRESHOLD { l2 = 0.0; }
                            }
                            gilrs::Button::RightTrigger2 => {
                                if r2 > GAMEPAD_TRIGGER_RELEASE_THRESHOLD { r2 = 0.0; }
                            }
                            _ => {}
                        }
                    }
                    _ => {}
                }
            }

            // Pack and send: <6fI> little-endian: 6 f32 + 1 u32 = 28 bytes
            let mut buf = [0u8; 28];
            let pack_ok = {
                let mut cursor = std::io::Cursor::new(&mut buf[..]);
                cursor.write_f32::<LittleEndian>(throttle)
                    .and_then(|_| cursor.write_f32::<LittleEndian>(yaw))
                    .and_then(|_| cursor.write_f32::<LittleEndian>(pitch))
                    .and_then(|_| cursor.write_f32::<LittleEndian>(roll))
                    .and_then(|_| cursor.write_f32::<LittleEndian>(l2))
                    .and_then(|_| cursor.write_f32::<LittleEndian>(r2))
                    .and_then(|_| cursor.write_u32::<LittleEndian>(buttons_mask))
                    .is_ok()
            };
            if !pack_ok {
                warn!("Failed to pack gamepad UDP packet");
                continue;
            }

            if let Err(e) = socket.send_to(&buf, (&host[..], port)) {
                error!(error = %e, "Gamepad UDP send failed");
            }

            let elapsed = loop_start.elapsed();
            if elapsed < dt {
                thread::sleep(dt - elapsed);
            }
        }
    }

    pub fn stop(&mut self) {
        self.running.store(false, Ordering::SeqCst);
        if let Some(handle) = self.thread.take() {
            let _ = handle.join();
            info!("Gamepad controller stopped");
        }
    }
}

impl Drop for GamepadController {
    fn drop(&mut self) {
        self.stop();
    }
}

