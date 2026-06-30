// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins


//! ## Key Concepts for Rust Beginners
//! - `Option<T>`: A type that can be `Some(value)` or `None` - Rust's way of handling nullable values
//! - `Arc<T>`: Atomic Reference Counted pointer - allows shared ownership across threads
//! - `&` vs `&mut`: Immutable vs mutable references (borrowing)
//! - `impl`: Implementation block - where you define methods for a struct
//! - `match`: Pattern matching - like a powerful switch statement
//! - `if let`: Conditional pattern matching - combines `if` with pattern matching

use tracing::{info, warn, error};
use tracing_subscriber::{fmt, EnvFilter};

use std::env;              // for reading command line arguments
use std::sync::Arc;        // Arc = Atomic Reference Counted smart pointer. Allows multiple owners of data across threads
use std::time::Instant;    // for measuring time/frame rates
use nalgebra::Vector3;     // nalgebra is a linear algebra library for 3D math. Vector3 is a 3 component vector
use winit::{               // winit: Cross-platform window creation and event handling
    application::ApplicationHandler,  // trait we implement to handle window events
    event::{ElementState, KeyEvent, WindowEvent},  // types of events we can receive
    event_loop::{ActiveEventLoop, ControlFlow, EventLoop},  // main event loop types
    keyboard::{KeyCode, PhysicalKey},  // keyboard input types
    window::{Window, WindowId},  // window types
};

// mod declares a module. Rust will look for either:
    // a file named module_name.rs in the same directory, or
    // a folder named module_name with a mod.rs inside
mod constants_m;        // physical constants declared here
mod config_m;           // configuration file loading and parsing
mod renderer;           // GPU renderer setup (wgpu pipelines, etc.)
mod mesh;               // 3D mesh loading and GPU upload
mod vehicle_m;          // multi-part vehicle with control surfaces
mod camera_m;           // camera positioning and matrix calculations
mod math_m;             // math utilities for quaternion/euler angle conversions, coordinate frame transformations
mod udp_m;
mod hud_m;              // Heads up display rendering module
mod pilot_controls_m;   // gamepad controller input handling
mod subprocess_m;       // managing child processes (threads) (physics, controller, etc.)
mod ground;             // terrain rendering (streaming tiles, grid)
mod sky;                // atmospheric sky rendering

use constants_m::{SPEED_OF_SOUND_SEA_LEVEL_FT_S, FT_TO_M};
use config_m::Config;
use renderer::WgpuRenderer;
use ground::{StreamingTerrainManager, TerrainConfig, GroundGrid};
use camera_m::{CameraCache, CameraController, CameraMode, CameraState};
use vehicle_m::Vehicle;
use hud_m::{Hud, HudConfig, HudState};
use udp_m::{UdpStateReceiver, ControllerStateReceiver};
use subprocess_m::SubprocessManager;
use pilot_controls_m::GamepadController;
use sky::SkyRenderer;


// 1. load config from json file (or use default values)
// 2. create the winit event loop
// 3. create our application and run it
fn main() {
    // Initialize tracing subscriber with selective log filtering
    // - Our app logs at info level
    // - wgpu/naga logs filtered to warn (suppresses verbose Vulkan loader messages)
    let filter = EnvFilter::new("flightsim_graphics=info,wgpu_core=warn,wgpu_hal=warn,naga=warn,warn");
    fmt()
        .with_env_filter(filter)
        .with_target(false)
        .init();

    // Require the config file as a command-line argument (no default).
    let config_path = match env::args().nth(1) {
        Some(p) => p,
        None => {
            eprintln!("ERROR: no config file given.");
            eprintln!("Usage: flightsim_graphics <graphics_config.json>");
            std::process::exit(1);
        }
    };

    info!(path = %config_path, "Loading configuration");

    // match is Rust's pattern matching - it must handle all possible cases
    // Config::load() returns `Result<Config, Error>`:
    let config = match Config::load(&config_path) {
        Ok(c) => c,  // on success, unwrap the config
        Err(e) => {
            error!(error = %e, "Failed to load config");
            std::process::exit(1);  // exit with error code 1
        }
    };

    // .expect() is like .unwrap() but with a custom panic message
    // both will crash the program if the Result is Err.
    let event_loop = EventLoop::new().expect("Failed to create event loop");
    event_loop.set_control_flow(ControlFlow::Poll); // ControlFlow::Poll means the event loop runs continuously, updating as fast as possible
    let mut app = FlightSimApp::new(config);    // create the application with the loaded config

    // .run_app() starts the event loop and never returns until exit
    // it takes ownership of 'app' and calls our event handlers
    event_loop.run_app(&mut app).expect("Event loop error");
}


// application structs: FlightSimApp and AppState
struct FlightSimApp {
    config: Config,
    state: Option<AppState>,
    /// Present during background initialization — window is visible and responsive
    /// while shader compilation and asset loading run on a background thread.
    loading: Option<LoadingState>,
}

/// State during background initialization. Only the window stays on the main thread;
/// all GPU work (adapter enumeration, device creation, shader compilation) runs in the background.
struct LoadingState {
    window: Arc<Window>,
    result_rx: std::sync::mpsc::Receiver<InitResult>,
}

/// Results from background initialization thread — everything needed to build AppState.
struct InitResult {
    context: renderer::WgpuContext,
    components: renderer::RendererComponents,
    sky: Option<SkyRenderer>,
    terrain: Option<StreamingTerrainManager>,
    ground_grid: Option<GroundGrid>,
    vehicle: Option<Vehicle>,
    egui_renderer: egui_wgpu::Renderer,
}

// holds all runtime state for the application. only created after the window exists.
//
// IMPORTANT: Field order determines drop order. Rust drops fields top-to-bottom.
// Thread-owning resources are declared first so their threads stop before GPU
// resources are freed. This prevents use-after-free during shutdown.
struct AppState {
    // --- DROPPED FIRST: stop all background threads before GPU teardown ---
    terrain: Option<StreamingTerrainManager>,   // owns tile loader worker threads
    physics_receiver: Option<UdpStateReceiver>, // owns UDP receiver thread
    controller_receiver: Option<ControllerStateReceiver>,   // owns UDP receiver thread
    _gamepad_controller: Option<GamepadController>,  // owns gamepad polling thread
    subprocess_manager: SubprocessManager,  // owns child processes (physics, controller)

    // --- DROPPED SECOND: GPU resources (safe now that all threads are stopped) ---
    sky: Option<SkyRenderer>,
    ground_grid: Option<GroundGrid>,
    vehicle: Option<Vehicle>,
    hud: Hud,
    egui_renderer: egui_wgpu::Renderer,
    egui_state: egui_winit::State,
    egui_ctx: egui::Context,
    renderer: WgpuRenderer,
    window: Arc<Window>,

    // --- Non-resource fields (order doesn't matter) ---
    camera_controller: CameraController,

    // store the config needed to restart the physics subprocess by pressing 'r'
    physics_exe: Option<String>,
    physics_json: Option<String>,
    physics_path: Option<String>,

    camera_mode: CameraMode,
    cam_euler: [f64; 3],
    cam_location: [f64; 3],
    cam_distance: f64,
    vehicle_loc0: Vector3<f64>,
    vehicle_euler0: [f64; 3],
    ground_altitude: f64,
    clear_color: [f32; 3],

    last_instant: Instant,
    frame_count: u32,
    last_fps_print: Instant,
    waiting_for_physics: bool,
}

impl FlightSimApp {
    fn new(config: Config) -> Self {
        Self {
            config,
            state: None,
            loading: None,
        }
    }
}

// ApplicationHandler Implementation
impl ApplicationHandler for FlightSimApp {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.state.is_some() || self.loading.is_some() {
            return;
        }

        let window_attrs = Window::default_attributes()
            .with_title("Flight Simulator")
            .with_maximized(true);

        let window = Arc::new(
            event_loop
                .create_window(window_attrs)
                .expect("Failed to create window"),
        );

        // Create wgpu instance + surface on main thread. Instance::new() triggers
        // Vulkan driver initialization which can take several seconds, but it must
        // happen before we can create the surface (which needs the window handle).
        // After this, ALL remaining GPU work moves to a background thread.
        let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor {
            backends: wgpu::Backends::PRIMARY,
            ..Default::default()
        });
        let surface = instance.create_surface(Arc::clone(&window))
            .expect("Failed to create wgpu surface");
        let window_size = window.inner_size();

        info!("Window + surface created, starting background GPU initialization");

        let config = self.config.clone();
        let (tx, rx) = std::sync::mpsc::sync_channel(1);
        std::thread::Builder::new()
            .name("init".to_string())
            .spawn(move || {
                let result = build_systems_full(instance, surface, window_size, config);
                let _ = tx.send(result);
            })
            .expect("Failed to spawn init thread");

        self.loading = Some(LoadingState {
            window,
            result_rx: rx,
        });
    }

    fn window_event(
        &mut self,
        event_loop: &ActiveEventLoop,
        _window_id: WindowId,
        event: WindowEvent,
    ) {
        // --- Handle events during background loading ---
        if let Some(loading) = &self.loading {
            match event {
                WindowEvent::CloseRequested => { event_loop.exit(); return; }
                WindowEvent::KeyboardInput {
                    event: KeyEvent { physical_key: PhysicalKey::Code(KeyCode::Escape), state: ElementState::Pressed, .. }, ..
                } => { event_loop.exit(); return; }
                WindowEvent::RedrawRequested => {
                    // Check if background init is done
                    match loading.result_rx.try_recv() {
                        Ok(result) => {
                            let loading = self.loading.take().unwrap();
                            self.finalize_init(loading, result);
                        }
                        Err(std::sync::mpsc::TryRecvError::Empty) => {} // not ready yet — keep waiting
                        Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                            // The init thread panicked before sending a result. Without this arm we'd
                            // spin forever on a blank window; log and exit cleanly instead.
                            error!("Background initialization thread terminated without a result; exiting");
                            event_loop.exit();
                        }
                    }
                    return;
                }
                _ => { return; }
            }
        }

        // --- Normal event handling (fully initialized) ---
        let state = match self.state.as_mut() {
            Some(s) => s,
            None => return,
        };

        let _ = state.egui_state.on_window_event(&state.window, &event);

        match event {
            WindowEvent::CloseRequested => {
                state.shutdown();
                event_loop.exit();
            }
            WindowEvent::Resized(size) => {
                state.renderer.resize(size);
            }

            WindowEvent::KeyboardInput {
                event: KeyEvent {
                    physical_key: PhysicalKey::Code(key),
                    state: ElementState::Pressed,
                    ..
                },
                ..
            } => {
                match key {
                    KeyCode::Escape => {
                        state.shutdown();
                        event_loop.exit();
                    }
                    
                    // V: toggle camera view mode
                    KeyCode::KeyV => {
                        state.camera_mode = state.camera_mode.toggle();
                        info!(mode = ?state.camera_mode, "Camera mode changed");
                    }
                    
                    // Enter: start physics if waiting
                    KeyCode::Enter => {
                        if state.waiting_for_physics {
                            // start physics subprocess if config is available
                            if let (Some(exe), Some(json), Some(path)) =
                                (&state.physics_exe, &state.physics_json, &state.physics_path)
                            {
                                state.subprocess_manager.start_physics(exe, json, path);
                            }
                            state.waiting_for_physics = false;
                        }
                    }
                    
                    // R: restart physics
                    KeyCode::KeyR => {
                        if let (Some(exe), Some(json), Some(path)) =
                            (&state.physics_exe, &state.physics_json, &state.physics_path)
                        {
                            info!("Restarting physics...");
                            state.subprocess_manager.stop_physics();
                            state.subprocess_manager.start_physics(exe, json, path);
                            state.waiting_for_physics = false;
                        }
                    }
                    
                    // ignore other keys
                    _ => {}
                }
            }

            WindowEvent::RedrawRequested => {
                state.update_and_render();
            }

            // ignore all other events
            _ => {}
        }
    }

    fn about_to_wait(&mut self, _event_loop: &ActiveEventLoop) {
        if let Some(loading) = &self.loading {
            loading.window.request_redraw();
        } else if let Some(state) = &self.state {
            state.window.request_redraw();
        }
    }
}

// =============================================================================
// BACKGROUND INITIALIZATION
// =============================================================================

/// Runs on a background thread. Creates adapter + device, configures surface,
/// compiles all shader pipelines, loads meshes, and sets up terrain.
/// Instance and surface are created on the main thread and passed in.
fn build_systems_full(
    instance: wgpu::Instance,
    surface: wgpu::Surface<'static>,
    window_size: winit::dpi::PhysicalSize<u32>,
    config: Config,
) -> InitResult {
    let t0 = Instant::now();

    // Create adapter + device + configure surface (the remaining slow GPU init)
    let context = renderer::WgpuContext::from_parts(instance, surface, window_size)
        .expect("Failed to create GPU context");
    info!(elapsed_ms = t0.elapsed().as_millis(), "GPU context created");

    let device = Arc::clone(&context.device);
    let queue = Arc::clone(&context.queue);
    let surface_format = context.surface_config.format;
    let supports_bc = device.features().contains(wgpu::Features::TEXTURE_COMPRESSION_BC);

    // Build renderer pipelines + buffers
    let t = Instant::now();
    let components = WgpuRenderer::build_components(&device, surface_format, &config);
    info!(elapsed_ms = t.elapsed().as_millis(), "Renderer pipelines compiled");

    // Sky renderer (4 shader compilations + LUT textures)
    let sky = if let Some(ref sky_config) = config.sky {
        if sky_config.enabled {
            let t = Instant::now();
            let sky = SkyRenderer::new(&device, sky_config, surface_format);
            info!(elapsed_ms = t.elapsed().as_millis(), "Sky renderer compiled");
            Some(sky)
        } else {
            None
        }
    } else {
        None
    };

    // Vehicle (STL file loading + GPU buffer upload)
    let vehicle = {
        let t = Instant::now();
        match Vehicle::load(&device, &components.bind_group_layouts, &config.vehicle) {
            Ok(v) => {
                info!(elapsed_ms = t.elapsed().as_millis(), "Vehicle loaded");
                Some(v)
            }
            Err(e) => {
                error!(error = %e, "Failed to load vehicle");
                None
            }
        }
    };

    // Terrain or ground grid
    let mut terrain = None;
    let mut ground_grid = None;

    if config.use_streaming_terrain() {
        let stream_cfg = config.ground.streaming.as_ref()
            .expect("streaming config must exist when use_streaming_terrain() is true");
        let terrain_config = TerrainConfig::new(stream_cfg, config.ground.max_draw_distance_ft);

        let mut manager = StreamingTerrainManager::new(
            Arc::clone(&device),
            Arc::clone(&queue),
            renderer::BindGroupLayouts::new(&device),
            terrain_config,
            supports_bc,
        );

        match manager.load_index() {
            Ok(()) => {
                info!("Ground: streaming terrain");
                terrain = Some(manager);
            }
            Err(e) => {
                error!(error = %e, "Failed to load terrain index");
            }
        }
    }

    if terrain.is_none() && config.ground.mode == config_m::GroundMode::Grid {
        info!("Ground: grid mode");
        let color = ground::parse_ground_color(&config.ground.color);
        ground_grid = Some(GroundGrid::new(
            &device,
            &components.bind_group_layouts,
            -config.ground.altitude_ft,  // grid world-z (NED) = -altitude_ft, so +altitude_ft = up (MSL)
            config.ground.grid_scale_ft,
            config.ground.max_draw_distance_ft,
            color,
        ));
    }

    // egui GPU renderer (1 shader compilation)
    let t = Instant::now();
    let egui_renderer = egui_wgpu::Renderer::new(
        &device,
        surface_format,
        egui_wgpu::RendererOptions {
            depth_stencil_format: None,
            msaa_samples: 1,
            dithering: false,
            predictable_texture_filtering: false,
        },
    );
    info!(ms = t.elapsed().as_millis(), "egui renderer compiled");

    info!(total_ms = t0.elapsed().as_millis(), "Background initialization complete");

    InitResult { context, components, sky, terrain, ground_grid, vehicle, egui_renderer }
}

impl FlightSimApp {
    /// Called when background initialization completes. Assembles the full AppState
    /// from the loading context and background thread results.
    fn finalize_init(&mut self, loading: LoadingState, result: InitResult) {
        let window = loading.window;

        // Assemble the complete renderer from the context + background-built components
        let renderer = WgpuRenderer::assemble(result.context, result.components);

        let cam_euler = self.config.camera.orientation_deg.map(|d| d.to_radians());
        let cam_location = self.config.camera.location_ft;
        let vehicle_euler0 = self.config.vehicle.default_orientation_deg.map(|d| d.to_radians());

        let camera_cache = CameraCache::new(
            self.config.camera.view_plane.distance_ft,
            self.config.camera.view_plane.aspect_ratio,
            self.config.camera.view_plane.angle_deg,
            self.config.ground.max_draw_distance_ft,
        );
        let camera_controller = CameraController::new(camera_cache, cam_euler, vehicle_euler0);
        let cam_distance = Vector3::new(cam_location[0], cam_location[1], cam_location[2]).norm();
        let vehicle_loc0 = Vector3::new(
            self.config.vehicle.default_location_ft[0],
            self.config.vehicle.default_location_ft[1],
            self.config.vehicle.default_location_ft[2],
        );

        // UDP receivers (fast — just bind sockets and spawn listener threads)
        let physics_receiver = if self.config.udp.enable_udp {
            if let Some(order) = self.config.vehicle.get_physics_order() {
                let precision = self.config.vehicle.get_physics_precision();
                let control_surface_names = self.config.vehicle.get_control_surface_names();
                info!(port = self.config.udp.port_id, "UDP: receiving physics state");
                let default_quat = math_m::euler_to_quat(vehicle_euler0);
                Some(UdpStateReceiver::new(
                    self.config.udp.port_id, order, precision,
                    Vector3::zeros(), vehicle_loc0, default_quat, control_surface_names,
                ))
            } else { None }
        } else { None };

        let controller_receiver = if let Some(ref hud_cfg) = self.config.hud {
            if let (Some(port), Some(ref ctrl_cfg)) = (hud_cfg.udp_receive_controller_state, &hud_cfg.controller_status) {
                info!(port = port, "UDP: receiving controller state");
                Some(ControllerStateReceiver::new(port, ctrl_cfg))
            } else { None }
        } else { None };

        // HUD
        let hud_config = if let Some(ref hud_json) = self.config.hud {
            HudConfig {
                enable: hud_json.enable,
                color: hud_m::color_to_color32(config_m::parse_color(&hud_json.color, hud_json.opacity).unwrap_or([0.0, 1.0, 0.0, hud_json.opacity])),
                opacity: hud_json.opacity,
                font_size: hud_json.font_size,
                show_speed: true, show_altitude: true, show_heading: true, show_pitch_roll: true,
                show_controller_status: hud_json.udp_receive_controller_state.is_some() && hud_json.controller_status.is_some(),
                controller_status_config: hud_json.controller_status.clone(),
            }
        } else {
            HudConfig::default()
        };

        // egui (windowing part must be on main thread)
        let egui_ctx = egui::Context::default();
        let egui_state = egui_winit::State::new(
            egui_ctx.clone(), egui::ViewportId::ROOT, &window,
            Some(window.scale_factor() as f32), None, None,
        );

        let bg_color_str = self.config.background.as_ref().map(|b| b.color.as_str()).unwrap_or("white");
        let clear_color = config_m::parse_color(bg_color_str, 1.0)
            .map(|c| [c[0], c[1], c[2]])
            .unwrap_or([1.0, 1.0, 1.0]);

        let mut subprocess_manager = SubprocessManager::new();
        if let Some(ref pc) = self.config.pilot_controls {
            if pc.rust_enabled.unwrap_or(false) {
                if let (Some(exe), Some(json), Some(path)) = self.config.get_controller_paths() {
                    subprocess_manager.start_controller(&exe, &json, &path);
                }
            }
        }

        let gamepad_controller = if let Some(ref pc) = self.config.pilot_controls {
            if pc.is_enabled() {
                let mut ctrl = GamepadController::new("127.0.0.1".to_string(), pc.udp_port_id, pc.rate_hz);
                if ctrl.start() {
                    info!(port = pc.udp_port_id, rate_hz = pc.rate_hz, "Gamepad controls active");
                    Some(ctrl)
                } else { None }
            } else { None }
        } else { None };

        let (physics_exe, physics_json, physics_path) = self.config.get_physics_paths();

        self.state = Some(AppState {
            terrain: result.terrain,
            physics_receiver,
            controller_receiver,
            _gamepad_controller: gamepad_controller,
            subprocess_manager,
            sky: result.sky,
            ground_grid: result.ground_grid,
            vehicle: result.vehicle,
            hud: Hud::new(hud_config),
            egui_renderer: result.egui_renderer,
            egui_state,
            egui_ctx,
            renderer,
            window,
            camera_controller,
            physics_exe, physics_json, physics_path,
            camera_mode: CameraMode::from_config(&self.config.camera.fix_to),
            cam_euler, cam_location, cam_distance,
            vehicle_loc0, vehicle_euler0,
            ground_altitude: self.config.ground.altitude_ft,
            clear_color,
            last_instant: Instant::now(),
            frame_count: 0,
            last_fps_print: Instant::now(),
            waiting_for_physics: self.config.udp.rust_enabled.unwrap_or(false),
        });

        info!("Initialization complete — rendering started");
    }
}

// AppState implementation - main update/render loop
impl AppState {
    /// Explicit ordered shutdown: stop all threads and subprocesses before GPU teardown.
    /// Called from CloseRequested/Escape before event_loop.exit().
    /// Safe to call multiple times (each take()/cleanup() is idempotent).
    fn shutdown(&mut self) {
        info!("Shutting down...");
        // 1. Stop terrain loader threads (drops the send channel, workers exit)
        self.terrain.take();
        // 2. Stop UDP receiver threads
        self.physics_receiver.take();
        self.controller_receiver.take();
        // 3. Stop gamepad thread
        self._gamepad_controller.take();
        // 4. Kill subprocesses
        self.subprocess_manager.cleanup();
    }

    // main update and render function - called every frame.
    // ## frame Structure
    // 1. calculate timing
    // 2. get physics state from UDP
    // 3. update camera based on mode
    // 4. update terrain streaming
    // 5. update vehicle transforms
    // 6. build and render HUD
    // 7. render everything to GPU
    fn update_and_render(&mut self) {
        // skip rendering when window is minimized (zero size) to avoid invalid textures
        let size = self.window.inner_size();
        if size.width == 0 || size.height == 0 {
            return;
        }

        // timing
        let frame_start = Instant::now();
        // calculate time since last frame (clamped to minimum 1ms)
        let _delta = frame_start.duration_since(self.last_instant).as_secs_f64().max(0.001);
        self.last_instant = frame_start;

        // get vehicle state from physics or use defaults on startup
        let physics_state = if let Some(ref receiver) = self.physics_receiver {
            receiver.latest_state()  // returns full PhysicsState including control surfaces
        } else {
            // use default values when no physics connection
            udp_m::PhysicsState {
                velocity: Vector3::zeros(),
                position: self.vehicle_loc0,
                quaternion: math_m::euler_to_quat(self.vehicle_euler0),
                control_surfaces: std::collections::HashMap::new(),
            }
        };
        let v_b = physics_state.velocity;
        let vehicle_loc = physics_state.position;
        let q = physics_state.quaternion;
        let v_mag = v_b.magnitude();    // calculate velocity magnitude 
        let vehicle_euler = math_m::quat_to_euler(q);   // convert quaternion to euler angles for display/camera

        // update camera based on current mode. each mode returns a CameraState with position and rotation
        let camera_state: CameraState = match self.camera_mode {
            // body mode
            CameraMode::Body => self.camera_controller.update_body_mode(
                self.cam_euler,
                vehicle_euler,
                self.cam_location,
                &vehicle_loc,
            ),
            // velocity mode
            CameraMode::Velocity => self.camera_controller.update_velocity_mode(
                &v_b,
                v_mag,
                &vehicle_loc,
                vehicle_euler,
                self.cam_distance,
            ),
            // Fixed mode
            CameraMode::Fixed => self.camera_controller.update_fixed_mode(
                self.cam_euler,
                self.cam_location,
            ),
        };

        // build GPU compatible camera matrices and update uniform buffer
        let size = self.renderer.context.size();  // window size in pixels
        let camera_uniform = self.camera_controller.build_uniform(&camera_state, size);
        self.renderer.update_camera(&camera_uniform);

        // update terrain
        if let Some(ref mut terrain) = self.terrain {   // ref mut borrows mutably for terrain update
            let velocity_dir = if v_mag > 10.0 {    // calculate velocity direction for predictive tile loading
                let v_earth = math_m::body_to_earth_velocity(&v_b, q);  // convert body frame velocity to earth frame
            
                // calculate horizontal velocity magnitude
                // .powi(2) raises to integer power
                let horiz_mag = (v_earth.x.powi(2) + v_earth.y.powi(2)).sqrt();
                
                if horiz_mag > 1.0 {
                    // return normalized direction
                    Some([v_earth.x / horiz_mag, v_earth.y / horiz_mag])
                } else {
                    None
                }
            } else {
                None  // too slow to determine direction
            };

            // update terrain tiles based on camera position and view frustum
            // pass frame_start for time budgeting (prevents GPU stalls from tile uploads)
            let screen_height = self.window.inner_size().height;
            terrain.update_with_frustum(
                [camera_state.position.x, camera_state.position.y, camera_state.position.z],
                velocity_dir,
                self.camera_controller.cache.fov_y_rad as f64,
                screen_height,
                frame_start,
            );
        }

        // Update ground grid params (camera-relative ground Z for the procedural shader)
        if let Some(ref ground_grid) = self.ground_grid {
            ground_grid.update(&self.renderer.context.queue, &camera_state.position);
        }

        // Update vehicle transforms (main body and control surfaces)
        if let Some(ref mut vehicle) = self.vehicle {
            // calculate vehicle position relative to camera (for numerical precision with large world coordinates)
            let vehicle_loc_relative = vehicle_loc - camera_state.position;
            let rotation = math_m::quat_to_matrix(q);   // convert quaternion to rotation matrix
            vehicle.update_transforms(
                &self.renderer.context.queue,
                &rotation,
                &vehicle_loc_relative,
                &physics_state.control_surfaces,
            );
        }

        // Begin egui frame. egui uses immediate mode gui - ui rebuilt at given refresh rate
        let raw_input = self.egui_state.take_egui_input(&self.window);
        self.egui_ctx.begin_pass(raw_input);

        // Altitude datum: world z = 0 is MSL 0 (matches the photo-terrain meshes, whose vertices sit
        // at absolute MSL elevation). vehicle_loc.z is NED-down, so MSL altitude = -z. `ground
        // .altitude_ft` is the procedural grid plane's MSL altitude (POSITIVE = up; negated into a
        // world-z where the grid is built, see GroundGrid::new) and is the AGL datum when there is no
        // DEM terrain. So if the vehicle flies right on the grid, AGL = MSL - altitude_ft = 0.
        let msl_altitude = (-vehicle_loc.z) as f32;   // calculate altitude (MSL)

        // calculate altitude above ground level
        let agl = if let Some(ref terrain) = self.terrain {
            // DEM terrain present: AGL = vehicle MSL − terrain MSL elevation at this x,y.
            // .map() transforms Some(x) to Some(f(x)), None stays None
            terrain.sample_elevation(vehicle_loc.x, vehicle_loc.y)
                .map(|terrain_elev| (-vehicle_loc.z - terrain_elev) as f32)
        } else {
            // No DEM: the procedural grid is the ground, sitting at `ground.altitude_ft` MSL.
            Some(msl_altitude - self.ground_altitude as f32)
        };

        let mach = (v_mag / SPEED_OF_SOUND_SEA_LEVEL_FT_S) as f32;  // calculate Mach number (currently just using sea level sos)

        // compute HUD marker positions by projecting directions into camera frame
        // R_cam transforms earth-frame vectors to camera frame [forward, right, down]
        let r_cam = &camera_state.rotation;
        let r_be = math_m::quat_to_matrix(q);  // earth-to-body rotation

        // project a direction (earth frame) into screen offset angles [x_deg, y_deg]
        // x positive = right on screen, y positive = down on screen
        let project_to_screen = |dir_earth: &Vector3<f64>| -> [f32; 2] {
            let d_cam = r_cam * dir_earth;
            let x_deg = d_cam.y.atan2(d_cam.x).to_degrees() as f32;
            let y_deg = d_cam.z.atan2(d_cam.x).to_degrees() as f32;
            [x_deg, y_deg]
        };

        // nose direction in earth frame = R_eb * [1,0,0] = first column of R_be^T
        let r_eb = r_be.transpose();
        let nose_earth = Vector3::new(r_eb[(0,0)], r_eb[(1,0)], r_eb[(2,0)]);
        let nose_offset_deg = project_to_screen(&nose_earth);

        // velocity direction in earth frame
        let fpv_offset_deg = if v_mag > 10.0 {
            let v_earth = r_be.transpose() * v_b;
            project_to_screen(&(v_earth / v_mag))
        } else {
            nose_offset_deg  // at low speed, FPV defaults to nose direction
        };

        // extract camera roll and pitch from R_cam for the pitch ladder
        // R_cam row 0 is camera forward in earth frame; R_cam[0,2] = forward dot earth_down = -sin(camera_pitch)
        let camera_pitch_deg = (-r_cam[(0,2)]).asin().to_degrees() as f32;
        // camera roll: atan2(right·down, up_cam·down) where up_cam is -row2
        let camera_roll_deg = r_cam[(1,2)].atan2(r_cam[(2,2)]).to_degrees() as f32;

        // package HUD state
        let hud_state = HudState {
            velocity_magnitude: v_mag as f32,
            altitude: msl_altitude,
            agl,
            mach,
            heading_deg: vehicle_euler[2].to_degrees() as f32,
            camera_roll_deg,
            camera_pitch_deg,
            nose_offset_deg,
            fpv_offset_deg,
        };

        // get controller state for HUD display
        let controller_state = self.controller_receiver
            .as_ref()
            .map(|r| r.latest_state());

        // draw HUD or start overlay
        if self.waiting_for_physics {
            hud_m::draw_start_overlay(&self.egui_ctx);
        } else {
            self.hud.draw(&self.egui_ctx, &hud_state, controller_state.as_ref());   // .as_ref() converts Option<T> to Option<&T>
        }

        // End egui frame
        let egui_output = self.egui_ctx.end_pass();
        self.egui_state.handle_platform_output(     // handle platform output (cursor changes, clipboard, etc.)
            &self.window,
            egui_output.platform_output,
        );
        let paint_jobs = self.egui_ctx.tessellate(  // tessellate egui shapes into triangles for rendering
            egui_output.shapes,
            egui_output.pixels_per_point,
        );

        // Begin gpu rendering
        let output = match self.renderer.context.surface.get_current_texture() {    // get the next frame from the swap chain
            Ok(o) => o,
            // surface lost - need to recreate (e.g., window minimized)
            Err(wgpu::SurfaceError::Lost | wgpu::SurfaceError::Outdated) => {
                self.renderer.resize(self.window.inner_size());
                return;  // skip this frame
            }
            Err(wgpu::SurfaceError::OutOfMemory) => {
                error!("GPU out of memory");
                return;
            }
            Err(e) => {
                warn!(error = ?e, "Surface error");
                self.renderer.resize(self.window.inner_size());
                return;
            }
        };

        let view = output.texture.create_view(&wgpu::TextureViewDescriptor::default()); // create view into the output texture
        let mut encoder = self.renderer.context.device.create_command_encoder(  // create command encoder to record GPU commands
            &wgpu::CommandEncoderDescriptor {
                label: Some("Render Encoder"),
            },
        );

        // Sky rendering
        if let Some(ref mut sky) = self.sky {
            sky.generate_static_luts(&mut encoder); // generate lookup tables (only runs once)
            // Sky atmosphere density is a function of absolute altitude → use MSL (z = 0 is MSL 0).
            let camera_height_ft = -vehicle_loc.z;
            let camera_height_m = (camera_height_ft * FT_TO_M) as f32;
            sky.update_uniforms(    // update sky uniforms
                &self.renderer.context.queue,
                camera_height_m,
                sky.get_sun_direction(),
            );

            // Update sky camera with current view rotation
            // Must match the view matrix construction in build_uniform (using look_to_rh)
            let r_cam_world = camera_state.rotation.transpose();
            let (forward, up) = math_m::rotation_to_forward_up(&r_cam_world);

            // Build view axes (same as look_to_rh internally does)
            let z_axis = -forward.normalize();  // camera looks down -Z
            let x_axis = up.cross(z_axis).normalize();  // right
            let y_axis = z_axis.cross(x_axis);  // up in camera space

            // Inverse view rotation: columns are the camera axes in world space
            let inv_view_rotation: [[f32; 3]; 3] = [
                [x_axis.x, x_axis.y, x_axis.z],  // column 0: right axis
                [y_axis.x, y_axis.y, y_axis.z],  // column 1: up axis
                [z_axis.x, z_axis.y, z_axis.z],  // column 2: -forward axis
            ];

            let (w, h) = self.renderer.context.size();
            let aspect_ratio = w as f32 / h as f32;
            sky.update_camera(
                &self.renderer.context.queue,
                inv_view_rotation,
                self.camera_controller.cache.fov_y_rad,
                aspect_ratio,
            );

            // update sky view lookup table
            sky.update_skyview(&mut encoder);
        }

        // Main render pass
        {   // scope limits render_pass lifetime (it borrows encoder mutably)
            // begin render pass with color and depth attachments
            let mut render_pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("Main Render Pass"),
                
                // color attachment (what we're drawing to)
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    resolve_target: None,  // No MSAA resolve
                    depth_slice: None,
                    ops: wgpu::Operations {
                        // clear to background color at start
                        load: wgpu::LoadOp::Clear(wgpu::Color {
                            r: self.clear_color[0] as f64,
                            g: self.clear_color[1] as f64,
                            b: self.clear_color[2] as f64,
                            a: 1.0,
                        }),
                        store: wgpu::StoreOp::Store,  // keep the results
                    },
                })],
                
                // depth buffer for hidden surface removal
                depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
                    view: &self.renderer.depth_texture,
                    depth_ops: Some(wgpu::Operations {
                        load: wgpu::LoadOp::Clear(1.0),  // clear to far plane
                        store: wgpu::StoreOp::Store,
                    }),
                    stencil_ops: None,  // not using stencil buffer
                }),
                
                timestamp_writes: None,
                occlusion_query_set: None,
            });

            // set global bind group (camera matrices, etc.) at slot 0
            render_pass.set_bind_group(0, &self.renderer.global_bind_group.bind_group, &[]);

            // render Sky (drawn first, at far depth)
            if let Some(ref sky) = self.sky {
                sky.render(&mut render_pass);
                // reset bind group after sky (sky uses its own at slot 0)
                render_pass.set_bind_group(0, &self.renderer.global_bind_group.bind_group, &[]);
            }

            // render Terrain Tiles
            if let (Some(ref terrain), Some(ref terrain_pipeline)) = (&self.terrain, &self.renderer.terrain_pipeline) {
                render_pass.set_pipeline(&terrain_pipeline.pipeline);
                for tile in terrain.get_visible_tiles() {
                    render_pass.set_bind_group(1, &tile.bind_group, &[]);
                    render_pass.set_vertex_buffer(0, tile.vertex_buffer.slice(..));
                    render_pass.set_index_buffer(tile.index_buffer.slice(..), wgpu::IndexFormat::Uint32);
                    render_pass.draw_indexed(0..tile.index_count, 0, 0..1);
                }
            }
            // render ground grid (procedural, no vertex buffer)
            if let (Some(ref ground_grid), Some(ref grid_pipeline)) = (&self.ground_grid, &self.renderer.grid_pipeline) {
                render_pass.set_pipeline(&grid_pipeline.pipeline);
                render_pass.set_bind_group(1, &ground_grid.params_bind_group, &[]);
                render_pass.draw(0..6, 0..1);
            }

            // render vehicle (all parts)
            if let Some(ref vehicle) = self.vehicle {
                render_pass.set_pipeline(&self.renderer.mesh_pipeline.pipeline);
                vehicle.render(&mut render_pass);
            }
            // render_pass is dropped here, ending the render pass
        }

        // Render egui (hud)
        let screen_descriptor = egui_wgpu::ScreenDescriptor {
            size_in_pixels: [size.0, size.1],
            pixels_per_point: self.window.scale_factor() as f32,
        };

        // update egui textures (fonts, etc.)
        for (id, delta) in &egui_output.textures_delta.set {
            self.egui_renderer.update_texture(
                &self.renderer.context.device,
                &self.renderer.context.queue,
                *id,    // * dereferences - id is a reference
                delta,
            );
        }

        self.egui_renderer.update_buffers(  // update vertex/index buffers with new gui geometry
            &self.renderer.context.device,
            &self.renderer.context.queue,
            &mut encoder,
            &paint_jobs,
            &screen_descriptor,
        );

        // render egui with helper function
        render_egui(
            &self.egui_renderer,
            &mut encoder,
            &view,
            &paint_jobs,
            &screen_descriptor,
        );
        for id in &egui_output.textures_delta.free {    // free unused textures
            self.egui_renderer.free_texture(id);
        }

        // Submit to gpu
        // .finish() consumes the encoder and returns a CommandBuffer
        // .submit() sends commands to GPU
        // std::iter::once() creates iterator with single item
        self.renderer.context.queue.submit(std::iter::once(encoder.finish()));

        // Poll device to prevent implicit GPU synchronization on future operations
        // This helps avoid stutters when uploading new tile textures
        let _ = self.renderer.context.device.poll(wgpu::PollType::Poll);

        // present the frame to the screen
        output.present();

        // fps logging
        self.frame_count += 1;
        if self.frame_count.is_multiple_of(400) {
            let elapsed = self.last_fps_print.elapsed().as_secs_f32();
            let fps = 400.0 / elapsed;
            info!(fps = fps, "Frame rate");
            self.last_fps_print = Instant::now();
        }
    }
}

// =============================================================================
// HELPER FUNCTION FOR EGUI RENDERING
// =============================================================================

/// Renders egui draw commands to the GPU.
///
/// ## Why This Function Exists
/// This is a workaround for Rust's lifetime system combined with wgpu 23+.
///
/// ## The Problem
/// wgpu's `Renderer::render()` requires a `RenderPass<'static>` - a render pass
/// that could live forever. But our render pass borrows from the encoder and
/// can't actually live that long.
///
/// ## The Solution
/// We use `unsafe` code to tell Rust "trust me, this is fine" by transmuting
/// the lifetime. This is safe because:
/// 1. The render pass is created and used within this function
/// 2. The function completes before the borrowed data is used elsewhere
/// 3. Nothing stores a reference to the render pass
///
fn render_egui(
    renderer: &egui_wgpu::Renderer,
    encoder: &mut wgpu::CommandEncoder,
    view: &wgpu::TextureView,
    paint_jobs: &[egui::ClippedPrimitive],
    screen_descriptor: &egui_wgpu::ScreenDescriptor,
) {
    let render_pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        label: Some("egui Render Pass"),
        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
            view,
            resolve_target: None,
            depth_slice: None,
            ops: wgpu::Operations {
                load: wgpu::LoadOp::Load,
                store: wgpu::StoreOp::Store,
            },
        })],
        depth_stencil_attachment: None,
        timestamp_writes: None,
        occlusion_query_set: None,
    });

    // egui_wgpu requires RenderPass<'static>; wgpu provides this safe conversion
    let mut render_pass = render_pass.forget_lifetime();
    renderer.render(&mut render_pass, paint_jobs, screen_descriptor);
}