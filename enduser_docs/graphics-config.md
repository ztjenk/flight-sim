# Flight Simulator Graphics Configuration Guide

This document provides a comprehensive guide to configuring the flight simulator graphics system, including all configuration options, machine-specific profiles, vehicle integration, and controller setup.

## Table of Contents

1. [Configuration File Overview](#configuration-file-overview)
2. [Profile System](#profile-system)
3. [Machine Configuration Files](#machine-configuration-files)
4. [Main Configuration Sections](#main-configuration-sections)
   - [active_profile](#active_profile)
   - [camera](#camera)
   - [ground](#ground)
   - [vehicle](#vehicle)
   - [udp](#udp)
   - [pilot_controls](#pilot_controls)
   - [hud](#hud)
   - [sky](#sky)
   - [background](#background)
   - [lighting](#lighting)
5. [Controller Status Display](#controller-status-display)
6. [UDP Data Formats](#udp-data-formats)
7. [Integrating Aircraft](#integrating-aircraft)
8. [Rust-Enabled Physics and Controllers](#rust-enabled-physics-and-controllers)
9. [Color Specification](#color-specification)

---

## Configuration File Overview

The config file is a **required command-line argument** — there is no default file:

```bash
flightsim_graphics <your_config.json>
```

**A single self-contained file is the normal case.** One JSON holds every
rendering setting, the vehicle/mesh definitions, the UDP ports, and (optionally)
the relative paths used to auto-launch physics and the controller. The bundled
[`examples/`](../examples/) all use this single-file form — see any
`graphics_<Aircraft>.json`.

**Splitting into multiple files is optional** (the *profile system*, below). It
exists only for multi-machine workflows; you never need it for a normal setup.

---

## Profile System (optional)

The profile system lets one graphics config work unchanged across several
machines by moving the machine-specific paths into a separate file:
- Reuse one graphics config across multiple machines
- Quickly switch between physics simulators or vehicles by name

If you don't use `active_profile`, the renderer reads the paths directly from the
`udp` and `pilot_controls` sections instead (see those fields), and no second file
is needed. **Skip this whole section for a single-file setup.**

### How It Works

1. Create a machine-specific JSON file (e.g., `mymachine.json`)
2. Reference it from your graphics config via `active_profile.machine_config`
3. Select which physics simulator and vehicle to use

---

## Machine Configuration Files

Machine config files define paths that vary between computers. Create one for each machine you use.

### Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `tiles_dir` | string | **Required.** Path to terrain tile directory |
| `physics` | object | **Required.** Dictionary of available physics simulators |
| `controller_base_path` | string | **Required.** Base path where controller folders are located |
| `mesh_base_path` | string | **Required.** Base path for vehicle mesh files (relative or absolute) |

### Optional Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `mesh_overrides` | object | `{}` | Maps vehicle names to mesh folder names when they differ |

### Example: `mymachine.json`

```json
{
    "tiles_dir": "/path/to/terrain/tiles/",
    "physics": {
        "flightsim": {
            "exe": "flightsim",
            "path": "/path/to/flight-sim/physics/src/bin"
        }
    },
    "controller_base_path": "/path/to/flight-sim/controllers",
    "mesh_base_path": "meshes",
    "mesh_overrides": {
        "MyAircraft": "F16"
    }
}
```

### Physics Simulator Entry

Each physics entry requires:
- `exe`: Executable name (e.g., `"flightsim"` or `"flightsim.exe"`)
- `path`: Working directory containing the executable

---

## Main Configuration Sections

### active_profile

Selects the machine config and active physics/vehicle profile.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `machine_config` | string | Yes | Filename of machine config (e.g., `"mymachine.json"`) |
| `physics` | string | Yes | Key into machine's physics map (e.g., `"flightsim"`) |
| `vehicle` | string | Yes | Vehicle name for path derivation (e.g., `"MyAircraft"`) |

**Example:**
```json
"active_profile": {
    "machine_config": "mymachine.json",
    "physics": "flightsim",
    "vehicle": "MyAircraft"
}
```

**Derived Paths:** When `active_profile` is set, the system computes:
- `physics_exe`: From `machine.physics[physics].exe`
- `physics_path`: From `machine.physics[physics].path`
- `physics_json`: `"{vehicle}input.json"` (e.g., `"MyAircraftinput.json"`)
- `controller_exe`: `"{vehicle}controller"` (e.g., `"MyAircraftcontroller"`)
- `controller_path`: `"{controller_base_path}/{vehicle}controller"`
- `mesh_path`: `"{mesh_base_path}/{vehicle}"` or uses `mesh_overrides` if present

---

### camera

Controls camera positioning and view frustum settings.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `fix_to` | string | Yes | - | Camera attachment mode: `"body"`, `"velocity"`, or `"fixed"` |
| `location[ft]` | [f64; 3] | Yes | - | Camera offset from vehicle [x, y, z] in feet |
| `orientation[deg]` | [f64; 3] | Yes | - | Camera rotation [roll, pitch, yaw] in degrees |
| `view_plane` | object | Yes | - | View frustum settings |

**view_plane sub-fields:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `distance[ft]` | f64 | Yes | Near clipping plane distance in feet |
| `angle[deg]` | f64 | Yes | Vertical field of view in degrees |
| `aspect_ratio` | f64 | Yes | Width/height ratio |

**Example:**
```json
"camera": {
    "fix_to": "body",
    "location[ft]": [-35.0, 0.0, -5.0],
    "orientation[deg]": [0.0, -10.0, 0.0],
    "view_plane": {
        "distance[ft]": 1.0,
        "angle[deg]": 60.0,
        "aspect_ratio": 2.0
    }
}
```

---

### ground

Configures ground rendering mode and terrain settings.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `mode` | string | No | `"grid"` | Rendering mode: `"grid"` or `"streaming"` |
| `altitude[ft]` | f64 | Yes | - | Ground plane altitude in feet MSL |
| `grid_scale[ft]` | f64 | Yes | - | Spacing between grid lines (grid mode) |
| `color` | string | Yes | - | Ground color (name or hex) |
| `max_draw_distance[ft]` | f64 | No | unlimited | Maximum render distance |
| `streaming` | object | No | - | Streaming terrain config (required if mode="streaming") |

**streaming sub-fields:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `mesh_resolution` | usize | `64` | Vertices per tile edge |
| `vertical_scale` | f32 | `1.0` | Elevation multiplier |
| `origin_lat_lon` | [f64; 2] | - | [latitude, longitude] of coordinate origin |
| `reference_texture_size` | usize | `4096` | Typical tile texture width in pixels (used for auto LOD computation) |
| `max_gpu_tiles` | usize | `64` | Max tiles on GPU |
| `num_workers` | usize | `2` | Background loading threads |
| `max_uploads_per_frame` | usize | `1` | Max tile uploads to GPU per frame. Higher = faster loading, more stutter risk |
| `upload_cooldown_ms` | u64 | `200` | Cooldown (ms) after an upload before allowing the next. 0 = no cooldown |
| `max_deferred_uploads` | usize | `8` | Max tiles queued in memory waiting for cooldown to expire |

**Example:**
```json
"ground": {
    "mode": "streaming",
    "altitude[ft]": 0.0,
    "grid_scale[ft]": 1000.0,
    "max_draw_distance[ft]": 900000,
    "streaming": {
        "mesh_resolution": 256,
        "vertical_scale": 1.0,
        "origin_lat_lon": [40.56014, -111.88888],
        "reference_texture_size": 4096,
        "num_workers": 4,
        "max_gpu_tiles": 256,
        "max_uploads_per_frame": 8,
        "upload_cooldown_ms": 0
    }
}
```

---

### vehicle

Configures the vehicle mesh and control surfaces.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `stl_files` | object | Yes | - | Dictionary of STL parts |
| `control_surfaces` | object | Conditional | - | Physics packet configuration (see below) |
| `control_surface_units` | string | No | `"radians"` | Units from physics: `"radians"` or `"degrees"` |
| `color` | string | Yes | - | Vehicle color (name or hex) |
| `scale` | f64 | No | `1.0` | Scale multiplier |
| `default_location[ft]` | [f64; 3] | Yes | - | Initial position [x, y, z] |
| `default_orientation[deg]` | [f64; 3] | Yes | - | Initial rotation [roll, pitch, yaw] |

**stl_files entry fields:**

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `file` | string | Conditional | - | STL filename (required for actual parts) |
| `is_main` | bool | No | `false` | True for the main fuselage part |
| `control_surface` | string or object | No | - | Control surface mapping (see below) |
| `symmetric` | bool | No | `true` | If false, requires `side` |
| `side` | string | Conditional | - | `"left"` or `"right"` (required if symmetric=false) |
| `hinge_point` | [f64; 3] | Conditional | - | Hinge location in body coordinates |
| `hinge_line` | [f64; 3] | Conditional | - | Hinge axis direction (normalized) |
| `connect_to` | string | Conditional | - | Parent part name |

**control_surface field:**

The `control_surface` field can be specified in two formats:

1. **Simple string** (single surface): `"da"` - maps 1:1 to control surface "da"

2. **Object with coefficients** (combined surfaces): Maps multiple control surfaces with coefficients. The total deflection is the sum of each surface value multiplied by its coefficient.

**Example: Differential Elevator (stabilator)**

For an aircraft with symmetric + asymmetric elevator control:
- Physics sends `elevsym` (pitch) and `elevasym` (differential roll)
- Right elevator = elevsym + elevasym
- Left elevator = elevsym - elevasym

```json
"r_elevator": {
    "file": "r_elev.stl",
    "control_surface": {"elevsym": 1.0, "elevasym": 1.0},
    "connect_to": "main",
    "hinge_point": [-10.0, 2.0, 0.0],
    "hinge_line": [0.0, 1.0, 0.0]
},
"l_elevator": {
    "file": "l_elev.stl",
    "control_surface": {"elevsym": 1.0, "elevasym": -1.0},
    "connect_to": "main",
    "hinge_point": [-10.0, -2.0, 0.0],
    "hinge_line": [0.0, 1.0, 0.0]
}
```

**Note:** The coefficient values depend on how your physics defines the control surfaces. If `elevasym` is the half-difference, use coefficients of ±1.0. If it's the full difference, use ±0.5.

**control_surfaces fields:**

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `order` | [string] | Yes | - | Defines the entire UDP packet structure (see Physics Packet Keywords) |
| `precision` | string | No | `"single"` | Data precision: `"single"` (f32, 4 bytes) or `"double"` (f64, 8 bytes) |

**Example:**
```json
"vehicle": {
    "stl_files": {
        "main": {
            "is_main": true,
            "file": "main.stl"
        },
        "r_aileron": {
            "file": "raileron.stl",
            "control_surface": "da",
            "symmetric": false,
            "side": "right",
            "connect_to": "main",
            "hinge_line": [0.1811, -0.9833, -0.0146],
            "hinge_point": [-6.2224, 5.3822, -0.23421]
        }
    },
    "control_surfaces": {
        "order": [
            "skipthis", "ub", "vb", "wb",
            "skipthis", "skipthis", "skipthis",
            "xf", "yf", "zf",
            "e0", "ex", "ey", "ez",
            "skipthis", "skipthis", "skipthis", "skipthis",
            "da", "de", "dr", "thr"
        ],
        "precision": "single"
    },
    "control_surface_units": "radians",
    "color": "orange",
    "default_location[ft]": [0.0, 0.0, -5000.0],
    "default_orientation[deg]": [0.0, 0.0, 0.0],
    "scale": 1.0
}
```

---

### udp

Configures UDP communication with the physics engine.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `enable_udp` | bool | Yes | - | Enable UDP physics data reception |
| `port_id` | u16 | Yes | - | Port to listen for physics state |
| `rust_enabled` | bool | No | `false` | If true, physics runs internally |
| `physics_exe` | string | No | - | External physics executable (legacy) |
| `physics_json` | string | No | - | Physics config JSON (legacy) |
| `physics_path` | string | No | - | Physics working directory (legacy) |

**Note:** When using `active_profile`, the `physics_*` fields are derived automatically.

**Example:**
```json
"udp": {
    "enable_udp": true,
    "port_id": 5005,
    "rust_enabled": true
}
```

---

### pilot_controls

Configures gamepad/joystick input handling.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `enable_pilot_cmd` | bool | No | `false` | Enable gamepad controller |
| `udp_port_id` | u16 | Yes | - | Port to send control commands |
| `rate_hz` | f32 | Yes | - | Command send rate in Hz |
| `rust_enabled` | bool | No | `false` | If true, controller runs internally |
| `controller_exe` | string | No | - | External controller executable (legacy) |
| `controller_json` | string | No | - | Controller config JSON (legacy) |
| `controller_path` | string | No | - | Controller working directory (legacy) |

**Example:**
```json
"pilot_controls": {
    "enable_pilot_cmd": true,
    "udp_port_id": 6000,
    "rate_hz": 100,
    "rust_enabled": true
}
```

---

### hud

Configures the heads-up display overlay.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `enable` | bool | No | `true` | Show HUD |
| `color` | string | No | `"lime"` | HUD element color |
| `opacity` | f32 | No | `0.8` | Transparency (0.0-1.0) |
| `font_size` | f32 | No | `14.0` | Text size in pixels |
| `udp_receive_controller_state` | u16 | No | - | Port to receive controller state |
| `controller_status` | object | No | - | Controller status display config |

**Example:**
```json
"hud": {
    "enable": true,
    "color": "lime",
    "opacity": 0.8,
    "font_size": 16.0,
    "udp_receive_controller_state": 5003,
    "controller_status": {
        "cmd": ["p", "q", "r", "throttle", "bank", "elev"],
        "bool": ["trim"],
        "order": ["p", "q", "r", "throttle", "bank", "elev", "p_cmd", "q_cmd", "r_cmd", "throttle_cmd", "bank_cmd", "elev_cmd", "trim"],
        "cmd_raw_units": ["rad/s", "rad/s", "rad/s", "ft/s", "rad", "rad"],
        "cmd_display_units": ["deg/s", "deg/s", "deg/s", "ft/s", "deg", "deg"],
        "precision": "double"
    }
}
```

---

### sky

Configures atmospheric sky rendering.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `enabled` | bool | No | `true` | Enable sky rendering |
| `sun_direction` | [f64; 3] | No | `[0.5, 0.0, -0.866]` | Normalized sun direction [x, y, z] |
| `sun_intensity` | f64 | No | `20.0` | Sun brightness multiplier |
| `sun_angular_radius_deg` | f64 | No | `0.53` | Angular size of sun disc |
| `ground_albedo` | f64 | No | `0.3` | Ground reflectivity (0.0-1.0) |
| `exposure` | f64 | No | `10.0` | HDR exposure adjustment |

**Example:**
```json
"sky": {
    "enabled": true,
    "sun_direction": [0.0, 0.0, -1.0],
    "sun_intensity": 30.0,
    "sun_angular_radius_deg": 0.53,
    "ground_albedo": 0.9,
    "exposure": 3.0
}
```

---

### background

Simple background color when sky is disabled.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `color` | string | Yes | Background color (name or hex) |

**Example:**
```json
"background": {
    "color": "light_gray"
}
```

---

### lighting

Scene lighting configuration (optional, used when sky is disabled).

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `direction_world` | [f64; 3] | Yes | - | Light direction (normalized) |
| `aircraft_sun_intensity` | f64 | No | `8.0` | Brightness on aircraft |
| `ground_sun_intensity` | f64 | No | `1.0` | Brightness on terrain |
| `ambient` | f64 | No | `0.5` | Ambient light level |

---

## Controller Status Display

The `controller_status` section in `hud` configures how autopilot/controller state is displayed.

### Fields

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `cmd` | [string] | Yes | - | Controllers showing commanded values |
| `bool` | [string] | Yes | - | Controllers showing ON/OFF only |
| `order` | [string] | Yes | - | UDP packet order and display order |
| `cmd_raw_units` | [string] | Yes | - | Raw units from UDP (same length as cmd) |
| `cmd_display_units` | [string] | Yes | - | Display units for HUD (same length as cmd) |
| `precision` | string | No | `"double"` | UDP data precision: `"double"` (f64) or `"single"` (f32) |

### Valid Units

- **Angular rates:** `"rad/s"`, `"deg/s"`
- **Angles:** `"rad"`, `"deg"`
- **Velocities:** `"ft/s"`, `"m/s"`
- **Lengths:** `"ft"`, `"m"`

### Order Field Format

The `order` array defines both:
1. The structure of the UDP packet (what order data arrives)
2. The display order on the HUD

Each element can be:
- **Controller enable flag:** A name from `cmd` or `bool` (reads 1 value as boolean)
- **Controller value:** A name from `cmd` with `_cmd` suffix (reads 1 value as the commanded value)
- **Skip:** `"skipthis"` to read and discard a value

### Example

For a controller sending: 6 enable flags, then 6 command values, then 1 trim boolean:

```json
"controller_status": {
    "cmd": ["p", "q", "r", "throttle", "bank", "elev"],
    "bool": ["trim"],
    "order": [
        "p", "q", "r", "throttle", "bank", "elev",
        "p_cmd", "q_cmd", "r_cmd", "throttle_cmd", "bank_cmd", "elev_cmd",
        "trim"
    ],
    "cmd_raw_units": ["rad/s", "rad/s", "rad/s", "ft/s", "rad", "rad"],
    "cmd_display_units": ["deg/s", "deg/s", "deg/s", "ft/s", "deg", "deg"],
    "precision": "double"
}
```

This expects a UDP packet of 13 values (13 x 8 bytes = 104 bytes for double precision):
- 6 enable flags (p, q, r, throttle, bank, elev)
- 6 command values (p_cmd through elev_cmd)
- 1 trim boolean

### Unit Conversion

The system automatically converts between raw and display units:
- `rad/s` to `deg/s`: multiplies by 180/π
- `rad` to `deg`: multiplies by 180/π
- `m/s` to `ft/s`: multiplies by 3.28084
- `m` to `ft`: multiplies by 3.28084

### Validation

The configuration will throw an error if:
- `cmd_raw_units` or `cmd_display_units` length doesn't match `cmd`
- Any unit is not in the valid units list
- A controller in `cmd` doesn't have both its name AND `name_cmd` in `order`
- A controller in `bool` is not in `order`
- An item in `order` is not a valid controller name, `_cmd` suffix, or `"skipthis"`
- The same item appears multiple times in `order` (except `"skipthis"`)
- `precision` is not `"double"` or `"single"`

---

## UDP Data Formats

Both physics state and controller state use a configurable packet format defined by an `order` array. This allows the graphics system to work with any physics engine or controller that sends data via UDP.

### Physics Packet Keywords

The `control_surfaces.order` array defines the structure of the incoming physics UDP packet. Each element in the array corresponds to one value in the packet.

**Required State Keywords (must all be present):**

| Keyword | Description |
|---------|-------------|
| `ub` | Body X velocity (ft/s) |
| `vb` | Body Y velocity (ft/s) |
| `wb` | Body Z velocity (ft/s) |
| `xf` | X position in earth frame (ft) |
| `yf` | Y position in earth frame (ft) |
| `zf` | Z position in earth frame (ft, negative = up) |
| `e0` | Quaternion scalar component |
| `ex` | Quaternion X component |
| `ey` | Quaternion Y component |
| `ez` | Quaternion Z component |

**Control Surface Keywords:**

Control surface keywords are user-defined. For simple control surfaces, they must match the `control_surface` string in `stl_files`. For combined control surfaces (object format), include all component surface names.

Common examples:
- `da` - aileron deflection
- `de` - elevator deflection
- `dr` - rudder deflection
- `thr` - throttle position
- `elevsym`, `elevasym` - symmetric and asymmetric elevator for differential stabilators

**Special Keyword:**

| Keyword | Description |
|---------|-------------|
| `skipthis` | Skip this value (read but discard). Use for unused data in the packet. |

### Physics State (Port: `udp.port_id`)

Variable-length packet based on `control_surfaces.order`:
- Each item in `order` is one value
- **Single precision (default):** 4 bytes per value (f32)
- **Double precision:** 8 bytes per value (f64)

Total bytes = `order.length` x `bytes_per_value`

**Example:** For a 22-element order array with single precision:
- Packet size = 22 × 4 = 88 bytes

**Example order for traditional aircraft:**
```json
"order": [
    "skipthis", "ub", "vb", "wb",
    "skipthis", "skipthis", "skipthis",
    "xf", "yf", "zf",
    "e0", "ex", "ey", "ez",
    "skipthis", "skipthis", "skipthis", "skipthis",
    "da", "de", "dr", "thr"
]
```

**Example order for multirotor (8 motors, no traditional control surfaces):**
```json
"order": [
    "ub", "vb", "wb",
    "xf", "yf", "zf",
    "e0", "ex", "ey", "ez",
    "motor1", "motor2", "motor3", "motor4",
    "motor5", "motor6", "motor7", "motor8"
]
```

### Controller State (Port: `hud.udp_receive_controller_state`)

Variable-length packet based on `controller_status.order`:
- Each item in `order` is one value
- **Double precision (default):** 8 bytes per value (f64)
- **Single precision:** 4 bytes per value (f32)

Total bytes = `order.length` x `bytes_per_value`

---

## Integrating Aircraft

To add a new aircraft:

### 1. Create Mesh Files

Place STL files in `{mesh_base_path}/{vehicle_name}/` or use `mesh_overrides`.

### 2. Configure `stl_files`

Define each part in the `vehicle.stl_files` section:

**Main body (required):**
```json
"main": {
    "is_main": true,
    "file": "fuselage.stl"
}
```

**Control surface (e.g., aileron):**
```json
"right_aileron": {
    "file": "r_aileron.stl",
    "control_surface": "da",
    "symmetric": false,
    "side": "right",
    "connect_to": "main",
    "hinge_point": [-6.22, 5.38, -0.23],
    "hinge_line": [0.18, -0.98, -0.01]
}
```

### 3. Configure Physics Packet Structure

The `control_surfaces.order` array defines the entire UDP packet structure from your physics engine:

```json
"control_surfaces": {
    "order": [
        "skipthis", "ub", "vb", "wb",
        "skipthis", "skipthis", "skipthis",
        "xf", "yf", "zf",
        "e0", "ex", "ey", "ez",
        "skipthis", "skipthis", "skipthis", "skipthis",
        "da", "de", "dr", "thr"
    ],
    "precision": "single"
}
```

**Required keywords:** `ub`, `vb`, `wb`, `xf`, `yf`, `zf`, `e0`, `ex`, `ey`, `ez`

**Control surface keywords:** Must match the `control_surface` values in your `stl_files` entries (e.g., `da`, `de`, `dr`, `thr`)

**Use `skipthis`** for any values in your packet that should be ignored (e.g., time, angular rates, commanded values)

### 4. Optional: Add Mesh Override

If the mesh folder name differs from the vehicle name:

```json
// In machine config
"mesh_overrides": {
    "MyAircraft": "F16"
}
```

This maps vehicle `"MyAircraft"` to mesh folder `"F16"`.

---

## Rust-Enabled Physics and Controllers

When `rust_enabled` is set to `true`, the graphics code expects the physics or controller to run internally (compiled into the same executable) rather than as separate processes.

### Physics (`udp.rust_enabled: true`)

- The graphics code does NOT spawn an external physics process
- It expects to receive UDP physics data on `udp.port_id` from an internal source
- You must start the physics simulation separately or have it integrated

### Controller (`pilot_controls.rust_enabled: true`)

- The graphics code does NOT spawn an external controller process
- Gamepad input is handled internally
- Control commands are sent via UDP to `pilot_controls.udp_port_id`

### External Processes (`rust_enabled: false` or absent)

When `rust_enabled` is false, the graphics code will:
1. Use the derived paths (from `active_profile`) or explicit `*_exe`, `*_path`, `*_json` fields
2. Spawn the external executable as a subprocess
3. Pass the JSON config file as a command-line argument

**Derived executable names:**
- Physics: Uses `machine.physics[profile.physics].exe`
- Controller: Uses `{vehicle}controller` (e.g., `"MyAircraftcontroller"`)

---

## Color Specification

Colors can be specified as:

### Named Colors

| Name | RGB |
|------|-----|
| `black` | (0, 0, 0) |
| `white` | (1, 1, 1) |
| `gray` / `grey` | (0.5, 0.5, 0.5) |
| `light_gray` | (0.8, 0.8, 0.8) |
| `red` | (1, 0, 0) |
| `green` | (0, 1, 0) |
| `blue` | (0, 0, 1) |
| `yellow` | (1, 1, 0) |
| `cyan` | (0, 1, 1) |
| `magenta` | (1, 0, 1) |
| `orange` | (1, 0.5, 0) |
| `purple` | (0.5, 0, 0.5) |
| `lime` | (0, 1, 0) |
| `terrain_green` | (0.73, 0.85, 0.64) |

### Hex Colors

- `#RRGGBB` - 6-digit hex (e.g., `"#FF5500"`)
- `#RRGGBBAA` - 8-digit hex with alpha (e.g., `"#FF550080"`)

---

## Quick Start Checklist

1. Create a machine config file for your system (copy and modify `mymachine.json`)
2. Update `graphics_config.json`:
   - Set `active_profile.machine_config` to your machine config filename
   - Set `active_profile.physics` to your physics simulator key
   - Set `active_profile.vehicle` to your vehicle name
3. Ensure mesh files exist in the correct path
4. Configure `controller_status` if using autopilot display
5. Run the graphics executable

---

## Troubleshooting

### "Machine config not found"
- Ensure the file specified in `active_profile.machine_config` exists in the graphics folder

### "Physics simulator not found"
- Check that `active_profile.physics` matches a key in your machine config's `physics` section

### "Invalid controller_status config"
- Verify all controllers in `cmd` have both their name AND `name_cmd` in `order`
- Check that `cmd_raw_units` and `cmd_display_units` have the same length as `cmd`
- Ensure all units are valid keywords

### "Vehicle config must have at least one part with is_main: true"
- At least one entry in `stl_files` must have `"is_main": true`

### "Required physics state keyword 'X' is missing from order"
- Your `control_surfaces.order` array must include all required state keywords: `ub`, `vb`, `wb`, `xf`, `yf`, `zf`, `e0`, `ex`, `ey`, `ez`
- Use `skipthis` for values you want to ignore, not just omit them

### "Item 'X' in 'order' is not valid"
- Each item in `control_surfaces.order` must be either:
  - A physics state keyword (`ub`, `vb`, `wb`, `xf`, `yf`, `zf`, `e0`, `ex`, `ey`, `ez`)
  - A control surface name that matches a `control_surface` field in your `stl_files`
  - `skipthis` (to skip a value)

### No terrain showing
- Verify `tiles_dir` in your machine config points to valid terrain tiles
- Check that `ground.mode` is set to `"streaming"`
- Ensure `ground.streaming.origin_lat_lon` matches your terrain tile coverage
