# Input JSON Format Reference

Complete field reference for the flight simulator physics engine JSON configuration. All vehicle types (aircraft, quadcopters, projectiles, kinematic objects) use the same input structure.

## Top-Level Structure

```json
{
    "simulation"  : { ... },
    "atmosphere"  : { ... },
    "vehicles"    : { ... },
    "connections" : { ... }
}
```

| Section | Required | Description |
|---------|----------|-------------|
| `simulation` | **yes** | Time step, duration, output settings |
| `atmosphere` | no | Constant wind and turbulence |
| `vehicles` | **yes** | One or more named vehicle definitions |
| `connections` | no | UDP/file telemetry channels |

---

## Unit System

The simulator uses a **unit-aware input system**. Numeric JSON keys can include optional `[units]` in brackets after the base name. When brackets are present, values are auto-converted to internal units on load. When brackets are absent, values are assumed to be in internal units already.

### Internal Units

The simulator's internal unit system is **English (Imperial)**:

| Quantity | Internal Unit |
|----------|---------------|
| Length | feet (ft) |
| Time | seconds (s) |
| Mass | slugs (slug) |
| Angle | radians (rad) |
| Force | pounds-force (lbf) |
| Temperature | Fahrenheit (F) / Rankine (R) |
| Frequency | Hertz (hz) |

### How Unit Brackets Work

Keys are looked up by **base name** — the part before the `[`. The brackets and everything inside them are the unit specification.

```json
"altitude[ft]": 3000       // looked up as "altitude", units = "ft", converted from ft → ft (no-op)
"altitude[m]": 914.4       // looked up as "altitude", units = "m", converted from m → ft
"altitude": 3000            // looked up as "altitude", no units, assumed already in ft (internal)
```

All three forms above produce the same internal value. The code searches for the base name regardless of what unit suffix is attached. You can change units without changing any code — just change the bracket contents and the value.

### Available Base Units

| Category | Units | Internal |
|----------|-------|----------|
| **Length** | `ft`, `mi`, `yard`, `in`, `nami` (nautical mile), `m` | ft |
| **Time** | `s`, `min`, `hr`, `day`, `wk`, `yr` | s |
| **Angle** | `rad`, `deg` | rad |
| **Mass** | `slug`, `g` (gram), `lbm`, `oz`, `ton` | slug |
| **Speed** | `kts` (knots) | ft/s |
| **Acceleration** | `gs` (g's) | ft/s^2 |
| **Force** | `lbf`, `N` (Newton) | lbf |
| **Energy/Torque** | `J` (Joule) | lbf*ft |
| **Power** | `hp` (horsepower), `W` (Watt) | lbf*ft/s |
| **Temperature** | `F`, `R` (Rankine), `C` (Celsius), `K` (Kelvin) | F (delta only) |
| **Frequency** | `hz` | hz |

### SI Prefixes

Any base unit can be prefixed with an SI scaling prefix:

| Prefix | Symbol | Factor | | Prefix | Symbol | Factor |
|--------|--------|--------|-|--------|--------|--------|
| atto | `a` | 10^-18 | | deka | (none) | 10^1 |
| femto | `f` | 10^-15 | | hecto | (none) | 10^2 |
| pico | `p` | 10^-12 | | kilo | `k` | 10^3 |
| nano | `n` | 10^-9 | | mega | `M` | 10^6 |
| micro | `u` | 10^-6 | | giga | `G` | 10^9 |
| milli | `m` | 10^-3 | | tera | `T` | 10^12 |
| centi | `c` | 10^-2 | | peta | `P` | 10^15 |

Examples: `km` = kilometers, `mm` = millimeters, `kN` = kilonewtons, `mg` = milligrams.

**Note:** `m` alone means meters (length), not the milli prefix. The prefix `m` + unit `in` = `min` is disambiguated as minutes (not milli-inches).

### Unit Aliases

Long-form names are resolved to canonical abbreviations:

| Alias | Resolves to | | Alias | Resolves to |
|-------|-------------|-|-------|-------------|
| `degrees`, `degree` | `deg` | | `feet`, `foot` | `ft` |
| `radians`, `radian` | `rad` | | `meters`, `meter`, `metres`, `metre` | `m` |
| `seconds`, `second`, `sec` | `s` | | `inches`, `inch` | `in` |
| `minutes`, `minute` | `min` | | `slugs` | `slug` |
| `hours`, `hour` | `hr` | | `knots`, `knot` | `kts` |
| `newtons`, `newton` | `N` | | `Hz`, `hertz` | `hz` |
| `joules`, `joule` | `J` | | `watts`, `watt` | `W` |

### Compound Units

Units can be combined using operators:

| Operator | Meaning | Example |
|----------|---------|---------|
| `*` or `-` | Multiplication | `slug-ft^2`, `kg*m` |
| `/` | Division | `ft/s`, `m/s^2` |
| `^` or `**` | Exponent | `ft^2`, `m**2` |
| `^(expr)` | Evaluated exponent | `ft^(2*2)` → ft^4 |
| `/(...)` | Denominator group | `kg/(m*s^2)` — both m and s^2 go in denominator |
| `(...)` | Numerator group | `(kg*m)/s^2` — both kg and m in numerator |

**Limits:**
- Exponents must be **positive integers**. Use `/` for denominator instead of negative exponents (e.g., `ft/s^2` not `ft*s^-2`).
- Exponent expressions inside `^(...)` support `+`, `-`, `*` with left-to-right evaluation (no operator precedence).
- There is no limit on the number of units that can be multiplied or divided in a compound unit string.

**Examples of valid unit strings:**
```
ft/s            feet per second
slug-ft^2       slug-feet-squared (moment of inertia)
deg/s           degrees per second
m/s^2           meters per second squared
kg/(m*s^2)      kilograms per meter per second squared
lbf*ft/s        pound-force feet per second (power)
rad/s           radians per second
kN              kilonewtons
```

---

## Equations (Dynamic Values)

Any numeric field in the JSON can be replaced with a time-varying or state-varying equation. Place a `"sines"` or `"polynomials"` dictionary inside any JSON section; each key names the sibling field to override.

Equations are evaluated once per timestep (before RK4 integration). When a field appears both as a constant and inside an equations dictionary, the equation result overwrites the constant each timestep.

### Sine Equations

Formula: `offset + amplitude × sin(frequency × x + phase)`

```json
"mass" : {
    "weight[lbf]": 20500,
    "Ixx[slug-ft^2]": 9496,
    "sines": {
        "Izz[slug-ft^2]": {
            "independent_variable": "time",
            "amplitude": 100,
            "frequency": 0.5,
            "phase[rad]": 0,
            "offset": 5000
        }
    }
}
```

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `independent_variable` | string | **yes** | — | Name of the variable to use as input (see [Available Variables](#available-independent-variables)) |
| `amplitude` | real | **yes** | — | Wave amplitude |
| `frequency` | real | **yes** | — | Multiplier on the independent variable (not Hz — raw multiplier) |
| `phase` | real | no | `0.0` | Phase shift. Default units: rad. |
| `offset` | real | **yes** | — | DC offset (mean value) |

**Note:** `frequency` is a raw multiplier, not cycles-per-second. For a 1 Hz sine of time, use `frequency = 6.2832` (2π). For a second harmonic of a control angle, use `frequency = 2.0`.

### Polynomial Equations

Formula: sum of monomial terms `y = c₀ + c₁·x₁ + c₂·x₁² + c₃·x₁·x₂ + ...`

```json
"mass" : {
    "polynomials": {
        "weight[lbf]": {
            "0": 20500,
            "time": -0.5,
            "time^2": 0.001
        }
    }
}
```

Each key inside the polynomial object is a monomial term; the value is its coefficient. All terms are summed.

| Term Key | Meaning | Example |
|----------|---------|---------|
| `"0"` | Constant term | `"0": 20500` → 20500 |
| `"alpha"` | Linear in one variable | `"alpha": 3.85` → 3.85·α |
| `"alpha^2"` | Variable raised to a power | `"alpha^2": 0.24` → 0.24·α² |
| `"alpha_qbar"` | Product of two variables | `"alpha_qbar": 23.0` → 23.0·α·q̄ |
| `"alpha^2_qbar"` | Mixed term | `"alpha^2_qbar": -0.03` → -0.03·α²·q̄ |

Rules:
- `_` separates multiplied variables
- `^N` after a variable name sets its exponent (default 1)
- `"0"` is the constant (no-variable) term

### Available Independent Variables

These names can be used as `independent_variable` (sines) or as term variables (polynomials):

| Name | Description |
|------|-------------|
| `time` | Simulation time (s) |
| `altitude` | Altitude above ground (ft), positive up |
| `u`, `v`, `w` | Body-frame velocity components (ft/s) |
| `p`, `q`, `r` | Body-frame angular rates (rad/s) |
| *effector name* | Any control effector by its JSON key name (e.g., `aileron`, `elevator`, `throttle`) |
| *passive name* | Any passive effector by its JSON key name |

If an equation references a variable name that doesn't exist, the simulator prints an error and stops at startup.

### Currently Supported Targets

Equations can currently target these fields:

| Section | Target Names |
|---------|-------------|
| `mass` | `weight`, `Ixx`, `Iyy`, `Izz`, `Ixy`, `Ixz`, `Iyz` |
| `atmosphere` | `constant_wind_N`, `constant_wind_E`, `constant_wind_D` |
| *force source name* | Geometric fields (see below) |

When mass properties are modified by equations, the inertia tensor symmetry (`I(2,1)=I(1,2)`, etc.) and derived quantities (mass from weight, inverse inertia) are automatically recomputed each timestep.

### Variable Geometry (Force Source Equations)

Any force source can have `"polynomials"` or `"sines"` blocks at the top level of its JSON section. The equation section is automatically set to the source name.

**Example: folding vertical stabilizer driven by a control effector**
```json
"vstab" : {
    "type" : "wing",
    "reference" : { "semispan[ft]": 0.83, "root_chord[ft]": 0.78, "tip_chord[ft]": 0.38 },
    "polynomials" : {
        "semispan[ft]" : { "vtailFlag": 0.83 }
    }
}
```

This sets `vstab.semispan = 0.83 * vtailFlag` each timestep, where `vtailFlag` is a control effector (0 = folded, 1 = deployed).

**Available targets by source type:**

| Category | Target Names | Description |
|---|---|---|
| **Location** (all) | `location_x`, `location_y`, `location_z` | Component position relative to vehicle CG [ft] |
| **Orientation** (all) | `orientation_phi`, `orientation_theta`, `orientation_psi` | Component Euler angles [rad]. Quaternion recomputed automatically. |
| **Mass** (all) | `weight`, `comp_cg_x`, `comp_cg_y`, `comp_cg_z` | Component weight [lbf] and CG offset in component frame [ft]. Mass recomputed from weight. |
| **Inertia** (all) | `Ixx`, `Iyy`, `Izz`, `Ixy`, `Ixz`, `Iyz` | Component inertia tensor about CG in component frame. Symmetry enforced automatically. |
| **Wing** | `semispan`, `root_chord`, `tip_chord`, `sweep`, `dihedral` | Wing geometry |
| **Sphere** | `rx`, `ry`, `rz` | Ellipsoid radii |
| **Cuboid** | `lx`, `ly`, `lz` | Box dimensions |
| **Cylinder** | `r1`, `r2`, `length` | Frustum radii and length |
| **Propeller** | `diameter` | Propeller diameter |
| **Simple thrust** | `T0` | Max sea-level thrust |

**Example: tilt-rotor nacelle driven by a tilt servo**
```json
"front_rotor" : {
    "type" : "propulsion",
    "propulsion_type" : "propeller",
    "component_orientation[deg]" : [0, 90, 0],
    "polynomials" : {
        "orientation_theta[deg]" : { "tilt_servo": 1.0 }
    }
}
```

When geometry equations are present:
- Orientation quaternion is recomputed from the (possibly updated) Euler angles each timestep
- Component mass is recomputed from weight; inertia symmetry is enforced
- Wing derived quantities (S_w, R_A, mean_chord, ac_local) recompute automatically
- Vehicle mass properties reassemble from the base mass plus all component contributions (parallel-axis theorem), accounting for updated locations, orientations, and component inertias
- Inertia inverse is recomputed
- Zero-span and zero-chord are handled gracefully (wing produces zero force when area or aspect ratio reaches zero)

### Unit Conversion

Equation target keys support unit brackets just like regular fields. The equation result is converted from the specified units to internal units:

```json
"sines": {
    "Izz[kg-m^2]": { ... }
}
```

This evaluates the sine in kg·m² and converts the result to slug·ft².

---

## Simulation Settings

```json
"simulation" : {
    "time_step[s]"          : 0.01,
    "end_time[s]"           : 30.0,
    "rk4_verbose"           : false,
    "save_states"           : true,
    "realtime"              : false,
    "geographic_model"      : "flat",
    "print_states_rate[hz]" : 0.0,
    "save_states_rate[hz]"  : 0.0
}
```

All real-valued keys support the unit-aware system (see [Unit System](#unit-system)). For example, `"time_step[s]"` could also be written as `"time_step[ms]": 10` (10 milliseconds) or `"time_step": 0.01` (bare = seconds, the internal unit).

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `time_step` | real | **yes** | — | RK4 integration time step. Default units: seconds. |
| `end_time` | real | **yes** | — | Simulation duration. Default units: seconds. |
| `rk4_verbose` | bool | no | `false` | Print RK4 sub-step details to console |
| `save_states` | bool | no | `true` | Write state history to CSV file |
| `realtime` | bool | no | `false` | Run simulation in real-time (wall-clock pacing) |
| `time_scale` | real | no | `1.0` | Time scale factor for real-time mode. `5.0` runs 5× faster than real-time. Only applies when `realtime` = true. |
| `geographic_model` | string | no | `"flat"` | `"flat"`, `"sphere"`, or `"ellipse"` |
| `print_states_rate` | real | no | `0.0` | Console output rate. Default units: Hz. 0 = disabled. |
| `save_states_rate` | real | no | `0.0` | CSV output rate. Default units: Hz. 0 = write every timestep. Non-zero values limit CSV write frequency (e.g., 100 Hz writes every 0.01s regardless of physics dt). Also controls sensor CSV write rate. |

**Override behavior:**
- Setting `time_step[s]` to `0.0` auto-enables real-time mode with `dt = 0.01` (legacy compatibility). A console note is printed. Prefer explicitly setting `"realtime": true` with a nonzero time step.
- If `time_step[s]` is `0.0` AND `realtime` is `true`, dt defaults to `0.01`.

---

## Atmosphere

Optional top-level section. If omitted, no wind or turbulence is applied.

```json
"atmosphere" : {
    "constant_wind[ft/s]" : [0, 0, 0],
    "temperature_at_altitude[degF]" : 95.0,
    "pressure_at_altitude[inHg]"    : 29.75,
    "turbulence" : { ... }
}
```

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `constant_wind` | real[3] | no | `[0, 0, 0]` | Constant wind in earth frame [North, East, Down]. Default units: ft/s. |
| `temperature_at_altitude` | real | no | — | Actual temperature at the initial flight altitude. Code back-computes offset from standard day. Hot day = lower density = less lift/thrust. |
| `pressure_at_altitude` | real | no | — | Actual pressure at the initial flight altitude. Code back-computes offset from standard day. Low pressure = "high to low, look out below." |
| `use_wmm` | bool | no | `false` | Compute the magnetometer/IMU field and EKF declination from the World Magnetic Model (WMM2025, degree/order 12) at the vehicle's lat/lon/alt instead of a fixed constant. Requires the vehicle's initial `latitude`/`longitude` (constant on flat earth, tracked on spherical/ellipsoidal earth). |
| `date` | real | no | `2025.0` | Decimal year for the WMM secular variation (e.g. `2026.5`). Only used when `use_wmm` is true. |

### Turbulence

Optional subsection within `atmosphere`. If omitted or `enabled` is false, no turbulence is applied.

```json
"turbulence" : {
    "enabled"      : true,
    "sigma[ft/s]"  : 5.0,
    "intensity"    : "light",
    "Vmin[ft/s]"   : 5.0,
    "wingspan[ft]" : 30.0,
    "Lh_sep[ft]"   : 15.0,
    "Lv_sep[ft]"   : 14.0,
    "buffer_size"  : 20
}
```

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `enabled` | bool | no | `false` | Enable/disable turbulence |
| `sigma` | real | no | — | Fixed turbulence intensity. Default units: ft/s. **Overrides `intensity` if present.** |
| `intensity` | string | no | `"light"` | Altitude-dependent sigma from Tables 9.2.1-9.2.3. Valid: `"light"`, `"moderate"`, `"severe"`. Only used when `sigma` is absent. |
| `Vmin` | real | no | `5.0` | Minimum velocity floor for frozen-field step. Default units: ft/s. |
| `wingspan` | real | no | `0.0` | Aircraft wingspan for roll-rate gust (p). Default units: ft. **0 = no p-gust.** |
| `Lh_sep` | real | no | `0.0` | CG-to-horizontal-tail distance for pitch-rate gust (q). Default units: ft. **0 = no q-gust.** |
| `Lv_sep` | real | no | `0.0` | CG-to-vertical-tail distance for yaw-rate gust (r). Default units: ft. **0 = no r-gust.** |
| `buffer_size` | int | no | `20` | Circular buffer size for q/r gust finite differences |
| `seed` | int | no | `42` | Random number generator seed for reproducible turbulence |

**Sigma modes:**
- If `sigma[ft/s]` is present: fixed sigma at all altitudes (good for testing and validation)
- If `intensity` is present without `sigma[ft/s]`: sigma is looked up from MIL-HDBK-1797 Tables 9.2.1-9.2.3 based on vehicle altitude, updated each timestep
- If neither is present: defaults to `"light"` intensity

**Turbulence model:** Dryden-Beal recursive filters (MIL-HDBK-1797 Ch 9, Eqs. 9.3.26-9.3.31). High-altitude length scales (Lu=1750 ft, Lv=Lw=875 ft). Gusts are applied to aerodynamic model velocities only per Section 9.8 — not to the rigid-body state integrator. Turbulence does NOT affect UDP packet contents.

---

## Vehicles

Each vehicle is a named JSON object inside `"vehicles"`. The key becomes the vehicle name. Only vehicles with `run_physics` = true (the default) are loaded.

```json
"vehicles" : {
    "my_vehicle_name" : {
        "run_physics"       : true,
        "is_kinematic"      : false,
        "mass"              : { ... },
        "batteries"         : { ... },
        "control_effectors" : { ... },
        "passive_effectors" : { ... },
        "force_sources"     : { ... },
        "initial"           : { ... },
        "analysis"          : { ... },
        "sensors"           : { ... }
    }
}
```

### Vehicle-Level Fields

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `run_physics` | bool | no | `true` | If false, vehicle is skipped entirely |
| `is_kinematic` | bool | no | `false` | If true, no forces are computed; state is propagated kinematically |

---

### Mass Properties

The vehicle-level `"mass"` block is **optional**. When it is present it provides the base
mass/inertia (located at the body origin). When it is **omitted**, the base mass is zero and the
vehicle's total mass, CG, and inertia are assembled entirely from the per-component `"mass"` blocks
on the force sources (see [Component mass](#common-fields-all-force-source-types) and the `point_mass`
type) — a fully component-built vehicle. If present, `weight` is required; inertias default to `0.0`
(and may instead be supplied by an equation block).

```json
"mass" : {
    "weight[lbf]"    : 20500.0,
    "Ixx[slug-ft^2]" : 9496.0,
    "Iyy[slug-ft^2]" : 55814.0,
    "Izz[slug-ft^2]" : 63100.0,
    "Ixy[slug-ft^2]" : 0.0,
    "Ixz[slug-ft^2]" : 982.0,
    "Iyz[slug-ft^2]" : 0.0,
    "h[slug-ft^2/s]" : [160.0, 0.0, 0.0]
}
```

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `weight` | real | yes¹ | — | Vehicle weight. Default units: lbf. |
| `Ixx` | real | no | `0.0` | Roll moment of inertia. Default units: slug-ft^2. |
| `Iyy` | real | no | `0.0` | Pitch moment of inertia. Default units: slug-ft^2. |
| `Izz` | real | no | `0.0` | Yaw moment of inertia. Default units: slug-ft^2. |
| `Ixy` | real | no | `0.0` | Product of inertia. Default units: slug-ft^2. |
| `Ixz` | real | no | `0.0` | Product of inertia. Default units: slug-ft^2. |
| `Iyz` | real | no | `0.0` | Product of inertia. Default units: slug-ft^2. |
| `h` | real[3] | no | `[0, 0, 0]` | Rotor angular momentum vector in body frame. Default units: slug-ft^2/s. |

The inertia matrix is symmetric: `I(2,1) = I(1,2)`, etc. Mass is computed from weight: `mass = weight / g`.

¹ Required only when the `"mass"` block is present. The block as a whole is optional (see above).

---

### Batteries

Optional section for electric propulsion. Defines battery packs that electric motors can reference by name. One battery can power multiple motors (e.g., quadrotor with 4 motors on one pack). Batteries are named objects inside `"batteries"`. Implements Phillips Sec 4.6 (Eqs 4.6.1–4.6.4).

Specify a pack **one of two ways**. Either way, `cells_series` (S) and `cells_parallel` (P) define
the configuration, and the model scales per-cell properties to the pack: pack voltage = S × cell
voltage, pack capacity = P × cell capacity, pack resistance = (S/P) × cell resistance.

**(a) Pack-level** — give the values the way they are printed on the battery label. The loader divides
them down to per-cell internally. Constant voltage (no discharge curve). This is the simplest form:

```json
"batteries" : {
    "main" : {
        "cells_series"    : 6,
        "cells_parallel"  : 1,
        "pack_voltage"    : 22.2,
        "pack_capacity"   : 5000,
        "pack_resistance" : 0.025,
        "C_rating"        : 20.0
    }
}
```

**(b) Per-cell** — give a `"cell"` block with per-cell values. Use this when you have a real cell
discharge curve. Open-circuit voltage then follows the Maoquan/Haixin model (Eq 4.6.2):

```
cell_OCV = cell_voltage − EA · (Q_total / Q_remaining) + EB · exp(−EC · Q_used)
pack_OCV = cells_series × cell_OCV
```

Set `EA = EB = 0` for a constant-voltage cell; otherwise `EA` drives the smooth sag near
end-of-charge and `EB`/`EC` capture the exponential plateau.

```json
"batteries" : {
    "main" : {
        "cells_series"   : 6,
        "cells_parallel" : 1,
        "cell" : {
            "cell_voltage"    : 4.2,
            "cell_capacity"   : 3000,
            "cell_resistance" : 0.004,
            "EA" : 0.0, "EB" : 0.0, "EC" : 0.0
        },
        "C_rating" : 20.0
    }
}
```

Provide **either** the pack-level fields **or** a `cell` block (the pack-level fields take precedence
if both are present). All voltages are [V], capacities [mAh], resistances [Ohm].

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `cells_series` | int | no | `1` | Cells in series (S). Pack voltage = S × cell voltage. |
| `cells_parallel` | int | no | `1` | Cells in parallel (P). Pack capacity = P × cell capacity. |
| `pack_voltage` | real | (a) | — | **Pack** nominal voltage [V]. Its presence selects pack-level mode; per-cell = `pack_voltage / S`. |
| `pack_capacity` | real | (a) | — | **Pack** capacity [mAh]; per-cell = `pack_capacity / P`. Required when `pack_voltage` is given. |
| `pack_resistance` | real | no | `0.0` | **Pack** internal resistance [Ohm]; per-cell = `pack_resistance × P / S`. |
| `cell.cell_voltage` | real | (b) | — | **Per-cell** full-charge no-load voltage `E_b0F` [V] (Eq 4.6.2). |
| `cell.cell_capacity` | real | (b) | — | **Per-cell** capacity [mAh]. Internally converted to A·s (× 3.6). |
| `cell.cell_resistance` | real | no | `0.0` | **Per-cell** internal resistance [Ohm]. |
| `cell.EA` | real | no | `0.0` | Maoquan/Haixin voltage-sag constant `E_A` [V] (Eq 4.6.2). |
| `cell.EB` | real | no | `0.0` | Maoquan/Haixin plateau-amplitude constant `E_B` [V] (Eq 4.6.2). |
| `cell.EC` | real | no | `0.0` | Maoquan/Haixin plateau-rate constant `E_C` in `1/(A·hr)` (Eq 4.6.2). Internally divided by 3600. |
| `C_rating` | real | no | `0.0` | Battery C-rating `C_b` in `1/hr` (Eq 4.6.4). `0` disables the check. When `|I_total| > C_b · Q_remaining`, a warning is printed once per battery. |
| `power_aux` | real | no | `0.0` | Auxiliary power draw [W] (avionics, payload). |
| `voltage_aux` | real | no | `5.0` | Auxiliary voltage [V]. Auxiliary current = power_aux / voltage_aux. |

(a) Required for pack-level mode. (b) Required for per-cell mode. Use one mode or the other.

Battery SOC is updated each timestep via Euler integration of the **battery-side** current (not motor armature current): `I_b = (E_b0 − E_b) / R_b` with `E_b` from Eq 4.6.32. When SOC reaches 0, motors produce zero thrust.

---

### Control Effectors

Control effectors are named actuators that force sources can reference. The JSON key is the effector name. Vehicles without control surfaces (sphere, kinematic) omit this section entirely.

```json
"control_effectors" : {
    "aileron" : {
        "dynamics_order"              : 2,
        "magnitude_limits[deg]"       : [-21.5, 21.5],
        "rate_limits[deg/s]"          : [-80.0, 80.0],
        "acceleration_limits[deg/s^2]": [-1000.0, 1000.0],
        "time_constant[s]"            : 0.05,
        "natural_frequency[rad/s]"    : 20.0,
        "damping_ratio"               : 0.7
    },
    "throttle" : {
        "dynamics_order"      : 0,
        "magnitude_limits"    : [0.0, 1.0],
        "rate_limits[/s]"     : [-1.0, 1.0]
    }
}
```

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `magnitude_limits` | real[2] | no | `[-1e30, 1e30]` | [min, max] position limits. If the key has angular units (e.g., `[deg]`), effector is marked as an **angle** and values are auto-converted to radians. If no units or non-angular units, effector is non-angle. |
| `dynamics_order` | int | no | `0` | `0` = instant, `1` = first-order, `2` = second-order. Valid values: 0, 1, 2. |
| `time_constant` | real | conditional | `0.0` | First-order time constant. **Required and must be > 0 if `dynamics_order` = 1.** |
| `natural_frequency` | real | conditional | `0.0` | Second-order natural frequency. **Required and must be > 0 if `dynamics_order` = 2.** |
| `damping_ratio` | real | conditional | `0.0` | Second-order damping ratio. **Required and must be > 0 if `dynamics_order` = 2.** |
| `rate_limits` | real[2] | no | `[-1e30, 1e30]` | [min, max] rate limits. Use `[deg/s]` for angle effectors, `[/s]` for non-angle. Units are auto-converted. |
| `acceleration_limits` | real[2] | no | `[-1e30, 1e30]` | [min, max] acceleration limits. Use `[deg/s^2]` for angle effectors, `[/s^2]` for non-angle. |

**Angle detection** is automatic: the code inspects the units on `magnitude_limits`. If the numerator contains an angular unit (`deg`, `rad`), `is_angle` is set to true. If there are no units or the units are non-angular, `is_angle` is false.

**Rate and acceleration limit units must include the angle unit explicitly.** For angle effectors, use `rate_limits[deg/s]` (not `rate_limits[/s]`). For non-angle effectors like throttle, `rate_limits[/s]` is correct.

**Override behavior — `dynamics_order` controls which parameters matter:**

| `dynamics_order` | Active parameters | Ignored parameters |
|------------------|-------------------|--------------------|
| `0` (instant) | `magnitude_limits` only | `time_constant`, `natural_frequency`, `damping_ratio`, `rate_limits`, `acceleration_limits` — all ignored |
| `1` (first-order) | `time_constant` (**required**, error if <= 0), `magnitude_limits`, `rate_limits` | `natural_frequency`, `damping_ratio`, `acceleration_limits` |
| `2` (second-order) | `natural_frequency` (**required**, error if <= 0), `damping_ratio` (**required**, error if <= 0), `magnitude_limits`, `rate_limits`, `acceleration_limits` | `time_constant` |

**Important**: Effector names must **not contain underscores** if used as variables in coefficient term keys, since underscores separate factors in product terms (e.g., `"alpha_elevator"` means alpha * elevator). Use names like `motor1`, not `motor_1`. Effector names with underscores are fine for thrust sources and initial conditions — only coefficient term keys use underscore splitting.

---

### Passive Effectors

Free-floating aerodynamic surfaces (e.g., canards, fins) driven by aerodynamic moments. Each passive effector has its own inertia, damping, and a driving moment coefficient. The JSON key is the effector name.

```json
"passive_effectors" : {
    "canard" : {
        "inertia[slug-ft^2]"    : 0.01,
        "reference_length[ft]"  : 0.5,
        "reference_area[ft^2]"  : 0.25,
        "damping[slug-ft^2/s]"  : 0.001,
        "magnitude_limits[deg]" : [-25.0, 25.0],
        "rate_variable"         : "canardrate",
        "nondimensional_rate"   : true,
        "driving_coefficient"   : { "alpha" : -2.5, "qbar" : -8.0 },
        "driving_database"      : { ... }
    }
}
```

#### Physical Properties

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `inertia` | real | **yes** | — | Hinge moment of inertia. Default units: slug-ft^2. |
| `reference_length` | real | **yes** | — | Reference length for moment nondimensionalization. Default units: ft. |
| `reference_area` | real | no | `0.0` | Reference area. Default units: ft^2. **If 0 or absent, defaults to the first aerodynamic force source's area.** |
| `damping` | real | no | `0.0` | Bearing friction. Default units: slug-ft^2/s. If 0, no damping is applied. |
| `magnitude_limits` | real[2] | no | — | [min, max] position limits. Use `[deg]` for degrees (auto-converted to radians). |
| `rate_variable` | string | no | `""` | Name by which the rate is accessible as a variable in coefficient terms and database IVs. If empty, rate is not accessible. |
| `nondimensional_rate` | bool | no | `true` | If true: rate = theta_dot * L_ref / (2V). If false: rate = theta_dot. |

#### Driving Moment

Each passive effector requires **exactly one** of:

**Option 1: `driving_coefficient`** — polynomial-style moment coefficient using the same term syntax as `stability_derivatives` coefficients:

```json
"driving_coefficient" : { "alpha" : -2.5, "qbar" : -8.0 }
```

**Option 2: `driving_database`** — table-lookup moment coefficient from CSV files:

```json
"driving_database" : {
    "driving_variable"   : "Ch",
    "database_directory" : "databases/",
    "files"              : ["canard_Ch.csv"],
    "saturate"           : true,
    "presorted"          : false
}
```

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `driving_variable` | string | **yes** | — | Name of the dependent variable column to use as the driving coefficient |
| `database_directory` | string | no | `""` | Path prefix for database files |
| `files` | string[] | **yes** | — | List of CSV database filenames |
| `saturate` | bool | no | `true` | Clamp interpolation at table boundaries |
| `presorted` | bool | no | `false` | If true, skip sorting (data must already be sorted) |

**Initial conditions** for passive effectors are set in the `state.passive_effectors` section (see Initial Conditions).

---

### Force Sources

Force sources are named objects inside `"force_sources"`. Each has a `"type"` field that determines what other fields are expected. A vehicle can have any number of sources; their forces and moments are summed.

```json
"force_sources" : {
    "source_name" : {
        "type" : "...",
        ...
    }
}
```

Supported types: `stability_derivatives`, `database`, `propulsion`, `wing`, `sphere`, `cuboid`, `cylinder`, `point_mass`

#### Common Fields (All Force Source Types)

Every force source supports these optional fields in addition to its type-specific fields:

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `type` | string | **yes** | — | Force source type identifier |
| `use_source` | bool | no | `true` | If false, this source is skipped |
| `location` | real[3] | no | `[0, 0, 0]` | Position relative to CG in body frame. Default units: ft. |
| `component_orientation` | real[3] | no | — | Euler angles [phi, theta, psi] defining component frame rotation relative to body frame. Default units: rad. Use `[deg]`. When present, velocity is transformed to component frame for force computation, and forces/moments are rotated back to body frame (Eqs 3.6.2-3.6.5). |
| `mass` | object | no | — | Per-component mass properties (see below) |

**Component mass** (optional sub-object on any force source):

```json
"mass" : {
    "weight[lbf]"        : 0.5,
    "cg[ft]"             : [0.0, 0.0, 0.0],
    "Ixx[slug-ft^2]"     : 0.001,
    "Iyy[slug-ft^2]"     : 0.001,
    "Izz[slug-ft^2]"     : 0.001,
    "Ixy[slug-ft^2]"     : 0.0,
    "Ixz[slug-ft^2]"     : 0.0,
    "Iyz[slug-ft^2]"     : 0.0,
    "inertia_ref[ft]"    : [0.0, 0.0, 0.0],
    "h[slug-ft^2/s]"     : [0.0, 0.0, 0.0]
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `weight` | real | — | Component weight. Default units: lbf. |
| `cg` | real[3] | `[0,0,0]` | CG offset in component frame. Default units: ft. |
| `Ixx`, `Iyy`, `Izz` | real | `0.0` | Component inertias. Default units: slug-ft^2. |
| `Ixy`, `Ixz`, `Iyz` | real | `0.0` | Products of inertia. |
| `inertia_ref` | real[3] | — | Point about which inertia is measured (if different from CG). Parallel-axis theorem shifts to CG. |
| `h` | real[3] | `[0,0,0]` | Spinning angular momentum in component frame. |

Component masses are assembled at init via parallel-axis theorem: total mass, composite CG, and total
inertia are computed from the (optional) vehicle base mass plus all component masses. The assembled
total mass, CG, and inertia tensor are printed at startup. If the vehicle `"mass"` block is omitted,
the total is built purely from these component masses.

---

#### Type: `point_mass`

An inert mass element — a payload, ballast, battery, avionics box, or any lumped mass that contributes
to the vehicle's mass/CG/inertia but produces **no** aerodynamic or propulsive force. (`ballast` and
`mass` are accepted as aliases of `point_mass`.)

```json
"battery_mass" : {
    "type"        : "point_mass",
    "location[ft]": [0.0, 0.0, 0.05],
    "mass" : {
        "weight[lbf]"    : 0.9,
        "Ixx[slug-ft^2]" : 0.000101,
        "Iyy[slug-ft^2]" : 0.000319,
        "Izz[slug-ft^2]" : 0.000353
    }
}
```

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `type` | string | **yes** | `"point_mass"` (or `"ballast"` / `"mass"`) |
| `location` | real[3] | **yes** | Position of the mass relative to the body origin. Default units: ft. |
| `mass` | object | **yes** | Component mass block. `weight` is required; the inertia tensor is optional (omit it for a true point mass, whose only inertia contribution is the parallel-axis term about `location`). See [Component mass](#common-fields-all-force-source-types). |

Use several `point_mass` sources (plus the `"mass"` blocks on real components) to build a vehicle's
inertia entirely from its parts and omit the vehicle-level `"mass"` block — see
`examples/quadrotor/sim_quadrotor.json`.

---

#### Type: `stability_derivatives`

Full aerodynamic model using linearized stability derivatives. Supports any number of control/passive effectors and custom intermediate variables.

```json
"aerodynamics" : {
    "type" : "stability_derivatives",
    "reference" : {
        "area[ft^2]"              : 300.0,
        "longitudinal_length[ft]" : 11.32,
        "lateral_length[ft]"      : 30.0,
        "location[ft]"            : [-1.0, 0.0, 0.0]
    },
    "stall" : { ... },
    "coefficients" : { ... }
}
```

**Reference geometry:**

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `area` | real | **yes** | — | Reference wing area. Default units: ft^2. |
| `longitudinal_length` | real | **yes** | — | Mean aerodynamic chord (for pitch moments). Default units: ft. |
| `lateral_length` | real | **yes** | — | Wing span (for roll/yaw moments). Default units: ft. |
| `location` | real[3] | no | `[0, 0, 0]` | Aero reference point offset from CG in body frame. Default units: ft. |

**Stall model** (optional):

```json
"stall" : {
    "include_stall" : true,
    "CL" : { "alpha_0[deg]" : 0.0, "alpha_s[deg]" : 43.0, "lambda_b" : 7.0 },
    "CD" : { "alpha_0[deg]" : 5.0, "alpha_s[deg]" : 45.0, "lambda_b" : 7.0 },
    "Cm" : { "min" : -0.6184, "alpha_0[deg]" : 20.0, "alpha_s[deg]" : 40.0, "lambda_b" : 6.0 },
    "pbar" : { "stall" : 0.5, "lambda" : 10.0, "Cl_stall" : 0.02 },
    "qbar" : { "stall" : 0.5, "lambda" : 10.0, "Cm_stall" : -0.1 },
    "rbar" : { "stall" : 0.5, "lambda" : 10.0, "Cn_stall" : 0.01 }
}
```

*Alpha stall parameters (CL, CD, Cm) — each is a child object within `stall`:*

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `include_stall` | bool | `false` | Master enable for the stall model |
| `CL.alpha_0` | real | `0.0` | Angle where CL stall blending begins. Default units: rad. Use `[deg]` for degrees. |
| `CL.alpha_s` | real | `0.0` | Angle of full CL stall. Default units: rad. Use `[deg]` for degrees. |
| `CL.lambda_b` | real | `0.0` | CL blending sharpness parameter |
| `CD.alpha_0` | real | `0.0` | Angle where CD stall blending begins. Default units: rad. Use `[deg]` for degrees. |
| `CD.alpha_s` | real | `0.0` | Angle of full CD stall. Default units: rad. Use `[deg]` for degrees. |
| `CD.lambda_b` | real | `0.0` | CD blending sharpness parameter |
| `Cm.min` | real | `0.0` | Minimum pitching moment at full stall |
| `Cm.alpha_0` | real | `0.0` | Angle where Cm stall blending begins. Default units: rad. Use `[deg]` for degrees. |
| `Cm.alpha_s` | real | `0.0` | Angle of full Cm stall. Default units: rad. Use `[deg]` for degrees. |
| `Cm.lambda_b` | real | `0.0` | Cm blending sharpness parameter |

*Rotation rate stall parameters (pbar, qbar, rbar):*

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `pbar.stall` | real | `0.0` | Non-dimensional roll rate stall threshold |
| `pbar.lambda` | real | `0.0` | Roll rate stall blending sharpness |
| `pbar.Cl_stall` | real | `0.0` | Roll moment coefficient at pbar stall |
| `qbar.stall` | real | `0.0` | Non-dimensional pitch rate stall threshold |
| `qbar.lambda` | real | `0.0` | Pitch rate stall blending sharpness |
| `qbar.Cm_stall` | real | `0.0` | Pitch moment coefficient at qbar stall |
| `rbar.stall` | real | `0.0` | Non-dimensional yaw rate stall threshold |
| `rbar.lambda` | real | `0.0` | Yaw rate stall blending sharpness |
| `rbar.Cn_stall` | real | `0.0` | Yaw moment coefficient at rbar stall |

*Lateral beta-stall parameters (side force CS, yaw Cn) — the β-axis parallel to the α stall (Sec 3.8), each a child object within `stall`:*

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `CS.beta_0` | real | `0.0` | Sideslip where CS stall blending begins. Default units: rad. Use `[deg]` for degrees. |
| `CS.beta_s` | real | `0.0` | Sideslip of full CS stall. Default units: rad. Use `[deg]` for degrees. |
| `CS.lambda_b` | real | `0.0` | CS stall blending sharpness |
| `CS.max` | real | `0.0` | Post-stall side-force magnitude (flat-plate `sign(β)·sin²β·cosβ`) |
| `Cn.beta_0` | real | `0.0` | Sideslip where Cn stall blending begins. Default units: rad. Use `[deg]` for degrees. |
| `Cn.beta_s` | real | `0.0` | Sideslip of full Cn stall. Default units: rad. Use `[deg]` for degrees. |
| `Cn.lambda_b` | real | `0.0` | Cn stall blending sharpness |
| `Cn.min` | real | `0.0` | Post-stall yaw-moment magnitude (flat-plate `sign(β)·sin²β`) |

Alpha stall angles use the unit-aware system — `alpha_0[deg]` auto-converts degrees to radians. Without `[deg]`, values are in radians.

**Coefficients** (generic evaluator):

Each coefficient group (CL, CS, CD, Cl, Cm, Cn) is a sum of terms. Each term is a coefficient value multiplied by zero, one, or two variables from the variable pool.

```json
"coefficients" : {
    "custom" : {
        "CL1" : { "0" : 0.0535, "alpha" : 3.8459 }
    },
    "CL" : { "0" : 0.0535, "alpha" : 3.8459, "qbar" : 29.5, "elevator" : 0.5153 },
    "CS" : { "beta" : -1.1086, "pbar" : -0.0207, "alpha_pbar" : 1.1566 },
    "CD" : { "0" : 0.0425, "CL1" : -0.1154, "CL1_CL1" : 0.2427 },
    "Cl" : { ... },
    "Cm" : { ... },
    "Cn" : { ... }
}
```

**Term key syntax:**

| Key Format | Meaning | Example |
|------------|---------|---------|
| `"0"` | Constant (bias) term | `"0" : 0.0535` adds 0.0535 |
| `"var"` | Linear term | `"alpha" : 3.8459` adds 3.8459 * alpha |
| `"var1_var2"` | Product term | `"alpha_pbar" : 1.1566` adds 1.1566 * alpha * pbar |

Maximum 2 factors per term (product of at most 2 variables).

**Available standard variables:**

| Variable | Description |
|----------|-------------|
| `alpha` | Angle of attack [rad] |
| `beta` | Sideslip angle [rad] |
| `pbar` | Non-dimensional roll rate: p * b / (2V) |
| `qbar` | Non-dimensional pitch rate: q * c / (2V) |
| `rbar` | Non-dimensional yaw rate: r * b / (2V) |
| `alphahat` | Non-dimensional alpha rate: alpha_dot * c / (2V) (Eq 3.4.20) |
| `betahat` | Non-dimensional beta rate: beta_dot * b / (2V) (Eq 3.4.21) |
| `beta_flank` | Flanking angle [rad] |

**Additional variables available in term keys:**

- Any **control effector name** (e.g., `elevator`, `aileron`, `rudder`, `throttle`) — uses the current effector value
- Any **passive effector name** — uses the current passive effector position [rad]
- Any **passive effector rate variable** — uses the computed rate (if `rate_variable` was defined on the passive effector)
- Any **custom variable name** defined in the `"custom"` section
- Any **group result**: `CL`, `CS`, `CD`, `Cl`, `Cm`, `Cn` (and the stability-axis groups `CLstab`, `CDstab`, `CSstab`, `Clstab`, `Cnstab`) — evaluated groups are available to later groups

**Evaluation order:** custom variables first, then the body/wind groups CL, CS, CD, Cl, Cm, Cn, then the stability-axis groups CLstab, CDstab, CSstab, Clstab, Cnstab. A group can reference any group that was evaluated before it (e.g., CD can reference CL through a custom variable).

**Coefficient frames.** A coefficient's reference frame is implied by its name:
- **Wind axis** — `CL`, `CD`, `CS` (lift/drag/side): rotated to body by α and β (Table 3.4.4).
- **Body axis** — `Cx`, `Cy`, `Cz` and moments `Cl`, `Cm`, `Cn`: applied directly.
- **Stability axis** — `CLstab`, `CDstab`, `CSstab` (forces) and `Clstab`, `Cnstab` (roll/yaw): rotated to body by α only (stability axes are the body axes rotated by α; this is the β=0 specialization of the wind transform). Stability-axis pitch equals body pitch, so use `Cm`. These let you load classic stability-axis derivatives (e.g. `Clstab_beta`, `Cnstab_beta`) without pre-rotating them to body/wind. Available in both the `stability_derivatives` (group) and `database` (column-name) aero sources.

**Custom variables** allow intermediate calculations. For example, defining `CL1` as a custom variable lets CD depend on CL through terms like `CL1_CL1` (CL1 squared).

---

#### Type: `propulsion`

Unified propulsion model. The `propulsion_type` field selects the model.

##### Propulsion Type: `simple`

A single thrust vector scaled by a control effector and density correction.

```json
"engine" : {
    "type"             : "propulsion",
    "propulsion_type"  : "simple",
    "effector"         : "throttle",
    "T0[lbf]"         : 29550,
    "Ta"               : 0.84,
    "location[ft]"     : [0.0, 0.0, 0.0],
    "orientation[deg]" : [0.0, 0.0, 0.0]
}
```

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `propulsion_type` | string | **yes** | — | `"simple"` or `"propeller"` |
| `effector` | string | **yes** | — | Name of control effector. Must match a name in `control_effectors`. |
| `T0` | real | no | `0.0` | Maximum (sea-level) thrust. Default units: lbf. |
| `Ta` | real | no | `0.0` | Density exponent: thrust scales as (ρ/ρ₀)^Ta. 0 = no altitude effect. |
| `location` | real[3] | no | `[0, 0, 0]` | Position relative to CG in body frame. Default units: ft. |
| `orientation` | real[3] | no | `[0, 0, 0]` | Euler angles [roll, pitch, yaw] defining thrust direction. [0,0,0] = forward (+x body). |

Thrust magnitude = `effector_value × T0 × (ρ / ρ₀)^Ta`

##### Propulsion Type: `propeller`

Polynomial coefficient model for propeller thrust, torque, normal force, and yaw moment as functions of advance ratio J. Based on rotors_elecprop.pdf Section 4.5.

```json
"front_rotor" : {
    "type"            : "propulsion",
    "propulsion_type" : "propeller",
    "effector"        : "throttle",
    "diameter[ft]"    : 1.25,
    "rotation"        : "right",
    "motor"           : { "type": "rpm" },
    "CT(J)"           : [0.0560, -0.0704, -0.1027],
    "CPb(J)"          : [0.0137,  0.0144, -0.0850],
    "CNa(J)"          : [0.0, 0.0036, 0.0160, 0.0148],
    "Cna(J)"          : [0.0, -0.0112, 0.0029, 0.0050],
    "location[ft]"    : [0.5, 0.0, 0.0],
    "mass" : {
        "weight[lbf]"      : 0.0567,
        "Ixx[slug-ft^2]"   : 0.000095
    }
}
```

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `diameter` | real | **yes** | — | Propeller diameter. Default units: ft. |
| `rotation` | string | no | `"right"` | Rotation direction: `"right"` (+1) or `"left"` (-1). Affects torque reaction and yaw moment sign. |
| `motor` | object | no | `{"type":"rpm"}` | Motor model. `"rpm"` (direct RPM command) or `"electric"` (battery-powered BLDC motor). |
| `CT(J)` | real[3] | **yes** | — | Thrust coefficient: CT = c₀ + c₁J + c₂J² |
| `CPb(J)` | real[3] | **yes** | — | Brake power coefficient: CPb = c₀ + c₁J + c₂J² |
| `CNa(J)` | real[4] | no | `[0,0,0,0]` | Normal force slope: CNα = c₀ + c₁J + c₂J² + c₃J³ |
| `Cna(J)` | real[4] | no | `[0,0,0,0]` | Yaw moment slope: Cnα = c₀ + c₁J + c₂J² + c₃J³ |
| `location` | real[3] | no | `[0,0,0]` | Position relative to CG. Default units: ft. |
| `mass` | object | no | — | Optional mass block (weight, Ixx, etc.). Ixx is used for gyroscopic angular momentum h = Ixx × ω. |

**Motor type `rpm`**: The control effector value is interpreted as RPM (rev/min). Advance ratio: `J = V / (n × d)` where n = RPM/60 (rev/s). Optional `J_limits` array clamps the advance ratio.

**Motor type `electric`**: Battery-ESC-motor chain per Phillips Sec 4.6. The control effector is throttle τ ∈ [0, 1]. The equilibrium prop rpm is found by bisection on the shaft torque balance, using the closed-form inner step of Algorithm 4.6.2 (Eqs 4.6.34–4.6.37).

```json
"motor" : {
    "type"                : "electric",
    "battery"             : "main_pack",
    "kV"                  : 450,
    "resistance"          : 0.12,
    "no_load_current"     : 0.3,
    "ESC_resistance"      : 0.01,
    "Ic_max"              : 60.0,
    "gearbox_ratio"       : 1.0,
    "gearbox_efficiency"  : 1.0,
    "J_limits"            : [-10.0, 10.0],
    "solver" : {
        "max_iterations" : 60,
        "tolerance"      : 1.0e-10
    }
}
```

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `battery` | string | **yes** | — | Name of battery in the vehicle's `batteries` section |
| `kV` | real | **yes** | — | Motor speed constant `K_v` in RPM/Volt. Internally converted to rev/s/V. Torque constant `k_T = C_I/K_v` is derived per Eq 4.6.7/4.6.8 (`C_I = 7.04319971369755` for ft·lbf / (rpm/V) / A). |
| `resistance` | real | **yes** | — | Motor armature resistance `R_m` [Ohm] |
| `no_load_current` | real | no | `0.0` | Motor idle current `I_m0` [A] |
| `ESC_resistance` | real | no | `0.0` | ESC resistance `R_c` [Ohm] |
| `Ic_max` | real | no | `huge(0.0)` | ESC maximum current `I_c_max` [A] (Table 4.6.3). When `I_m` exceeds this, a warning is printed once per motor. |
| `gearbox_ratio` | real | no | `1.0` | Gear ratio `G_m = N_m / N_s` (motor rpm / prop rpm). For direct drive `G_m = 1`; for a 4:1 reduction `G_m = 4`. |
| `gearbox_efficiency` | real | no | `1.0` | Gearbox mechanical efficiency `η_g` |
| `J_limits` | real[2] | no | `[-10, 10]` | Advance ratio clamp [min, max] |
| `solver.max_iterations` | int | no | `60` | Bisection iteration limit for the outer torque balance |
| `solver.tolerance` | real | no | `1e-10` | Convergence tolerance on the shaft/prop torque residual [ft·lbf] |

ESC PWM efficiency uses Eq 4.6.14: `η_c = 1 − 0.078·(1 − τ)`. Battery-side current `I_b` is recovered from the Eq 4.6.32 quadratic and used to update SOC (not the motor armature current `I_m` — those differ by roughly `τ·η_c`). Battery depletion (SOC = 0) returns zero thrust gracefully.

**Forces and moments** (computed in rotor frame, x-axis = rotor axis):
- Thrust: `T = ρ n² d⁴ CT(J)` along rotor axis (Eq 4.5.2)
- Torque: `τ = ρ n³ d⁵ CPb(J) / (2πn)` — reaction moment about rotor axis (Eq 4.5.29)
- Normal force: `N = ρ n² d⁴ CNα(J) αc` perpendicular to rotor axis (Eq 4.5.5)
- Yaw moment: `n = ρ n² d⁵ Cnα(J) αc` (Eq 4.5.6)

where αc = angle between freestream velocity and rotor axis.

**Gyroscopic effects**: When the mass block includes Ixx > 0, the full angular momentum `h = I · [ω_spin + p_c, q_c, r_c]` is computed each timestep using the complete 3×3 inertia tensor and body rates rotated into the component frame. This captures nutation coupling from Iyy/Izz (significant for large rotors under aggressive maneuvers). When only Ixx is specified (Iyy = Izz = 0), the result reduces to the scalar form `h = δ × Ixx × ω`.

Multiple propellers with alternating rotation directions (right/left) cancel net torque in hover (quadrotor configuration).

---

#### Type: `sphere`

Sphere or ellipsoid drag with Reynolds-dependent CD (Eqs 3.6.26-3.6.29).

```json
"ball" : {
    "type" : "sphere",
    "reference" : {
        "radius[ft]" : 0.0656
    }
}
```

For an ellipsoid, use `radii` instead:

```json
"reference" : {
    "radii[ft]" : [0.1, 0.05, 0.05]
}
```

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `reference.radius` | real | conditional | — | Single radius for a sphere. Default units: ft. |
| `reference.radii` | real[3] | conditional | — | Ellipsoid radii [rx, ry, rz]. Default units: ft. |

Projected cross-sectional area is computed normal to the flow direction. CD is looked up from the standard sphere drag curve as a function of Reynolds number.

---

#### Type: `cuboid`

Rectangular box drag (Eqs 3.6.8-3.6.11). Velocity-direction-dependent reference area: the face most normal to the flow is used.

```json
"frame_drag" : {
    "type" : "cuboid",
    "reference" : {
        "dimensions[ft]" : [2.0, 0.5, 0.3]
    },
    "CD" : 1.05
}
```

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `reference.dimensions` | real[3] | **yes** | — | Box dimensions [lx, ly, lz]. Default units: ft. |
| `CD` | real | no | `1.05` | Drag coefficient |

Also accepts `"type": "body_drag"` for backward compatibility.

---

#### Type: `cylinder`

Cylinder or frustum (tapered cylinder / nose cone) with cross-flow model (Eqs 3.6.12-3.6.25). Reynolds-dependent base CD, lift/drag from cross-flow principle.

```json
"fuselage" : {
    "type" : "cylinder",
    "reference" : {
        "length[ft]"   : 4.0,
        "radius_1[ft]" : 0.3,
        "radius_2[ft]" : 0.0
    }
}
```

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `reference.length` | real | **yes** | — | Cylinder length along component x-axis. Default units: ft. |
| `reference.radius` | real | conditional | — | Uniform radius. Default units: ft. |
| `reference.radius_1` | real | conditional | — | Radius at end 1 (for frustum/taper). Default units: ft. |
| `reference.radius_2` | real | conditional | — | Radius at end 2 (for frustum/taper). 0 = cone tip. Default units: ft. |

Use `radius` for a uniform cylinder, or `radius_1`/`radius_2` for a frustum.

---

#### Type: `wing`

Wing segment aerodynamic model (Eqs 3.6.30-3.6.65). Supports lift slope, drag polar, stall, and control surfaces. Used for component-based vehicle models.

```json
"right_wing" : {
    "type" : "wing",
    "reference" : {
        "semispan[ft]"   : 3.0,
        "root_chord[ft]" : 1.2,
        "tip_chord[ft]"  : 0.8,
        "sweep[deg]"     : 5.0,
        "dihedral[deg]"  : 3.0
    },
    "side" : "right",
    "aero" : {
        "CL_alpha"     : 0.0,
        "alpha_L0[deg]": -2.0,
        "CD0"          : 0.01,
        "CD1"          : 0.0,
        "e_O"          : 0.8,
        "Cm0"          : -0.02,
        "Cm_alpha"     : 0.0
    },
    "control_surface" : {
        "effector"      : "aileron",
        "flap_fraction" : 0.25,
        "efficiency"    : 0.8,
        "antisymmetric" : true
    },
    "stall" : {
        "include_stall"    : true,
        "alpha_stall[deg]" : 15.0,
        "alpha_max[deg]"   : 20.0
    },
    "location[ft]" : [0.0, 2.0, 0.0],
    "component_orientation[deg]" : [0.0, 0.0, 0.0]
}
```

**Reference geometry:**

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `reference.semispan` | real | **yes** | — | Wing semispan. Default units: ft. |
| `reference.root_chord` | real | **yes** | — | Root chord. Default units: ft. |
| `reference.tip_chord` | real | **yes** | — | Tip chord. Default units: ft. |
| `reference.sweep` | real | no | `0.0` | Quarter-chord sweep angle. Default units: rad. |
| `reference.dihedral` | real | no | `0.0` | Dihedral angle. Default units: rad. |

**Wing properties:**

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `side` | string | no | `"both"` | `"left"`, `"right"`, or `"both"` (mirrors geometry). |
| `aero.CL_alpha` | real | no | `0.0` | Lift slope [/rad]. 0 = auto-compute from aspect ratio (Eq 3.6.51). |
| `aero.alpha_L0` | real | no | `0.0` | Zero-lift angle of attack. Default units: rad. |
| `aero.CD0` | real | no | `0.01` | Zero-lift drag coefficient. |
| `aero.CD1` | real | no | `0.0` | Linear drag term. |
| `aero.e_O` | real | no | `0.8` | Oswald efficiency factor. |
| `aero.Cm0` | real | no | `0.0` | Pitch moment at zero AoA. |
| `aero.Cm_alpha` | real | no | `0.0` | Pitch moment slope. |

**Control surface** (optional):

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `control_surface.effector` | string | **yes** | — | Control effector name |
| `control_surface.flap_fraction` | real | no | `0.25` | Flap chord / total chord ratio |
| `control_surface.efficiency` | real | no | `0.8` | Flap effectiveness multiplier |
| `control_surface.antisymmetric` | bool | no | `false` | If true, deflection is negated for left-side wings (aileron mode) |

Derived quantities computed at init: mean chord (Eq 3.6.31), planform area (Eq 3.6.30), aspect ratio (Eq 3.6.32), AC location (Eqs 3.6.33-3.6.35). Stall uses Newtonian above-stall model with sigmoid blending (Eqs 3.6.59-3.6.65).

---

#### Type: `database`

Aerodynamic model using tabulated data from CSV files. Supports multi-dimensional interpolation with any combination of independent variables.

```json
"aero_tables" : {
    "type" : "database",
    "reference" : {
        "area[ft^2]"              : 300.0,
        "longitudinal_length[ft]" : 11.32,
        "lateral_length[ft]"      : 30.0,
        "location[ft]"            : [0.0, 0.0, 0.0]
    },
    "database_directory" : "databases/F16/",
    "files" : [
        "Cx_alpha_beta.csv",
        "Cy_beta.csv",
        "Cl_alpha_beta_aileron.csv"
    ],
    "saturate"  : true,
    "presorted" : false,
    "stall"     : { ... }
}
```

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `reference.area[ft^2]` | real | **yes** | — | Reference wing area |
| `reference.longitudinal_length[ft]` | real | **yes** | — | Mean aerodynamic chord |
| `reference.lateral_length[ft]` | real | **yes** | — | Wing span |
| `reference.location[ft]` | real[3] | no | `[0, 0, 0]` | Aero reference point offset from CG |
| `database_directory` | string | no | `""` | Path prefix prepended to all filenames |
| `files` | string[] | **yes** | — | List of CSV database filenames |
| `saturate` | bool | no | `true` | Clamp interpolation at table boundaries (vs. extrapolate) |
| `presorted` | bool | no | `false` | If true, skip internal sorting (data must already be sorted) |
| `stall` | object | no | — | Same stall model as `stability_derivatives` (see above) |

**Database CSV format:** CSV headers define independent variables (IVs) and dependent variables (DVs). IVs can include `[units]` suffixes (e.g., `alpha[deg]`) which are auto-converted using the unit system — the code multiplies internal state values by the conversion factor to match the database's units during lookup. Recognized DVs: `Cx`, `Cy`, `Cz` (body-axis), `CL`, `CD`, `CS` (wind-axis), `Cl`, `Cm`, `Cn` (moment). DV column names can include underscore-separated factors (e.g., `Cl_beta`, `Cx_qbar`) which are automatically multiplied during evaluation. Recognized IVs: `alpha`, `beta`, `pbar`, `qbar`, `rbar`, `alphahat`, `betaflank`, plus any control or passive effector name. Multiple databases are summed.

---

### Initial Conditions

```json
"initial" : {
    "airspeed[ft/s]"    : 550,
    "altitude[ft]"      : 30000,
    "latitude[deg]"     : 80.0,
    "longitude[deg]"    : 90.0,
    "Euler_angles[deg]" : [0.0, 2.0, 45.0],
    "type"              : "trim",
    "state"             : { ... },
    "trim"              : { ... }
}
```

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `airspeed` | real | **yes** | — | Initial true airspeed magnitude. Default units: ft/s. |
| `altitude` | real | **yes** | — | Initial altitude above sea level. Default units: ft. Sets position(3) = -altitude. |
| `latitude` | real | no | `0.0` | Initial geodetic latitude. Default units: rad. Use `[deg]` for degrees. |
| `longitude` | real | no | `0.0` | Initial geodetic longitude. Default units: rad. Use `[deg]` for degrees. |
| `Euler_angles` | real[3] | no | `[0, 0, 0]` | [phi, theta, psi] — roll, pitch, heading. Default units: rad. Use `[deg]` for degrees. |
| `type` | string | no | `"state"` | `"state"` or `"trim"`. Determines whether the trim solver runs. |

#### State Section

The `"state"` object provides initial aerodynamic angles, body rates, and control/passive effector positions. When `"type"` is `"state"`, these are the actual initial conditions. When `"type"` is `"trim"`, these serve as the starting guess for the trim solver.

```json
"state" : {
    "angle_of_attack[deg]" : 7.866,
    "sideslip_angle[deg]"  : 0.0,
    "p[deg/s]"             : 0.0,
    "q[deg/s]"             : 0.0,
    "r[deg/s]"             : 0.0,
    "control_effectors"    : {
        "aileron[deg]"  : 0.0,
        "elevator[deg]" : -9.217,
        "rudder[deg]"   : 0.0,
        "throttle"      : 1.585
    },
    "passive_effectors" : {
        "canard[deg]" : 5.0
    }
}
```

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `angle_of_attack` | real | no | `0.0` | Initial alpha. Add `[deg]` for degrees, bare = radians. |
| `sideslip_angle` | real | no | `0.0` | Initial beta. Add `[deg]` for degrees, bare = radians. |
| `p` | real | no | `0.0` | Initial roll rate. Add `[deg/s]` or `[rad/s]` for units, bare = rad/s. |
| `q` | real | no | `0.0` | Initial pitch rate. Add `[deg/s]` or `[rad/s]` for units, bare = rad/s. |
| `r` | real | no | `0.0` | Initial yaw rate. Add `[deg/s]` or `[rad/s]` for units, bare = rad/s. |
| `pbar` | real | no | — | Initial nondimensional roll rate (p * b_ref / 2V). **Cannot coexist with `p`.** |
| `qbar` | real | no | — | Initial nondimensional pitch rate (q * c_bar / 2V). **Cannot coexist with `q`.** |
| `rbar` | real | no | — | Initial nondimensional yaw rate (r * b_ref / 2V). **Cannot coexist with `r`.** |
| `control_effectors` | object | conditional | — | **Required** if the vehicle has control effectors. Keys must match defined effector names. Append `[units]` for unit conversion (e.g., `[deg]` for angle effectors). |
| `passive_effectors` | object | no | — | Initial passive effector positions. Keys must match defined passive effector names. Append `[units]` for conversion (e.g., `[deg]`). Bare values are in radians. |

**Rotation rate options:** For each axis (p/q/r), you can specify either a dimensional rate or a nondimensional rate, but **not both**. Specifying both `p` and `pbar` (or `q`/`qbar`, `r`/`rbar`) is a fatal error. You can mix forms across axes — for example, `pbar`, `q[deg/s]`, and `r` in the same state block.

Nondimensional rates (`pbar`, `qbar`, `rbar`) are converted to dimensional rates using the reference lengths from the first aerodynamic force source:
- `p = pbar * 2 * V / b_ref` (lateral_length)
- `q = qbar * 2 * V / c_bar` (longitudinal_length)
- `r = rbar * 2 * V / b_ref` (lateral_length)

This requires `airspeed > 0` and the relevant reference length > 0.

---

#### Trim Settings

When `"type"` is `"trim"`, the `"trim"` object configures the trim solver. When `"type"` is `"state"`, the `"trim"` object is ignored.

```json
"trim" : {
    "type"                     : "sct",
    "sideslip_angle[deg]"      : -10.0,
    "fixed_climb_angle[deg]"   : 0.0,
    "load_factor"              : 1.2,
    "vbr_pw[deg/s]"            : 30.0,
    "vbr_direction"            : 1,
    "fixed_control_effectors"  : {
        "throttle" : 0.9
    },
    "solver" : {
        "finite_difference_step_size" : 0.01,
        "relaxation_factor"           : 0.9,
        "tolerance"                   : 1.0e-12,
        "max_iterations"              : 2000,
        "verbose"                     : true
    }
}
```

**Trim types:**

| Type | Description |
|------|-------------|
| `"sct"` | **Steady Coordinated Turn** (default). Finds alpha, control deflections, and bank angle for a given load factor or turn rate. Beta is always free. |
| `"shss"` | **Steady Heading Sideslip**. Straight flight with nonzero sideslip. If `sideslip_angle[deg]` is specified, beta is fixed and phi becomes free. |
| `"vbr"` | **Velocity-axis Bank-to-turn Roll**. Steady rolling maneuver about the velocity axis. |
| `"hover"` | **Hover**. Zero-velocity trim for multirotors. Alpha, beta, and phi are locked at 0 (level attitude). Only control effectors are solved for. Set initial velocity to `[0, 0, 0]` in the state. |

**Trim parameters — applicability depends on trim type:**

| Key | Type | Default | Applies to | Description |
|-----|------|---------|------------|-------------|
| `type` | string | `"sct"` | all | Trim type selector |
| `sideslip_angle` | real | `0.0` | **shss only** | Fixes beta to this value. Default units: rad. Use `[deg]` for degrees. For sct, this value is read but beta remains free. |
| `fixed_climb_angle` | real | — | all | If present, constrains the flight path angle gamma. Default units: rad. Use `[deg]` for degrees. |
| `load_factor` | real | — | **sct only** | Determines bank angle from load factor (Eq 7.3.4). Ignored for shss and vbr. |
| `vbr_pw` | real | `0.0` | **vbr only** | Wind-axis roll rate. Default units: rad/s. Use `[deg/s]` for degrees/second. Ignored for sct and shss. |
| `vbr_direction` | real | `1` (ascending) | **vbr only** | Positive = ascending (gamma=90), negative = descending (gamma=-90). Ignored for sct and shss. |
| `fixed_control_effectors` | object | — | all | Dictionary of effector names to hold at specified values during trim. Append `[units]` to keys for conversion (e.g., `"sb[deg]": 0.0`). |

**Solver settings:**

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `finite_difference_step_size` | real | `0.01` | Perturbation size for numerical Jacobian |
| `relaxation_factor` | real | `0.9` | Newton step damping (0-1, lower = more conservative) |
| `tolerance` | real | `1.0e-12` | Convergence tolerance on residual norm |
| `max_iterations` | int | `2000` | Maximum Newton iterations |
| `verbose` | bool | `true` | Print iteration history |

**Override behavior:**
- `load_factor` is only used when trim type is `"sct"`. It is ignored for `"shss"`, `"vbr"`, and `"hover"`.
- `sideslip_angle[deg]` only fixes beta when trim type is `"shss"`. For `"sct"` and `"hover"`, beta is already fixed (free for sct, locked at 0 for hover).
- When `sideslip_angle[deg]` is specified for `"shss"`, phi (bank angle) automatically becomes a free variable.
- `vbr_pw[deg/s]` and `vbr_direction` are only meaningful for `"vbr"` trim type.
- `fixed_control_effectors` holds listed effectors at their specified values for any trim type; those effectors are removed from the free-variable set.
- When there are more free control variables than 6 DOF equations (underdetermined), the solver finds the minimum-norm solution — distributing control effort evenly. Use `fixed_control_effectors` to bias allocation toward preferred controls.
- When trim fails to converge, the final per-axis residuals are printed (u_dot, v_dot, w_dot, p_dot, q_dot, r_dot) to help diagnose which forces or moments are unbalanced.

---

### Analysis Settings

Optional per-vehicle section. When present and `export_state_space` is true, the simulator computes linearized A and B matrices via central-difference Jacobians at the trim/initial point and writes them to CSV files. Analysis runs after trim (if trim is enabled) and before the simulation loop.

```json
"analysis" : {
    "export_state_space" : true,
    "state_form"         : "euler",
    "fd_step"            : 1.0e-5,
    "output_prefix"      : "F16_trim"
}
```

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `export_state_space` | bool | no | `false` | Compute and export A and B matrices. If false (or section is absent), analysis is skipped. |
| `state_form` | string | no | `"euler"` | State vector form: `"euler"` (12 states) or `"quaternion"` (13 states). |
| `fd_step` | real | no | `1.0e-5` | Central-difference perturbation step size (same units as the state). |
| `output_prefix` | string | no | `""` | Filename prefix for output CSVs. Empty string defaults to the vehicle name (e.g., `F16_A.csv`, `F16_B.csv`). |

**Output files:**

Two CSV files are written to the working directory:

| File | Contents |
|------|----------|
| `<prefix>_A.csv` | State matrix A (n_states × n_states). Rows = state derivatives, columns = state variables. |
| `<prefix>_B.csv` | Input matrix B (n_states × n_inputs). Rows = state derivatives, columns = control effectors. |

The matrices are also printed to the terminal in a formatted table before the simulation starts.

**State vector forms:**

| `state_form` | Dimensions | State variables |
|--------------|-----------|-----------------|
| `"euler"` | 12 + n_actuators | u, v, w, p, q, r, x, y, z, φ, θ, ψ, then actuator states |
| `"quaternion"` | 13 + n_actuators | u, v, w, p, q, r, x, y, z, e₀, eₓ, eᵧ, e_z, then actuator states |

Actuator states contribute one state per order-1 effector and two states (position + rate) per order-2 effector. Order-0 (instant) effectors do not appear in the state vector.

**Input vector:** one entry per control effector, in the order they are defined in `control_effectors`.

**Algorithm:** central-difference Jacobian (Algorithm 8.3.9). For each column j:
```
A[:,j] = (f(y₀ + δeⱼ) - f(y₀ - δeⱼ)) / (2δ)
B[:,j] = (f(y₀, u₀ + δeⱼ) - f(y₀, u₀ - δeⱼ)) / (2δ)
```
Actuator clamping is disabled during analysis for clean finite differences.

**Placement in vehicle JSON** (after `initial`):

```json
"vehicles" : {
    "F16" : {
        ...
        "initial" : { ... },
        "analysis" : {
            "export_state_space" : true,
            "state_form"         : "euler",
            "fd_step"            : 1.0e-5,
            "output_prefix"      : "F16_trim"
        }
    }
}
```

**Override behavior:**
- If `export_state_space` is false or the `analysis` section is absent, no analysis is performed and the simulation proceeds normally.
- If `"type"` in `initial` is `"trim"`, analysis uses the converged trim state. If `"type"` is `"state"`, analysis uses the specified initial state as-is.
- Output filenames: if `output_prefix` is empty, defaults to the vehicle key name (e.g., vehicle `"F16"` → `F16_A.csv`).

---

### Sensors

Optional per-vehicle section. Simulates realistic onboard sensors by reading from the vehicle's true state, applying physical transformations (position offset, attitude rotation, pressure/temperature physics), then corrupting the output with bias, noise, quantization, and saturation. Sensor outputs can be saved to CSV and/or sent via UDP.

Sensors are defined as named objects inside `"sensors"`, alongside a `"save_outputs"` flag. The JSON key becomes the sensor name (used in CSV headers and connection `"sensors"` lists).

```json
"sensors" : {
    "save_outputs" : true,
    "imu_main" : {
        "type"                 : "imu",
        "location[ft]"         : [2.0, 0.0, -0.5],
        "attitude[deg]"        : [0.0, 0.0, 0.0],
        "magnetic_field[nT]"   : [20225.1, 3919.4, 46952.8],
        "refresh_rate[hz]"     : 100,
        "bias"                 : [0.01, 0.01, 0.01, 0.001, 0.001, 0.001, 50, 50, 50],
        "noise_std"            : [0.05, 0.05, 0.05, 0.005, 0.005, 0.005, 100, 100, 100],
        "min_value"            : [-300, -300, -300, -20, -20, -20, -100000, -100000, -100000],
        "max_value"            : [300, 300, 300, 20, 20, 20, 100000, 100000, 100000],
        "bit_count"            : 16
    }
}
```

#### Sensor-Level Fields

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `save_outputs` | bool | no | `false` | If true, creates `<vehicle_name>_sensors.csv` with time-stamped sensor outputs. This flag is at the `"sensors"` object level, not inside individual sensors. CSV write rate matches the simulation's `save_states_rate[hz]`. |

#### Per-Sensor Fields (Common to All Types)

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `type` | string | **yes** | — | Sensor type. See table below. |
| `location` | real[3] | no | `[0, 0, 0]` | Sensor mounting position relative to CG in body frame. Default units: ft. Only affects accelerometer and IMU — sensors at non-zero offsets experience centripetal and Euler accelerations from vehicle rotation. |
| `attitude` | real[3] | no | `[0, 0, 0]` | Sensor mounting Euler angles [phi, theta, psi] relative to body frame. Default units: rad. Use `[deg]` for degrees. Builds a DCM that rotates measurements from body frame to sensor frame. [0,0,0] = aligned with body axes. |
| `refresh_rate` | real | no | `0.0` | Sensor update rate. Default units: Hz. 0 = update every physics timestep. Non-zero values rate-limit sensor updates (e.g., GPS at 10 Hz while physics runs at 100 Hz). Between updates, the sensor holds its last output. |

#### Error Model Fields (All Optional)

All error model fields are optional. If omitted, no error is applied for that stage. A sensor with no error fields outputs perfect (true) values — useful for debugging and validation.

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `bias` | real[N] | no | — | Constant offset added to each channel. Array length must match sensor's output count N. Models manufacturing/calibration defects (e.g., a thermometer that always reads 1.5° low). |
| `noise_std` | real[N] | no | — | Gaussian noise standard deviation per channel. Each timestep, `randn() * noise_std` is added. Models random measurement variation. |
| `min_value` | real[N] | no | — | Lower saturation bound per channel. Output is clamped to `max(min_value, output)`. Also defines the lower range for quantization. |
| `max_value` | real[N] | no | — | Upper saturation bound per channel. Output is clamped to `min(max_value, output)`. Also defines the upper range for quantization. |
| `bit_count` | int | no | `0` | ADC bit resolution. 0 = no quantization. When > 0, output is rounded to `(max - min) / 2^bit_count` steps. An 8-bit sensor with range [-300, 300] can only report in steps of 2.34. Modern sensors use 16+ bits where quantization error is negligible. |

**Error pipeline order** (each stage uses the output of the previous):
1. **Bias** — add constant offset
2. **Gaussian noise** — add random N(0, noise_std) per channel
3. **Quantization** — round to nearest ADC step (requires `min_value`, `max_value`, and `bit_count > 0`)
4. **Saturation** — clamp to [min_value, max_value]

#### Sensor Types

| `type` string | N outputs | Output channels | Description |
|---------------|-----------|-----------------|-------------|
| `"gyroscope"` | 3 | p, q, r [rad/s] | Angular velocity in sensor frame. Rotates body rates [p,q,r] through the sensor's attitude DCM. |
| `"accelerometer"` | 3 | ax, ay, az [ft/s²] | Specific force (non-gravitational force / mass) at the sensor's physical location. Includes CG-offset correction: centripetal (ω×(ω×r)) and Euler (ω̇×r) terms. Rotated to sensor frame. An accelerometer reads zero in freefall and 1g sitting on a table. |
| `"imu"` | 9 | ax, ay, az [ft/s²], p, q, r [rad/s], Bx, By, Bz [nT] | Composite sensor: accelerometer (channels 1-3) + gyroscope (channels 4-6) + magnetometer (channels 7-9). All share the same location and attitude. |
| `"air_data_system"` | 6 | P0 [psf], P∞ [psf], T∞ [R], IAS [ft/s], CAS [ft/s], EAS [ft/s] | Pitot-static system. Computes stagnation pressure, static pressure, and temperature from the standard atmosphere model at vehicle altitude. Derives indicated, calibrated, and equivalent airspeeds from pressure differences. Uses **air-relative velocity** (body velocity + turbulence gusts) — this is physically what a pitot tube measures. |
| `"gps"` | 6 | x, y, z [ft], Vx, Vy, Vz [ft/s] | Position and velocity in Earth-fixed frame. Position is taken directly from vehicle state. Velocity is body-frame velocity rotated to Earth frame via the attitude quaternion. GPS measures **inertial** velocity (not affected by gusts). Typical: 1-20 Hz update rate, ~3-10 ft position noise, ~0.1-0.3 ft/s velocity noise. |
| `"aero_angles"` | 2 | alpha [rad], beta [rad] | Angle of attack and sideslip. Uses **air-relative velocity** (body velocity + turbulence gusts). Alpha = atan2(w_air, u_air). Beta = asin(v_air / V_air). Equivalent to a vane or multi-port probe measuring local airflow direction. |
| `"magnetometer"` | 3 | Bx, By, Bz [nT] | Earth's magnetic field rotated to sensor frame. Earth field → body frame (via attitude quaternion) → sensor frame (via attitude DCM). |

#### Type-Specific Fields

| Key | Type | Applies to | Default | Description |
|-----|------|------------|---------|-------------|
| `magnetic_field[nT]` | real[3] | `imu`, `magnetometer` | `[20225.1, 3919.4, 46952.8]` | Local Earth magnetic field vector in Earth-fixed frame [North, East, Down] in nanoTesla. Default is approximate for mid-latitude US. |

#### Air-Relative vs. Inertial Measurements

Sensors that measure through the air (pitot tube, vanes) inherently see the air-relative velocity, which includes turbulence gusts. When turbulence is active, gust velocities are automatically added to body velocity for these sensors. When turbulence is off, gusts are zero and air-relative = inertial.

| Sensor | Uses air-relative velocity (body + gusts) | Uses inertial velocity (body only) |
|--------|:------------------------------------------:|:----------------------------------:|
| Air Data System | yes | — |
| Aero Angles | yes | — |
| GPS | — | yes |
| Gyroscope | N/A (rates only) | N/A |
| Accelerometer | N/A (forces only) | N/A |
| IMU | N/A (accel: forces, gyro: rates, mag: field) | N/A |
| Magnetometer | N/A (field only) | N/A |

#### Accelerometer Off-CG Physics

When `location[ft]` is non-zero, the accelerometer (and IMU's accel channels) accounts for rotational effects at the sensor's mounting point (Eq 10.4.18):

```
a_sensor = a_CG + ω̇ × r + ω × (ω × r)
```

Where:
- `a_CG = F_total / mass` — specific force at the center of gravity
- `ω̇ × r` — Euler (tangential) acceleration from angular acceleration
- `ω × (ω × r)` — centripetal acceleration from rotation
- `r = location` — sensor offset from CG in body frame

The angular acceleration `ω̇` is computed from cached total moments and the inverse inertia tensor. If `location` is `[0, 0, 0]`, these terms vanish and the sensor reports `F_total / mass` directly.

#### CSV Output

When `save_outputs` is true, a file `<vehicle_name>_sensors.csv` is created with columns:

```
t[s], <sensor1_name>_<ch1>, <sensor1_name>_<ch2>, ..., <sensor2_name>_<ch1>, ...
```

Example for an IMU named `imu_main` and GPS named `gps`:
```
t[s], imu_main_ax[ft/s^2], imu_main_ay[ft/s^2], imu_main_az[ft/s^2], imu_main_p[rad/s], imu_main_q[rad/s], imu_main_r[rad/s], imu_main_mx[nT], imu_main_my[nT], imu_main_mz[nT], gps_x[ft], gps_y[ft], gps_z[ft], gps_Vx[ft/s], gps_Vy[ft/s], gps_Vz[ft/s]
```

The CSV write rate matches the simulation's `save_states_rate[hz]` setting. Sensor values between updates (due to `refresh_rate`) hold their last computed value.

#### EKF (Extended Kalman Filter)

Optional sub-section within `"sensors"`. When enabled, runs a 15-state EKF that fuses sensor measurements to produce a filtered state estimate. The EKF state can be sent via connections with `data_type` = `"ekf_state"` or `"ekf_both"`.

```json
"sensors" : {
    "ekf" : {
        "enabled"            : true,
        "gyro_noise"         : 0.005,
        "accel_noise"        : 0.05,
        "gyro_bias_walk"     : 0.0001,
        "accel_bias_walk"    : 0.001,
        "gps_position_noise" : 5.0,
        "gps_velocity_noise" : 0.3,
        "mag_heading_noise"  : 0.1,
        "airspeed_noise"     : 3.0,
        "save_output"        : false
    }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | bool | `false` | Enable the EKF |
| `gyro_noise` | real | `0.005` | Gyroscope process noise [rad/s] |
| `accel_noise` | real | `0.05` | Accelerometer process noise [ft/s²] |
| `gyro_bias_walk` | real | `0.0001` | Gyro bias random walk |
| `accel_bias_walk` | real | `0.001` | Accel bias random walk |
| `gps_position_noise` | real | `5.0` | GPS position measurement noise [ft] |
| `gps_velocity_noise` | real | `0.3` | GPS velocity measurement noise [ft/s] |
| `mag_heading_noise` | real | `0.1` | Magnetometer heading noise [rad] |
| `airspeed_noise` | real | `3.0` | Airspeed measurement noise [ft/s] |
| `save_output` | bool | `false` | Save EKF state estimates to CSV |

#### Placement in Vehicle JSON

```json
"vehicles" : {
    "F16" : {
        "mass"              : { ... },
        "control_effectors" : { ... },
        "force_sources"     : { ... },
        "initial"           : { ... },
        "sensors"           : {
            "save_outputs" : true,
            "ekf"          : { "enabled": true },
            "my_imu"       : { "type": "imu", ... },
            "my_gps"       : { "type": "gps", ... }
        }
    }
}
```

---

## Connections (Telemetry)

UDP connections for sending vehicle state to external programs (graphics, controllers) or receiving commanded controls. Each connection is a named object within `"connections"`.

```json
"connections" : {
    "state_out" : {
        "enabled"          : true,
        "vehicle"          : "my_vehicle",
        "channel_type"     : "udp",
        "type"             : "send",
        "data_type"        : "both",
        "IP_address"       : "127.0.0.1",
        "port_ID"          : 5005,
        "double_precision" : false,
        "refresh_rate"     : 100,
        "wait_for_input"   : false
    }
}
```

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `enabled` | bool | no | `false` | Enable/disable this channel. Disabled channels are skipped entirely. |
| `vehicle` | string | **yes** | — | Name of the vehicle this connection is attached to. Must match a vehicle key in `"vehicles"`. |
| `channel_type` | string | **yes** | — | `"udp"` or `"file"`. |
| `type` | string | **yes** | — | `"send"` or `"receive"` |
| `data_type` | string | no | `"both"` | `"controls"`, `"state"`, `"both"`, `"sensors"`, `"ekf_state"`, or `"ekf_both"`. Determines packet contents (see below). |
| `sensors` | string[] | conditional | — | **Required when `data_type` = `"sensors"`.** List of sensor names to include in the packet, in order. Names must match sensor keys defined in the vehicle's `"sensors"` section. Example: `["imu_main", "ads", "gps"]` |
| `port_ID` | int | **yes** | — | UDP port number |
| `double_precision` | bool | no | `false` | Use 64-bit floats in packets (false = 32-bit) |
| `IP_address` | string | no | `"127.0.0.1"` | Target IP address. **Only parsed for `"send"` connections.** |
| `refresh_rate` | real | no | `0.0` | Send/receive rate in Hz. 0 = every time step (no rate limit). |
| `wait_for_input` | bool | no | `false` | **Only parsed for `"receive"` connections.** true = blocking receive, false = non-blocking (uses last received packet). |
| `entity_tagged` | bool | no | `false` | Prepend a 4-byte int32 entity ID to each UDP packet. Used for multi-vehicle routing — the entity ID matches the vehicle index so a single controller process can handle multiple vehicles. |

**Override behavior — `type` controls which parameters are parsed:**
- `"send"` connections: `IP_address` is parsed. `wait_for_input` is ignored.
- `"receive"` connections: `wait_for_input` is parsed. `IP_address` is ignored (receiver binds to all interfaces).

**Data type packet contents:**

| `data_type` | Packet values |
|-------------|---------------|
| `"controls"` | Effector values only (1 per effector) |
| `"state"` | 14 rigid-body values: [t, u, v, w, p, q, r, x, y, z, e0, ex, ey, ez] |
| `"both"` | State (14) + control effectors (1 per instant effector, 2 per dynamic effector: commanded + actual) + passive effectors (2 per: position + rate) |
| `"sensors"` | Concatenated sensor output arrays for the sensors listed in `"sensors"`. Total values = sum of each listed sensor's output count. Sensor outputs include the full error pipeline (bias, noise, quantization, saturation). |
| `"ekf_state"` | 17 values: the 14 `"state"` fields [t, u, v, w, p, q, r, x, y, z, e0, ex, ey, ez] with the EKF's estimated body-frame state instead of the true state, followed by 3 appended EKF angular-acceleration fields [ṗ, q̇, ṙ] (for INDI control). Requires the vehicle's EKF to be enabled. A controller that only reads the first 14 fields needs no change. |
| `"ekf_both"` | EKF estimated state (14) + control effectors + passive effectors (same layout as `"both"`) followed by the 3 appended EKF angular-acceleration fields [ṗ, q̇, ṙ]. State values are EKF estimates; control deflections are the actual (true) values since those are known by the sim. |

---

## Override Behavior Summary

Quick reference for fields where one value overrides or gates another:

| Condition | Effect |
|-----------|--------|
| `dynamics_order = 0` | Code ignores `time_constant`, `natural_frequency`, `damping_ratio`, `rate_limits`, `acceleration_limits` |
| `dynamics_order = 1` | Requires `time_constant` > 0 (fatal error otherwise). Ignores `natural_frequency`, `damping_ratio`. |
| `dynamics_order = 2` | Requires `natural_frequency` > 0 AND `damping_ratio` > 0 (fatal error otherwise). Ignores `time_constant`. |
| `magnitude_limits` has angular units | `is_angle = true`. Auto-detected from `[deg]`, `[rad]`, etc. in the key's unit brackets. |
| Both `p` and `pbar` specified | Fatal error. Cannot specify dimensional and nondimensional rate for the same axis. Same for q/qbar, r/rbar. |
| `sigma[ft/s]` present | Overrides `intensity` in turbulence config |
| `time_step[s] = 0.0` | Auto-enables `realtime = true` with `dt = 0.01` |
| Trim type = `"sct"` | `load_factor` is used; `sideslip_angle[deg]` value is read but beta stays free |
| Trim type = `"shss"` | `sideslip_angle[deg]` fixes beta; phi becomes free. `load_factor` is ignored. |
| Trim type = `"vbr"` | `vbr_pw[deg/s]` and `vbr_direction` are used. `load_factor` and `sideslip_angle[deg]` not used. |
| Trim type = `"hover"` | Alpha, beta, phi locked at 0. Only control effectors are solved. Set initial velocity to `[0,0,0]`. |
| `fixed_control_effectors` | Listed effectors are held constant during trim (removed from free variables) |
| More controls than 6 DOF | Minimum-norm solution distributes effort evenly; use `fixed_control_effectors` to bias |
| Passive `reference_area[ft^2]` = 0 | Defaults to first aerodynamic force source's `area[ft^2]` |
| Connection `type` = `"send"` | `IP_address` is parsed. `wait_for_input` is ignored. |
| Connection `type` = `"receive"` | `wait_for_input` is parsed. `IP_address` is ignored. |
| Connection `data_type` = `"sensors"` | `"sensors"` array is **required** — lists which sensor names to include. |
| Connection `data_type` = `"ekf_state"` or `"ekf_both"` | Requires the vehicle's EKF to be enabled (`sensors.ekf.enabled = true`). Packet layout is identical to `"state"`/`"both"` so the receiving controller does not need to change. |
| Sensor `location[ft]` = `[0,0,0]` | Off-CG correction terms (centripetal, Euler) are skipped for accelerometer/IMU |
| Sensor `attitude[deg]` = `[0,0,0]` | DCM is identity — sensor frame = body frame |
| Sensor `refresh_rate[hz]` = `0` | Sensor updates every physics timestep |
| Sensor error fields omitted | No error applied for that stage — sensor outputs perfect values |
| Sensor `bit_count` = `0` | Quantization disabled |
| `save_outputs` = `false` (or `sensors` section absent) | No sensor CSV file is created |
| Turbulence `wingspan[ft]` = 0 | No p-gust (roll-rate gust disabled) |
| Turbulence `Lh_sep[ft]` = 0 | No q-gust (pitch-rate gust disabled) |
| Turbulence `Lv_sep[ft]` = 0 | No r-gust (yaw-rate gust disabled) |
| Initial `type` = `"state"` | `trim` section is ignored |
| Initial `type` = `"trim"` | `state` section values become trim solver initial guess |

---

## Complete Examples

### Minimal Kinematic Vehicle

```json
"my_object" : {
    "run_physics" : true,
    "is_kinematic" : true,
    "mass" : {
        "weight[lbf]" : 1.0,
        "Ixx[slug-ft^2]" : 1.0,
        "Iyy[slug-ft^2]" : 1.0,
        "Izz[slug-ft^2]" : 1.0
    },
    "initial" : {
        "airspeed[ft/s]" : 500.0,
        "altitude[ft]" : 10000,
        "Euler_angles[deg]" : [0.0, 0.0, 0.0],
        "type" : "state",
        "state" : {
            "angle_of_attack[deg]" : 0.0,
            "sideslip_angle[deg]" : 0.0,
            "p[deg/s]" : 0.0,
            "q[deg/s]" : 0.0,
            "r[deg/s]" : 0.0
        }
    }
}
```

### Quadcopter (4 Motors + Frame Drag)

```json
"quadcopter" : {
    "run_physics" : true,
    "mass" : {
        "weight[lbf]" : 2.5,
        "Ixx[slug-ft^2]" : 0.005,
        "Iyy[slug-ft^2]" : 0.005,
        "Izz[slug-ft^2]" : 0.009
    },
    "control_effectors" : {
        "motor1" : { "magnitude_limits" : [0.0, 1.0] },
        "motor2" : { "magnitude_limits" : [0.0, 1.0] },
        "motor3" : { "magnitude_limits" : [0.0, 1.0] },
        "motor4" : { "magnitude_limits" : [0.0, 1.0] }
    },
    "force_sources" : {
        "motor_fl" : {
            "type" : "propulsion",
            "propulsion_type" : "simple",
            "effector" : "motor1",
            "T0[lbf]" : 1.5,
            "Ta" : 0.0,
            "location[ft]" : [0.5, -0.5, 0.0],
            "orientation[deg]" : [0.0, -90.0, 0.0]
        },
        "motor_fr" : {
            "type" : "propulsion",
            "propulsion_type" : "simple",
            "effector" : "motor2",
            "T0[lbf]" : 1.5,
            "Ta" : 0.0,
            "location[ft]" : [0.5, 0.5, 0.0],
            "orientation[deg]" : [0.0, -90.0, 0.0]
        },
        "motor_rl" : {
            "type" : "propulsion",
            "propulsion_type" : "simple",
            "effector" : "motor3",
            "T0[lbf]" : 1.5,
            "Ta" : 0.0,
            "location[ft]" : [-0.5, -0.5, 0.0],
            "orientation[deg]" : [0.0, -90.0, 0.0]
        },
        "motor_rr" : {
            "type" : "propulsion",
            "propulsion_type" : "simple",
            "effector" : "motor4",
            "T0[lbf]" : 1.5,
            "Ta" : 0.0,
            "location[ft]" : [-0.5, 0.5, 0.0],
            "orientation[deg]" : [0.0, -90.0, 0.0]
        },
        "frame_drag" : {
            "type" : "body_drag",
            "reference" : { "area[ft^2]" : 0.25 },
            "CD" : 1.0
        }
    },
    "initial" : {
        "airspeed[ft/s]" : 0.0,
        "altitude[ft]" : 100.0,
        "Euler_angles[deg]" : [0.0, 0.0, 0.0],
        "type" : "state",
        "state" : {
            "angle_of_attack[deg]" : 0.0,
            "sideslip_angle[deg]" : 0.0,
            "p[deg/s]" : 0.0,
            "q[deg/s]" : 0.0,
            "r[deg/s]" : 0.0,
            "control_effectors" : {
                "motor1" : 0.0,
                "motor2" : 0.0,
                "motor3" : 0.0,
                "motor4" : 0.0
            }
        }
    }
}
```

### Multi-Engine Aircraft

A twin-engine aircraft uses two thrust sources with separate throttle effectors. Asymmetric thrust automatically produces yaw moments through the moment arm cross product.

```json
"control_effectors" : {
    "aileron"        : { "magnitude_limits[deg]" : [-25.0, 25.0], "rate_limits[deg/s]" : [-80.0, 80.0] },
    "elevator"       : { "magnitude_limits[deg]" : [-25.0, 25.0], "rate_limits[deg/s]" : [-80.0, 80.0] },
    "rudder"         : { "magnitude_limits[deg]" : [-30.0, 30.0], "rate_limits[deg/s]" : [-80.0, 80.0] },
    "left_throttle"  : { "magnitude_limits" : [0.0, 1.0] },
    "right_throttle" : { "magnitude_limits" : [0.0, 1.0] }
},
"force_sources" : {
    "aerodynamics" : {
        "type" : "stability_derivatives",
        "reference" : { ... },
        "coefficients" : { ... }
    },
    "left_engine" : {
        "type" : "propulsion",
            "propulsion_type" : "simple",
        "effector" : "left_throttle",
        "T0[lbf]" : 5000,
        "Ta" : 0.7,
        "location[ft]" : [2.0, -15.0, 1.0]
    },
    "right_engine" : {
        "type" : "propulsion",
            "propulsion_type" : "simple",
        "effector" : "right_throttle",
        "T0[lbf]" : 5000,
        "Ta" : 0.7,
        "location[ft]" : [2.0, 15.0, 1.0]
    }
}
```
