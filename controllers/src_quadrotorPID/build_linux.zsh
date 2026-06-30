#!/usr/bin/env zsh
# Linux/macOS build for the quadrotor PID controller. Builds the shared common/
# modules first, then the controller-specific modules, linking ../common/obj/*.o.
# Release by default; pass "debug" for the checked build.
# Identical to build_windows.bat except for the platform UDP layer (in
# ../common): Windows adds -DWINDOWS, links -lws2_32 (winsock), and emits a .exe.
set -euo pipefail
cd "${0:A:h}"

FC=${GFORTRAN:-gfortran}
COMMON_DIR="../common"
COMMON_OBJ="$COMMON_DIR/obj"
OBJ_DIR="obj"
BIN_DIR="bin"
EXEC="$BIN_DIR/quadPID"
MODE="${1:-release}"

# build the shared modules first
zsh "$COMMON_DIR/build_linux.zsh" "$MODE"

COMMON=(-fdefault-real-8 -ffree-line-length-512 -cpp)
if [[ "$MODE" == "debug" ]]; then
  echo "Building quadrotor PID controller [DEBUG]..."
  FFLAGS=(-c "${COMMON[@]}" -O0 -g -Wall -Wextra -fcheck=all -fbacktrace -finit-real=snan -ffpe-trap=invalid -finit-integer=-999999 -I "$OBJ_DIR" -I "$COMMON_OBJ" -J "$OBJ_DIR")
  LFLAGS=("${COMMON[@]}" -O0 -g -fbacktrace -static)
else
  echo "Building quadrotor PID controller [RELEASE]..."
  FFLAGS=(-c "${COMMON[@]}" -O2 -I "$OBJ_DIR" -I "$COMMON_OBJ" -J "$OBJ_DIR")
  LFLAGS=("${COMMON[@]}" -O2 -static)
fi

SRCS=(mixer_m.f90 config_m.f90 control_law_m.f90 controller_main.f90)

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
"$FC" "${LFLAGS[@]}" -o "$EXEC" "${OBJECTS[@]}" "$COMMON_OBJ"/*.o

echo ""
echo "Build complete [$MODE]: $EXEC"
echo "Usage: $EXEC <config.json>"
