@echo off
setlocal enabledelayedexpansion
rem Windows build for the physics engine.
rem Release by default; pass "debug" for the checked build:
rem     build_windows.bat            (release, optimized)
rem     build_windows.bat debug      (debug, -O0, full runtime checks)
rem Identical to build_linux.zsh except for the platform UDP layer: Windows
rem compiles udp_windows_m.f90 and adds -DWINDOWS and -lws2_32 (winsock).
cd /d "%~dp0"

set FC=gfortran
set OBJDIR=obj
set BINDIR=bin
set EXE=%BINDIR%\flightsim.exe

rem ---- build mode (default: release) ----
set MODE=release
if /I "%1"=="debug" set MODE=debug

rem ---- common flags (= Linux flags + -DWINDOWS) ----
set COMMON=-fdefault-real-8 -ffree-line-length-512 -cpp -DWINDOWS

rem ---- mode-specific flags ----
if "%MODE%"=="debug" (
    echo Building flight simulator [DEBUG]...
    set FFLAGS=-c %COMMON% -O0 -g -Wall -Wextra -fcheck=all -fbacktrace -finit-real=snan -ffpe-trap=invalid -finit-integer=-999999 -I %OBJDIR% -J %OBJDIR%
    set LFLAGS=%COMMON% -O0 -g -fbacktrace -static
) else (
    echo Building flight simulator [RELEASE]...
    set FFLAGS=-c %COMMON% -O2 -I %OBJDIR% -J %OBJDIR%
    set LFLAGS=%COMMON% -O2 -static
)

rem ---- sources in dependency order (udp_windows_m.f90 is the Windows UDP layer) ----
set SRCS= ^
  constants_m.f90 ^
  wmm_m.f90 ^
  random_m.f90 ^
  turbulence_m.f90 ^
  math_m.f90 ^
  atmosphere_m.f90 ^
  json.f90 ^
  jsonx.f90 ^
  udp_windows_m.f90 ^
  units_m.f90 ^
  jsonx_units_m.f90 ^
  equations_m.f90 ^
  aero_state_m.f90 ^
  aero_database_m.f90 ^
  battery_m.f90 ^
  force_source_m.f90 ^
  sensor_m.f90 ^
  ekf_m.f90 ^
  vehicle_types_m.f90 ^
  vehicle_io_m.f90 ^
  dynamics_m.f90 ^
  trim_m.f90 ^
  analysis_m.f90 ^
  connection_m.f90 ^
  packet_builder_m.f90 ^
  simulation_m.f90 ^
  main.f90

if not exist %OBJDIR% mkdir %OBJDIR%
if not exist %BINDIR% mkdir %BINDIR%

set OBJECTS=
for %%S in (%SRCS%) do (
  set SRC=%%S
  set BASE=%%~nS
  set OBJ=%OBJDIR%\!BASE!.o
  echo Compiling !SRC! -^> !OBJ!
  %FC% %FFLAGS% -o "!OBJ!" "!SRC!"
  if errorlevel 1 goto :error
  set OBJECTS=!OBJECTS! "!OBJ!"
)

echo Linking -^> %EXE%
rem IMPORTANT: put -lws2_32 AFTER the objects so winsock symbols resolve
%FC% %LFLAGS% -o "%EXE%" %OBJECTS% -lws2_32
if errorlevel 1 goto :error

echo.
echo Build complete [%MODE%]: %EXE%
echo Usage: %EXE% ^<config.json^>
goto :end

:error
echo.
echo Build failed!
exit /b 1

:end
endlocal
