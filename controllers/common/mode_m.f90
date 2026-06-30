! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! Unified flight-control mode logic shared by all fixed-wing controllers.
! Implements the priority-stack mode scheme (manual < rates < angles < altitude)
! with independent velocity-hold (A) and sideslip-hold (RB) overlays, maps the
! Xbox gamepad to mode toggles + stick references, and maps CSV maneuver rows
! to the same pilot_cmd_t. Control laws read pilot_cmd_t; they never see the pad.
module mode_m
  use constants_m, only: DEG2RAD
  use math_m, only: clamp
  use gamepad_m
  use pilot_cmd_m
  use command_profile_m, only: profile_commands
  implicit none
  private

  public :: mode_handle_buttons, mode_apply_sticks, mode_apply_csv, mode_name

contains

  ! Process button rising-edges: toggle modes/overlays, step V_cmd, and report
  ! what changed (for bumpless transfer). Updates gp%buttons_prev.
  subroutine mode_handle_buttons(gp, pm, trans)
    type(gamepad_t), intent(inout) :: gp
    type(pilot_cmd_t), intent(inout) :: pm
    type(mode_transition_t), intent(out) :: trans

    integer :: rising

    trans = mode_transition_t()
    rising = gp_rising(gp)

    ! A: velocity hold
    if (btest(rising, BTN_A)) then
      pm%velocity_on = .not. pm%velocity_on
      trans%velocity_just_on = pm%velocity_on
      trans%any_change = .true.
      print *, "velocity hold:", pm%velocity_on
    end if

    ! B: angles mode flag
    if (btest(rising, BTN_B)) then
      pm%angles_on = .not. pm%angles_on
      trans%angles_just_on = pm%angles_on
      trans%any_change = .true.
      print *, "angles flag:", pm%angles_on
    end if

    ! X: rates mode flag
    if (btest(rising, BTN_X)) then
      pm%rates_on = .not. pm%rates_on
      trans%rates_just_on = pm%rates_on
      trans%any_change = .true.
      print *, "rates flag:", pm%rates_on
    end if

    ! Y: altitude mode flag
    if (btest(rising, BTN_Y)) then
      pm%altitude_on = .not. pm%altitude_on
      trans%altitude_just_on = pm%altitude_on
      trans%any_change = .true.
      print *, "altitude flag:", pm%altitude_on
    end if

    ! RB: sideslip (beta) hold
    if (btest(rising, BTN_RB)) then
      pm%beta_on = .not. pm%beta_on
      trans%beta_just_on = pm%beta_on
      trans%any_change = .true.
      print *, "sideslip (beta) hold:", pm%beta_on
    end if

    ! D-pad left/right: adjust V_cmd (only meaningful with velocity hold on)
    if (btest(rising, BTN_DRIGHT) .and. pm%velocity_on) then
      pm%V_cmd = min(pm%V_cmd + pm%V_cmd_step, pm%V_cmd_max)
      print '(A,F7.1,A)', " V_cmd:", pm%V_cmd, " ft/s"
    end if
    if (btest(rising, BTN_DLEFT) .and. pm%velocity_on) then
      pm%V_cmd = max(pm%V_cmd - pm%V_cmd_step, pm%V_cmd_min)
      print '(A,F7.1,A)', " V_cmd:", pm%V_cmd, " ft/s"
    end if

    gp%buttons_prev = gp%buttons
  end subroutine mode_handle_buttons

  ! Map stick deflections to reference commands per the effective mode.
  ! Sign conventions match the legacy controllers.
  subroutine mode_apply_sticks(gp, pm, dt)
    type(gamepad_t), intent(in) :: gp
    type(pilot_cmd_t), intent(inout) :: pm
    real, intent(in) :: dt

    real :: phi_max, theta_max, beta_max
    integer :: m

    phi_max   = pm%phi_cmd_max_deg   * DEG2RAD
    theta_max = pm%theta_cmd_max_deg * DEG2RAD
    beta_max  = pm%beta_cmd_max_deg  * DEG2RAD

    m = effective_mode(pm)

    select case (m)
    case (MODE_MANUAL)
      pm%da_manual = gp%roll  * pm%da_max_deg * DEG2RAD
      pm%de_manual = gp%pitch * pm%de_max_deg * DEG2RAD
      pm%dr_manual = gp%yaw   * pm%dr_max_deg * DEG2RAD

    case (MODE_RATES)
      pm%p_cmd = -gp%roll  * pm%p_cmd_max_dps * DEG2RAD
      pm%q_cmd = -gp%pitch * pm%q_cmd_max_dps * DEG2RAD
      pm%r_cmd = -gp%yaw   * pm%r_cmd_max_dps * DEG2RAD

    case (MODE_ANGLES)
      pm%phi_cmd   = clamp(-gp%roll  * phi_max,   -phi_max,   phi_max)
      pm%theta_cmd = clamp(-gp%pitch * theta_max, -theta_max, theta_max)
      call yaw_axis(gp, pm, beta_max)

    case (MODE_ALTITUDE)
      pm%phi_cmd = clamp(-gp%roll * phi_max, -phi_max, phi_max)
      ! pitch stick trims commanded altitude at +-hdot_stick_max ft/s
      pm%h_cmd = pm%h_cmd - gp%pitch * pm%hdot_stick_max * dt
      call yaw_axis(gp, pm, beta_max)
    end select

    ! manual throttle source when velocity hold is off
    pm%thr_manual = gp%throttle
  end subroutine mode_apply_sticks

  ! yaw stick: sideslip command when beta hold is on, else direct yaw-rate command
  subroutine yaw_axis(gp, pm, beta_max)
    type(gamepad_t), intent(in) :: gp
    type(pilot_cmd_t), intent(inout) :: pm
    real, intent(in) :: beta_max
    if (pm%beta_on) then
      pm%beta_cmd = clamp(-gp%yaw * beta_max, -beta_max, beta_max)
    else
      pm%r_cmd = -gp%yaw * pm%r_cmd_max_dps * DEG2RAD
    end if
  end subroutine yaw_axis

  ! Map an interpolated CSV maneuver row to pilot_cmd_t per the effective mode.
  subroutine mode_apply_csv(csv, pm)
    type(profile_commands), intent(in) :: csv
    type(pilot_cmd_t), intent(inout) :: pm

    real :: phi_max, theta_max, beta_max
    integer :: m

    phi_max   = pm%phi_cmd_max_deg   * DEG2RAD
    theta_max = pm%theta_cmd_max_deg * DEG2RAD
    beta_max  = pm%beta_cmd_max_deg  * DEG2RAD
    m = effective_mode(pm)

    if (pm%velocity_on) pm%V_cmd = csv%V_cmd_fps

    select case (m)
    case (MODE_RATES)
      pm%p_cmd = csv%p_cmd_dps * DEG2RAD
      pm%q_cmd = csv%q_cmd_dps * DEG2RAD
      pm%r_cmd = csv%r_cmd_dps * DEG2RAD
    case (MODE_ANGLES)
      pm%phi_cmd   = clamp(csv%phi_cmd_deg   * DEG2RAD, -phi_max,   phi_max)
      pm%theta_cmd = clamp(csv%theta_cmd_deg * DEG2RAD, -theta_max, theta_max)
      if (pm%beta_on) pm%beta_cmd = clamp(csv%beta_cmd_deg * DEG2RAD, -beta_max, beta_max)
    case (MODE_ALTITUDE)
      pm%phi_cmd = clamp(csv%phi_cmd_deg * DEG2RAD, -phi_max, phi_max)
      if (csv%h_cmd_ft >= 0.0) pm%h_cmd = csv%h_cmd_ft
      if (pm%beta_on) pm%beta_cmd = clamp(csv%beta_cmd_deg * DEG2RAD, -beta_max, beta_max)
    end select
  end subroutine mode_apply_csv

  pure function mode_name(pm) result(name)
    type(pilot_cmd_t), intent(in) :: pm
    character(len=8) :: name
    select case (effective_mode(pm))
    case (MODE_MANUAL);   name = 'MANUAL'
    case (MODE_RATES);    name = 'RATES'
    case (MODE_ANGLES);   name = 'ANGLES'
    case (MODE_ALTITUDE); name = 'ALTITUDE'
    case default;         name = '???'
    end select
  end function mode_name

end module mode_m
