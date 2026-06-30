# Flight Simulator

A research flight-simulation stack built during a master's degree in aerospace engineering: a
six-degree-of-freedom rigid-body **physics engine** (Fortran), a real-time **graphics** front-end
(Rust + wgpu), and a set of **flight controllers** (Fortran). The three run as separate processes
and communicate over UDP, so each can be developed, swapped, or run on its own.

> Status: research software, actively developed.

> **Disclaimer:** This code and documentation were developed with LLM assistance. All physics, math,
> and code have been reviewed and verified by a human. This is research and educational software,
> provided without warranty (see [LICENSE](LICENSE)). It is not intended for operational,
> safety-critical, or flight-certification use. Validate results independently before relying on them.

---

## What's in here

```
flight-sim/
├── physics/        6-DOF rigid-body flight dynamics engine (modern Fortran)
├── graphics/       real-time wgpu/winit renderer + HUD (Rust)
├── controllers/   Fortran controllers sharing one common/ library
│   ├── common/             shared modules (math, UDP, PID, modes, config, ...)
│   ├── src_PID/            cascaded PID            -> bin/PID      (example: Aeroscout)
│   ├── src_DI/             dynamic inversion (NDI) -> bin/DI       (example: F-16)
│   └── src_quadrotorPID/   quadrotor PID + mixer   -> bin/quadPID  (example: quadrotor)
├── examples/
│   ├── f16_equations/   F-16 using an inline stability-derivative (equations) aero model
│   ├── aeroscout/       RC trainer using tabulated (database) aerodynamics
│   └── quadrotor/       electric quadrotor: component-built mass, battery, full nav + EKF
├── enduser_docs/   configuration reference (input format, connections, graphics)
└── LICENSE
```

## How it fits together

The physics engine integrates the equations of motion and streams vehicle **state** over UDP. The
graphics front-end receives that state and renders the aircraft (articulated control surfaces),
terrain, sky, and a HUD; it also sends **pilot/gamepad input** back. A controller can close the loop:
it receives state and sends **control-surface + throttle commands** that the physics engine applies.

```
        pilot input (UDP)
   ┌───────────────────────────┐
   ▼                           │
┌─────────┐   state (UDP)   ┌──┴────────┐
│ graphics│◄────────────────│  physics  │   (graphics can launch the physics
│  (Rust) │                 │ (Fortran) │    engine as a subprocess)
└─────────┘                 └──┬─────▲──┘
                  state (UDP)  │     │  controls (UDP)
                               ▼     │
                          ┌──────────┴───┐
                          │  controller  │
                          │  (Fortran)   │
                          └──────────────┘
```

UDP channels are declared in each vehicle config's `connections` section (state out, controls in).
The defaults used by the examples: physics sends state on ports **5005** (→ graphics) and **5001**
(→ controller), and receives controls on **5002**; graphics receives pilot input on **6000**. See
[enduser_docs/connections.md](enduser_docs/connections.md) for the packet formats and field reference.

---

## Prerequisites

- **gfortran** (GCC ≥ 9) — builds the physics engine and controllers.
- **Rust** (stable, `cargo`) — builds the graphics front-end. A GPU with Vulkan/Metal/DX12 is needed
  to actually render.
- **zsh** — the Linux build scripts (`build_linux.zsh`); Windows uses the `build_windows.bat` pair.
  See [Platform support](#platform-support) for macOS.

## Platform support

Built and tested on **Linux** and **Windows**. Each Fortran component ships a
`build_linux.zsh` / `build_windows.bat` pair; the only code difference between them is the UDP
layer. The Rust graphics front-end is cross-platform and also targets macOS (Metal).

**macOS is untested**, and the Fortran side (physics engine + controllers) would need two changes
before it works there:

1. **Build** — the `build_linux.zsh` scripts link with `-static`, which macOS does not support.
   Drop `-static` from the link flags to build on macOS.
2. **UDP** — `udp_m.f90` is written for Linux. macOS/BSD use a different `sockaddr_in` layout (a
   leading `sin_len` byte and an 8-bit `sin_family`) and a different `O_NONBLOCK` value, so `bind`,
   `sendto`, and non-blocking receive will not behave correctly as-is. The module would need a macOS
   variant, mirroring the existing Linux/Windows split (`udp_m.f90` / `udp_windows_m.f90`).

Single-process physics use on macOS (trimming an aircraft, writing datalogs — no UDP) should work
once `-static` is removed; the live multi-process UDP setup needs the macOS UDP variant.

## Build

Each component builds independently.

```bash
# physics engine  ->  physics/src/bin/flightsim
cd physics/src && zsh build_linux.zsh

# controllers     ->  controllers/<name>/bin/{PID,DI,quadPID}
cd controllers/src_PID          && zsh build_linux.zsh
cd controllers/src_DI           && zsh build_linux.zsh
cd controllers/src_quadrotorPID && zsh build_linux.zsh

# graphics        ->  graphics/target/release/flightsim_graphics
cd graphics && cargo build --release
```

Every Fortran component has a matching `build_linux.zsh` / `build_windows.bat` pair that build
identically (the only platform difference is the UDP layer). Both default to an **optimized release**
build; pass `debug` for the checked build (`zsh build_linux.zsh debug`). On Windows run the
`build_windows.bat` of each instead.

## Quick start

**1. Sanity-check the physics engine** (no GPU needed). Trim an aircraft and watch it converge:

```bash
cd examples/f16_equations
../../physics/src/bin/flightsim sim_f16.json
```

You should see the aero model load, `Trim converged successfully`, and a trim state printed
(for the F-16 equations model: α ≈ 3.94°, elevator ≈ −5.6°, throttle ≈ 0.084). The Aeroscout
example (`examples/aeroscout/sim_aeroscout.json`) instead loads tabulated `.csv` databases and trims
to α ≈ 1.28°. Press Ctrl-C to stop once it enters the run loop.

**2. Run a full example** (physics + controller + graphics). Each example is self-contained and is run
**from its own directory**. The Aeroscout example is one command — graphics auto-launches the physics
engine and the PID controller, which flies a scripted maneuver:

```bash
cd examples/aeroscout
../../graphics/target/release/flightsim_graphics graphics_aeroscout.json
```

See [examples/README.md](examples/README.md) for all three aircraft, the one-command vs. three-terminal
workflows, and the gamepad examples. Graphics config fields are documented in
[enduser_docs/graphics-config.md](enduser_docs/graphics-config.md); STL↔VTK mesh helpers
(`stltovtk.py`, `checkvtk.py`) and an example `f16.vtk` live in `graphics/`.

Controllers (PID / DI / quad), their flight modes, the gamepad map, and the control-law
designs are all in [controllers/README.md](controllers/README.md).

---

## Examples

| Example | Aero model | Notes |
|---|---|---|
| `examples/f16_equations` | Inline stability derivatives (equations) | Self-contained NASA-style polynomial F-16; no external data. |
| `examples/aeroscout` | Tabulated databases (`.csv`) | RC trainer; base + aileron/elevator/rudder + p/q/r-bar tables. The binary `.dat` cache is regenerated from the `.csv` on first load. |
| `examples/quadrotor` | Simple-geometry (bluff-body) + propeller/electric propulsion | Electric quadrotor (Phillips App. C.4). Shows component-built mass/inertia assembly (no vehicle-level mass block), a shared battery, propeller gyroscopics, and a full IMU/GPS/baro/magnetometer suite fused by the EKF. Flown by the `src_quadrotorPID` controller on the EKF estimate. |

## Controllers

All three are Fortran and share one `common/` library; they expose an identical
mode/gamepad interface (see [controllers/README.md](controllers/README.md)).
Each is the example controller for one bundled aircraft.

- **src_PID** (`bin/PID`, example: **Aeroscout**) — cascaded PID: inner body-rate loops, outer
  attitude (bank/pitch/sideslip) and altitude loops, autothrottle, with dynamic-pressure gain
  scheduling. Commands from a maneuver CSV or an Xbox gamepad over UDP.
- **src_DI** (`bin/DI`, example: **F-16**) — dynamic inversion: an outer attitude loop feeds an
  angular-acceleration command that is inverted through the aircraft model. `ndi` (default, no EKF)
  or `indi` (inverts the measured increment; needs EKF ω̇, opt-in).
- **src_quadrotorPID** (`bin/quadPID`, example: **quadrotor**) — X-quad mixer plus a climb-rate +
  attitude/rate PID cascade; single-precision packets, flies on the EKF-estimated state.

## Configuration & documentation

- [enduser_docs/INPUT_FORMAT.md](enduser_docs/INPUT_FORMAT.md) — complete vehicle/simulation config reference.
- [enduser_docs/connections.md](enduser_docs/connections.md) — UDP/file connection setup and packet formats.
- [enduser_docs/graphics-config.md](enduser_docs/graphics-config.md) — graphics configuration.
- [examples/README.md](examples/README.md) — the three ready-to-run aircraft.
- [controllers/README.md](controllers/README.md) — controllers, flight modes, and gamepad map.

## License

Copyright (C) 2026 Zachary Jenkins.

This program is free software: you can redistribute it and/or modify it under the terms of the
**GNU General Public License, version 3** as published by the Free Software Foundation. It is
distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied
warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See [LICENSE](LICENSE) for the full
text, or <https://www.gnu.org/licenses/>.

### Interface clarification — programs that talk to this over UDP are separate works

The physics engine, the controllers, and the graphics front-end are independent programs that
communicate only through documented **UDP packet interfaces**. As the copyright holder, I clarify that a
program which interacts with this software **solely through those UDP interfaces** — your own controller,
autopilot, ground station, visualizer, data logger, etc. — is a **separate and independent work**, not a
derivative work of this software. You may write, license, and distribute such a program under **any terms
you choose, including as proprietary / closed source**, and the GPL's copyleft does **not** reach it.

This is an intentional permission: the UDP boundary is a plug-in seam, and standalone processes on either
side of it are yours to license freely. (Copying this project's **source code** into your program, or
linking its modules/objects, is a derivative work and remains subject to the GPL as usual.)

### Third-party components

Bundled third-party code keeps its own (permissive, GPL-compatible) license: the Fortran JSON parser is
[JSON-Fortran](https://github.com/jacobwilliams/json-fortran) (BSD-3-Clause, © Jacob Williams — see the
header in `physics/src/json.f90` / `controllers/common/json.f90`), and the Rust graphics front-end links
MIT/Apache-2.0 crates (see `graphics/Cargo.toml`).

## Acknowledgements

Developed as part of master's-degree research in flight dynamics and control. The F-16 example uses a
public NASA-style aerodynamic model.
