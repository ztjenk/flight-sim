! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! Quadrotor control law -- PROVISIONAL / SCAFFOLD.
!
! A standard PID cascade: attitude-angle P -> body-rate command -> rate PID ->
! desired angular acceleration -> body moments (I*nu); a climb-rate PI -> vertical
! acceleration -> collective thrust; then the X-quad mixer maps the desired wrench
! [T,L,M,N] to four rotor thrusts, inverted through the quadratic thrust map to
! rotor throttles.
!
! This is a buildable starting point chosen so the structure (I/O, mixer, stick
! mapping) is in place. The control law itself (pure PID here, vs. the proven INDI
! inner loop) and its gains/a_thrust/kappa are DEFERRED for tuning against the sim.
module control_law_m
  use, intrinsic :: ieee_arithmetic, only: ieee_is_finite
  use math_m, only: clamp, quat_to_euler, quat_rotate_body_to_inertial
  use constants_m, only: TOLERANCE
  use pid_m
  use mixer_m
  use config_m, only: quad_config_t
  implicit none
  private
  public :: quad_state_t, quad_cmd_t, quad_law_t, law_init, law_step

  type :: quad_state_t
    real :: t = 0.0
    real :: vel(3) = 0.0          ! body velocity [ft/s]
    real :: omega(3) = 0.0        ! body rates [rad/s]
    real :: quat(4) = [1.0,0.0,0.0,0.0]
    real :: rotor_act(4) = 0.0    ! actual rotor throttles [0..1]
    real :: omega_dot(3) = 0.0    ! EKF angular accel (unused by PID law; for future INDI)
  end type quad_state_t

  type :: quad_cmd_t
    real :: hdot_cmd = 0.0        ! climb rate [ft/s]   (left stick Y)
    real :: yaw_rate_cmd = 0.0    ! yaw rate [rad/s]    (left stick X)
    real :: phi_cmd = 0.0         ! bank [rad]          (right stick X)
    real :: theta_cmd = 0.0       ! pitch [rad]         (right stick Y)
  end type quad_cmd_t

  type :: quad_law_t
    type(pid_ctrl) :: pc, qc, rc      ! rate loops -> desired angular accel
    type(mixer_t)  :: mx
    real :: vz_integ = 0.0            ! climb-rate PI integrator
    real :: last_good(4) = 0.46       ! last good rotor throttles (hover-ish)
  end type quad_law_t

contains

  subroutine law_init(law, cfg)
    type(quad_law_t), intent(out) :: law
    type(quad_config_t), intent(in) :: cfg
    call pid_init(law%pc, kp=cfg%rkp_p, ki=cfg%rki_p, kd=cfg%rkd_p, out_min=-cfg%nu_max, out_max=cfg%nu_max)
    call pid_init(law%qc, kp=cfg%rkp_q, ki=cfg%rki_q, kd=cfg%rkd_q, out_min=-cfg%nu_max, out_max=cfg%nu_max)
    call pid_init(law%rc, kp=cfg%rkp_r, ki=cfg%rki_r, kd=cfg%rkd_r, out_min=-cfg%nu_max, out_max=cfg%nu_max)
    call mixer_build(law%mx, cfg%rotor_x, cfg%rotor_y, cfg%spin, cfg%kappa)
    if (.not. law%mx%ok) print *, "WARNING: quad mixer matrix is singular (check rotor geometry)"
  end subroutine law_init

  subroutine law_step(law, cfg, st, cmd, dt, throttles)
    type(quad_law_t), intent(inout) :: law
    type(quad_config_t), intent(in) :: cfg
    type(quad_state_t), intent(in) :: st
    type(quad_cmd_t), intent(in) :: cmd
    real, intent(in) :: dt
    real, intent(out) :: throttles(4)

    real :: euler(3), phi, theta
    real :: p_cmd, q_cmd, r_cmd, nu(3), L, M, N
    real :: v_earth(3), hdot, az, cos_tilt, T, err_h, vz_integ_lim
    real :: wrench(4), f(4)
    integer :: i

    euler = quat_to_euler(st%quat); phi = euler(1); theta = euler(2)

    ! attitude angle -> body-rate command (P)
    p_cmd = clamp(cfg%k_att_phi   * (cmd%phi_cmd   - phi),   -cfg%pqr_max, cfg%pqr_max)
    q_cmd = clamp(cfg%k_att_theta * (cmd%theta_cmd - theta), -cfg%pqr_max, cfg%pqr_max)
    r_cmd = clamp(cmd%yaw_rate_cmd, -cfg%pqr_max, cfg%pqr_max)

    ! rate PID -> desired angular accelerations -> moments
    call pid_step(law%pc, dt, p_cmd, st%omega(1), 0.0, nu(1))
    call pid_step(law%qc, dt, q_cmd, st%omega(2), 0.0, nu(2))
    call pid_step(law%rc, dt, r_cmd, st%omega(3), 0.0, nu(3))
    L = cfg%I(1) * nu(1)
    M = cfg%I(2) * nu(2)
    N = cfg%I(3) * nu(3)

    ! climb-rate PI -> vertical accel -> collective thrust (tilt-compensated).
    ! Conditional-integration anti-windup: hold vz_integ when az is already
    ! saturated and the error would drive it further out. The integrator is
    ! bounded by its CONTRIBUTION (vz_ki*vz_integ <= az_max), so raising az_max
    ! does not enlarge the windup the integrator can hold.
    v_earth = quat_rotate_body_to_inertial(st%vel, st%quat)
    hdot = -v_earth(3)                                  ! z is down, so climb = -vz_earth
    err_h = cmd%hdot_cmd - hdot
    az = clamp(cfg%vz_kp * err_h + cfg%vz_ki * law%vz_integ, -cfg%az_max, cfg%az_max)
    if (.not. ((az >=  cfg%az_max .and. err_h > 0.0) .or. &
               (az <= -cfg%az_max .and. err_h < 0.0))) then
      law%vz_integ = law%vz_integ + err_h * dt
      if (cfg%vz_ki > TOLERANCE) then
        vz_integ_lim = cfg%az_max / cfg%vz_ki
        law%vz_integ = clamp(law%vz_integ, -vz_integ_lim, vz_integ_lim)
      end if
    end if
    az = clamp(cfg%vz_kp * err_h + cfg%vz_ki * law%vz_integ, -cfg%az_max, cfg%az_max)
    cos_tilt = max(0.5, cos(phi) * cos(theta))
    T = (cfg%weight_lbf + cfg%mass_slug * az) / cos_tilt

    ! mixer: wrench -> rotor thrusts -> throttles via sqrt(f / a_thrust)
    wrench = [T, L, M, N]
    f = mixer_solve(law%mx, wrench)
    do i = 1, 4
      f(i) = clamp(f(i), 0.0, cfg%f_max)
      throttles(i) = clamp(sqrt(f(i) / cfg%a_thrust), 0.0, 1.0)
    end do

    ! finite guard: hold last good
    if (all(ieee_is_finite(throttles))) then
      law%last_good = throttles
    else
      throttles = law%last_good
    end if
  end subroutine law_step

end module control_law_m
