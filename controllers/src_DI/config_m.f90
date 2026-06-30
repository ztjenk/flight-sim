! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! DI controller configuration: shared base + the vehicle model + DI gains.
! Rate loops are specified as pole placement (wn, zeta) -> kp=2*zeta*wn, ki=wn^2,
! because dynamic inversion makes each rate axis look like a 1/s integrator.
module config_m
  use json_m
  use jsonx_m
  use constants_m, only: DEG2RAD
  use config_base_m
  use pilot_cmd_m, only: pilot_cmd_t
  use vehicle_m, only: vehicle_t, vehicle_set
  implicit none
  private

  public :: di_config_t, controls_t, load_di_config

  type :: controls_t
    real :: da = 0.0
    real :: de = 0.0
    real :: dr = 0.0
    real :: throttle = 0.0
  end type controls_t

  type :: di_config_t
    type(base_config_t) :: base
    type(vehicle_t)     :: veh

    character(len=8) :: method = 'ndi'      ! 'ndi' | 'indi'
    logical :: use_pkt_wdot = .true.        ! INDI: take omega_dot from packet (vs finite diff)
    real :: trim_throttle = 0.0

    ! rate loops (converted from wn/zeta)
    real :: pkp=0, pki=0, pkd=0
    real :: qkp=0, qki=0, qkd=0
    real :: rkp=0, rki=0, rkd=0
    real :: nu_max(3) = [500.0, 150.0, 100.0]   ! accel limits [deg/s^2] -> rad/s^2 at load
    real :: dlim(3) = [21.5, 25.0, 30.0]        ! deflection limits [deg] -> rad at load

    ! throttle loop
    real :: thkp=0, thki=0, thkd=0

    ! outer attitude loop
    logical :: outer_enable = .true.
    real :: bw_phi = 1.3, bw_theta = 1.0, bw_beta = 0.7
    real :: erl_phi = 200.0, erl_theta = 60.0, erl_beta = 10.0   ! euler-rate limits [deg/s] -> rad/s
    logical :: turn_coord = .false., grav_relief = .true.

    ! altitude outer loop (h -> theta), used in altitude mode
    real :: alt_kp_h=0.1, alt_ki_h=0.01, alt_kd_h=0.0, alt_tau_hdot=0.5, alt_theta_max_deg=20.0

    ! numerical floors
    real :: qdyn_floor = 10.0, V_floor = 50.0
  end type di_config_t

contains

  subroutine load_di_config(filename, cfg, pm, ctrl)
    character(len=*), intent(in) :: filename
    type(di_config_t), intent(out) :: cfg
    type(pilot_cmd_t), intent(inout) :: pm
    type(controls_t), intent(out) :: ctrl

    type(json_value), pointer :: j_main, j_gains, j_outer, j_veh
    character(len=:), allocatable :: str_temp
    real :: Sw,b,cbar, Ixx,Iyy,Izz, Ixy,Ixz,Iyz, hx,hy,hz
    logical :: ok

    call jsonx_load(filename, j_main)
    call load_base_config(j_main, cfg%base, pm)

    call jsonx_get(j_main, 'method', str_temp); if (json_found) cfg%method = str_temp
    call jsonx_get(j_main, 'indi.omega_dot_source', str_temp)
    if (json_found) cfg%use_pkt_wdot = (trim(str_temp) == 'packet')
    call jsonx_get(j_main, 'trim_throttle', cfg%trim_throttle, 0.0)
    call jsonx_get(j_main, 'floors.qdyn_psf', cfg%qdyn_floor, 10.0)
    call jsonx_get(j_main, 'floors.V_fps', cfg%V_floor, 50.0)

    ! deflection + accel limits
    call jsonx_get(j_main, 'deflection_limits_deg.da', cfg%dlim(1), 21.5)
    call jsonx_get(j_main, 'deflection_limits_deg.de', cfg%dlim(2), 25.0)
    call jsonx_get(j_main, 'deflection_limits_deg.dr', cfg%dlim(3), 30.0)
    cfg%dlim = cfg%dlim * DEG2RAD
    call jsonx_get(j_main, 'accel_limits_dps2.p', cfg%nu_max(1), 500.0)
    call jsonx_get(j_main, 'accel_limits_dps2.q', cfg%nu_max(2), 150.0)
    call jsonx_get(j_main, 'accel_limits_dps2.r', cfg%nu_max(3), 100.0)
    cfg%nu_max = cfg%nu_max * DEG2RAD

    ! rate loop gains from pole placement
    call jsonx_get(j_main, 'gains', j_gains)
    call pole_gains(j_gains, 'p', cfg%pkp, cfg%pki, cfg%pkd)
    call pole_gains(j_gains, 'q', cfg%qkp, cfg%qki, cfg%qkd)
    call pole_gains(j_gains, 'r', cfg%rkp, cfg%rki, cfg%rkd)
    call jsonx_get(j_gains, 'throttle.kp', cfg%thkp, 0.02)
    call jsonx_get(j_gains, 'throttle.ki', cfg%thki, 0.005)
    call jsonx_get(j_gains, 'throttle.kd', cfg%thkd, 0.0)

    ! outer attitude loop
    call jsonx_get(j_main, 'outer_loop', j_outer)
    call jsonx_get(j_outer, 'enable', cfg%outer_enable, .true.)
    call jsonx_get(j_outer, 'gains.phi.bandwidth', cfg%bw_phi, 1.3)
    call jsonx_get(j_outer, 'gains.theta.bandwidth', cfg%bw_theta, 1.0)
    call jsonx_get(j_outer, 'gains.beta.bandwidth', cfg%bw_beta, 0.7)
    call jsonx_get(j_outer, 'euler_rate_limits_dps.phi', cfg%erl_phi, 200.0)
    call jsonx_get(j_outer, 'euler_rate_limits_dps.theta', cfg%erl_theta, 60.0)
    call jsonx_get(j_outer, 'euler_rate_limits_dps.beta', cfg%erl_beta, 10.0)
    cfg%erl_phi = cfg%erl_phi*DEG2RAD; cfg%erl_theta = cfg%erl_theta*DEG2RAD; cfg%erl_beta = cfg%erl_beta*DEG2RAD
    call jsonx_get(j_outer, 'turn_coordination', cfg%turn_coord, .false.)
    call jsonx_get(j_outer, 'gravity_relief', cfg%grav_relief, .true.)

    ! altitude loop (added vs pythonDI for altitude mode)
    call jsonx_get(j_gains, 'altitude.kp_h', cfg%alt_kp_h, 0.1)
    call jsonx_get(j_gains, 'altitude.ki_h', cfg%alt_ki_h, 0.01)
    call jsonx_get(j_gains, 'altitude.kd_h', cfg%alt_kd_h, 0.0)
    call jsonx_get(j_gains, 'altitude.tau_hdot', cfg%alt_tau_hdot, 0.5)
    call jsonx_get(j_gains, 'altitude.theta_cmd_max_deg', cfg%alt_theta_max_deg, 20.0)

    ! vehicle model
    call jsonx_get(j_main, 'vehicle', j_veh)
    call jsonx_get(j_veh, 'geometry.Sw', Sw)
    call jsonx_get(j_veh, 'geometry.b', b)
    call jsonx_get(j_veh, 'geometry.cbar', cbar)
    call jsonx_get(j_veh, 'inertia.Ixx', Ixx); call jsonx_get(j_veh, 'inertia.Iyy', Iyy)
    call jsonx_get(j_veh, 'inertia.Izz', Izz); call jsonx_get(j_veh, 'inertia.Ixy', Ixy, 0.0)
    call jsonx_get(j_veh, 'inertia.Ixz', Ixz, 0.0); call jsonx_get(j_veh, 'inertia.Iyz', Iyz, 0.0)
    call jsonx_get(j_veh, 'inertia.hx', hx, 0.0); call jsonx_get(j_veh, 'inertia.hy', hy, 0.0)
    call jsonx_get(j_veh, 'inertia.hz', hz, 0.0)
    call vehicle_set(cfg%veh, Sw, b, cbar, Ixx, Iyy, Izz, Ixy, Ixz, Iyz, hx, hy, hz, ok)
    if (.not. ok) print *, "WARNING: inertia matrix is singular; INDI will be unreliable"
    call load_aero(j_veh, cfg%veh)

    pm%da_max_deg = cfg%dlim(1) / DEG2RAD
    pm%de_max_deg = cfg%dlim(2) / DEG2RAD
    pm%dr_max_deg = cfg%dlim(3) / DEG2RAD

    print '(A,A,A,L1)', " DI method: ", trim(cfg%method), "   outer attitude loop: ", cfg%outer_enable
    ctrl = controls_t()
  end subroutine load_di_config

  ! pole placement -> PID gains: kp = 2*zeta*wn, ki = wn^2
  subroutine pole_gains(j_gains, axis, kp, ki, kd)
    type(json_value), pointer, intent(in) :: j_gains
    character(*), intent(in) :: axis
    real, intent(out) :: kp, ki, kd
    real :: wn, zeta
    call jsonx_get(j_gains, trim(axis)//'.wn', wn, 3.0)
    call jsonx_get(j_gains, trim(axis)//'.zeta', zeta, 0.7)
    call jsonx_get(j_gains, trim(axis)//'.kd', kd, 0.0)
    kp = 2.0 * zeta * wn
    ki = wn * wn
  end subroutine pole_gains

  subroutine load_aero(j_veh, veh)
    type(json_value), pointer, intent(in) :: j_veh
    type(vehicle_t), intent(inout) :: veh
    call jsonx_get(j_veh, 'aero.Clbeta', veh%Clbeta);   call jsonx_get(j_veh, 'aero.Clpbar', veh%Clpbar)
    call jsonx_get(j_veh, 'aero.Clrbar', veh%Clrbar);   call jsonx_get(j_veh, 'aero.Clarbar', veh%Clarbar)
    call jsonx_get(j_veh, 'aero.Clda', veh%Clda);       call jsonx_get(j_veh, 'aero.Cldr', veh%Cldr)
    call jsonx_get(j_veh, 'aero.Cm0', veh%Cm0);         call jsonx_get(j_veh, 'aero.Cmalpha', veh%Cmalpha)
    call jsonx_get(j_veh, 'aero.Cmqbar', veh%Cmqbar);   call jsonx_get(j_veh, 'aero.Cmde', veh%Cmde)
    call jsonx_get(j_veh, 'aero.Cnbeta', veh%Cnbeta);   call jsonx_get(j_veh, 'aero.Cnpbar', veh%Cnpbar)
    call jsonx_get(j_veh, 'aero.Cnapbar', veh%Cnapbar); call jsonx_get(j_veh, 'aero.Cnrbar', veh%Cnrbar)
    call jsonx_get(j_veh, 'aero.Cnda', veh%Cnda);       call jsonx_get(j_veh, 'aero.Cnada', veh%Cnada)
    call jsonx_get(j_veh, 'aero.Cndr', veh%Cndr)
  end subroutine load_aero

end module config_m
