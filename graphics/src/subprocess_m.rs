// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

use std::path::Path;
use std::process::{Child, Command, Stdio};
use tracing::{info, error};

// manages child processes spawned by Rust
pub struct SubprocessManager {
    controller: Option<Child>,
    physics: Option<Child>,
}

impl SubprocessManager {
    pub fn new() -> Self {
        Self {
            controller: None,
            physics: None,
        }
    }

    /// Validate and spawn a subprocess. Returns the Child on success.
    fn spawn_process(exe: &str, json: &str, path: &str, label: &str) -> Option<Child> {
        let exe_path_buf = Path::new(path).join(exe);
        let exe_path = exe_path_buf.display().to_string();

        // Check that the working directory exists
        if !Path::new(path).is_dir() {
            error!(%label, %path, "Working directory does not exist");
            return None;
        }

        // Check that the executable exists
        if !exe_path_buf.exists() {
            error!(%label, %exe_path, "Executable not found");
            return None;
        }

        match Command::new(&exe_path)
            .arg(json)
            .current_dir(path)
            .stdout(Stdio::null())
            .stderr(Stdio::inherit()) // subprocess errors visible in terminal
            .spawn()
        {
            Ok(child) => {
                info!(%label, %exe, %json, "Started subprocess");
                Some(child)
            }
            Err(e) => {
                error!(%label, %exe_path, %e, "Failed to start subprocess");
                None
            }
        }
    }

    pub fn start_controller(&mut self, exe: &str, json: &str, path: &str) -> bool {
        match Self::spawn_process(exe, json, path, "controller") {
            Some(child) => {
                self.controller = Some(child);
                true
            }
            None => false,
        }
    }

    pub fn start_physics(&mut self, exe: &str, json: &str, path: &str) -> bool {
        match Self::spawn_process(exe, json, path, "physics") {
            Some(child) => {
                self.physics = Some(child);
                true
            }
            None => false,
        }
    }

    pub fn stop_physics(&mut self) {
        if let Some(child) = self.physics.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
        self.physics = None;
    }

    pub fn cleanup(&mut self) {
        if let Some(ref mut child) = self.controller {
            let _ = child.kill();
            let _ = child.wait();
            info!("Controller terminated");
            self.controller = None;
        }
        if let Some(ref mut child) = self.physics {
            let _ = child.kill();
            let _ = child.wait();
            info!("Physics terminated");
            self.physics = None;
        }
    }
}

impl Drop for SubprocessManager {
    fn drop(&mut self) {
        self.cleanup();
    }
}
