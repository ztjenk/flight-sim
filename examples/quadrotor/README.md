# Quadrotor example

Electric quadrotor (Phillips App. C.4): **component-built mass/inertia**, a shared
battery, propeller gyroscopics, and a full IMU/GPS/baro/magnetometer suite fused
by the EKF. Flown by the quad PID controller (`src_quadrotorPID`) on the EKF
estimate, with an Xbox gamepad.

`graphics_quadrotor.json` has `rust_enabled: true` on both links, so one command
launches everything:

```bash
cd examples/quadrotor
../../graphics/target/release/flightsim_graphics graphics_quadrotor.json
```

Fly with an Xbox gamepad (left stick = climb/yaw, right stick = pitch/roll; mapping
in [../../controllers/README.md](../../controllers/README.md)). Without a gamepad it
holds hover.

Files:
- `sim_quadrotor.json` — physics (component-built quad, full sensor suite + EKF).
- `controller_quadrotor.json` — quad PID (single-precision UDP, 4 rotor outputs).
- `graphics_quadrotor.json` — viewer + subprocess launch.
- `meshes/simplequad/` — STL body.
