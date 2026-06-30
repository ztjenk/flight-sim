@echo off
setlocal enabledelayedexpansion
rem Windows build for the DI controller. Builds the shared common\ modules
rem first, then the controller-specific modules, linking ..\common\obj\*.o.
rem Release by default; pass "debug" for the checked build.
rem Identical to build_linux.zsh except for the platform UDP layer (in
rem ..\common): Windows adds -DWINDOWS, links -lws2_32 (winsock), emits a .exe.
cd /d "%~dp0"

set FC=gfortran
set COMMON_OBJ=..\common\obj
set OBJDIR=obj
set BINDIR=bin
set EXE=%BINDIR%\DI.exe

rem ---- build mode (default: release) ----
set MODE=release
if /I "%1"=="debug" set MODE=debug

rem ---- build the shared modules first, then return here ----
call ..\common\build_windows.bat %MODE%
if errorlevel 1 goto :error
cd /d "%~dp0"

rem ---- common flags (= Linux flags + -DWINDOWS) ----
set COMMON=-fdefault-real-8 -ffree-line-length-512 -cpp -DWINDOWS
if "%MODE%"=="debug" (
    echo Building DI controller [DEBUG]...
    set FFLAGS=-c %COMMON% -O0 -g -Wall -Wextra -fcheck=all -fbacktrace -finit-real=snan -ffpe-trap=invalid -finit-integer=-999999 -I %OBJDIR% -I %COMMON_OBJ% -J %OBJDIR%
    set LFLAGS=%COMMON% -O0 -g -fbacktrace -static
) else (
    echo Building DI controller [RELEASE]...
    set FFLAGS=-c %COMMON% -O2 -I %OBJDIR% -I %COMMON_OBJ% -J %OBJDIR%
    set LFLAGS=%COMMON% -O2 -static
)

set SRCS= ^
  vehicle_m.f90 ^
  config_m.f90 ^
  control_law_m.f90 ^
  controller_main.f90

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
%FC% %LFLAGS% -o "%EXE%" %OBJECTS% %COMMON_OBJ%\*.o -lws2_32
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
