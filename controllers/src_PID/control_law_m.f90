! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! PID control law: cascaded bank/pitch/sideslip/altitude outer loops feeding the
! p/q/r/throttle inner PID loops. Which loops run is decided by the effective
! flight mode on the pilot_cmd_t (manual < rates < angles < altitude). This is
! the only PID-specific control code; everything else is shared in common/.
module control_law_m
  use constants_m, only: DEG2RAD
  use math_m, only: clamp, quat_to_euler, calc_dynamic_pressure
  use atmosphere_m, only: std_atm_English
  use pid_m
  use pilot_cmd_m
  use flight_state_m, only: flight_state_t
  use config_m, only: pid_config_t, controls_t
  implicit none
  private

  public :: pid_law_t, law_init, law_step, law_sync_bumpless, law_capture_altitude

  type :: pid_law_t
    type(pid_ctrl)     :: pc, qc, rc, thc                 ! inner: p, q, r, throttle
    type(cascade_ctrl) :: bank_cc, pitch_cc, sideslip_cc  ! mid: phi->p, theta->q, beta->r
    type(cascade_ctrl) :: alt_h_cc                        ! outer: h->theta
  end type pid_law_t

contains

  subroutine law_init(law, cfg, pm)
    type(pid_law_t), intent(out) :: law
    type(pid_config_t), intent(in) :: cfg
    type(pilot_cmd_t), intent(in) :: pm

    call pid_init(law%pc, kp=cfg%pkp, ki=cfg%pki, kd=cfg%pkd, Qref=cfg%base%Qref, tau_d=cfg%ptau_d, &
                  out_min=cfg%da_min_deg*DEG2RAD, out_max=cfg%da_max_deg*DEG2RAD)
    call pid_init(law%qc, kp=cfg%qkp, ki=cfg%qki, kd=cfg%qkd, Qref=cfg%base%Qref, tau_d=cfg%qtau_d, &
                  out_min=cfg%de_min_deg*DEG2RAD, out_max=cfg%de_max_deg*DEG2RAD)
    call pid_init(law%rc, kp=cfg%rkp, ki=cfg%rki, kd=cfg%rkd, Qref=cfg%base%Qref, tau_d=cfg%rtau_d, &
                  out_min=cfg%dr_min_deg*DEG2RAD, out_max=cfg%dr_max_deg*DEG2RAD)
    ! throttle PID omits Qref (no dynamic-pressure scheduling on airspeed loop)
    call pid_init(law%thc, kp=cfg%thkp, ki=cfg%thki, kd=cfg%thkd, tau_d=cfg%thtau_d, &
                  out_min=cfg%th_min, out_max=cfg%th_max)

    call cascade_init(law%bank_cc, kp=cfg%bkp, ki=cfg%bki, kd=cfg%bkd, &
                      out_max=pm%p_cmd_max_dps*DEG2RAD, tau_d=cfg%btau_d)
    call cascade_init(law%pitch_cc, kp=cfg%tkp, ki=cfg%tki, kd=cfg%tkd, &
                      out_max=pm%q_cmd_max_dps*DEG2RAD, tau_d=cfg%ttau_d)
    call cascade_init(law%sideslip_cc, kp=cfg%sskp, ki=cfg%sski, kd=cfg%sskd, &
                      out_max=pm%r_cmd_max_dps*DEG2RAD, tau_meas=cfg%ss_tau_beta, tau_d=cfg%sstau_d)
    call cascade_init(law%alt_h_cc, kp=cfg%alt_kp_h*DEG2RAD, ki=cfg%alt_ki_h*DEG2RAD, &
                      kd=cfg%alt_kd_h*DEG2RAD, out_max=cfg%alt_theta_max_deg*DEG2RAD, &
                      tau_d=cfg%alt_tau_hdot)
  end subroutine law_init

  subroutine law_step(law, pm, st, dt, ctrl)
    type(pid_law_t), intent(inout) :: law
    type(pilot_cmd_t), intent(inout) :: pm
    type(flight_state_t), intent(in) :: st
    real, intent(in) :: dt
    type(controls_t), intent(inout) :: ctrl

    real :: altitude, velocity, rho, Qbar
    real :: Z_atm, T_atm, P_atm, a_atm, mu_atm
    real :: euler(3), beta_raw, theta_cmd, cos_phi
    integer :: m

    altitude = -st%z
    velocity = sqrt(st%u*st%u + st%v*st%v + st%w*st%w)
    call std_atm_English(altitude, Z_atm, T_atm, P_atm, rho, a_atm, mu_atm)
    Qbar = calc_dynamic_pressure(rho, velocity)
    euler = quat_to_euler([st%e0, st%ex, st%ey, st%ez])

    m = effective_mode(pm)

    ! ---- mid/outer loops (angles & altitude modes) ----
    if (m >= MODE_ANGLES) then
      call cascade_step(law%bank_cc, dt, pm%phi_cmd, euler(1), pm%p_cmd)

      if (m == MODE_ALTITUDE) then
        call cascade_step(law%alt_h_cc, dt, pm%h_cmd, altitude, theta_cmd)
        cos_phi = max(cos(euler(1)), 0.3)             ! bank compensation
        theta_cmd = clamp(theta_cmd / cos_phi, -law%alt_h_cc%out_max, law%alt_h_cc%out_max)
      else
        theta_cmd = pm%theta_cmd
      end if
      pm%theta_cmd = theta_cmd     ! expose the commanded pitch attitude for the HUD
      call cascade_step(law%pitch_cc, dt, theta_cmd, euler(2), pm%q_cmd)

      if (pm%beta_on) then
        if (velocity > 1.0) then
          beta_raw = atan2(st%v, max(abs(st%u), 1.0))
        else
          beta_raw = 0.0
        end if
        call cascade_step(law%sideslip_cc, dt, pm%beta_cmd, beta_raw, pm%r_cmd)
      end if
    end if

    ! ---- inner rate loops (rates/angles/altitude) or direct surfaces (manual) ----
    if (m >= MODE_RATES) then
      call pid_step(law%pc, dt, pm%p_cmd, st%p, Qbar, ctrl%da)
      call pid_step(law%qc, dt, pm%q_cmd, st%q, Qbar, ctrl%de)
      call pid_step(law%rc, dt, pm%r_cmd, st%r, Qbar, ctrl%dr)
    else
      ctrl%da = pm%da_manual
      ctrl%de = pm%de_manual
      ctrl%dr = pm%dr_manual
    end if

    ! ---- throttle (independent velocity-hold overlay) ----
    if (pm%velocity_on) then
      call pid_step(law%thc, dt, pm%V_cmd, velocity, Qbar, ctrl%throttle)
    else
      ctrl%throttle = pm%thr_manual
    end if
  end subroutine law_step

  ! Bumpless transfer: on any mode change, re-sync loop integrators to current
  ! outputs/state so engaging a loop does not bump the surfaces.
  subroutine law_sync_bumpless(law, pm, st, ctrl, trans)
    type(pid_law_t), intent(inout) :: law
    type(pilot_cmd_t), intent(inout) :: pm
    type(flight_state_t), intent(in) :: st
    type(controls_t), intent(in) :: ctrl
    type(mode_transition_t), intent(in) :: trans
    real :: euler(3)

    if (.not. trans%any_change) return

    call pid_reset_to(law%pc, ctrl%da)
    call pid_reset_to(law%qc, ctrl%de)
    call pid_reset_to(law%rc, ctrl%dr)
    call pid_reset_to(law%thc, ctrl%throttle)
    call cascade_reset(law%bank_cc)
    call cascade_reset(law%pitch_cc)
    call cascade_reset(law%sideslip_cc)
    call cascade_reset(law%alt_h_cc)
    euler = quat_to_euler([st%e0, st%ex, st%ey, st%ez])
    law%alt_h_cc%integ = euler(2)             ! seed altitude outer with current pitch

    if (trans%altitude_just_on) pm%h_cmd = -st%z
  end subroutine law_sync_bumpless

  ! First-packet altitude capture + outer-loop seeding.
  subroutine law_capture_altitude(law, pm, st)
    type(pid_law_t), intent(inout) :: law
    type(pilot_cmd_t), intent(inout) :: pm
    type(flight_state_t), intent(in) :: st
    real :: euler(3)
    if (pm%h_cmd_needs_capture) then
      pm%h_cmd = -st%z
      pm%h_cmd_needs_capture = .false.
    end if
    call cascade_reset(law%alt_h_cc)
    euler = quat_to_euler([st%e0, st%ex, st%ey, st%ez])
    law%alt_h_cc%integ = euler(2)
  end subroutine law_capture_altitude

end module control_law_m
