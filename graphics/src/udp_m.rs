// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

//! Unified UDP receiver module for physics and controller state
//!
//! This module provides a configurable UDP receiver that can parse packets
//! of any structure based on a JSON-defined order array.

use std::collections::HashMap;
use std::net::UdpSocket;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Duration;
use arc_swap::ArcSwap;
use byteorder::{LittleEndian, ReadBytesExt};
use nalgebra::Vector3;
use tracing::{error, warn};
use crate::config_m::Precision;

// ============================================================================
// Generic Configurable UDP Receiver
// ============================================================================

/// Configuration for a UDP packet parser
#[derive(Clone, Debug)]
pub struct UdpPacketConfig {
    /// Order of fields in the UDP packet. Each string is a keyword.
    /// Use "skipthis" to skip a value.
    pub order: Vec<String>,
    /// Precision: "single" (f32, 4 bytes) or "double" (f64, 8 bytes)
    pub is_double: bool,
}

impl UdpPacketConfig {
    pub fn new(order: Vec<String>, precision: Precision) -> Self {
        Self {
            order,
            is_double: precision.is_double(),
        }
    }

    /// Get bytes per value based on precision
    pub fn bytes_per_value(&self) -> usize {
        if self.is_double { 8 } else { 4 }
    }

    /// Get expected packet size in bytes
    pub fn expected_packet_size(&self) -> usize {
        self.order.len() * self.bytes_per_value()
    }
}

/// Generic UDP receiver that parses packets based on configuration.
/// Uses lock-free ArcSwap so the render thread never blocks on the UDP thread.
pub struct ConfigurableUdpReceiver {
    running: Arc<AtomicBool>,
    state: Arc<ArcSwap<HashMap<String, f64>>>,
    thread: Option<JoinHandle<()>>,
}

impl ConfigurableUdpReceiver {
    /// Create and start a new configurable UDP receiver
    pub fn new(port: u16, config: UdpPacketConfig, default_values: HashMap<String, f64>) -> Self {
        let running = Arc::new(AtomicBool::new(true));
        let state = Arc::new(ArcSwap::from_pointee(default_values));

        let running_clone = Arc::clone(&running);
        let state_clone = Arc::clone(&state);

        let order = config.order.clone();
        let is_double = config.is_double;
        let expected_bytes = config.expected_packet_size();

        let handle = thread::spawn(move || {
            let socket = match UdpSocket::bind(format!("0.0.0.0:{}", port)) {
                Ok(s) => s,
                Err(e) => {
                    error!(port = port, error = %e, "Failed to bind UDP socket");
                    return;
                }
            };

            if let Err(e) = socket.set_nonblocking(true) {
                error!(port = port, error = %e, "Failed to set UDP socket to non-blocking mode");
                return;
            }

            let mut buf = [0u8; crate::constants_m::UDP_RECV_BUFFER_SIZE];
            let mut wrong_size_count: u64 = 0;
            let mut recv_error_count: u64 = 0;
            // Pre-allocate parse buffer — reused every packet to avoid per-packet HashMap allocation
            let mut values: HashMap<String, f64> = HashMap::with_capacity(order.len());

            while running_clone.load(Ordering::SeqCst) {
                // Drain all pending packets, keep last
                let mut last_len = 0usize;
                loop {
                    match socket.recv(&mut buf) {
                        Ok(len) if len == expected_bytes => {
                            last_len = len;
                        }
                        Ok(len) => {
                            wrong_size_count += 1;
                            if wrong_size_count <= 5 || wrong_size_count.is_multiple_of(100) {
                                if len == expected_bytes * 2 {
                                    // Exactly 2x: the sender is double-precision (f64) while this
                                    // receiver's config expects single (f32), or vice-versa. Previously
                                    // `len >= expected_bytes` let this through and it parsed as garbage
                                    // with no diagnostic. Fix `is_double` in the packet config.
                                    warn!(
                                        port = port,
                                        received = len,
                                        expected = expected_bytes,
                                        total_bad = wrong_size_count,
                                        "UDP packet is exactly 2x expected — precision mismatch (double sender vs single config, or vice-versa); dropped"
                                    );
                                } else {
                                    warn!(
                                        port = port,
                                        received = len,
                                        expected = expected_bytes,
                                        total_bad = wrong_size_count,
                                        "UDP packet wrong size (dropped)"
                                    );
                                }
                            }
                        }
                        Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                            break; // No more data available — normal for non-blocking
                        }
                        Err(e) => {
                            recv_error_count += 1;
                            if recv_error_count <= 5 || recv_error_count.is_multiple_of(100) {
                                warn!(
                                    port = port,
                                    error = %e,
                                    total_errors = recv_error_count,
                                    "UDP receive error"
                                );
                            }
                            break;
                        }
                    }
                }

                // Parse packet based on config order
                if last_len > 0 {
                    let mut cursor = std::io::Cursor::new(&buf[..last_len]);
                    values.clear();

                    let mut parse_ok = true;
                    for item in &order {
                        let value = if is_double {
                            match cursor.read_f64::<LittleEndian>() {
                                Ok(v) => v,
                                Err(e) => {
                                    if parse_ok {
                                        warn!(port = port, field = %item, error = %e, "UDP packet parse error, remaining fields will use defaults");
                                        parse_ok = false;
                                    }
                                    0.0
                                }
                            }
                        } else {
                            match cursor.read_f32::<LittleEndian>() {
                                Ok(v) => v as f64,
                                Err(e) => {
                                    if parse_ok {
                                        warn!(port = port, field = %item, error = %e, "UDP packet parse error, remaining fields will use defaults");
                                        parse_ok = false;
                                    }
                                    0.0
                                }
                            }
                        };

                        if item != "skipthis" {
                            values.insert(item.clone(), value);
                        }
                    }

                    state_clone.store(Arc::new(values.clone()));
                }

                thread::sleep(Duration::from_millis(crate::constants_m::UDP_POLL_INTERVAL_MS));
            }
        });

        Self {
            running,
            state,
            thread: Some(handle),
        }
    }

    /// Get the latest state as a HashMap (lock-free atomic load)
    pub fn latest_state(&self) -> Arc<HashMap<String, f64>> {
        self.state.load_full()
    }
}

impl Drop for ConfigurableUdpReceiver {
    fn drop(&mut self) {
        self.running.store(false, Ordering::SeqCst);
        if let Some(handle) = self.thread.take() {
            handle.join().ok();
        }
    }
}

// ============================================================================
// Physics State Receiver (using ConfigurableUdpReceiver)
// ============================================================================

/// Control surface positions as a dynamic HashMap
/// Keys are control surface names (e.g., "da", "de", "dr", "thr")
pub type ControlSurfaces = HashMap<String, f32>;

/// Complete physics state received from simulation
#[derive(Clone, Debug)]
pub struct PhysicsState {
    pub velocity: Vector3<f64>,
    pub position: Vector3<f64>,
    pub quaternion: [f64; 4],
    pub control_surfaces: ControlSurfaces,
}

impl Default for PhysicsState {
    fn default() -> Self {
        Self {
            velocity: Vector3::zeros(),
            position: Vector3::zeros(),
            quaternion: [1.0, 0.0, 0.0, 0.0],
            control_surfaces: HashMap::new(),
        }
    }
}

/// Receives vehicle pose from physics engine via UDP
/// Uses the configurable receiver internally
pub struct UdpStateReceiver {
    receiver: ConfigurableUdpReceiver,
    default_state: PhysicsState,
    control_surface_names: Vec<String>,
}

impl UdpStateReceiver {
    /// Create a new physics state receiver
    ///
    /// # Arguments
    /// * `port` - UDP port to listen on
    /// * `order` - Order of fields in the packet (keywords: ub, vb, wb, xf, yf, zf, e0, ex, ey, ez, control surface names, skipthis)
    /// * `precision` - "single" (f32) or "double" (f64)
    /// * `default_vel` - Default velocity when no data received
    /// * `default_pos` - Default position when no data received
    /// * `default_quat` - Default quaternion when no data received
    /// * `control_surface_names` - List of control surface names to extract (e.g., ["da", "de", "dr", "thr"])
    pub fn new(
        port: u16,
        order: Vec<String>,
        precision: Precision,
        default_vel: Vector3<f64>,
        default_pos: Vector3<f64>,
        default_quat: [f64; 4],
        control_surface_names: Vec<String>,
    ) -> Self {
        // Build default values HashMap
        let mut default_values = HashMap::new();
        default_values.insert("ub".to_string(), default_vel.x);
        default_values.insert("vb".to_string(), default_vel.y);
        default_values.insert("wb".to_string(), default_vel.z);
        default_values.insert("xf".to_string(), default_pos.x);
        default_values.insert("yf".to_string(), default_pos.y);
        default_values.insert("zf".to_string(), default_pos.z);
        default_values.insert("e0".to_string(), default_quat[0]);
        default_values.insert("ex".to_string(), default_quat[1]);
        default_values.insert("ey".to_string(), default_quat[2]);
        default_values.insert("ez".to_string(), default_quat[3]);

        // Add default 0.0 for control surfaces
        for name in &control_surface_names {
            default_values.insert(name.clone(), 0.0);
        }

        let config = UdpPacketConfig::new(order, precision);
        let receiver = ConfigurableUdpReceiver::new(port, config, default_values);

        let default_state = PhysicsState {
            velocity: default_vel,
            position: default_pos,
            quaternion: default_quat,
            control_surfaces: HashMap::new(),
        };

        Self {
            receiver,
            default_state,
            control_surface_names,
        }
    }

    /// Get the latest physics state including control surfaces
    pub fn latest_state(&self) -> PhysicsState {
        let values = self.receiver.latest_state();

        // Extract physics state from HashMap
        let velocity = Vector3::new(
            *values.get("ub").unwrap_or(&self.default_state.velocity.x),
            *values.get("vb").unwrap_or(&self.default_state.velocity.y),
            *values.get("wb").unwrap_or(&self.default_state.velocity.z),
        );

        let position = Vector3::new(
            *values.get("xf").unwrap_or(&self.default_state.position.x),
            *values.get("yf").unwrap_or(&self.default_state.position.y),
            *values.get("zf").unwrap_or(&self.default_state.position.z),
        );

        let quaternion = [
            *values.get("e0").unwrap_or(&self.default_state.quaternion[0]),
            *values.get("ex").unwrap_or(&self.default_state.quaternion[1]),
            *values.get("ey").unwrap_or(&self.default_state.quaternion[2]),
            *values.get("ez").unwrap_or(&self.default_state.quaternion[3]),
        ];
        // Renormalize: downstream quat_to_matrix / quat_to_euler assume a unit quaternion. A packet
        // can carry a slightly off-norm quaternion (or a degenerate all-zero one before the physics
        // sends real data); fall back to identity if the norm is ~0 to avoid NaNs.
        let qnorm = (quaternion[0] * quaternion[0]
            + quaternion[1] * quaternion[1]
            + quaternion[2] * quaternion[2]
            + quaternion[3] * quaternion[3])
            .sqrt();
        let quaternion = if qnorm > 1.0e-6 {
            [
                quaternion[0] / qnorm,
                quaternion[1] / qnorm,
                quaternion[2] / qnorm,
                quaternion[3] / qnorm,
            ]
        } else {
            self.default_state.quaternion
        };

        // Extract control surfaces
        let mut control_surfaces = HashMap::new();
        for name in &self.control_surface_names {
            if let Some(&value) = values.get(name) {
                control_surfaces.insert(name.clone(), value as f32);
            }
        }

        PhysicsState {
            velocity,
            position,
            quaternion,
            control_surfaces,
        }
    }
}

use crate::config_m::ControllerStatusConfig;
use std::collections::HashSet;

// ============================================================================
// Controller State Receiver (using ConfigurableUdpReceiver)
// ============================================================================

/// Dynamic controller state based on config
#[derive(Clone, Debug, Default)]
pub struct ControllerState {
    /// Enable flags for each controller (keyed by controller name)
    pub enables: HashMap<String, bool>,
    /// Command values for cmd-type controllers (keyed by controller name)
    pub values: HashMap<String, f64>,
}

/// Receives controller/autopilot state for HUD display
/// Uses the configurable receiver internally
pub struct ControllerStateReceiver {
    receiver: ConfigurableUdpReceiver,
    cmd_set: HashSet<String>,
    bool_set: HashSet<String>,
}

impl ControllerStateReceiver {
    pub fn new(port: u16, config: &ControllerStatusConfig) -> Self {
        let cmd_set: HashSet<String> = config.cmd.iter().cloned().collect();
        let bool_set: HashSet<String> = config.bool_controllers.iter().cloned().collect();

        let packet_config = UdpPacketConfig::new(
            config.order.clone(),
            config.precision,
        );

        // Default values are all 0.0
        let default_values = HashMap::new();

        let receiver = ConfigurableUdpReceiver::new(port, packet_config, default_values);

        Self {
            receiver,
            cmd_set,
            bool_set,
        }
    }

    pub fn latest_state(&self) -> ControllerState {
        let values = self.receiver.latest_state();

        let mut enables = HashMap::new();
        let mut cmd_values = HashMap::new();

        for (key, value) in values.as_ref() {
            // Check if this is an enable flag (controller name in cmd or bool)
            if self.cmd_set.contains(key) || self.bool_set.contains(key) {
                enables.insert(key.clone(), *value > 0.5);
            }
            // Check if this is a _cmd value
            else if key.ends_with("_cmd") {
                let base_name = &key[..key.len() - 4];
                if self.cmd_set.contains(base_name) {
                    cmd_values.insert(base_name.to_string(), *value);
                }
            }
        }

        ControllerState {
            enables,
            values: cmd_values,
        }
    }
}