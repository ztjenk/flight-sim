! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! Shared pilot command + flight-mode state. This is the single type the gamepad,
! mode state-machine, and CSV maneuver loader all operate on, which is what lets
! that logic live once in common/ instead of being copied per controller.
!
! Flight modes are a priority stack (altitude > angles > rates); when none are
! on the effective mode is MANUAL (sticks drive control surfaces directly).
! Velocity hold and sideslip (beta) hold are independent overlays.
module pilot_cmd_m
  use constants_m, only: DEG2RAD
  implicit none
  private

  public :: pilot_cmd_t, mode_transition_t
  public :: effective_mode
  integer, parameter, public :: MODE_MANUAL = 0
  integer, parameter, public :: MODE_RATES = 1
  integer, parameter, public :: MODE_ANGLES = 2
  integer, parameter, public :: MODE_ALTITUDE = 3

  type :: pilot_cmd_t
    ! --- mode flags (priority stack) + independent overlays ---
    logical :: rates_on    = .true.    ! B
    logical :: angles_on   = .false.   ! X
    logical :: altitude_on = .false.   ! Y
    logical :: velocity_on = .true.    ! A  (airspeed/throttle hold)
    logical :: beta_on     = .true.    ! RB (sideslip hold, used in angles/altitude)

    ! --- reference commands (rad, rad/s, ft, ft/s) ---
    real :: p_cmd   = 0.0
    real :: q_cmd   = 0.0
    real :: r_cmd   = 0.0
    real :: phi_cmd   = 0.0
    real :: theta_cmd = 0.0
    real :: beta_cmd  = 0.0
    real :: V_cmd   = 350.0
    real :: h_cmd   = 0.0
    logical :: h_cmd_needs_capture = .false.

    ! --- manual-mode direct surface outputs (rad) + manual throttle (0..1) ---
    real :: da_manual = 0.0
    real :: de_manual = 0.0
    real :: dr_manual = 0.0
    real :: thr_manual = 0.0

    ! --- stick scaling / limits ---
    real :: p_cmd_max_dps   = 300.0
    real :: q_cmd_max_dps   = 30.0
    real :: r_cmd_max_dps   = 30.0
    real :: phi_cmd_max_deg   = 90.0
    real :: theta_cmd_max_deg = 30.0
    real :: beta_cmd_max_deg  = 20.0
    real :: da_max_deg = 30.0
    real :: de_max_deg = 30.0
    real :: dr_max_deg = 30.0
    real :: hdot_stick_max = 100.0     ! climb-rate authority of pitch stick in altitude mode [ft/s]

    ! --- velocity command limits / step ---
    real :: V_cmd_min  = 200.0
    real :: V_cmd_max  = 1000.0
    real :: V_cmd_step = 100.0
  end type pilot_cmd_t

  ! Records what changed on a button frame so the controller can do bumpless
  ! transfer (re-sync only the loops that just turned on).
  type :: mode_transition_t
    logical :: any_change      = .false.
    logical :: rates_just_on   = .false.
    logical :: angles_just_on  = .false.
    logical :: altitude_just_on= .false.
    logical :: beta_just_on    = .false.
    logical :: velocity_just_on= .false.
  end type mode_transition_t

contains

  ! Effective flight mode = highest-priority flag currently on.
  pure function effective_mode(pm) result(m)
    type(pilot_cmd_t), intent(in) :: pm
    integer :: m
    if (pm%altitude_on) then
      m = MODE_ALTITUDE
    else if (pm%angles_on) then
      m = MODE_ANGLES
    else if (pm%rates_on) then
      m = MODE_RATES
    else
      m = MODE_MANUAL
    end if
  end function effective_mode

end module pilot_cmd_m
