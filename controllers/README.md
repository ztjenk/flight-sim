# Flight Controllers

Three UDP flight controllers that share one library and present an identical
user-level interface; only the control law underneath differs. Each one is the
example controller for one of the bundled aircraft (see `../examples/`):

```
common/              shared library (single copy of everything reused)
src_PID/             classic cascaded PID            -> bin/PID       (example: Aeroscout)
src_DI/              dynamic inversion (NDI/INDI)     -> bin/DI        (example: F-16)
src_quadrotorPID/    quadrotor (provisional PID)      -> bin/quadPID   (example: quadrotor)
```

Each controller's ready-to-run config lives next to its aircraft in `../examples/`:

| Controller | Pair with example | Config (in the example dir) |
|---|---|---|
| `src_PID` → `bin/PID` | `examples/aeroscout` | `controller_aeroscout.json` |
| `src_DI` → `bin/DI` | `examples/f16_equations` | `controller_f16_di.json` |
| `src_quadrotorPID` → `bin/quadPID` | `examples/quadrotor` | `controller_quadrotor.json` |

## Build

Each controller builds itself and the shared modules it needs. Release by
default; pass `debug` for the checked build. On Windows use the matching
`build_windows.bat` (identical except for the UDP layer: `-DWINDOWS`, winsock
`-lws2_32`, and a `.exe`).

```sh
cd src_PID && zsh build_linux.zsh          # release (optimized + static)
cd src_PID && zsh build_linux.zsh debug    # debug (-O0, full runtime checks)
```

`build_linux.zsh` first runs `../common/build_linux.zsh` (compiles the shared
modules into `common/obj/`), then compiles the controller-specific modules and
links against `common/obj/*.o`. Run a binary from a directory containing its
`controller.json`, or pass a config path. Requires `gfortran`; all reals are
double precision (`-fdefault-real-8`).

## Shared library (`common/`)

| Module | Role |
|---|---|
| `constants_m`, `math_m`, `atmosphere_m` | constants, quaternion/aero math, standard atmosphere |
| `linalg_m` | 3×3 solve / inverse + diagonal solve (for DI) |
| `json` / `jsonx` | JSON parsing |
| `udp_m` | UDP sockets; double **and** single precision send/recv |
| `pid_m` | `pid_ctrl` + `cascade_ctrl` PID library (shared by all laws) |
| `gamepad_m` | raw Xbox/PS4 pad UDP read + button bits + edge detection |
| `pilot_cmd_m` | `pilot_cmd_t`: flight-mode state + reference commands + limits |
| `flight_state_m` | packet map + decoded `flight_state_t` |
| `config_base_m` | shared config parsing (udp / pilot / modes / limits / control values) |
| `command_profile_m` | CSV scripted-maneuver loader |
| `mode_m` | the flight-mode state machine + stick/CSV mapping |

`udp_windows_m.f90` is the Windows implementation of `udp_m` (swapped in by a
Windows build only; **not** compiled on Linux).

## Flight modes (fixed-wing: PID / DI)

The two fixed-wing controllers expose the **same** controls. Modes are a
priority stack — the effective mode is the highest one currently on:

```
manual  <  rates  <  angles  <  altitude
```

| Effective mode | roll stick | pitch stick | yaw stick |
|---|---|---|---|
| MANUAL   | aileron      | elevator        | rudder |
| RATES    | roll rate p  | pitch rate q    | yaw rate r |
| ANGLES   | bank φ       | pitch attitude θ| sideslip β (or yaw rate) |
| ALTITUDE | bank φ       | climb-rate trim | sideslip β (or yaw rate) |

Altitude implies the angle loops; angles implies the rate loops. Velocity
(airspeed) hold and sideslip hold are **independent overlays**.

**Xbox gamepad (when `pilot_inputs.type = "udp"`):**

| Button | Action |
|---|---|
| A | toggle velocity (airspeed) hold |
| B | toggle angles mode |
| X | toggle rates mode |
| Y | toggle altitude mode |
| RB | toggle sideslip (β) hold |
| D-pad ←/→ | decrease / increase commanded airspeed |

Set the startup mode and overlays in `controller.json` → `modes`
(`initial_mode`, `velocity_hold`, `sideslip_hold`). Scripted testing uses
`pilot_inputs.type = "csv"` with a maneuver file (see the shipped example
`../examples/aeroscout/maneuvers/aeroscout_demo.csv`). Per-controller `maneuvers/`
folders are local scratch and are not tracked in git.

## Controllers

- **src_PID** — cascaded PID: bank φ→p, pitch θ→q, sideslip β→r, altitude h→θ,
  and inner p/q/r/throttle PID loops with dynamic-pressure gain scheduling.
- **src_DI** — dynamic inversion. Outer attitude loop (φ/θ/β → kinematic body-rate
  commands + coordinated-turn feedforward) → inner rate loops → desired angular
  acceleration ν → NDI or INDI inversion → surface deflections. `method: "ndi"`
  (default, no EKF needed) or `"indi"` (needs EKF ω̇ + actual surfaces in the
  packet — opt-in).
- **src_quadrotorPID** — dedicated quad controls (left stick = climb/yaw, right
  stick = pitch/roll), an X-quad mixer, and a climb-rate + attitude/rate PID
  cascade. Uses single-precision packets (21-field `ekf_both` in, 4 rotor
  throttles out).

## UDP

Fixed-wing controllers exchange double-precision packets with an entity-id
prefix; the field layout is declared per config in `udp.packet_order`. They send
`[da, de, dr, throttle]` plus a HUD status channel. The quad uses
single-precision packets (21-field `ekf_both` in, 4 rotor throttles out).
