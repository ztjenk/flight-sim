# Connections Configuration Guide

How to configure telemetry connections in your physics config (e.g. `sim_f16.json`).

## Overview

The `connections` section defines communication channels for sending simulation data to external programs (graphics, logging) and receiving control commands from autopilots or controllers. Each connection is linked to a specific vehicle.

## JSON Structure

```json
"connections": {
    "my_connection_name": {
        "note": "Optional description (ignored by code)",
        "enabled": true,
        "vehicle": "F16",
        "type": "send",
        "data_type": "both",
        "channel_type": "udp",
        "IP_address": "127.0.0.1",
        "port_ID": 5005,
        "double_precision": false,
        "refresh_rate": 100
    }
}
```

## Field Reference

### Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | boolean | `true` to activate, `false` to skip |
| `vehicle` | string | Vehicle name (must match a vehicle with `run_physics: true`) |
| `type` | string | `"send"` or `"receive"` |
| `channel_type` | string | `"udp"` or `"file"` |

### Optional Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `note` | string | — | Human-readable description (ignored by code) |
| `data_type` | string | `"both"` | Packet format (see below) |
| `packet_type` | string | `""` | For receive: identifies packet purpose (e.g., `"controls"`) |
| `IP_address` | string | `"127.0.0.1"` | Destination IP for UDP send |
| `port_ID` | integer | — | UDP port number |
| `double_precision` | boolean | `false` | Use 64-bit floats instead of 32-bit |
| `refresh_rate` | number | `0` | Max updates per second (0 = unlimited) |
| `wait_for_input` | boolean | `false` | For receive: `true` = blocking, `false` = non-blocking |
| `entity_tagged` | boolean | `false` | Prepend 4-byte int32 entity_id to all packets |
| `sensors` | string[] | — | For `data_type: "sensors"`: list of sensor names to include |

## Data Types and Packet Formats

### `data_type: "controls"` (N values)

All control effector values in the order they appear in the vehicle's `control_effectors` JSON. The number of values equals the number of control effectors defined on the vehicle.

| Index | Value | Units |
|-------|-------|-------|
| 1..N | control effector values | radians (angles) or dimensionless |

### `data_type: "state"` (14 values)

| Index | Value | Units |
|-------|-------|-------|
| 1 | t | seconds |
| 2-4 | u, v, w | ft/s (body velocity) |
| 5-7 | p, q, r | rad/s (body angular rates) |
| 8-10 | xf, yf, zf | ft (earth position, z positive down) |
| 11-14 | e0, ex, ey, ez | quaternion |

### `data_type: "both"` (14 + 2N values)

State (14) + commanded controls (N) + actual controls (N):

| Index | Value | Description |
|-------|-------|-------------|
| 1-14 | state | Same as `"state"` |
| 15..14+N | commanded | Last commanded values (from autopilot) |
| 15+N..14+2N | actual | Actual values (used by simulation) |

Commanded and actual differ when actuator dynamics are enabled (actual lags behind commanded).

### `data_type: "sensors"` (variable)

Concatenated outputs from the sensors listed in the `"sensors"` field. Each sensor contributes its `n_outputs` values. Requires the vehicle to have sensors configured.

### `data_type: "ekf_state"` (17 values)

The 14 `"state"` fields, but populated from the EKF estimated state instead of the true state, followed by 3 appended EKF angular-acceleration fields (ṗ, q̇, ṙ, for INDI control). A controller that reads only the first 14 fields needs no change. Requires the vehicle's EKF to be enabled.

### `data_type: "ekf_both"` (14 + 2N + 3 values)

Same layout as `"both"` but with EKF-estimated state, followed by the 3 appended EKF angular-acceleration fields. Control deflections remain the actual (true) values.

## Entity-Tagged Packets

When `"entity_tagged": true`, a 4-byte little-endian int32 entity_id is prepended to every packet:

```
[entity_id (int32)] [payload...]
```

Used for multi-vehicle controller routing — one controller process serving several vehicles, each identified by its entity id.

## Examples

### Send State to Graphics

```json
"graphics_send": {
    "enabled": true,
    "vehicle": "F16",
    "type": "send",
    "data_type": "both",
    "channel_type": "udp",
    "port_ID": 5005,
    "refresh_rate": 60
}
```

### Receive Autopilot Commands

```json
"autopilot_rx": {
    "enabled": true,
    "vehicle": "F16",
    "type": "receive",
    "packet_type": "controls",
    "data_type": "controls",
    "channel_type": "udp",
    "port_ID": 5002,
    "entity_tagged": true,
    "wait_for_input": false,
    "refresh_rate": 100
}
```

### Send Sensor Data to Controller

```json
"sensors_to_ctrl": {
    "enabled": true,
    "vehicle": "F16",
    "type": "send",
    "data_type": "sensors",
    "sensors": ["imu_main", "ads", "gps"],
    "channel_type": "udp",
    "port_ID": 5010,
    "refresh_rate": 100
}
```

### Blocking Receive (HIL)

```json
"hardware_in_loop": {
    "enabled": true,
    "vehicle": "F16",
    "type": "receive",
    "packet_type": "controls",
    "data_type": "controls",
    "channel_type": "udp",
    "port_ID": 5010,
    "wait_for_input": true
}
```

## Error Messages

| Error | Cause |
|-------|-------|
| `Connection "X" missing required "vehicle" field` | The `vehicle` field is not specified |
| `Connection "X" references unknown vehicle: Y` | Vehicle name doesn't match any vehicle in JSON |

## Tips

1. **Disable unused connections** — set `enabled: false`
2. **Use refresh_rate** — limit send rate to avoid flooding
3. **Non-blocking receive** — `wait_for_input: false` for real-time sims
4. **Blocking receive** — `wait_for_input: true` for HIL synchronization
