# Aeroscout example

RC trainer with **tabulated (database) aerodynamics**, flown by the cascaded PID
controller (`src_PID`) through a **scripted maneuver** — no gamepad needed.

This is the simplest demo: `graphics_aeroscout.json` has `rust_enabled: true` on
both the physics and controller links, so a single command launches everything.

```bash
cd examples/aeroscout
../../graphics/target/release/flightsim_graphics graphics_aeroscout.json
```

The controller plays `maneuvers/aeroscout_demo.csv` (≈60 s, altitude mode):
settle at trim (50 ft/s, 5000 ft) → 100 ft climb → small bank right → bank left →
wings level → descend back. Edit that CSV to change the maneuver.

Files:
- `sim_aeroscout.json` — physics (realtime, 60 s); `databases/Aeroscout/` holds the
  aero `.csv` tables (the `.dat` binary cache is regenerated on first load).
- `controller_aeroscout.json` — PID gains + `pilot_inputs.type: "csv"`.
- `graphics_aeroscout.json` — viewer + subprocess launch.
- `meshes/Aeroscout/` — STL parts.
