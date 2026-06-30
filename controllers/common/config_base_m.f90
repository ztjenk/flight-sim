! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! Shared configuration parsing for the fixed-wing controllers: the parts of the
! JSON that are identical across PID / BIREPID / DI (udp, packet_order, pilot
! input, the new flight-mode block, rate limits, gain-scheduling reference, and
! the initial control_values). Each controller's own config_m parses only its
! gains and calls load_base_config for everything here.
module config_base_m
  use json_m
  use jsonx_m
  use constants_m, only: DEG2RAD, TOLERANCE
  use atmosphere_m, only: std_atm_English
  use math_m, only: calc_dynamic_pressure
  use flight_state_m, only: packet_map_t, load_packet_order
  use pilot_cmd_m
  implicit none
  private

  public :: base_config_t, load_base_config

  type :: base_config_t
    ! UDP
    character(len=64) :: listen_host = '0.0.0.0'
    integer :: listen_port = 5001
    character(len=64) :: send_host = '127.0.0.1'
    integer :: send_port = 5002
    integer :: hud_port  = 5003
    character(len=16) :: precision = 'double'   ! 'double' (real8) | 'single' (real4)
    logical :: entity_tagged = .false.          ! prepend 4-byte int32 entity_id to controller<->physics packets (multi-vehicle routing). Must match the physics connection's entity_tagged.

    ! packet map
    type(packet_map_t) :: pmap

    ! pilot input
    logical :: pilot_enabled = .false.
    character(len=16)  :: pilot_type = 'csv'
    character(len=256) :: pilot_csv_file = ''
    integer :: pilot_port = 6000
    real    :: pilot_deadzone = 0.08

    ! gain scheduling reference
    real :: alt_ref_ft = 0.0
    real :: Vref_fps   = 0.0
    real :: Qref       = 0.0
  end type base_config_t

contains

  ! Parse the shared sections from an already-loaded JSON root (j_main) into the
  ! base config and the pilot command/mode state.
  subroutine load_base_config(j_main, bc, pm)
    type(json_value), pointer, intent(in) :: j_main
    type(base_config_t), intent(inout) :: bc
    type(pilot_cmd_t), intent(inout) :: pm

    type(json_value), pointer :: j_udp, j_pilot, j_modes, j_rate, j_gains
    character(len=:), allocatable :: str_temp
    logical :: found
    real :: rho_ref, Z_s, T_s, P_s, a_s, mu_s

    ! ---- UDP ----
    call jsonx_get(j_main, 'udp', j_udp)
    call jsonx_get(j_udp, 'listen_host', str_temp); bc%listen_host = str_temp
    call jsonx_get(j_udp, 'listen_port', bc%listen_port)
    call jsonx_get(j_udp, 'send_host', str_temp);   bc%send_host = str_temp
    call jsonx_get(j_udp, 'send_port', bc%send_port)
    call jsonx_get(j_udp, 'precision', str_temp)
    if (json_found) bc%precision = str_temp
    call jsonx_get(j_udp, 'entity_tagged', bc%entity_tagged, .false.)
    call load_packet_order(j_udp, bc%pmap)

    ! ---- pilot input ----
    call jsonx_get(j_main, 'pilot_inputs', j_pilot)
    call jsonx_get(j_pilot, 'enabled', bc%pilot_enabled)
    call jsonx_get(j_pilot, 'type', str_temp); bc%pilot_type = str_temp
    if (trim(bc%pilot_type) == 'csv') then
      call jsonx_get(j_pilot, 'csv_file', str_temp); bc%pilot_csv_file = str_temp
      print *, "Pilot input: csv mode, file = ", trim(bc%pilot_csv_file)
    else if (trim(bc%pilot_type) == 'udp') then
      call jsonx_get(j_pilot, 'listen_port', bc%pilot_port)
      call jsonx_get(j_pilot, 'deadzone', bc%pilot_deadzone)
      print *, "Pilot input: udp (gamepad) mode, port = ", bc%pilot_port
    else
      print *, "ERROR: pilot_inputs.type must be 'csv' or 'udp', got: ", trim(bc%pilot_type)
      stop
    end if

    ! ---- flight modes (priority stack + overlays) ----
    call jsonx_get(j_main, 'modes', j_modes)
    call jsonx_get(j_modes, 'initial_mode', str_temp)
    if (.not. json_found) str_temp = 'rates'
    call set_initial_mode(str_temp, pm)
    call jsonx_get(j_modes, 'velocity_hold', pm%velocity_on, .true.)
    call jsonx_get(j_modes, 'sideslip_hold', pm%beta_on, .true.)
    call jsonx_get(j_modes, 'send_port', bc%hud_port)
    if (.not. json_found) bc%hud_port = 5003

    ! ---- rate / angle stick limits ----
    call jsonx_get(j_main, 'rate_limits', j_rate)
    call jsonx_get(j_rate, 'p_cmd_max_dps', pm%p_cmd_max_dps)
    call jsonx_get(j_rate, 'q_cmd_max_dps', pm%q_cmd_max_dps)
    call jsonx_get(j_rate, 'r_cmd_max_dps', pm%r_cmd_max_dps)
    call jsonx_get(j_rate, 'phi_cmd_max_deg', pm%phi_cmd_max_deg)
    call jsonx_get(j_rate, 'theta_cmd_max_deg', pm%theta_cmd_max_deg, 30.0)
    call jsonx_get(j_rate, 'beta_cmd_max_deg', pm%beta_cmd_max_deg)

    ! ---- gain scheduling reference (Qref from Vref @ alt_ref) ----
    call jsonx_get(j_main, 'gains', j_gains)
    call jsonx_get(j_gains, 'alt_ref_ft', bc%alt_ref_ft, 0.0)
    call jsonx_get(j_gains, 'Vref_fps', bc%Vref_fps)
    if (.not. json_found) bc%Vref_fps = 0.0
    if (bc%Vref_fps > TOLERANCE) then
      call std_atm_English(bc%alt_ref_ft, Z_s, T_s, P_s, rho_ref, a_s, mu_s)
      bc%Qref = calc_dynamic_pressure(rho_ref, bc%Vref_fps)
      print '(A,F8.1,A,F8.1,A,F8.2,A)', " Gain scheduling: alt_ref =", bc%alt_ref_ft, &
            " ft, Vref =", bc%Vref_fps, " ft/s, Qref =", bc%Qref, " psf"
    else
      bc%Qref = 0.0
      print *, "Gain scheduling: disabled (Vref_fps not set or <= 0)"
    end if

    ! ---- initial commanded values (deg -> rad where applicable) ----
    call jsonx_get(j_main, 'control_values.p_cmd[dps]', pm%p_cmd, 0.0)
    call jsonx_get(j_main, 'control_values.q_cmd[dps]', pm%q_cmd, 0.0)
    call jsonx_get(j_main, 'control_values.r_cmd[dps]', pm%r_cmd, 0.0)
    pm%p_cmd = pm%p_cmd * DEG2RAD
    pm%q_cmd = pm%q_cmd * DEG2RAD
    pm%r_cmd = pm%r_cmd * DEG2RAD
    call jsonx_get(j_main, 'control_values.V_cmd[ft/s].initial', pm%V_cmd)
    call jsonx_get(j_main, 'control_values.V_cmd[ft/s].minimum', pm%V_cmd_min)
    call jsonx_get(j_main, 'control_values.V_cmd[ft/s].maximum', pm%V_cmd_max)
    call jsonx_get(j_main, 'control_values.V_cmd[ft/s].step size', pm%V_cmd_step)
    call jsonx_get(j_main, 'control_values.phi_cmd[deg]', pm%phi_cmd, 0.0)
    pm%phi_cmd = pm%phi_cmd * DEG2RAD
    call jsonx_get(j_main, 'control_values.theta_cmd[deg]', pm%theta_cmd, 0.0)
    pm%theta_cmd = pm%theta_cmd * DEG2RAD
    call jsonx_get(j_main, 'control_values.beta_cmd[deg]', pm%beta_cmd, 0.0)
    pm%beta_cmd = pm%beta_cmd * DEG2RAD
    call json_get(j_main, 'control_values.h_cmd[ft]', pm%h_cmd, found)
    if (.not. found) then
      call json_clear_exceptions()
      pm%h_cmd_needs_capture = .true.
    end if
  end subroutine load_base_config

  subroutine set_initial_mode(name, pm)
    character(len=*), intent(in) :: name
    type(pilot_cmd_t), intent(inout) :: pm
    pm%rates_on    = .false.
    pm%angles_on   = .false.
    pm%altitude_on = .false.
    select case (trim(name))
    case ('manual')
      ! all off
    case ('rates')
      pm%rates_on = .true.
    case ('angles')
      pm%rates_on = .true.; pm%angles_on = .true.
    case ('altitude')
      pm%rates_on = .true.; pm%angles_on = .true.; pm%altitude_on = .true.
    case default
      print *, "WARNING: unknown modes.initial_mode '", trim(name), "', defaulting to rates"
      pm%rates_on = .true.
    end select
    print *, "Initial flight mode: ", trim(name)
  end subroutine set_initial_mode

end module config_base_m
