# Examples

Three ready-to-run aircraft, each a self-contained directory with its own physics
(`sim_*.json`), controller (`controller_*.json`), graphics (`graphics_*.json`),
meshes, and (where needed) aero databases. Each example is run **from its own
directory** so every path inside the configs is local and relative.

| Example | Aero model | Controller | Commands | Who launches physics + controller |
|---|---|---|---|---|
| **aeroscout** | tabulated CSV databases | `src_PID` (`bin/PID`) | scripted CSV maneuver | **graphics** (`rust_enabled: true`) — one command |
| **f16_equations** | inline stability derivatives | `src_DI` (`bin/DI`, NDI) | Xbox gamepad over UDP | **you** (three terminals) |
| **quadrotor** | bluff-body + electric props | `src_quadrotorPID` (`bin/quadPID`) | Xbox gamepad over UDP | **graphics** (`rust_enabled: true`) — one command |

The two `rust_enabled: true` examples (aeroscout, quadrotor) are one-command demos:
graphics auto-launches the physics and controller subprocesses. The F16 example
keeps `rust_enabled: false` to show the explicit three-process workflow.

## Build once (release is the default)

```bash
# from the repo root  (on Windows run each build_windows.bat instead)
cd physics/src              && zsh build_linux.zsh           # -> physics/src/bin/flightsim
cd ../../controllers/src_PID         && zsh build_linux.zsh  # -> bin/PID
cd ../src_DI                         && zsh build_linux.zsh  # -> bin/DI
cd ../src_quadrotorPID               && zsh build_linux.zsh  # -> bin/quadPID
cd ../../graphics           && cargo build --release         # -> graphics/target/release/flightsim_graphics
```

## Run

**Aeroscout — one command** (graphics launches physics + PID; flies the scripted
`maneuvers/aeroscout_demo.csv`: settle → 100 ft climb → bank right → bank left → level → descend):

```bash
cd examples/aeroscout
../../graphics/target/release/flightsim_graphics graphics_aeroscout.json
```

**Quadrotor — one command** (graphics launches physics + quad PID; fly it with an
Xbox gamepad):

```bash
cd examples/quadrotor
../../graphics/target/release/flightsim_graphics graphics_quadrotor.json
```

**F-16 — three terminals** (explicit workflow; fly it with an Xbox gamepad):

```bash
# terminal 1 — graphics (binds its sockets, then waits for state)
cd examples/f16_equations && ../../graphics/target/release/flightsim_graphics graphics_f16.json
# terminal 2 — DI controller
cd examples/f16_equations && ../../controllers/src_DI/bin/DI controller_f16_di.json
# terminal 3 — physics (starts streaming state to both)
cd examples/f16_equations && ../../physics/src/bin/flightsim sim_f16.json
```

## UDP ports (shared by all examples)

| Port | From → To | Contents |
|---|---|---|
| 5005 | physics → graphics | aircraft state (single precision) |
| 5001 | physics → controller | aircraft state |
| 5002 | controller → physics | commanded controls |
| 6000 | graphics → controller | pilot / gamepad commands |
| 5003 | controller → graphics | HUD status (PID/DI only) |

## Notes

- Run each example from its own directory — the configs use relative paths
  (`meshes/...`, `../../physics/...`, `../../controllers/...`).
- Ground is rendered as a reference **grid** (no terrain tiles required). The
  `streaming` terrain mode is an optional power-user feature documented in
  [enduser_docs/graphics-config.md](../enduser_docs/graphics-config.md).
- Physics writes `*_datalog.csv` into the example directory; these are gitignored.
- An Xbox/PS4 gamepad is optional — without one, the gamepad examples simply hold
  trim. Button/stick mapping is in [controllers/README.md](../controllers/README.md).
