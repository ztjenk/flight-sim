#!/usr/bin/env zsh
# Linux/macOS build for the physics engine.
# Release by default; pass "debug" for the checked build:
#     zsh build_linux.zsh            # release (optimized)
#     zsh build_linux.zsh debug      # debug (-O0, full runtime checks)
# This is identical to build_windows.bat except for the platform UDP layer:
# Linux compiles udp_m.f90; Windows compiles udp_windows_m.f90 and adds
# -DWINDOWS and -lws2_32 (winsock).
set -euo pipefail
cd "${0:A:h}"

FC=${GFORTRAN:-gfortran}
OBJ_DIR="obj"
BIN_DIR="bin"
EXEC="$BIN_DIR/flightsim"

# Build mode: release (default) or debug
MODE="${1:-release}"

COMMON=(-fdefault-real-8 -ffree-line-length-512 -cpp)

if [[ "$MODE" == "debug" ]]; then
  echo "Building flight simulator [DEBUG]..."
  FFLAGS=(-c "${COMMON[@]}" -O0 -g -Wall -Wextra -fcheck=all -fbacktrace -finit-real=snan -ffpe-trap=invalid -finit-integer=-999999 -I "$OBJ_DIR" -J "$OBJ_DIR")
  LFLAGS=("${COMMON[@]}" -O0 -g -fbacktrace -static)
else
  echo "Building flight simulator [RELEASE]..."
  FFLAGS=(-c "${COMMON[@]}" -O2 -I "$OBJ_DIR" -J "$OBJ_DIR")
  LFLAGS=("${COMMON[@]}" -O2 -static)
fi

# Source files in dependency order (udp_m.f90 is the Linux UDP layer)
SRCS=(
  constants_m.f90
  wmm_m.f90
  random_m.f90
  turbulence_m.f90
  math_m.f90
  atmosphere_m.f90
  json.f90
  jsonx.f90
  udp_m.f90
  units_m.f90
  jsonx_units_m.f90
  equations_m.f90
  aero_state_m.f90
  aero_database_m.f90
  battery_m.f90
  force_source_m.f90
  sensor_m.f90
  ekf_m.f90
  vehicle_types_m.f90
  vehicle_io_m.f90
  dynamics_m.f90
  trim_m.f90
  analysis_m.f90
  connection_m.f90
  packet_builder_m.f90
  simulation_m.f90
  main.f90
)

mkdir -p "$OBJ_DIR" "$BIN_DIR"

OBJECTS=()
for SRC in "${SRCS[@]}"; do
  [[ -f "$SRC" ]] || { print -u2 "Missing source: $SRC"; exit 2; }
  base="${SRC:t:r}"
  obj="$OBJ_DIR/$base.o"
  echo "Compiling $SRC -> $obj"
  "$FC" "${FFLAGS[@]}" -o "$obj" "$SRC"
  OBJECTS+=("$obj")
done

echo "Linking -> $EXEC"
"$FC" "${LFLAGS[@]}" -o "$EXEC" "${OBJECTS[@]}"

echo ""
echo "Build complete [$MODE]: $EXEC"
echo "Usage: $EXEC <config.json>"
