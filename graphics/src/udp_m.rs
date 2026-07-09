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
///
/// The published state is a positional `Arc<Vec<f64>>` indexed by packet slot (one slot per entry
/// in `config.order`, including `skipthis`), NOT a `HashMap<String, f64>`. A field's slot is
/// resolved once at construction via `slot_of`, so the hot path does zero per-packet allocation and
/// no string hashing — it just writes values into the reused buffer by index.
pub struct ConfigurableUdpReceiver {
    running: Arc<AtomicBool>,
    state: Arc<ArcSwap<Vec<f64>>>,
    /// Order → slot index. `order[i]` lives at slot `i`; duplicate names resolve to their first
    /// slot (validation elsewhere forbids duplicates, but first-wins is a safe fallback).
    slot_index: HashMap<String, usize>,
    thread: Option<JoinHandle<()>>,
}

impl ConfigurableUdpReceiver {
    /// Create and start a new configurable UDP receiver.
    ///
    /// `default_values` are keyed by field name; they are baked into the positional default vector
    /// (slots for unlisted / `skipthis` fields default to 0.0), so the published `Arc<Vec<f64>>`
    /// always has one entry per `config.order` slot.
    pub fn new(port: u16, config: UdpPacketConfig, default_values: HashMap<String, f64>) -> Self {
        let running = Arc::new(AtomicBool::new(true));

        let order = config.order.clone();
        let is_double = config.is_double;
        let expected_bytes = config.expected_packet_size();

        // Build the constructor-time order → slot map (first occurrence wins).
        let mut slot_index: HashMap<String, usize> = HashMap::with_capacity(order.len());
        for (i, name) in order.iter().enumerate() {
            slot_index.entry(name.clone()).or_insert(i);
        }

        // Positional default vector: slot i initialized from default_values[order[i]] (or 0.0).
        let default_slots: Vec<f64> = order
            .iter()
            .map(|name| default_values.get(name).copied().unwrap_or(0.0))
            .collect();
        let state = Arc::new(ArcSwap::from_pointee(default_slots));

        let running_clone = Arc::clone(&running);
        let state_clone = Arc::clone(&state);

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
            // Pre-allocate positional parse buffer — one slot per order entry, reused every packet.
            // Writing by index (not by string key) avoids the per-packet HashMap allocation/hashing.
            let mut values: Vec<f64> = vec![0.0; order.len()];

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

                // Parse packet based on config order (positional: slot i <- order[i])
                if last_len > 0 {
                    let mut cursor = std::io::Cursor::new(&buf[..last_len]);

                    let mut parse_ok = true;
                    for (slot, item) in order.iter().enumerate() {
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

                        // Every slot is written (including "skipthis", which consumers never read),
                        // so the buffer needs no per-packet clear.
                        values[slot] = value;
                    }

                    state_clone.store(Arc::new(values.clone()));
                }

                thread::sleep(Duration::from_millis(crate::constants_m::UDP_POLL_INTERVAL_MS));
            }
        });

        Self {
            running,
            state,
            slot_index,
            thread: Some(handle),
        }
    }

    /// Resolve a field name to its positional slot (constructor-built, O(1) lookup).
    /// Consumers cache these once instead of hashing names on every frame.
    pub fn slot_of(&self, name: &str) -> Option<usize> {
        self.slot_index.get(name).copied()
    }

    /// Get the latest positional state vector (lock-free atomic load).
    /// Index with a slot from `slot_of`.
    pub fn latest_state(&self) -> Arc<Vec<f64>> {
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
    /// Control surface (name, slot) pairs, resolved once at construction.
    control_surface_slots: Vec<(String, Option<usize>)>,
    /// Slots for the ten physics state keywords, resolved once at construction.
    /// Order: ub, vb, wb, xf, yf, zf, e0, ex, ey, ez.
    state_slots: [Option<usize>; 10],
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

        // Resolve every field to its positional slot once (was a per-frame HashMap lookup).
        let state_slots = [
            receiver.slot_of("ub"), receiver.slot_of("vb"), receiver.slot_of("wb"),
            receiver.slot_of("xf"), receiver.slot_of("yf"), receiver.slot_of("zf"),
            receiver.slot_of("e0"), receiver.slot_of("ex"), receiver.slot_of("ey"),
            receiver.slot_of("ez"),
        ];
        let control_surface_slots: Vec<(String, Option<usize>)> = control_surface_names
            .iter()
            .map(|name| (name.clone(), receiver.slot_of(name)))
            .collect();

        let default_state = PhysicsState {
            velocity: default_vel,
            position: default_pos,
            quaternion: default_quat,
            control_surfaces: HashMap::new(),
        };

        Self {
            receiver,
            default_state,
            control_surface_slots,
            state_slots,
        }
    }

    /// Get the latest physics state including control surfaces
    pub fn latest_state(&self) -> PhysicsState {
        let values = self.receiver.latest_state();

        // Positional read: fall back to the default if the slot is absent from the packet order.
        let slot = |i: usize, default: f64| -> f64 {
            self.state_slots[i]
                .and_then(|s| values.get(s).copied())
                .unwrap_or(default)
        };

        // Extract physics state by slot (slots: ub,vb,wb, xf,yf,zf, e0,ex,ey,ez)
        let velocity = Vector3::new(
            slot(0, self.default_state.velocity.x),
            slot(1, self.default_state.velocity.y),
            slot(2, self.default_state.velocity.z),
        );

        let position = Vector3::new(
            slot(3, self.default_state.position.x),
            slot(4, self.default_state.position.y),
            slot(5, self.default_state.position.z),
        );

        let quaternion = [
            slot(6, self.default_state.quaternion[0]),
            slot(7, self.default_state.quaternion[1]),
            slot(8, self.default_state.quaternion[2]),
            slot(9, self.default_state.quaternion[3]),
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

        // Extract control surfaces by their resolved slots (only those present in the packet order)
        let mut control_surfaces = HashMap::new();
        for (name, slot) in &self.control_surface_slots {
            if let Some(&value) = slot.and_then(|s| values.get(s)) {
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
    /// Enable flags: (controller name, slot). Built once from cmd + bool controllers.
    enable_slots: Vec<(String, usize)>,
    /// Command values: (base controller name, slot of "<name>_cmd"). Built once.
    cmd_value_slots: Vec<(String, usize)>,
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

        // Resolve the packet order → slots once (was a per-frame scan of the whole HashMap).
        // Mirrors the old classification: a slot is an enable flag if its name is a cmd/bool
        // controller, or a command value if it is "<cmd>_cmd".
        let mut enable_slots = Vec::new();
        let mut cmd_value_slots = Vec::new();
        for (slot, key) in config.order.iter().enumerate() {
            if cmd_set.contains(key) || bool_set.contains(key) {
                enable_slots.push((key.clone(), slot));
            } else if let Some(base) = key.strip_suffix("_cmd") {
                if cmd_set.contains(base) {
                    cmd_value_slots.push((base.to_string(), slot));
                }
            }
        }

        Self {
            receiver,
            enable_slots,
            cmd_value_slots,
        }
    }

    pub fn latest_state(&self) -> ControllerState {
        let values = self.receiver.latest_state();

        let mut enables = HashMap::new();
        let mut cmd_values = HashMap::new();

        for (name, slot) in &self.enable_slots {
            if let Some(&v) = values.get(*slot) {
                enables.insert(name.clone(), v > 0.5);
            }
        }
        for (base, slot) in &self.cmd_value_slots {
            if let Some(&v) = values.get(*slot) {
                cmd_values.insert(base.clone(), v);
            }
        }

        ControllerState {
            enables,
            values: cmd_values,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Struct4: the constructor-built slot index maps each order entry to its position, and the
    // published default vector is positional (one slot per order entry, defaults baked in).
    #[test]
    fn slot_index_and_positional_defaults() {
        let order = vec![
            "ub".to_string(), "skipthis".to_string(), "vb".to_string(), "da".to_string(),
        ];
        let config = UdpPacketConfig::new(order, Precision::Double);
        let mut defaults = HashMap::new();
        defaults.insert("ub".to_string(), 111.0);
        defaults.insert("vb".to_string(), 222.0);
        defaults.insert("da".to_string(), 3.0);

        // Bind to an ephemeral port (0) so the test doesn't collide with anything.
        let rx = ConfigurableUdpReceiver::new(0, config, defaults);

        assert_eq!(rx.slot_of("ub"), Some(0));
        assert_eq!(rx.slot_of("skipthis"), Some(1));
        assert_eq!(rx.slot_of("vb"), Some(2));
        assert_eq!(rx.slot_of("da"), Some(3));
        assert_eq!(rx.slot_of("nope"), None);

        // Before any packet arrives, latest_state() is the positional default vector.
        let v = rx.latest_state();
        assert_eq!(v.len(), 4);
        assert_eq!(v[0], 111.0); // ub
        assert_eq!(v[1], 0.0); // skipthis -> 0.0
        assert_eq!(v[2], 222.0); // vb
        assert_eq!(v[3], 3.0); // da
    }

    // The physics receiver's public API is unchanged: with no packets it returns the defaults.
    #[test]
    fn physics_receiver_defaults_before_packets() {
        let order = vec![
            "ub".to_string(), "vb".to_string(), "wb".to_string(),
            "xf".to_string(), "yf".to_string(), "zf".to_string(),
            "e0".to_string(), "ex".to_string(), "ey".to_string(), "ez".to_string(),
            "da".to_string(),
        ];
        let default_pos = Vector3::new(1.0, 2.0, 3.0);
        let default_quat = [1.0, 0.0, 0.0, 0.0];
        let rx = UdpStateReceiver::new(
            0, order, Precision::Double,
            Vector3::new(10.0, 20.0, 30.0), default_pos, default_quat,
            vec!["da".to_string()],
        );
        let st = rx.latest_state();
        assert_eq!(st.velocity, Vector3::new(10.0, 20.0, 30.0));
        assert_eq!(st.position, default_pos);
        assert_eq!(st.quaternion, default_quat);
        // Control surface default is 0.0 and present.
        assert_eq!(st.control_surfaces.get("da").copied(), Some(0.0));
    }
}