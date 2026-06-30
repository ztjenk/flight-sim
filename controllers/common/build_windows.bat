@echo off
setlocal enabledelayedexpansion
rem Windows build of the shared controller modules into common\obj\ (.o + .mod).
rem Each controller's build_windows.bat calls this first, then adds -I ..\common\obj
rem and links ..\common\obj\*.o. Compile-only: no executable is produced.
rem Release by default; pass "debug" for the checked build.
rem Identical to build_linux.zsh except for the platform UDP layer: Windows
rem compiles udp_windows_m.f90 and adds -DWINDOWS.
cd /d "%~dp0"

set FC=gfortran
set OBJDIR=obj

rem ---- build mode (default: release) ----
set MODE=release
if /I "%1"=="debug" set MODE=debug

rem ---- common flags (= Linux flags + -DWINDOWS) ----
set COMMON=-fdefault-real-8 -ffree-line-length-512 -cpp -DWINDOWS

rem ---- mode-specific flags ----
if "%MODE%"=="debug" (
    echo Building common modules [DEBUG]...
    set FFLAGS=-c %COMMON% -O0 -g -Wall -Wextra -fcheck=all -fbacktrace -finit-real=snan -ffpe-trap=invalid -finit-integer=-999999 -I %OBJDIR% -J %OBJDIR%
) else (
    echo Building common modules [RELEASE]...
    set FFLAGS=-c %COMMON% -O2 -I %OBJDIR% -J %OBJDIR%
)

rem ---- shared modules in dependency order (udp_windows_m.f90 is the Windows UDP layer) ----
set SRCS= ^
  constants_m.f90 ^
  atmosphere_m.f90 ^
  math_m.f90 ^
  linalg_m.f90 ^
  json.f90 ^
  jsonx.f90 ^
  pid_m.f90 ^
  pilot_cmd_m.f90 ^
  flight_state_m.f90 ^
  config_base_m.f90 ^
  command_profile_m.f90 ^
  udp_windows_m.f90 ^
  gamepad_m.f90 ^
  mode_m.f90

if not exist %OBJDIR% mkdir %OBJDIR%

for %%S in (%SRCS%) do (
  set SRC=%%S
  set BASE=%%~nS
  set OBJ=%OBJDIR%\!BASE!.o
  echo Compiling !SRC! -^> !OBJ!
  %FC% %FFLAGS% -o "!OBJ!" "!SRC!"
  if errorlevel 1 goto :error
)

echo Common modules built [%MODE%] in %~dp0%OBJDIR%
goto :end

:error
echo.
echo Common build failed!
exit /b 1

:end
endlocal
