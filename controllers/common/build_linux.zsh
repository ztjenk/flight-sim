#!/usr/bin/env zsh
# Linux/macOS build of the shared controller modules into common/obj/ (.o + .mod).
# Each controller's build_linux.zsh runs this first, then adds -I ../common/obj
# and links ../common/obj/*.o. Compile-only: no executable is produced.
# Release by default; pass "debug" for the checked build.
# Identical to build_windows.bat except for the platform UDP layer: Linux
# compiles udp_m.f90; Windows compiles udp_windows_m.f90 and adds -DWINDOWS.
set -euo pipefail
cd "${0:A:h}"

FC=${GFORTRAN:-gfortran}
OBJ_DIR="obj"

# Build mode: release (default) or debug
MODE="${1:-release}"

COMMON=(-fdefault-real-8 -ffree-line-length-512 -cpp)

if [[ "$MODE" == "debug" ]]; then
  echo "Building common modules [DEBUG]..."
  FFLAGS=(-c "${COMMON[@]}" -O0 -g -Wall -Wextra -fcheck=all -fbacktrace -finit-real=snan -ffpe-trap=invalid -finit-integer=-999999 -I "$OBJ_DIR" -J "$OBJ_DIR")
else
  echo "Building common modules [RELEASE]..."
  FFLAGS=(-c "${COMMON[@]}" -O2 -I "$OBJ_DIR" -J "$OBJ_DIR")
fi

# Shared modules in dependency order (udp_m.f90 is the Linux UDP layer)
SRCS=(
  constants_m.f90
  atmosphere_m.f90
  math_m.f90
  linalg_m.f90
  json.f90
  jsonx.f90
  pid_m.f90
  pilot_cmd_m.f90
  flight_state_m.f90
  config_base_m.f90
  command_profile_m.f90
  udp_m.f90
  gamepad_m.f90
  mode_m.f90
)

mkdir -p "$OBJ_DIR"

for SRC in "${SRCS[@]}"; do
  [[ -f "$SRC" ]] || { print -u2 "Missing common source: $SRC"; exit 2; }
  base="${SRC:t:r}"
  obj="$OBJ_DIR/$base.o"
  echo "Compiling $SRC -> $obj"
  "$FC" "${FFLAGS[@]}" -o "$obj" "$SRC"
done

echo "Common modules built [$MODE] in ${0:A:h}/$OBJ_DIR"
