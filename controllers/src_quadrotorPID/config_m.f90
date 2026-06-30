! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! Quadrotor controller configuration (standalone — the quad uses single-precision
! float32 packets and its own stick mapping, so it does not share config_base_m or
! the fixed-wing mode system). Geometry/inertia from Phillips App. C.4.
!
! NOTE: the control law this configures is PROVISIONAL (see control_law_m) and the
! a_thrust / kappa / gains need validation against the sim — revisit before relying on it.
module config_m
  use json_m
  use jsonx_m
  use constants_m, only: DEG2RAD
  implicit none
  private
  public :: quad_config_t, load_quad_config

  type :: quad_config_t
    ! UDP (float32)
    character(len=64) :: listen_host = '0.0.0.0'
    integer :: listen_port = 5001
    character(len=64) :: send_host = '127.0.0.1'
    integer :: send_port = 5002
    integer :: pilot_port = 6000
    real :: deadzone = 0.08
    logical :: pilot_enabled = .true.

    ! mass / inertia
    real :: weight_lbf = 5.0          ! W
    real :: mass_slug  = 0.0          ! derived = W / g
    real :: I(3) = [0.0231, 0.0231, 0.0392]

    ! rotor geometry (X-quad): positions, spin (+1 CCW / -1 CW), yaw-torque ratio
    real :: rotor_x(4) = [ 1.0, -1.0, -1.0,  1.0]
    real :: rotor_y(4) = [ 1.0,  1.0, -1.0, -1.0]
    real :: spin(4)    = [ 1.0, -1.0,  1.0, -1.0]
    real :: kappa = 0.05

    ! thrust map: f = a_thrust * throttle^2  (per rotor), capped at f_max
    real :: a_thrust = 5.907          ! tuned so 4*a*0.46^2 = 5 lbf hover
    real :: f_max = 4.0

    ! gains (PROVISIONAL)
    real :: k_att_phi = 6.0, k_att_theta = 6.0      ! attitude P -> rate cmd [1/s]
    real :: rkp_p = 8.0, rki_p = 2.0, rkd_p = 0.2   ! rate PID -> angular accel
    real :: rkp_q = 8.0, rki_q = 2.0, rkd_q = 0.2
    real :: rkp_r = 4.0, rki_r = 1.0, rkd_r = 0.1
    real :: nu_max = 60.0                            ! angular-accel clamp [rad/s^2]
    real :: vz_kp = 2.5, vz_ki = 1.5, az_max = 16.0  ! climb-rate PI -> vertical accel [ft/s^2]

    ! stick limits
    real :: hdot_max = 20.0           ! ft/s
    real :: yaw_rate_max = 1.0        ! rad/s
    real :: tilt_max = 0.4363         ! rad (25 deg) — right-stick -> bank/pitch
    real :: tilt_rate_max = 1.0472    ! rad/s (60 deg/s) — slew limit on bank/pitch cmd
    real :: pqr_max = 4.0             ! rad/s rate command clamp
  end type quad_config_t

contains

  subroutine load_quad_config(filename, cfg)
    character(len=*), intent(in) :: filename
    type(quad_config_t), intent(out) :: cfg
    type(json_value), pointer :: j_main, j_udp, j_pilot, j_geom, j_gains
    character(len=:), allocatable :: s
    real, parameter :: G_FT = 32.174049

    call jsonx_load(filename, j_main)

    call jsonx_get(j_main, 'udp', j_udp)
    call jsonx_get(j_udp, 'listen_host', s); cfg%listen_host = s
    call jsonx_get(j_udp, 'listen_port', cfg%listen_port)
    call jsonx_get(j_udp, 'send_host', s); cfg%send_host = s
    call jsonx_get(j_udp, 'send_port', cfg%send_port)

    call jsonx_get(j_main, 'pilot_inputs', j_pilot)
    call jsonx_get(j_pilot, 'enabled', cfg%pilot_enabled, .true.)
    call jsonx_get(j_pilot, 'listen_port', cfg%pilot_port, 6000)
    call jsonx_get(j_pilot, 'deadzone', cfg%deadzone, 0.08)

    call jsonx_get(j_main, 'vehicle', j_geom)
    call jsonx_get(j_geom, 'weight_lbf', cfg%weight_lbf, 5.0)
    call jsonx_get(j_geom, 'Ixx', cfg%I(1), 0.0231)
    call jsonx_get(j_geom, 'Iyy', cfg%I(2), 0.0231)
    call jsonx_get(j_geom, 'Izz', cfg%I(3), 0.0392)
    call jsonx_get(j_geom, 'kappa', cfg%kappa, 0.05)
    call jsonx_get(j_geom, 'a_thrust', cfg%a_thrust, 5.907)
    call jsonx_get(j_geom, 'f_max', cfg%f_max, 4.0)
    call jsonx_get(j_geom, 'arm_ft', cfg%rotor_x(1), 1.0)   ! optional uniform arm; else defaults used
    cfg%mass_slug = cfg%weight_lbf / G_FT

    call jsonx_get(j_main, 'gains', j_gains)
    call jsonx_get(j_gains, 'att.k_phi', cfg%k_att_phi, 6.0)
    call jsonx_get(j_gains, 'att.k_theta', cfg%k_att_theta, 6.0)
    call jsonx_get(j_gains, 'rate.p.kp', cfg%rkp_p, 8.0)
    call jsonx_get(j_gains, 'rate.p.ki', cfg%rki_p, 2.0)
    call jsonx_get(j_gains, 'rate.p.kd', cfg%rkd_p, 0.2)
    call jsonx_get(j_gains, 'rate.q.kp', cfg%rkp_q, 8.0)
    call jsonx_get(j_gains, 'rate.q.ki', cfg%rki_q, 2.0)
    call jsonx_get(j_gains, 'rate.q.kd', cfg%rkd_q, 0.2)
    call jsonx_get(j_gains, 'rate.r.kp', cfg%rkp_r, 4.0)
    call jsonx_get(j_gains, 'rate.r.ki', cfg%rki_r, 1.0)
    call jsonx_get(j_gains, 'rate.r.kd', cfg%rkd_r, 0.1)
    call jsonx_get(j_gains, 'nu_max', cfg%nu_max, 60.0)
    call jsonx_get(j_gains, 'climb.kp', cfg%vz_kp, 2.5)
    call jsonx_get(j_gains, 'climb.ki', cfg%vz_ki, 1.5)
    call jsonx_get(j_gains, 'climb.az_max', cfg%az_max, 16.0)

    call jsonx_get(j_main, 'stick_limits.hdot_max_fps', cfg%hdot_max, 20.0)
    call jsonx_get(j_main, 'stick_limits.yaw_rate_max_dps', cfg%yaw_rate_max, 57.3)
    cfg%yaw_rate_max = cfg%yaw_rate_max * DEG2RAD
    call jsonx_get(j_main, 'stick_limits.tilt_max_deg', cfg%tilt_max, 25.0)
    cfg%tilt_max = cfg%tilt_max * DEG2RAD
    call jsonx_get(j_main, 'stick_limits.tilt_rate_max_dps', cfg%tilt_rate_max, 60.0)
    cfg%tilt_rate_max = cfg%tilt_rate_max * DEG2RAD
  end subroutine load_quad_config

end module config_m
