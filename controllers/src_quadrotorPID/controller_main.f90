! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! Quadrotor controller entry point. Uses single-precision (float32) UDP packets to
! match the quad physics example: receives a 21-field ekf_both packet and sends 4
! rotor throttles. Dedicated stick mapping (no rates/angles/altitude modes):
!   left stick Y  -> climb rate     left stick X  -> yaw rate
!   right stick Y -> pitch angle    right stick X -> roll angle
program main
  use iso_c_binding, only: c_int, c_float
  use config_m
  use control_law_m
  use gamepad_m
  use udp_m
  use math_m, only: clamp
  implicit none

  type(quad_config_t) :: cfg
  type(quad_law_t)    :: law
  type(quad_state_t)  :: st
  type(quad_cmd_t)    :: cmd
  type(gamepad_t)     :: gp

  integer(c_int) :: sockfd_physics, sockfd_pad
  real(c_float)  :: rxbuf(21), txbuf(4)
  real :: throttles(4), dt, t_prev
  real :: phi_tgt, theta_tgt, dtilt_max
  integer :: step
  logical :: got_data
  integer :: clock_now, clock_last_packet, clock_rate
  real, parameter :: IDLE_TIMEOUT = 10.0
  character(len=512) :: filename

  call udp_initialize()
  if (command_argument_count() < 1) then
    write(*,'(A)') "ERROR: no config file given."
    write(*,'(A)') "Usage: quadPID <config.json>"
    stop 1
  end if
  call get_command_argument(1, filename)
  call load_quad_config(trim(filename), cfg)
  call law_init(law, cfg)

  sockfd_physics = udp_open_socket()
  if (sockfd_physics < 0) stop "ERROR: Failed to create physics socket"
  call udp_bind_socket(sockfd_physics, cfg%listen_port)
  call udp_set_recv_timeout(sockfd_physics, 1)
  call system_clock(count=clock_last_packet, count_rate=clock_rate)
  print *, "Quad physics: listening on UDP port", cfg%listen_port
  print *, "Quad physics: sending rotor cmds to ", trim(cfg%send_host), ":", cfg%send_port

  if (cfg%pilot_enabled) then
    sockfd_pad = udp_open_socket()
    if (sockfd_pad < 0) then
      print *, "WARNING: no gamepad socket; manual control disabled"
      cfg%pilot_enabled = .false.
    else
      call udp_bind_socket(sockfd_pad, cfg%pilot_port)
      call udp_set_nonblocking(sockfd_pad)
      print *, "Gamepad: listening on UDP port", cfg%pilot_port
    end if
  end if

  t_prev = -1.0; step = 0
  print *, "=========================================="
  print *, "Quadrotor PID controller (PROVISIONAL law)"
  print *, "ready - entering main loop"
  print *, "=========================================="

  do
    call udp_recv_real4_latest(sockfd_physics, rxbuf, got_data)
    if (got_data) then
      call system_clock(count=clock_last_packet)
    else
      call system_clock(count=clock_now)
      if (real(clock_now - clock_last_packet) / real(clock_rate) > IDLE_TIMEOUT) then
        print *, ""; print *, "No UDP packets for 10 seconds. Shutting down."; exit
      end if
      cycle
    end if

    step = step + 1
    call decode(rxbuf, st)

    if (t_prev < 0.0) then
      dt = 0.002
    else
      dt = clamp(st%t - t_prev, 1.0e-4, 0.05)
    end if
    t_prev = st%t

    ! pilot sticks (quad mapping)
    if (cfg%pilot_enabled) then
      call gp_recv(sockfd_pad, gp)
      cmd%hdot_cmd     =  (gp%throttle - 0.5) * 2.0 * cfg%hdot_max  ! left stick Y
      cmd%yaw_rate_cmd = -gp%yaw   * cfg%yaw_rate_max               ! left stick X (negated)

      ! bank/pitch commands are slew-rate limited so releasing the stick eases
      ! the vehicle back to level instead of snapping the setpoint to zero.
      phi_tgt   = -gp%roll  * cfg%tilt_max                          ! right stick X (negated)
      theta_tgt = -gp%pitch * cfg%tilt_max                         ! right stick Y (negated)
      dtilt_max = cfg%tilt_rate_max * dt
      cmd%phi_cmd   = cmd%phi_cmd   + clamp(phi_tgt   - cmd%phi_cmd,   -dtilt_max, dtilt_max)
      cmd%theta_cmd = cmd%theta_cmd + clamp(theta_tgt - cmd%theta_cmd, -dtilt_max, dtilt_max)
    end if

    call law_step(law, cfg, st, cmd, dt, throttles)

    txbuf = real(throttles, c_float)
    call udp_send_real4(sockfd_physics, trim(cfg%send_host), cfg%send_port, txbuf)

    if (mod(step, 3000) == 0) &
      print '(A,4F6.3)', " rotor throttles: ", throttles
  end do

  call udp_close_socket(sockfd_physics)
  if (cfg%pilot_enabled) call udp_close_socket(sockfd_pad)
  call udp_finalize()

contains

  ! decode ekf_both packet (21 float32) into the quad state
  subroutine decode(b, s)
    real(c_float), intent(in) :: b(21)
    type(quad_state_t), intent(inout) :: s
    s%t = real(b(1))
    s%vel = real(b(2:4))
    s%omega = real(b(5:7))
    ! b(8:10) = earth position (unused by this law)
    s%quat = real(b(11:14))
    s%rotor_act = real(b(15:18))
    s%omega_dot = real(b(19:21))
  end subroutine decode

end program main
