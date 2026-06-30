# F-16 example

F-16 using an **inline stability-derivative (equations) aero model** — fully
self-contained, no external aero data. Flown by the **dynamic-inversion**
controller (`src_DI`, NDI) with an Xbox gamepad.

This example uses the **explicit three-process workflow** (`rust_enabled: false`),
so you launch each piece yourself — useful for seeing how the pieces connect.

```bash
# terminal 1 — graphics
cd examples/f16_equations && ../../graphics/target/release/flightsim_graphics graphics_f16.json
# terminal 2 — DI controller
cd examples/f16_equations && ../../controllers/src_DI/bin/DI controller_f16_di.json
# terminal 3 — physics
cd examples/f16_equations && ../../physics/src/bin/flightsim sim_f16.json
```

Fly with an Xbox gamepad (mapping in [../../controllers/README.md](../../controllers/README.md));
without a gamepad the aircraft holds trim. The DI controller's `vehicle` block (in
`controller_f16_di.json`) carries the aero/inertia model it inverts — keep it
consistent with `sim_f16.json` if you change the aircraft.

Files:
- `sim_f16.json` — physics (equations aero, self-contained).
- `controller_f16_di.json` — DI/NDI config incl. the inversion `vehicle` model.
- `graphics_f16.json` — viewer + gamepad.
- `meshes/F16/` — STL parts.
