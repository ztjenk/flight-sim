! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! DI controller entry point. Same shared input/mode/state wiring as the PID
! controllers; the control law is dynamic inversion (NDI default, INDI opt-in).
program main
  use iso_c_binding, only: c_int
  use config_m
  use control_law_m
  use pilot_cmd_m
  use flight_state_m
  use mode_m
  use gamepad_m
  use command_profile_m
  use udp_m
  use math_m, only: clamp
  implicit none

  type(di_config_t)       :: cfg
  type(pilot_cmd_t)       :: pm
  type(controls_t)        :: ctrl
  type(di_law_t)          :: law
  type(gamepad_t)         :: gp
  type(mode_transition_t) :: trans
  type(flight_state_t)    :: st
  type(command_profile)   :: prof
  type(profile_commands)  :: csv
  integer :: csv_iostat

  integer(c_int) :: sockfd_physics, sockfd_pad
  real, allocatable :: instate(:)
  real :: outcont(4), hud_status(16)
  real :: dt, t_prev
  integer :: step, entity_id
  logical :: first_packet, got_data
  integer :: clock_now, clock_last_packet, clock_rate
  real, parameter :: IDLE_TIMEOUT = 10.0
  character(len=512) :: filename

  call udp_initialize()
  if (command_argument_count() < 1) then
    write(*,'(A)') "ERROR: no config file given."
    write(*,'(A)') "Usage: DI <config.json>"
    stop 1
  end if
  call get_command_argument(1, filename)
  call load_di_config(trim(filename), cfg, pm, ctrl)

  allocate(instate(cfg%base%pmap%n)); instate = 0.0
  call law_init(law, cfg)

  sockfd_physics = udp_open_socket()
  if (sockfd_physics < 0) stop "ERROR: Failed to create physics socket"
  call udp_bind_socket(sockfd_physics, cfg%base%listen_port)
  call udp_set_recv_timeout(sockfd_physics, 1)
  call system_clock(count=clock_last_packet, count_rate=clock_rate)
  print *, "Physics: listening on UDP port", cfg%base%listen_port
  print *, "Physics: sending to ", trim(cfg%base%send_host), ":", cfg%base%send_port

  if (cfg%base%pilot_enabled) then
    if (trim(cfg%base%pilot_type) == 'csv') then
      call profile_load_csv(prof, trim(cfg%base%pilot_csv_file), csv_iostat)
      if (csv_iostat /= 0 .or. .not. prof%loaded) then
        print *, "ERROR: Failed to load command profile, disabling pilot input"
        cfg%base%pilot_enabled = .false.
      end if
    else if (trim(cfg%base%pilot_type) == 'udp') then
      sockfd_pad = udp_open_socket()
      if (sockfd_pad < 0) then
        print *, "WARNING: Could not create gamepad socket, manual control disabled"
        cfg%base%pilot_enabled = .false.
      else
        call udp_bind_socket(sockfd_pad, cfg%base%pilot_port)
        call udp_set_nonblocking(sockfd_pad)
        print *, "Gamepad: listening on UDP port", cfg%base%pilot_port
      end if
    end if
  else
    print *, "Pilot input: disabled in configuration"
  end if

  t_prev = -1.0; step = 0; entity_id = 1; first_packet = .true.
  print *, "=========================================="
  print *, "DI controller ready - entering main loop"
  print *, "=========================================="

  do
    if (cfg%base%entity_tagged) then
      call udp_recv_real8_latest_with_id(sockfd_physics, instate, entity_id, got_data)
    else
      call udp_recv_real8_latest(sockfd_physics, instate, got_data)
    end if
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
    call unpack_state(instate, cfg%base%pmap, st)

    if (t_prev < 0.0) then
      dt = 0.01
    else
      dt = clamp(st%t - t_prev, 1.0e-4, 0.10)
    end if
    t_prev = st%t

    if (first_packet) then
      first_packet = .false.
      call law_capture_altitude(law, pm, st)
    end if

    if (mod(step, 3000) == 0) call print_status()

    if (cfg%base%pilot_enabled) then
      if (trim(cfg%base%pilot_type) == 'csv') then
        call profile_get_commands(prof, st%t, csv)
        call mode_apply_csv(csv, pm)
      else
        call gp_recv(sockfd_pad, gp)
        call mode_handle_buttons(gp, pm, trans)
        call law_sync_bumpless(law, pm, st, trans)
        call mode_apply_sticks(gp, pm, dt)
      end if
    end if

    call law_step(law, cfg, pm, st, dt, ctrl)

    outcont = [ctrl%da, ctrl%de, ctrl%dr, ctrl%throttle]
    if (cfg%base%entity_tagged) then
      call udp_send_real8_with_id(sockfd_physics, trim(cfg%base%send_host), cfg%base%send_port, entity_id, outcont)
    else
      call udp_send_real8(sockfd_physics, trim(cfg%base%send_host), cfg%base%send_port, outcont)
    end if
    call send_hud()
  end do

  call udp_close_socket(sockfd_physics)
  if (cfg%base%pilot_enabled .and. trim(cfg%base%pilot_type) == 'udp') call udp_close_socket(sockfd_pad)
  call udp_finalize()

contains

  subroutine send_hud()
    integer :: m
    m = effective_mode(pm)
    hud_status = [ merge(1.0, 0.0, m >= MODE_RATES), &
                   merge(1.0, 0.0, m >= MODE_RATES), &
                   merge(1.0, 0.0, m >= MODE_RATES), &
                   merge(1.0, 0.0, pm%velocity_on), &
                   merge(1.0, 0.0, m >= MODE_ANGLES), &
                   merge(1.0, 0.0, m >= MODE_ANGLES), &
                   merge(1.0, 0.0, pm%beta_on .and. m >= MODE_ANGLES), &
                   merge(1.0, 0.0, m == MODE_ALTITUDE), &
                   pm%p_cmd, pm%q_cmd, pm%r_cmd, pm%V_cmd, &
                   pm%phi_cmd, pm%theta_cmd, pm%beta_cmd, pm%h_cmd ]
    call udp_send_real8(sockfd_physics, trim(cfg%base%send_host), cfg%base%hud_port, hud_status)
  end subroutine send_hud

  subroutine print_status()
    print *, "============ DI STATUS ============"
    write(*,'(A,A)')  "  flight mode:  ", trim(mode_name(pm))
    write(*,'(A,A)')  "  inversion:    ", trim(cfg%method)
    write(*,'(A,L1)') "  velocity hold:", pm%velocity_on
    print *, "==================================="
  end subroutine print_status

end program main
