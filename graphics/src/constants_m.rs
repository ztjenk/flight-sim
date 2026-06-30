// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

// ============================================================================
// Unit Conversions
// ============================================================================

/// Meters to feet
pub const M_TO_FT: f64 = 3.28084;

/// Feet to meters
pub const FT_TO_M: f64 = 0.3048;

/// Speed of sound at sea level (ft/s at 59F / 15C)
pub const SPEED_OF_SOUND_SEA_LEVEL_FT_S: f64 = 1116.4;

/// Degrees to radians
pub const DEG_TO_RAD: f64 = std::f64::consts::PI / 180.0;


// ============================================================================
// Named Colors [R, G, B] in 0.0-1.0 range
// ============================================================================

pub const COLOR_BLACK:        [f32; 3] = [0.0, 0.0, 0.0];
pub const COLOR_WHITE:        [f32; 3] = [1.0, 1.0, 1.0];
pub const COLOR_GRAY:         [f32; 3] = [0.5, 0.5, 0.5];
pub const COLOR_LIGHT_GRAY:   [f32; 3] = [0.8, 0.8, 0.8];
pub const COLOR_RED:          [f32; 3] = [1.0, 0.0, 0.0];
pub const COLOR_GREEN:        [f32; 3] = [0.0, 1.0, 0.0];
pub const COLOR_BLUE:         [f32; 3] = [0.0, 0.0, 1.0];
pub const COLOR_YELLOW:       [f32; 3] = [1.0, 1.0, 0.0];
pub const COLOR_CYAN:         [f32; 3] = [0.0, 1.0, 1.0];
pub const COLOR_MAGENTA:      [f32; 3] = [1.0, 0.0, 1.0];
pub const COLOR_ORANGE:       [f32; 3] = [1.0, 0.5, 0.0];
pub const COLOR_PURPLE:       [f32; 3] = [0.5, 0.0, 0.5];
pub const COLOR_PINK:         [f32; 3] = [1.0, 0.0, 0.5];
pub const COLOR_LIME:         [f32; 3] = [0.0, 1.0, 0.0];
pub const COLOR_TERRAIN_GREEN:[f32; 3] = [0.7333, 0.8549, 0.6431];

/// Build the named color lookup map. Called once via lazy_static in parse_color.
pub fn named_color_map() -> std::collections::HashMap<&'static str, [f32; 3]> {
    let mut m = std::collections::HashMap::new();
    m.insert("black",        COLOR_BLACK);
    m.insert("white",        COLOR_WHITE);
    m.insert("gray",         COLOR_GRAY);
    m.insert("grey",         COLOR_GRAY);
    m.insert("light_gray",   COLOR_LIGHT_GRAY);
    m.insert("red",          COLOR_RED);
    m.insert("green",        COLOR_GREEN);
    m.insert("blue",         COLOR_BLUE);
    m.insert("yellow",       COLOR_YELLOW);
    m.insert("cyan",         COLOR_CYAN);
    m.insert("magenta",      COLOR_MAGENTA);
    m.insert("orange",       COLOR_ORANGE);
    m.insert("purple",       COLOR_PURPLE);
    m.insert("pink",         COLOR_PINK);
    m.insert("lime",         COLOR_LIME);
    m.insert("terrain_green", COLOR_TERRAIN_GREEN);
    m
}

// ============================================================================
// UDP / Networking
// ============================================================================

/// UDP receive buffer size (bytes). Must be larger than any expected packet.
pub const UDP_RECV_BUFFER_SIZE: usize = 2048;

/// Sleep between non-blocking recv drain loops (ms). Balances CPU usage vs latency.
pub const UDP_POLL_INTERVAL_MS: u64 = 1;

// ============================================================================
// Terrain Streaming
// ============================================================================

/// Max LOD upgrade requests per frame.
pub const TERRAIN_MAX_UPGRADES_PER_FRAME: usize = 2;

/// Tile loader recv timeout (ms). Shorter = faster thread exit on shutdown.
pub const TERRAIN_TILE_LOAD_TIMEOUT_MS: u64 = 10;

/// How often to log cache status to console (seconds).
pub const TERRAIN_CACHE_LOG_INTERVAL_SECS: u64 = 10;

/// Distance within which tiles are always highest priority (feet).
pub const TERRAIN_CRITICAL_RADIUS_FT: f64 = 5000.0;

/// Age of a pending request before it's discarded as stale (ms).
pub const TERRAIN_STALE_REQUEST_MS: u64 = 1000;

/// Default nodata elevation value for DEM tiles.
pub const DEM_NODATA_VALUE: f64 = -9999.0;

// ============================================================================
// Renderer Defaults
// ============================================================================

/// Default far clipping plane distance (feet).
pub const DEFAULT_FAR_CLIP_FT: f64 = 50000.0;

/// Default mesh color [R, G, B, A].
pub const DEFAULT_MESH_COLOR: [f32; 4] = [0.5, 0.5, 0.5, 1.0];

/// Default light intensities [aircraft_sun, ground_sun, ambient].
pub const DEFAULT_LIGHT_AIRCRAFT_INTENSITY: f64 = 1.0;
pub const DEFAULT_LIGHT_GROUND_INTENSITY: f64 = 1.0;
pub const DEFAULT_LIGHT_AMBIENT: f64 = 0.15;

/// LOD texture sampler clamp range.
pub const LOD_MIN_CLAMP: f32 = 0.0;
pub const LOD_MAX_CLAMP: f32 = 32.0;

/// Terrain polygon depth bias slope scale (negative = push away from camera to reduce z-fighting).
pub const TERRAIN_DEPTH_BIAS_SLOPE: f32 = -2.0;

// ============================================================================
// HUD Layout
// ============================================================================

/// Default HUD font size (pixels).
pub const HUD_DEFAULT_FONT_SIZE: f32 = 14.0;

/// Default HUD opacity (0.0-1.0).
pub const HUD_DEFAULT_OPACITY: f32 = 0.8;

/// HUD update throttle interval (seconds). 1/30 = 30 FPS HUD refresh.
pub const HUD_UPDATE_INTERVAL_SECS: f64 = 1.0 / 30.0;

/// Speed tape half-height (pixels).
pub const HUD_TAPE_HALF_HEIGHT: f32 = 150.0;

/// Speed tape X offset from left edge (pixels).
pub const HUD_SPEED_TAPE_X_OFFSET: f32 = 80.0;

/// Altitude tape X offset from right edge (pixels).
pub const HUD_ALT_TAPE_X_OFFSET: f32 = 80.0;

/// Heading indicator Y offset from bottom (pixels).
pub const HUD_HEADING_Y_OFFSET: f32 = 55.0;

/// Speed tape visible range (knots above/below current).
pub const HUD_SPEED_TAPE_RANGE: f32 = 100.0;

/// Speed tape tick spacing (knots).
pub const HUD_SPEED_TAPE_TICK_STEP: f32 = 20.0;

/// Altitude tape visible range (feet above/below current).
pub const HUD_ALT_TAPE_RANGE: f32 = 1000.0;

/// Altitude tape tick spacing (feet).
pub const HUD_ALT_TAPE_TICK_STEP: f32 = 200.0;

/// Heading tape visible range (degrees).
pub const HUD_HEADING_VISIBLE_RANGE: f32 = 180.0;

/// Heading tape cardinal direction step (degrees).
pub const HUD_HEADING_CARDINAL_STEP: f32 = 45.0;

/// Attitude indicator pixels per degree of pitch.
pub const HUD_ATTITUDE_PX_PER_DEG: f32 = 5.5;

/// Pitch ladder tick spacing (degrees).
pub const HUD_PITCH_LADDER_STEP: f32 = 10.0;

/// Pitch ladder half range (degrees above/below horizon).
pub const HUD_PITCH_LADDER_HALF_RANGE: f32 = 45.0;

/// Flight path vector reticle radius (pixels).
pub const HUD_FPV_RETICLE_RADIUS: f32 = 8.0;

/// Flight path vector wing length (pixels).
pub const HUD_FPV_WING_LENGTH: f32 = 18.0;

/// Flight path vector tail length (pixels).
pub const HUD_FPV_TAIL_LENGTH: f32 = 12.0;

/// Controller status panel width (pixels).
pub const HUD_CONTROLLER_STATUS_WIDTH: f32 = 200.0;

// ============================================================================
// Gamepad / Pilot Controls
// ============================================================================

/// Default gamepad polling rate (Hz).
pub const GAMEPAD_DEFAULT_RATE_HZ: f32 = 60.0;

/// Default gamepad stick deadzone (0.0-1.0).
pub const GAMEPAD_DEFAULT_DEADZONE: f32 = 0.08;

/// Trigger threshold for detecting a press (0.0-1.0).
pub const GAMEPAD_TRIGGER_PRESS_THRESHOLD: f32 = 0.1;

/// Trigger threshold for detecting a release (0.0-1.0).
pub const GAMEPAD_TRIGGER_RELEASE_THRESHOLD: f32 = 0.9;

// ============================================================================
// Numerical Thresholds
// ============================================================================

/// Epsilon for floating point change detection (camera movement, etc).
pub const EPSILON_CHANGE: f64 = 1e-6;

/// Epsilon for velocity magnitude checks (is the vehicle moving?).
pub const EPSILON_VELOCITY: f64 = 1e-3;

/// Epsilon for vector normalization (avoid div-by-zero on tiny vectors).
pub const EPSILON_NORMALIZE: f64 = 1e-6;

// ============================================================================
// STL Binary Format
// ============================================================================

/// STL binary header size (80 bytes header + 4 bytes triangle count).
pub const STL_HEADER_SIZE: usize = 84;

/// Bytes per triangle in binary STL (normal + 3 vertices + attribute).
pub const STL_BYTES_PER_TRIANGLE: usize = 50;

/// Vertex quantization scale for deduplication (0.0001 unit precision).
pub const STL_VERTEX_QUANTIZE_SCALE: f64 = 10000.0;

// ============================================================================
// DDS / BC Texture Format
// ============================================================================

/// DDS file magic number ("DDS ").
pub const DDS_MAGIC: u32 = 0x20534444;

/// DDPF_FOURCC pixel format flag.
pub const DDS_DDPF_FOURCC: u32 = 0x4;

/// DXT1 FourCC code.
pub const DDS_FOURCC_DXT1: u32 = 0x31545844;

/// DX10 extended header FourCC bytes.
pub const DDS_FOURCC_DX10: [u8; 4] = [0x44, 0x58, 0x31, 0x30];

/// DXGI_FORMAT_BC7_UNORM.
pub const DXGI_FORMAT_BC7_UNORM: u32 = 98;

/// DXGI_FORMAT_BC7_UNORM_SRGB.
pub const DXGI_FORMAT_BC7_UNORM_SRGB: u32 = 99;

/// DDSD_MIPMAPCOUNT flag.
pub const DDS_DDSD_MIPMAPCOUNT: u32 = 0x20000;


// ============================================================================
// Ground Grid Constants
// ============================================================================

/// Distance ratio at which far fade starts (fraction of max_distance)
pub const GRID_FAR_FADE_START_RATIO: f32 = 0.6;

/// Distance ratio at which far fade ends (fraction of max_distance)
pub const GRID_FAR_FADE_END_RATIO: f32 = 0.90;

/// Default fallback color for ground grid [R, G, B]
pub const GRID_DEFAULT_COLOR: [f32; 3] = [0.4, 0.4, 0.4];

/// Default maximum render distance for grid when not specified (in feet)
pub const GRID_DEFAULT_MAX_DISTANCE: f64 = 100000.0;
