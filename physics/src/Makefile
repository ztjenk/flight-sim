# GNU Makefile for the physics engine — single source-of-truth dependency list,
# FFLAGS in one place, and incremental compilation (json.f90's 4184 lines are
# only recompiled when json.f90 itself changes, not every build).
#
#   make              # release build (optimized, -O2)   -> bin/flightsim
#   make MODE=debug   # checked build (-O0, full runtime checks)
#   make PLATFORM=windows   # compile udp_windows_m instead of udp_m (+ winsock)
#   make clean        # remove obj/ and the binary
#
# build_linux.zsh / build_windows.bat remain valid full-rebuild wrappers.
# The precision system lives here on purpose: -fdefault-real-8 makes every real
# double precision. Do NOT move it into a wp=real64 kind parameter.

# Make presets FC=f77 as a built-in, so ?= won't take; only override that default.
ifeq ($(origin FC),default)
  FC := gfortran
endif
OBJ_DIR := obj
BIN_DIR := bin
EXEC    := $(BIN_DIR)/flightsim

MODE     ?= release
PLATFORM ?= linux

# --- one-place flag definition (mirrors build_linux.zsh / build_windows.bat) ---
COMMON := -fdefault-real-8 -ffree-line-length-512 -cpp
ifeq ($(PLATFORM),windows)
  COMMON += -DWINDOWS
  LIBS   := -lws2_32
  UDP    := udp_windows_m
else
  LIBS   :=
  UDP    := udp_m
endif

ifeq ($(MODE),debug)
  MODEFLAGS := -O0 -g -Wall -Wextra -fcheck=all -fbacktrace -finit-real=snan \
               -ffpe-trap=invalid -finit-integer=-999999
  LMODE     := -O0 -g -fbacktrace -static
else
  MODEFLAGS := -O2
  LMODE     := -O2 -static
endif

FFLAGS := -c $(COMMON) $(MODEFLAGS) -I $(OBJ_DIR) -J $(OBJ_DIR)
LFLAGS := $(COMMON) $(LMODE)

# --- single source-of-truth dependency-ordered module list ($(UDP) is platform-picked) ---
MODULES := constants_m wmm_m random_m turbulence_m math_m atmosphere_m json jsonx \
           $(UDP) units_m jsonx_units_m equations_m aero_state_m aero_database_m \
           battery_m force_source_m sensor_m ekf_m vehicle_types_m vehicle_io_m \
           dynamics_m trim_m analysis_m connection_m packet_builder_m simulation_m main

OBJECTS := $(addprefix $(OBJ_DIR)/,$(addsuffix .o,$(MODULES)))

.PHONY: all clean
all: $(EXEC)

$(EXEC): $(OBJECTS) | $(BIN_DIR)
	@echo "Linking -> $@"
	$(FC) $(LFLAGS) -o $@ $(OBJECTS) $(LIBS)
	@echo "Build complete [$(MODE)/$(PLATFORM)]: $@"

# generic compile rule: each object depends on its source; inter-module
# prerequisites below force recompiles when an upstream .mod changes.
$(OBJ_DIR)/%.o: %.f90 | $(OBJ_DIR)
	@echo "Compiling $< -> $@"
	$(FC) $(FFLAGS) -o $@ $<

$(OBJ_DIR) $(BIN_DIR):
	@mkdir -p $@

# --- inter-module dependencies (upstream .o must be current before downstream) ---
$(OBJ_DIR)/wmm_m.o:          $(OBJ_DIR)/constants_m.o
$(OBJ_DIR)/random_m.o:       $(OBJ_DIR)/constants_m.o
$(OBJ_DIR)/turbulence_m.o:   $(OBJ_DIR)/constants_m.o $(OBJ_DIR)/random_m.o
$(OBJ_DIR)/math_m.o:         $(OBJ_DIR)/constants_m.o
$(OBJ_DIR)/atmosphere_m.o:   $(OBJ_DIR)/constants_m.o
$(OBJ_DIR)/jsonx.o:          $(OBJ_DIR)/json.o
$(OBJ_DIR)/units_m.o:        $(OBJ_DIR)/constants_m.o
$(OBJ_DIR)/jsonx_units_m.o:  $(OBJ_DIR)/json.o $(OBJ_DIR)/jsonx.o $(OBJ_DIR)/units_m.o
$(OBJ_DIR)/equations_m.o:    $(OBJ_DIR)/json.o $(OBJ_DIR)/jsonx.o $(OBJ_DIR)/units_m.o
$(OBJ_DIR)/aero_state_m.o:   $(OBJ_DIR)/constants_m.o $(OBJ_DIR)/math_m.o
$(OBJ_DIR)/aero_database_m.o:$(OBJ_DIR)/constants_m.o
$(OBJ_DIR)/force_source_m.o: $(OBJ_DIR)/aero_database_m.o $(OBJ_DIR)/aero_state_m.o \
                             $(OBJ_DIR)/atmosphere_m.o $(OBJ_DIR)/battery_m.o \
                             $(OBJ_DIR)/constants_m.o $(OBJ_DIR)/math_m.o
$(OBJ_DIR)/sensor_m.o:       $(OBJ_DIR)/atmosphere_m.o $(OBJ_DIR)/constants_m.o \
                             $(OBJ_DIR)/math_m.o $(OBJ_DIR)/random_m.o
$(OBJ_DIR)/ekf_m.o:          $(OBJ_DIR)/constants_m.o $(OBJ_DIR)/math_m.o
$(OBJ_DIR)/vehicle_types_m.o:$(OBJ_DIR)/aero_database_m.o $(OBJ_DIR)/battery_m.o \
                             $(OBJ_DIR)/constants_m.o $(OBJ_DIR)/ekf_m.o \
                             $(OBJ_DIR)/force_source_m.o $(OBJ_DIR)/json.o \
                             $(OBJ_DIR)/math_m.o $(OBJ_DIR)/sensor_m.o
$(OBJ_DIR)/vehicle_io_m.o:   $(OBJ_DIR)/aero_database_m.o $(OBJ_DIR)/atmosphere_m.o \
                             $(OBJ_DIR)/battery_m.o $(OBJ_DIR)/constants_m.o \
                             $(OBJ_DIR)/ekf_m.o $(OBJ_DIR)/equations_m.o \
                             $(OBJ_DIR)/force_source_m.o $(OBJ_DIR)/json.o \
                             $(OBJ_DIR)/jsonx.o $(OBJ_DIR)/jsonx_units_m.o \
                             $(OBJ_DIR)/math_m.o $(OBJ_DIR)/sensor_m.o \
                             $(OBJ_DIR)/units_m.o $(OBJ_DIR)/vehicle_types_m.o
$(OBJ_DIR)/dynamics_m.o:     $(OBJ_DIR)/aero_state_m.o $(OBJ_DIR)/atmosphere_m.o \
                             $(OBJ_DIR)/constants_m.o $(OBJ_DIR)/force_source_m.o \
                             $(OBJ_DIR)/math_m.o $(OBJ_DIR)/vehicle_types_m.o
$(OBJ_DIR)/trim_m.o:         $(OBJ_DIR)/atmosphere_m.o $(OBJ_DIR)/constants_m.o \
                             $(OBJ_DIR)/dynamics_m.o $(OBJ_DIR)/math_m.o \
                             $(OBJ_DIR)/vehicle_types_m.o
$(OBJ_DIR)/analysis_m.o:     $(OBJ_DIR)/constants_m.o $(OBJ_DIR)/dynamics_m.o \
                             $(OBJ_DIR)/math_m.o $(OBJ_DIR)/vehicle_types_m.o
$(OBJ_DIR)/connection_m.o:   $(OBJ_DIR)/json.o $(OBJ_DIR)/jsonx.o $(OBJ_DIR)/$(UDP).o
$(OBJ_DIR)/packet_builder_m.o:$(OBJ_DIR)/ekf_m.o $(OBJ_DIR)/sensor_m.o \
                             $(OBJ_DIR)/vehicle_types_m.o
$(OBJ_DIR)/simulation_m.o:   $(OBJ_DIR)/atmosphere_m.o $(OBJ_DIR)/connection_m.o \
                             $(OBJ_DIR)/constants_m.o $(OBJ_DIR)/dynamics_m.o \
                             $(OBJ_DIR)/ekf_m.o $(OBJ_DIR)/equations_m.o \
                             $(OBJ_DIR)/force_source_m.o $(OBJ_DIR)/json.o \
                             $(OBJ_DIR)/math_m.o $(OBJ_DIR)/packet_builder_m.o \
                             $(OBJ_DIR)/random_m.o $(OBJ_DIR)/sensor_m.o \
                             $(OBJ_DIR)/turbulence_m.o $(OBJ_DIR)/units_m.o \
                             $(OBJ_DIR)/vehicle_io_m.o $(OBJ_DIR)/vehicle_types_m.o \
                             $(OBJ_DIR)/wmm_m.o
$(OBJ_DIR)/main.o:           $(OBJ_DIR)/analysis_m.o $(OBJ_DIR)/atmosphere_m.o \
                             $(OBJ_DIR)/connection_m.o $(OBJ_DIR)/constants_m.o \
                             $(OBJ_DIR)/equations_m.o $(OBJ_DIR)/json.o \
                             $(OBJ_DIR)/simulation_m.o $(OBJ_DIR)/trim_m.o \
                             $(OBJ_DIR)/vehicle_io_m.o $(OBJ_DIR)/vehicle_types_m.o

clean:
	rm -rf $(OBJ_DIR) $(BIN_DIR)
