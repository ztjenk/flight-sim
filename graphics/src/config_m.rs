// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

use serde::Deserialize;         // serde: Serialization/Deserialization framework. Deserialize parses json into structs
use std::fmt;
use std::collections::HashMap;  // HashMap: Key-value dictionary for named color lookups
use indexmap::IndexMap;         // IndexMap: Like HashMap but preserves insertion order (for deterministic STL loading)
use std::path::{Path, PathBuf}; // PathBuf: Owned, mutable path - like String but for file paths

// ============================================================================
// Profile-based configuration system
// ============================================================================

/// machine_config in the active_profile may be either:
///   - a filename string (loaded from the same directory as the main config), or
///   - an inline machine config object (single-file distributions).
///
/// `#[serde(untagged)]` lets serde pick the variant based on JSON shape.
#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
pub enum MachineConfigRef {
    File(String),
    Inline(MachineConfig),
}

/// Active profile selection - points to machine config and selects physics/vehicle
#[derive(Debug, Clone, Deserialize)]
pub struct ActiveProfile {
    pub machine_config: MachineConfigRef,   // either "windows.json" or an inline object
    pub physics: String,                    // key into machine.physics map (e.g., "mavrik")
    pub vehicle: String,                    // vehicle name - used for path derivation (e.g., "RCBIRE")
}

/// Machine-specific configuration - loaded from separate JSON file
#[derive(Debug, Clone, Deserialize)]
pub struct MachineConfig {
    // Required: vehicle meshes are always loaded
    pub mesh_base_path: String,                         // base path to mesh folders

    // Optional: only required for streaming terrain mode
    #[serde(default)]
    pub tiles_dir: Option<String>,                      // path to terrain tiles

    // Optional: only required when Rust auto-launches the physics subprocess
    // (i.e., udp.rust_enabled = true). Empty map disables physics auto-launch.
    #[serde(default)]
    pub physics: HashMap<String, SimulatorPaths>,       // available physics simulators

    // Optional: only required when Rust auto-launches the controller subprocess
    // (i.e., pilot_controls.rust_enabled = true).
    #[serde(default)]
    pub controller_base_path: Option<String>,           // base path to controller folders

    #[serde(default)]
    pub mesh_overrides: HashMap<String, String>,        // vehicle -> mesh folder (if different from vehicle name)
}

/// Paths for a physics simulator
#[derive(Debug, Clone, Deserialize)]
pub struct SimulatorPaths {
    pub exe: String,        // executable name (e.g., "mavrik.exe")
    pub path: String,       // directory containing the executable
}

/// Derived paths - computed at runtime from profile + machine config.
/// Physics/controller fields are None when their respective sections are
/// omitted from the machine config (e.g., viewer-only distribution builds).
#[derive(Debug, Clone)]
pub struct DerivedPaths {
    pub physics_exe: Option<String>,        // full physics executable name
    pub physics_path: Option<String>,       // physics working directory
    pub physics_json: Option<String>,       // physics input JSON filename
    pub controller_exe: Option<String>,     // controller executable name
    pub controller_path: Option<String>,    // controller working directory
    pub controller_json: Option<String>,    // controller config filename (always "controller.json")
    pub mesh_path: String,                  // full path to mesh folder (always required)
}

// ============================================================================
// Main Config struct
// ============================================================================

#[derive(Debug, Clone, Deserialize)]
pub struct Config {
    #[serde(default)]
    pub active_profile: Option<ActiveProfile>,  // profile selection (if using new system)

    pub camera: CameraConfig,
    pub ground: GroundConfig,
    pub vehicle: VehicleConfig,

    #[serde(default)]                   // #[serde(default)] means use Default::default() if field is missing
    pub lighting: Option<LightingConfig>,   // sun direction and intensity settings

    pub udp: UdpConfig,

    #[serde(default)]
    pub background: Option<BackgroundConfig>,   // background color when sky is disabled

    #[serde(default)]
    pub pilot_controls: Option<PilotControlsConfig>,    // gamepad/controller settings

    #[serde(default)]
    pub hud: Option<HudConfig>,         // heads-up display settings

    #[serde(default)]
    pub sky: Option<SkyConfig>,         // atmospheric sky rendering settings

    // These are populated after loading if active_profile is set
    #[serde(skip)]
    pub machine: Option<MachineConfig>,

    #[serde(skip)]
    pub derived: Option<DerivedPaths>,
}


// simple background color configuration.
// used when sky rendering is disabled.
#[derive(Debug, Clone, Deserialize)]
pub struct BackgroundConfig {
    pub color: String,  // color name ("blue") or hex code
}

// atmospheric sky rendering config
#[derive(Debug, Clone, Deserialize)]
pub struct SkyConfig {
    #[serde(default = "default_sky_enabled")]
    pub enabled: bool,                      // whether to render the atmospheric sky

    #[serde(default = "default_sun_direction")]
    pub sun_direction: [f64; 3],            // normalized direction vector to the sun (x, y, z)

    #[serde(default = "default_sky_sun_intensity")]
    pub sun_intensity: f64,                 // brightness multiplier for sun

    #[serde(default = "default_sun_angular_radius")]
    pub sun_angular_radius_deg: f64,        // angular size of sun disc in degrees

    #[serde(default = "default_ground_albedo")]
    pub ground_albedo: f64,                 // ground reflectivity for atmospheric scattering (0.0-1.0)

    #[serde(default = "default_sky_exposure")]
    pub exposure: f64,                      // HDR exposure adjustment
}

// default value functions for SkyConfig
// these are called by serde when the field is missing from json
fn default_sky_enabled() -> bool { true }
fn default_sun_direction() -> [f64; 3] { [0.5, 0.0, -0.866] }   // 60 degree elevation angle
fn default_sky_sun_intensity() -> f64 { 20.0 }
fn default_sun_angular_radius() -> f64 { 0.53 }                  // realistic sun size in degrees
fn default_ground_albedo() -> f64 { 0.3 }                        // typical earth surface reflectivity
fn default_sky_exposure() -> f64 { 10.0 }

// camera positioning and view frustum configuration.
#[derive(Debug, Clone, Deserialize)]
pub struct CameraConfig {
    pub view_plane: ViewPlane,              // view frustum settings

    pub fix_to: String,                     // what the camera is attached to (e.g., "vehicle")

    #[serde(rename = "orientation[deg]")]   // #[serde(rename = "...")] maps json key to Rust field
    pub orientation_deg: [f64; 3],          // camera rotation (roll, pitch, yaw) in degrees

    #[serde(rename = "location[ft]")]
    pub location_ft: [f64; 3],              // camera offset from attachment point in feet
}

// view frustum (visible area) configuration.
#[derive(Debug, Clone, Deserialize)]
pub struct ViewPlane {
    pub aspect_ratio: f64,                  // width / height ratio

    #[serde(rename = "distance[ft]")]
    pub distance_ft: f64,                   // near clipping plane distance in feet

    #[serde(rename = "angle[deg]")]
    pub angle_deg: f64,                     // vertical field of view in degrees
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum GroundMode {
    Grid,
    Streaming,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Precision {
    Single,
    Double,
}

impl Precision {
    pub fn is_double(self) -> bool {
        self == Precision::Double
    }
}

impl fmt::Display for Precision {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Precision::Single => write!(f, "single"),
            Precision::Double => write!(f, "double"),
        }
    }
}

// ground plane and terrain rendering configuration.
#[derive(Debug, Clone, Deserialize)]
pub struct GroundConfig {
    #[serde(default = "default_ground_mode")]
    pub mode: GroundMode,

    #[serde(rename = "altitude[ft]")]
    pub altitude_ft: f64,                       // ground plane altitude in feet MSL

    #[serde(rename = "grid_scale[ft]")]
    pub grid_scale_ft: f64,                     // spacing between grid lines in feet

    pub color: String,                          // ground color name or hex code

    #[serde(rename = "max_draw_distance[ft]")]
    #[serde(default)]
    pub max_draw_distance_ft: Option<f64>,      // optional render distance limit

    #[serde(default)]
    pub streaming: Option<StreamingTerrainConfig>,  // streaming terrain settings (if mode = "streaming")
}

fn default_ground_mode() -> GroundMode {
    GroundMode::Grid
}

// streaming terrain configuration for loading real elevation data.
#[derive(Debug, Clone, Deserialize)]
pub struct StreamingTerrainConfig {
    #[serde(default)]
    pub tiles_dir: Option<String>,              // directory containing terrain tile files

    #[serde(default = "default_mesh_resolution")]
    pub mesh_resolution: usize,                 // vertices per tile edge (e.g., 64 = 64x64 grid)

    #[serde(default = "default_vertical_scale")]
    pub vertical_scale: f32,                    // multiplier for elevation values

    #[serde(default)]
    pub origin_lat_lon: Option<[f64; 2]>,       // [latitude, longitude] of coordinate system origin

    #[serde(default = "default_reference_texture_size")]
    pub reference_texture_size: usize,          // typical tile texture width in pixels (for auto LOD)

    #[serde(default = "default_max_gpu_tiles")]
    pub max_gpu_tiles: usize,                   // maximum tiles loaded on GPU simultaneously

    #[serde(default = "default_num_workers")]
    pub num_workers: usize,                     // number of background threads for tile loading

    #[serde(default = "default_max_uploads_per_frame")]
    pub max_uploads_per_frame: usize,           // max tile uploads to GPU per frame

    #[serde(default = "default_upload_cooldown_ms")]
    pub upload_cooldown_ms: u64,                // cooldown (ms) after an upload before allowing another

    #[serde(default = "default_max_deferred_uploads")]
    pub max_deferred_uploads: usize,            // max tiles queued waiting for cooldown
}

// default value functions for StreamingTerrainConfig
fn default_mesh_resolution() -> usize { 64 }
fn default_vertical_scale() -> f32 { 1.0 }
fn default_reference_texture_size() -> usize { 4096 }
fn default_max_gpu_tiles() -> usize { 64 }
fn default_num_workers() -> usize { 2 }
fn default_max_uploads_per_frame() -> usize { 1 }
fn default_upload_cooldown_ms() -> u64 { 200 }
fn default_max_deferred_uploads() -> usize { 8 }

impl StreamingTerrainConfig {
    // Converts the tiles_dir string to a PathBuf if present.
    // Returns `None` if tiles_dir is not configured, otherwise returns
    // Some(PathBuf) pointing to the tiles directory.
    pub fn tiles_dir_path(&self) -> Option<PathBuf> {
        // .as_ref() converts Option<String> to Option<&String>
        // .map() applies a function to the inner value if Some
        self.tiles_dir.as_ref().map(PathBuf::from)
    }
}

// mesh and positioning configuration.
#[derive(Debug, Clone, Deserialize)]
pub struct VehicleConfig {
    /// Dictionary of named STL parts (main body, control surfaces, etc.)
    pub stl_files: IndexMap<String, StlPartConfig>,

    /// Control surfaces configuration - defines the entire UDP packet structure
    /// This replaces the old control_surface_order field with a more flexible system
    #[serde(default)]
    pub control_surfaces: Option<ControlSurfacesConfig>,

    /// DEPRECATED: Old control surface order - use control_surfaces.order instead
    /// Kept for backwards compatibility
    #[serde(default)]
    pub control_surface_order: Option<Vec<String>>,

    /// Units for control surface deflections from physics: "degrees" or "radians" (default: "radians")
    #[serde(default = "default_control_surface_units")]
    pub control_surface_units: String,

    pub color: String,                          // vehicle color name or hex code

    #[serde(default)]
    pub scale: Option<f64>,                     // optional scale multiplier (default: 1.0)

    #[serde(rename = "default_location[ft]")]
    pub default_location_ft: [f64; 3],          // initial position (x, y, z) in feet

    #[serde(rename = "default_orientation[deg]")]
    pub default_orientation_deg: [f64; 3],      // initial rotation (roll, pitch, yaw) in degrees
}

/// Configuration for physics packet parsing and control surfaces
/// This defines the structure of the incoming UDP packet from the physics engine
#[derive(Debug, Clone, Deserialize)]
pub struct ControlSurfacesConfig {
    /// UDP packet order - each element defines what data is at that position.
    /// Valid keywords:
    /// - State data: "ub", "vb", "wb" (body velocities), "xf", "yf", "zf" (position),
    ///   "e0", "ex", "ey", "ez" (quaternion)
    /// - Control surfaces: any name defined in stl_files with control_surface set
    /// - "skipthis" to skip a value
    pub order: Vec<String>,

    /// Precision of UDP packet data: single (f32, 4 bytes) or double (f64, 8 bytes)
    #[serde(default = "default_physics_precision")]
    pub precision: Precision,
}

fn default_physics_precision() -> Precision { Precision::Single }

/// Reserved keywords for physics state data
pub const PHYSICS_STATE_KEYWORDS: &[&str] = &["ub", "vb", "wb", "xf", "yf", "zf", "e0", "ex", "ey", "ez"];

impl ControlSurfacesConfig {
    /// Validate the control surfaces configuration
    pub fn validate(&self, stl_control_surfaces: &[String]) -> Result<(), String> {
        // Check that all required state keywords are present
        let required_keywords = ["ub", "vb", "wb", "xf", "yf", "zf", "e0", "ex", "ey", "ez"];
        for keyword in &required_keywords {
            if !self.order.contains(&keyword.to_string()) {
                return Err(format!(
                    "Required physics state keyword '{}' is missing from order. \
                    Required keywords: {:?}",
                    keyword, required_keywords
                ));
            }
        }

        // Check that each item in order is valid
        for item in &self.order {
            if item == "skipthis" {
                continue;
            }

            // Check if it's a physics state keyword
            if PHYSICS_STATE_KEYWORDS.contains(&item.as_str()) {
                continue;
            }

            // Check if it's a control surface defined in stl_files
            if stl_control_surfaces.contains(item) {
                continue;
            }

            return Err(format!(
                "Item '{}' in 'order' is not valid. Must be a physics state keyword ({:?}), \
                a control surface name from stl_files, or 'skipthis'",
                item, PHYSICS_STATE_KEYWORDS
            ));
        }

        // Check for duplicate state keywords (except skipthis)
        let mut seen_state = std::collections::HashSet::new();
        for item in &self.order {
            if item != "skipthis" && PHYSICS_STATE_KEYWORDS.contains(&item.as_str())
                && !seen_state.insert(item) {
                return Err(format!(
                    "Physics state keyword '{}' appears multiple times in 'order'",
                    item
                ));
            }
        }

        Ok(())
    }

    /// Get the list of control surface names from the order (excludes state keywords and skipthis)
    pub fn get_control_surface_names(&self) -> Vec<String> {
        self.order.iter()
            .filter(|item| {
                *item != "skipthis" && !PHYSICS_STATE_KEYWORDS.contains(&item.as_str())
            })
            .cloned()
            .collect()
    }
}

/// Control surface mapping - can be a single surface or a combination with coefficients
///
/// Supports two JSON formats:
/// - Simple string: `"da"` - maps 1:1 to control surface "da"
/// - Object with coefficients: `{"elevsym": 1.0, "elevasym": 1.0}` - combines multiple surfaces
///
/// Example for differential elevator:
/// - Right elevator: `{"elevsym": 1.0, "elevasym": 1.0}` = elevsym + elevasym
/// - Left elevator: `{"elevsym": 1.0, "elevasym": -1.0}` = elevsym - elevasym
#[derive(Debug, Clone)]
pub struct ControlSurfaceMapping {
    /// List of (surface_name, coefficient) pairs
    pub surfaces: Vec<(String, f64)>,
}

impl ControlSurfaceMapping {
    /// Create a simple 1:1 mapping to a single control surface
    pub fn single(name: String) -> Self {
        Self {
            surfaces: vec![(name, 1.0)],
        }
    }

    /// Create a combined mapping from multiple surfaces with coefficients
    pub fn combined(surfaces: Vec<(String, f64)>) -> Self {
        Self { surfaces }
    }

}

// Custom deserializer to handle both string and object formats
impl<'de> serde::Deserialize<'de> for ControlSurfaceMapping {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        use serde::de::{self, MapAccess, Visitor};

        struct ControlSurfaceMappingVisitor;

        impl<'de> Visitor<'de> for ControlSurfaceMappingVisitor {
            type Value = ControlSurfaceMapping;

            fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
                formatter.write_str("a string or an object mapping surface names to coefficients")
            }

            // Handle string format: "da"
            fn visit_str<E>(self, value: &str) -> Result<Self::Value, E>
            where
                E: de::Error,
            {
                Ok(ControlSurfaceMapping::single(value.to_string()))
            }

            // Handle object format: {"elevsym": 1.0, "elevasym": 1.0}
            fn visit_map<M>(self, mut map: M) -> Result<Self::Value, M::Error>
            where
                M: MapAccess<'de>,
            {
                let mut surfaces = Vec::new();
                while let Some((key, value)) = map.next_entry::<String, f64>()? {
                    surfaces.push((key, value));
                }
                if surfaces.is_empty() {
                    return Err(de::Error::custom("control_surface object must have at least one entry"));
                }
                Ok(ControlSurfaceMapping::combined(surfaces))
            }
        }

        deserializer.deserialize_any(ControlSurfaceMappingVisitor)
    }
}

/// Configuration for a single STL part (main body or control surface)
#[derive(Debug, Clone, Deserialize)]
pub struct StlPartConfig {
    /// Path to the STL file (if missing, this entry is treated as notes and skipped)
    #[serde(default)]
    pub file: Option<String>,

    /// If true, this is the main body - no hinge, transforms with physics data
    #[serde(default)]
    pub is_main: bool,

    /// Which control surface(s) this responds to.
    /// Can be a simple string like "da" or an object with coefficients like {"elevsym": 1.0, "elevasym": 1.0}
    #[serde(default)]
    pub control_surface: Option<ControlSurfaceMapping>,

    /// If true (default), deflection is applied directly. If false, side must be specified.
    #[serde(default = "default_symmetric")]
    pub symmetric: bool,

    /// "left" or "right" - required if symmetric is false
    /// right side: multiply deflection by -1, left side: multiply by 1
    #[serde(default)]
    pub side: Option<String>,

    /// Point on the hinge line [x, y, z] in body coordinates (required for non-main parts)
    #[serde(default)]
    pub hinge_point: Option<[f64; 3]>,

    /// Hinge rotation axis [x, y, z] normalized direction (required for non-main parts)
    #[serde(default)]
    pub hinge_line: Option<[f64; 3]>,

    /// Name of the part this connects to (required for non-main parts)
    #[serde(default)]
    pub connect_to: Option<String>,
}

fn default_symmetric() -> bool { true }
fn default_control_surface_units() -> String { "radians".to_string() }

impl VehicleConfig {
    /// Validate the vehicle configuration and return any errors
    pub fn validate(&self) -> Result<(), String> {
        // Check for at least one main part
        let main_parts: Vec<&String> = self.stl_files.iter()
            .filter(|(_, part)| part.file.is_some() && part.is_main)
            .map(|(name, _)| name)
            .collect();

        if main_parts.is_empty() {
            return Err("Vehicle config must have at least one part with is_main: true".to_string());
        }

        // Collect control surface names from stl_files (including all surfaces in combined mappings)
        let stl_control_surfaces: Vec<String> = self.stl_files.iter()
            .filter_map(|(_, part)| part.control_surface.as_ref())
            .flat_map(|mapping| mapping.surfaces.iter().map(|(name, _)| name.clone()))
            .collect();

        // Check that non-main parts have required fields
        let mut has_control_surfaces = false;
        for (name, part) in &self.stl_files {
            // Skip entries without file (notes)
            if part.file.is_none() {
                continue;
            }

            if !part.is_main {
                if part.connect_to.is_none() {
                    return Err(format!("Part '{}' must have 'connect_to' specified (not is_main)", name));
                }
                if part.hinge_point.is_none() {
                    return Err(format!("Part '{}' must have 'hinge_point' specified (not is_main)", name));
                }
                if part.hinge_line.is_none() {
                    return Err(format!("Part '{}' must have 'hinge_line' specified (not is_main)", name));
                }

                // Validate connect_to references a valid part
                let connect_to = part.connect_to.as_ref()
                    .ok_or_else(|| format!("Part '{}' missing connect_to field", name))?;
                if !self.stl_files.contains_key(connect_to) {
                    return Err(format!("Part '{}' connect_to '{}' does not exist", name, connect_to));
                }
                let connected_part = &self.stl_files[connect_to];
                if connected_part.file.is_none() {
                    return Err(format!("Part '{}' connect_to '{}' has no file", name, connect_to));
                }

                // Check symmetric/side
                if !part.symmetric && part.side.is_none() {
                    return Err(format!("Part '{}' has symmetric: false but no 'side' specified", name));
                }
                if let Some(ref side) = part.side {
                    if side != "left" && side != "right" {
                        return Err(format!("Part '{}' side must be 'left' or 'right', got '{}'", name, side));
                    }
                }

                if part.control_surface.is_some() {
                    has_control_surfaces = true;
                }
            }
        }

        // Check that either control_surfaces or control_surface_order is provided if there are control surfaces
        if has_control_surfaces && self.control_surfaces.is_none() && self.control_surface_order.is_none() {
            return Err("control_surfaces (or deprecated control_surface_order) is required when parts have control_surface defined".to_string());
        }

        // Validate control_surfaces config if provided
        if let Some(ref cs_config) = self.control_surfaces {
            cs_config.validate(&stl_control_surfaces)?;
        }

        Ok(())
    }

    /// Get the UDP packet order for physics data.
    /// Returns the order from control_surfaces.order if available,
    /// or builds a legacy order from control_surface_order.
    pub fn get_physics_order(&self) -> Option<Vec<String>> {
        if let Some(ref cs_config) = self.control_surfaces {
            Some(cs_config.order.clone())
        } else if let Some(ref cs_order) = self.control_surface_order {
            // Build legacy 88-byte packet order (22 floats)
            // t, ub, vb, wb, p, q, r, xf, yf, zf, e0, ex, ey, ez, 4x skip, control surfaces
            let mut order = vec![
                "skipthis".to_string(), // t
                "ub".to_string(),
                "vb".to_string(),
                "wb".to_string(),
                "skipthis".to_string(), // p
                "skipthis".to_string(), // q
                "skipthis".to_string(), // r
                "xf".to_string(),
                "yf".to_string(),
                "zf".to_string(),
                "e0".to_string(),
                "ex".to_string(),
                "ey".to_string(),
                "ez".to_string(),
                "skipthis".to_string(), // cmd 1
                "skipthis".to_string(), // cmd 2
                "skipthis".to_string(), // cmd 3
                "skipthis".to_string(), // cmd 4
            ];
            order.extend(cs_order.iter().cloned());
            Some(order)
        } else {
            None
        }
    }

    /// Get the precision for physics UDP data
    pub fn get_physics_precision(&self) -> Precision {
        if let Some(ref cs_config) = self.control_surfaces {
            cs_config.precision
        } else {
            Precision::Single
        }
    }

    /// Get the list of control surface names
    pub fn get_control_surface_names(&self) -> Vec<String> {
        if let Some(ref cs_config) = self.control_surfaces {
            cs_config.get_control_surface_names()
        } else if let Some(ref cs_order) = self.control_surface_order {
            cs_order.clone()
        } else {
            Vec::new()
        }
    }

    /// Get the deflection multiplier for a part based on its side
    /// right = -1, left = 1, symmetric = 1
    pub fn get_side_multiplier(part: &StlPartConfig) -> f64 {
        if part.symmetric {
            1.0
        } else {
            match part.side.as_deref() {
                Some("right") => -1.0,
                Some("left") => 1.0,
                _ => 1.0,
            }
        }
    }
}

// scene lighting configuration.
#[derive(Debug, Clone, Deserialize)]
pub struct LightingConfig {
    pub direction_world: [f64; 3],              // direction from the light source (normalized)

    #[serde(default = "default_sun_intensity")]
    pub aircraft_sun_intensity: f64,            // sun brightness on aircraft

    #[serde(default = "default_ground_intensity")]
    pub ground_sun_intensity: f64,              // sun brightness on terrain

    #[serde(default = "default_ambient")]
    pub ambient: f64,                           // ambient light level (fills shadows)
}

// default value functions for LightingConfig
fn default_sun_intensity() -> f64 { 8.0 }
fn default_ground_intensity() -> f64 { 1.0 }
fn default_ambient() -> f64 { 0.5 }

// udp config
#[derive(Debug, Clone, Deserialize)]
pub struct UdpConfig {
    pub enable_udp: bool,                       // whether to listen for UDP physics data
    pub port_id: u16,                           // UDP port number to listen on

    #[serde(default)]
    pub rust_enabled: Option<bool>,             // if true, run physics internally (not via subprocess)

    #[serde(default)]
    pub physics_exe: Option<String>,            // path to external physics executable

    #[serde(default)]
    pub physics_json: Option<String>,           // path to physics configuration JSON

    #[serde(default)]
    pub physics_path: Option<String>,           // working directory for physics subprocess
}


// pilot controls config
#[derive(Debug, Clone, Deserialize)]
pub struct PilotControlsConfig {
    #[serde(default)]
    pub enable_pilot_cmd: Option<bool>,         // whether to enable gamepad controller support

    #[serde(default)]
    pub enable_ps4: Option<bool>,               // deprecated: use enable_pilot_cmd instead

    pub udp_port_id: u16,                       // UDP port to send controller commands
    pub rate_hz: f32,                           // how often to send controller state (Hz)

    #[serde(default)]
    pub rust_enabled: Option<bool>,             // if true, handle controller internally

    #[serde(default)]
    pub controller_exe: Option<String>,         // path to external controller executable

    #[serde(default)]
    pub controller_json: Option<String>,        // path to controller configuration JSON

    #[serde(default)]
    pub controller_path: Option<String>,        // working directory for controller subprocess
}

impl PilotControlsConfig {
    /// Returns true if gamepad controller is enabled (checks both new and old config names)
    pub fn is_enabled(&self) -> bool {
        self.enable_pilot_cmd.unwrap_or_else(|| self.enable_ps4.unwrap_or(false))
    }
}


// controller status configuration for HUD display
#[derive(Debug, Clone, Deserialize)]
pub struct ControllerStatusConfig {
    /// Controllers that display commanded values when enabled (OFF when disabled)
    /// These are the base names (e.g., "p", "q", "throttle")
    pub cmd: Vec<String>,

    /// Controllers that display ON/OFF status only
    #[serde(rename = "bool")]
    pub bool_controllers: Vec<String>,

    /// UDP packet order - each element can be:
    /// - A controller name (reads 1 f64/f32 as enable flag)
    /// - A controller name + "_cmd" (reads 1 f64/f32 as commanded value)
    /// - "skipthis" (reads 1 f64/f32 and discards)
    pub order: Vec<String>,

    /// Raw units for each cmd controller (same length as cmd)
    /// Valid: "rad/s", "deg/s", "ft/s", "m/s", "rad", "deg", "m", "ft"
    pub cmd_raw_units: Vec<String>,

    /// Display units for each cmd controller (same length as cmd)
    /// Valid: "rad/s", "deg/s", "ft/s", "m/s", "rad", "deg", "m", "ft"
    pub cmd_display_units: Vec<String>,

    /// Precision of UDP packet data: double (f64, 8 bytes) or single (f32, 4 bytes)
    #[serde(default = "default_precision")]
    pub precision: Precision,
}

fn default_precision() -> Precision { Precision::Double }

/// Valid unit keywords for controller values
const VALID_UNITS: &[&str] = &["rad/s", "deg/s", "ft/s", "m/s", "rad", "deg", "m", "ft"];

impl ControllerStatusConfig {
    /// Validate the controller status configuration
    pub fn validate(&self) -> Result<(), String> {
        // Check cmd_raw_units length matches cmd
        if self.cmd_raw_units.len() != self.cmd.len() {
            return Err(format!(
                "cmd_raw_units length ({}) must match cmd length ({})",
                self.cmd_raw_units.len(),
                self.cmd.len()
            ));
        }

        // Check cmd_display_units length matches cmd
        if self.cmd_display_units.len() != self.cmd.len() {
            return Err(format!(
                "cmd_display_units length ({}) must match cmd length ({})",
                self.cmd_display_units.len(),
                self.cmd.len()
            ));
        }

        // Validate all units are valid keywords
        for (i, unit) in self.cmd_raw_units.iter().enumerate() {
            if !VALID_UNITS.contains(&unit.as_str()) {
                return Err(format!(
                    "Invalid cmd_raw_units[{}]: '{}'. Valid units: {:?}",
                    i, unit, VALID_UNITS
                ));
            }
        }
        for (i, unit) in self.cmd_display_units.iter().enumerate() {
            if !VALID_UNITS.contains(&unit.as_str()) {
                return Err(format!(
                    "Invalid cmd_display_units[{}]: '{}'. Valid units: {:?}",
                    i, unit, VALID_UNITS
                ));
            }
        }

        // Check that every cmd controller has both name and name_cmd in order
        for controller in &self.cmd {
            if !self.order.contains(controller) {
                return Err(format!(
                    "Controller '{}' in 'cmd' must have its enable flag '{}' in 'order'",
                    controller, controller
                ));
            }
            let cmd_name = format!("{}_cmd", controller);
            if !self.order.contains(&cmd_name) {
                return Err(format!(
                    "Controller '{}' in 'cmd' must have its value '{}' in 'order'",
                    controller, cmd_name
                ));
            }
        }

        // Check that every bool controller is in order
        for controller in &self.bool_controllers {
            if !self.order.contains(controller) {
                return Err(format!(
                    "Controller '{}' in 'bool' is not listed in 'order'",
                    controller
                ));
            }
        }

        // Check that every item in order is valid
        for item in &self.order {
            if item == "skipthis" {
                continue;
            }

            // Check if it's an enable flag (in cmd or bool)
            if self.cmd.contains(item) || self.bool_controllers.contains(item) {
                continue;
            }

            // Check if it's a _cmd value
            if item.ends_with("_cmd") {
                let base_name = &item[..item.len() - 4];
                if self.cmd.iter().any(|c| c == base_name) {
                    continue;
                }
            }

            return Err(format!(
                "Item '{}' in 'order' is not valid. Must be a controller name from 'cmd' or 'bool', \
                a '_cmd' suffix value, or 'skipthis'",
                item
            ));
        }

        // Check for duplicates in order (except skipthis)
        let mut seen = std::collections::HashSet::new();
        for item in &self.order {
            if item != "skipthis" && !seen.insert(item) {
                return Err(format!(
                    "Item '{}' appears multiple times in 'order'",
                    item
                ));
            }
        }

        Ok(())
    }

    /// Returns true if the controller is a command type (shows value when enabled)
    pub fn is_cmd(&self, name: &str) -> bool {
        self.cmd.iter().any(|c| c == name)
    }

    /// Get the index of a cmd controller in the cmd list
    pub fn cmd_index(&self, name: &str) -> Option<usize> {
        self.cmd.iter().position(|c| c == name)
    }

    /// Get the display unit for a cmd controller
    pub fn get_display_unit(&self, name: &str) -> Option<&str> {
        self.cmd_index(name).map(|i| self.cmd_display_units[i].as_str())
    }

    /// Get the unit conversion factor from raw to display units for a cmd controller
    pub fn get_conversion_factor(&self, name: &str) -> Option<f64> {
        self.cmd_index(name).map(|i| {
            let raw = &self.cmd_raw_units[i];
            let display = &self.cmd_display_units[i];
            unit_conversion_factor(raw, display)
        })
    }

}

/// Calculate conversion factor from raw_unit to display_unit
fn unit_conversion_factor(raw: &str, display: &str) -> f64 {
    if raw == display {
        return 1.0;
    }

    // Angle conversions
    let deg_per_rad = 180.0 / std::f64::consts::PI;

    match (raw, display) {
        // Angular rate conversions
        ("rad/s", "deg/s") => deg_per_rad,
        ("deg/s", "rad/s") => 1.0 / deg_per_rad,

        // Angle conversions
        ("rad", "deg") => deg_per_rad,
        ("deg", "rad") => 1.0 / deg_per_rad,

        // Length conversions
        ("m", "ft") => 3.28084,
        ("ft", "m") => 1.0 / 3.28084,

        // Velocity conversions
        ("m/s", "ft/s") => 3.28084,
        ("ft/s", "m/s") => 1.0 / 3.28084,

        // Same unit type, no conversion needed
        _ => 1.0,
    }
}

// hud configuration
#[derive(Debug, Clone, Deserialize)]
pub struct HudConfig {
    #[serde(default = "default_hud_enable")]
    pub enable: bool,                           // whether to show the HUD

    #[serde(default = "default_hud_color")]
    pub color: String,                          // HUD text/element color

    #[serde(default = "default_hud_opacity")]
    pub opacity: f32,                           // HUD transparency (0.0 = invisible, 1.0 = opaque)

    #[serde(default = "default_hud_font_size")]
    pub font_size: f32,                         // text size in pixels

    #[serde(default)]
    pub udp_receive_controller_state: Option<u16>,  // optional port to receive controller state for HUD display

    #[serde(default)]
    pub controller_status: Option<ControllerStatusConfig>,  // controller status display configuration
}

// default value functions for HudConfig
fn default_hud_enable() -> bool { true }
fn default_hud_color() -> String { "lime".to_string() }
fn default_hud_opacity() -> f32 { 0.8 }
fn default_hud_font_size() -> f32 { 14.0 }


// color parsing utility - add colors to constants_m::named_color_map()
pub fn parse_color(c: &str, default_alpha: f32) -> Result<[f32; 4], String> {
    // lazy_static! creates a static variable that is initialized once on first access.
    // this avoids rebuilding the HashMap every time parse_color is called.
    lazy_static::lazy_static! {
        static ref NAMED_COLORS: HashMap<&'static str, [f32; 3]> =
            crate::constants_m::named_color_map();
    }

    let s = c.trim().to_lowercase();    // normalize: remove whitespace, convert to lowercase

    // try to find in named colors first
    if let Some(&rgb) = NAMED_COLORS.get(s.as_str()) {
        return Ok([rgb[0], rgb[1], rgb[2], default_alpha]);
    }

    // try to parse as hex color
    if let Some(h) = s.strip_prefix('#') {
        // helper closure to convert a 2-character hex string to a float 0.0-1.0
        let hex_to_f32 = |hex: &str| -> Result<f32, String> {
            u8::from_str_radix(hex, 16)              // parse hex string as u8 (0-255)
                .map(|v| v as f32 / 255.0)          // convert to 0.0-1.0 range
                .map_err(|e| e.to_string())         // convert parse error to String
        };

        match h.len() {
            6 => {
                // #RRGGBB format - use default alpha
                let r = hex_to_f32(&h[0..2])?;      // &h[0..2] is a slice of chars 0 and 1
                let g = hex_to_f32(&h[2..4])?;
                let b = hex_to_f32(&h[4..6])?;
                Ok([r, g, b, default_alpha])
            }
            8 => {
                // #RRGGBBAA format - includes alpha
                let r = hex_to_f32(&h[0..2])?;
                let g = hex_to_f32(&h[2..4])?;
                let b = hex_to_f32(&h[4..6])?;
                let a = hex_to_f32(&h[6..8])?;
                Ok([r, g, b, a])
            }
            _ => Err(format!("Invalid hex color length: {} (expected 6 or 8)", h.len())),
        }
    } else {
        Err(format!("Unrecognized color format: '{}'. Use a named color or hex code (#RRGGBB)", c))
    }
}

// config implementation
impl Config {
    pub fn load(path: &str) -> Result<Self, String> {
        // read file contents to string
        let content = std::fs::read_to_string(path)
            .map_err(|e| format!("Failed to read config file '{}': {}", path, e))?;

        // parse json into Config struct using serde
        let mut config: Config = serde_json::from_str(&content)
            .map_err(|e| format!("Failed to parse config '{}': {}", path, e))?;

        // If active_profile is set, load machine config and compute derived paths
        // Clone the profile to avoid borrow conflict with load_profile
        if let Some(profile) = config.active_profile.clone() {
            let config_dir = Path::new(path).parent().unwrap_or(Path::new("."));
            config.load_profile(config_dir, &profile)?;
        }

        // Validate controller_status config if present
        if let Some(ref hud) = config.hud {
            if let Some(ref controller_status) = hud.controller_status {
                controller_status.validate()
                    .map_err(|e| format!("Invalid controller_status config: {}", e))?;
            }
        }

        Ok(config)
    }

    /// Load machine config and compute derived paths from active profile
    fn load_profile(&mut self, config_dir: &Path, profile: &ActiveProfile) -> Result<(), String> {
        // Resolve the machine config — either load from a sibling file, or use
        // the inline object the user embedded directly in active_profile.
        let machine = match &profile.machine_config {
            MachineConfigRef::Inline(m) => m.clone(),
            MachineConfigRef::File(filename) => {
                let machine_config_path = config_dir.join(filename);
                Self::load_machine_config(&machine_config_path, filename)?
            }
        };

        // Validate that the selected physics simulator exists, but only if the
        // machine config actually defines a physics map. An empty map means the
        // user has opted out of Rust-managed physics (viewer-only setups).
        if !machine.physics.is_empty() && !machine.physics.contains_key(&profile.physics) {
            let available: Vec<&String> = machine.physics.keys().collect();
            return Err(format!(
                "Physics simulator '{}' not found in machine config.\nAvailable simulators: {:?}",
                profile.physics, available
            ));
        }

        // Compute derived paths
        let derived = Self::compute_derived_paths(profile, &machine)?;

        // Apply mesh path prefix to vehicle STL files
        self.apply_mesh_paths(&derived.mesh_path);

        // Override tiles_dir from machine config if both streaming terrain is
        // configured AND the machine config provides a tiles_dir. Grid-mode
        // builds don't need tiles_dir at all.
        if let (Some(streaming), Some(tiles_dir)) =
            (self.ground.streaming.as_mut(), machine.tiles_dir.as_ref())
        {
            streaming.tiles_dir = Some(tiles_dir.clone());
        }

        self.machine = Some(machine);
        self.derived = Some(derived);

        Ok(())
    }

    /// Load machine-specific config from file
    fn load_machine_config(path: &Path, filename: &str) -> Result<MachineConfig, String> {
        let content = std::fs::read_to_string(path).map_err(|_| {
            format!(
                "Machine config not found: '{}'\n\n\
                Hint: A minimal viewer-only '{}' only needs:\n\
                {{\n  \
                  \"mesh_base_path\": \"meshes\"\n\
                }}\n\n\
                For a full setup that auto-launches physics and the controller, add:\n\
                {{\n  \
                  \"mesh_base_path\": \"meshes\",\n  \
                  \"tiles_dir\": \"path/to/terrain/tiles\",\n  \
                  \"physics\": {{\n    \
                    \"mavrik\": {{ \"exe\": \"mavrik.exe\", \"path\": \"path/to/input_files\" }}\n  \
                  }},\n  \
                  \"controller_base_path\": \"path/to/Controllers\"\n\
                }}",
                filename, filename
            )
        })?;

        serde_json::from_str(&content)
            .map_err(|e| format!("Failed to parse machine config '{}': {}", filename, e))
    }

    /// Compute derived paths from profile and machine config.
    /// Physics and controller paths are only derived when the corresponding
    /// machine-config sections exist; otherwise their fields are None and the
    /// runtime treats them as "not configured" (no auto-launch).
    fn compute_derived_paths(profile: &ActiveProfile, machine: &MachineConfig) -> Result<DerivedPaths, String> {
        let vehicle = &profile.vehicle;

        // Physics paths: only derive when the machine config has the entry.
        let (physics_exe, physics_path, physics_json) = match machine.physics.get(&profile.physics) {
            Some(physics) => (
                Some(physics.exe.clone()),
                Some(physics.path.clone()),
                Some(format!("{}input.json", vehicle)),
            ),
            None => (None, None, None),
        };

        // Controller paths: only derive when controller_base_path is configured.
        let (controller_exe, controller_path, controller_json) = match machine.controller_base_path.as_ref() {
            Some(base) => {
                let exe = if cfg!(windows) {
                    format!("{}controller.exe", vehicle)
                } else {
                    format!("{}controller", vehicle)
                };
                let path = format!("{}/{}controller", base, vehicle);
                (Some(exe), Some(path), Some("controller.json".to_string()))
            }
            None => (None, None, None),
        };

        // Mesh path is always required.
        let mesh_folder = machine.mesh_overrides
            .get(vehicle)
            .cloned()
            .unwrap_or_else(|| vehicle.clone());
        let mesh_path = format!("{}/{}", machine.mesh_base_path, mesh_folder);

        Ok(DerivedPaths {
            physics_exe,
            physics_path,
            physics_json,
            controller_exe,
            controller_path,
            controller_json,
            mesh_path,
        })
    }

    /// Apply mesh path prefix to all STL file paths in vehicle config
    fn apply_mesh_paths(&mut self, mesh_path: &str) {
        for part in self.vehicle.stl_files.values_mut() {
            if let Some(ref mut file) = part.file {
                // Only modify if it doesn't already have the mesh path
                if !file.starts_with(mesh_path) {
                    // Extract just the filename from the path
                    let filename = Path::new(file)
                        .file_name()
                        .and_then(|f| f.to_str())
                        .unwrap_or(file);
                    *file = format!("{}/{}", mesh_path, filename);
                }
            }
        }
    }

    // check if streaming terrain is enabled and properly configured.
    pub fn use_streaming_terrain(&self) -> bool {
        self.ground.mode == GroundMode::Streaming
            && self.ground.streaming.as_ref()
                .map(|s| s.tiles_dir.is_some())  // check if tiles_dir is configured
                .unwrap_or(false)                // default to false if streaming config missing
    }

    /// Get physics exe, json, and path - from derived paths if available, else from udp config (legacy)
    pub fn get_physics_paths(&self) -> (Option<String>, Option<String>, Option<String>) {
        if let Some(ref derived) = self.derived {
            (
                derived.physics_exe.clone(),
                derived.physics_json.clone(),
                derived.physics_path.clone(),
            )
        } else {
            (
                self.udp.physics_exe.clone(),
                self.udp.physics_json.clone(),
                self.udp.physics_path.clone(),
            )
        }
    }

    /// Get controller exe, json, and path - from derived paths if available, else from pilot_controls config (legacy)
    pub fn get_controller_paths(&self) -> (Option<String>, Option<String>, Option<String>) {
        if let Some(ref derived) = self.derived {
            (
                derived.controller_exe.clone(),
                derived.controller_json.clone(),
                derived.controller_path.clone(),
            )
        } else if let Some(ref pc) = self.pilot_controls {
            (
                pc.controller_exe.clone(),
                pc.controller_json.clone(),
                pc.controller_path.clone(),
            )
        } else {
            (None, None, None)
        }
    }
}