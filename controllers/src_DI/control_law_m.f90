! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! Dynamic-inversion control law (port of pythonDI controller.py), wired to the
! shared flight-mode system. Cascade: outer attitude (phi/theta/beta) -> kinematic
! body-rate commands -> inner rate loops -> desired angular accel nu -> NDI/INDI
! inversion -> control deflections. Manual mode bypasses the law (direct surfaces).
module control_law_m
  use, intrinsic :: ieee_arithmetic, only: ieee_is_finite
  use constants_m, only: DEG2RAD, G_SSL_SI, FT_TO_M, R_MEAN_EARTH_ENGLISH
  use math_m, only: clamp, quat_to_euler, calc_alpha, calc_beta, norm3, calc_dynamic_pressure
  use atmosphere_m, only: std_atm_English
  use pid_m
  use pilot_cmd_m
  use flight_state_m, only: flight_state_t
  use vehicle_m
  use config_m, only: di_config_t, controls_t
  implicit none
  private

  public :: di_law_t, law_init, law_step, law_sync_bumpless, law_capture_altitude

  real, parameter :: G_FT = G_SSL_SI / FT_TO_M          ! 32.174 ft/s^2
  real, parameter :: R_EARTH_FT = R_MEAN_EARTH_ENGLISH

  type :: di_law_t
    type(pid_ctrl) :: pc, qc, rc              ! inner rate loops: rate error -> nu (accel)
    type(pid_ctrl) :: thc                     ! throttle
    type(pid_ctrl) :: att_phi, att_theta, att_beta  ! outer first-order attitude trackers
    type(cascade_ctrl) :: alt_h_cc            ! altitude h -> theta_cmd
    ! state carried between ticks
    real :: last_good(4) = 0.0
    logical :: have_last_good = .false.
    real :: omega_prev(3) = 0.0
    real :: t_prev = -1.0
    logical :: have_prev = .false.
  end type di_law_t

contains

  subroutine law_init(law, cfg)
    type(di_law_t), intent(out) :: law
    type(di_config_t), intent(in) :: cfg

    ! inner rate loops output desired angular acceleration nu, clamped to accel limits
    call pid_init(law%pc, kp=cfg%pkp, ki=cfg%pki, kd=cfg%pkd, out_min=-cfg%nu_max(1), out_max=cfg%nu_max(1))
    call pid_init(law%qc, kp=cfg%qkp, ki=cfg%qki, kd=cfg%qkd, out_min=-cfg%nu_max(2), out_max=cfg%nu_max(2))
    call pid_init(law%rc, kp=cfg%rkp, ki=cfg%rki, kd=cfg%rkd, out_min=-cfg%nu_max(3), out_max=cfg%nu_max(3))
    call pid_init(law%thc, kp=cfg%thkp, ki=cfg%thki, kd=cfg%thkd, out_min=-1.0, out_max=1.0)
    ! outer attitude: first-order trackers (ki=kd=0); kp = bandwidth, clamp = euler-rate limit
    call pid_init(law%att_phi,   kp=cfg%bw_phi,   ki=0.0, kd=0.0, out_min=-cfg%erl_phi,   out_max=cfg%erl_phi)
    call pid_init(law%att_theta, kp=cfg%bw_theta, ki=0.0, kd=0.0, out_min=-cfg%erl_theta, out_max=cfg%erl_theta)
    call pid_init(law%att_beta,  kp=cfg%bw_beta,  ki=0.0, kd=0.0, out_min=-cfg%erl_beta,  out_max=cfg%erl_beta)
    call cascade_init(law%alt_h_cc, kp=cfg%alt_kp_h*DEG2RAD, ki=cfg%alt_ki_h*DEG2RAD, &
                      kd=cfg%alt_kd_h*DEG2RAD, out_max=cfg%alt_theta_max_deg*DEG2RAD, tau_d=cfg%alt_tau_hdot)
  end subroutine law_init

  subroutine law_step(law, cfg, pm, st, dt, ctrl)
    type(di_law_t), intent(inout) :: law
    type(di_config_t), intent(in) :: cfg
    type(pilot_cmd_t), intent(inout) :: pm
    type(flight_state_t), intent(in) :: st
    real, intent(in) :: dt
    type(controls_t), intent(inout) :: ctrl

    real :: vel(3), omega(3), V, alpha, beta, qdyn, rho
    real :: Z_atm, T_atm, P_atm, a_atm, mu_atm, altitude
    real :: euler(3), phi, theta, psi
    real :: rate_cmd(3), nu(3), delta(3), base(3), omega_dot(3)
    real :: phidot_d, thetadot_d, betadot_d, theta_tgt, beta_tgt, a_c, vh
    real :: thr, thr_raw, out4(4)
    integer :: m
    logical :: ok, use_indi, do_di

    vel = [st%u, st%v, st%w]
    omega = [st%p, st%q, st%r]
    V = norm3(vel)
    alpha = calc_alpha(vel)
    beta  = calc_beta(vel)
    V = max(V, cfg%V_floor)
    altitude = -st%z
    call std_atm_English(altitude, Z_atm, T_atm, P_atm, rho, a_atm, mu_atm)
    qdyn = max(calc_dynamic_pressure(rho, V), cfg%qdyn_floor)
    euler = quat_to_euler([st%e0, st%ex, st%ey, st%ez]); phi = euler(1); theta = euler(2); psi = euler(3)

    m = effective_mode(pm)
    do_di = (m >= MODE_RATES)

    ! ---- determine body-rate commands ----
    if (m >= MODE_ANGLES .and. cfg%outer_enable) then
      if (m == MODE_ALTITUDE) then
        call cascade_step(law%alt_h_cc, dt, pm%h_cmd, altitude, theta_tgt)
      else
        theta_tgt = pm%theta_cmd
      end if
      pm%theta_cmd = theta_tgt     ! expose the commanded pitch attitude for the HUD
      beta_tgt = 0.0
      if (pm%beta_on) beta_tgt = pm%beta_cmd

      call pid_step(law%att_phi,   dt, pm%phi_cmd, phi,   0.0, phidot_d)
      call pid_step(law%att_theta, dt, theta_tgt,  theta, 0.0, thetadot_d)
      if (pm%beta_on) then
        call pid_step(law%att_beta, dt, beta_tgt, beta, 0.0, betadot_d)
      else
        betadot_d = 0.0
      end if
      ! coordinated-turn feedforward keeps beta ~ 0 in a bank without an integrator
      if (cfg%turn_coord) then
        if (cfg%grav_relief) then
          vh = body_to_earth_horiz_speed(st%u, st%v, st%w, st%e0, st%ex, st%ey, st%ez)
          a_c = gravity_relief(vh, altitude)
        else
          a_c = 0.0
        end if
        betadot_d = betadot_d - coord_turn_ff(phi, theta, beta, V, a_c)
      end if
      rate_cmd = attitude_rate_cmd(phidot_d, thetadot_d, betadot_d, phi, theta, alpha)
    else
      rate_cmd = [pm%p_cmd, pm%q_cmd, pm%r_cmd]
    end if

    ! ---- inner rate loops -> desired angular accelerations nu ----
    if (do_di) then
      call pid_step(law%pc, dt, rate_cmd(1), omega(1), 0.0, nu(1))
      call pid_step(law%qc, dt, rate_cmd(2), omega(2), 0.0, nu(2))
      call pid_step(law%rc, dt, rate_cmd(3), omega(3), 0.0, nu(3))

      ! ---- inversion: nu -> control deflections ----
      use_indi = (trim(cfg%method) == 'indi')
      if (use_indi .and. cfg%use_pkt_wdot) then
        use_indi = st%has_wdot
      else if (use_indi) then
        use_indi = law%have_prev .and. (dt > 1.0e-4)
      end if

      if (use_indi) then
        if (cfg%use_pkt_wdot) then
          omega_dot = [st%pdot, st%qdot, st%rdot]
        else
          omega_dot = (omega - law%omega_prev) / max(dt, 1.0e-4)
        end if
        if (st%has_surf) then
          base = [st%da_act, st%de_act, st%dr_act]
        else
          base = 0.0
        end if
        call indi(cfg%veh, nu, omega_dot, base, alpha, qdyn, delta, ok)
      else
        call ndi(cfg%veh, nu, omega, V, alpha, beta, qdyn, delta, ok)
      end if

      ! clamp to surface limits
      delta(1) = clamp(delta(1), -cfg%dlim(1), cfg%dlim(1))
      delta(2) = clamp(delta(2), -cfg%dlim(2), cfg%dlim(2))
      delta(3) = clamp(delta(3), -cfg%dlim(3), cfg%dlim(3))
      if (.not. ok) delta = 0.0   ! singular solve -> handled by finite guard below
    else
      delta = [pm%da_manual, pm%de_manual, pm%dr_manual]
      ok = .true.
    end if

    ! ---- throttle ----
    if (pm%velocity_on) then
      call pid_step(law%thc, dt, pm%V_cmd, V, 0.0, thr_raw)
      thr = clamp(cfg%trim_throttle + thr_raw, 0.0, 1.0)
    else
      thr = cfg%trim_throttle
    end if

    ! ---- finite / non-finite guard: hold last good command ----
    out4 = [delta(1), delta(2), delta(3), thr]
    if (all_finite(out4) .and. ok) then
      law%last_good = out4
      law%have_last_good = .true.
    else if (law%have_last_good) then
      out4 = law%last_good
    else
      out4 = [0.0, 0.0, 0.0, cfg%trim_throttle]
    end if

    ctrl%da = out4(1); ctrl%de = out4(2); ctrl%dr = out4(3); ctrl%throttle = out4(4)

    law%omega_prev = omega
    law%t_prev = st%t
    law%have_prev = .true.
  end subroutine law_step

  subroutine law_sync_bumpless(law, pm, st, trans)
    type(di_law_t), intent(inout) :: law
    type(pilot_cmd_t), intent(inout) :: pm
    type(flight_state_t), intent(in) :: st
    type(mode_transition_t), intent(in) :: trans
    real :: euler(3)
    if (.not. trans%any_change) return
    ! reset rate-loop and outer-loop integrators (bumpless); DI surfaces follow from nu
    call pid_reset(law%pc); call pid_reset(law%qc); call pid_reset(law%rc)
    call pid_reset(law%att_phi); call pid_reset(law%att_theta); call pid_reset(law%att_beta)
    call pid_reset_to(law%thc, 0.0)
    call cascade_reset(law%alt_h_cc)
    euler = quat_to_euler([st%e0, st%ex, st%ey, st%ez])
    law%alt_h_cc%integ = euler(2)
    if (trans%altitude_just_on) pm%h_cmd = -st%z
  end subroutine law_sync_bumpless

  subroutine law_capture_altitude(law, pm, st)
    type(di_law_t), intent(inout) :: law
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

  ! ---- DI kinematics (ported from kinematics.py) ----

  ! Invert Euler-rate kinematics (book Eq 5.3.5 + sideslip): desired angle rates -> body rates.
  pure function attitude_rate_cmd(phidot_d, thetadot_d, betadot_d, phi, theta, alpha) result(rate)
    real, intent(in) :: phidot_d, thetadot_d, betadot_d, phi, theta, alpha
    real :: rate(3)
    real :: sphi, cphi, sth, cth, sal, cal, den, psidot
    real, parameter :: DEN_FLOOR = 0.15
    sphi = sin(phi); cphi = cos(phi)
    sth = sin(theta); cth = cos(theta)
    sal = sin(alpha); cal = cos(alpha)
    den = sal*sth + cal*cphi*cth
    if (abs(den) < DEN_FLOOR) then
      den = merge(DEN_FLOOR, -DEN_FLOOR, den >= 0.0)
    end if
    psidot = (phidot_d*sal + thetadot_d*sphi*cal - betadot_d) / den
    rate(1) = phidot_d - psidot*sth                  ! p_c
    rate(2) = thetadot_d*cphi + psidot*cth*sphi      ! q_c
    rate(3) = -thetadot_d*sphi + psidot*cth*cphi     ! r_c
  end function attitude_rate_cmd

  pure function body_to_earth_horiz_speed(u, v, w, e0, ex, ey, ez) result(vh)
    real, intent(in) :: u, v, w, e0, ex, ey, ez
    real :: vh, vN, vE
    vN = (e0*e0 + ex*ex - ey*ey - ez*ez)*u + 2.0*(ex*ey - e0*ez)*v + 2.0*(ex*ez + e0*ey)*w
    vE = 2.0*(ex*ey + e0*ez)*u + (e0*e0 - ex*ex + ey*ey - ez*ez)*v + 2.0*(ey*ez - e0*ex)*w
    vh = sqrt(vN*vN + vE*vE)
  end function body_to_earth_horiz_speed

  pure function gravity_relief(V_horiz, alt_ft) result(a_c)
    real, intent(in) :: V_horiz, alt_ft
    real :: a_c
    a_c = V_horiz*V_horiz / (R_EARTH_FT + alt_ft)
  end function gravity_relief

  pure function coord_turn_ff(phi, theta, beta, V, a_c) result(ff)
    real, intent(in) :: phi, theta, beta, V, a_c
    real :: ff
    ff = ((G_FT - a_c) / (V * cos(beta))) * sin(phi) * cos(theta)
  end function coord_turn_ff

  pure function all_finite(x) result(f)
    real, intent(in) :: x(:)
    logical :: f
    integer :: i
    f = .true.
    do i = 1, size(x)
      if (.not. ieee_is_finite(x(i)) .or. abs(x(i)) > 1.0e12) f = .false.
    end do
  end function all_finite

end module control_law_m
