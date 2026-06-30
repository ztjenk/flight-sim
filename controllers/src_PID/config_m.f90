! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! PID controller configuration: the shared base (udp/pilot/modes/limits/control
! values, parsed by config_base_m) plus the PID-specific gains. Command values
! and stick limits live on the pilot_cmd_t; only gains live here.
module config_m
  use json_m
  use jsonx_m
  use constants_m, only: DEG2RAD
  use config_base_m
  use pilot_cmd_m, only: pilot_cmd_t
  implicit none
  private

  public :: pid_config_t, controls_t, load_pid_config

  type :: controls_t
    real :: da = 0.0
    real :: de = 0.0
    real :: dr = 0.0
    real :: throttle = 0.0
  end type controls_t

  type :: pid_config_t
    type(base_config_t) :: base

    ! inner PID gains + deflection limits
    real :: pkp = 0.0, pki = 0.0, pkd = 0.0, ptau_d = 0.0
    real :: da_min_deg = -30.0, da_max_deg = 30.0
    real :: qkp = 0.0, qki = 0.0, qkd = 0.0, qtau_d = 0.0
    real :: de_min_deg = -30.0, de_max_deg = 30.0
    real :: rkp = 0.0, rki = 0.0, rkd = 0.0, rtau_d = 0.0
    real :: dr_min_deg = -30.0, dr_max_deg = 30.0
    real :: thkp = 0.0, thki = 0.0, thkd = 0.0, thtau_d = 0.0
    real :: th_min = 0.0, th_max = 1.0

    ! bank outer loop (phi -> p_cmd)
    real :: bkp = 2.0, bki = 0.09, bkd = 0.0, btau_d = 0.0
    ! pitch-attitude loop (theta -> q_cmd), used in angles and altitude modes
    real :: tkp = 2.0, tki = 0.1, tkd = 0.0, ttau_d = 0.0
    ! sideslip loop (beta -> r_cmd)
    real :: sskp = 1.0, sski = 0.1, sskd = 0.0, sstau_d = 0.0, ss_tau_beta = 0.5
    ! altitude outer loop (h -> theta_cmd)
    real :: alt_kp_h = 0.1, alt_ki_h = 0.01, alt_kd_h = 0.0, alt_tau_hdot = 0.5
    real :: alt_theta_max_deg = 20.0
  end type pid_config_t

contains

  subroutine load_pid_config(filename, cfg, pm, ctrl)
    character(len=*), intent(in) :: filename
    type(pid_config_t), intent(out) :: cfg
    type(pilot_cmd_t), intent(inout) :: pm
    type(controls_t), intent(out) :: ctrl

    type(json_value), pointer :: j_main, j_gains

    call jsonx_load(filename, j_main)
    call load_base_config(j_main, cfg%base, pm)

    call jsonx_get(j_main, 'gains', j_gains)

    ! inner loops
    call load_pid_block(j_gains, 'p', cfg%pkp, cfg%pki, cfg%pkd, cfg%ptau_d)
    call load_pid_block(j_gains, 'q', cfg%qkp, cfg%qki, cfg%qkd, cfg%qtau_d)
    call load_pid_block(j_gains, 'r', cfg%rkp, cfg%rki, cfg%rkd, cfg%rtau_d)
    call load_pid_block(j_gains, 'throttle', cfg%thkp, cfg%thki, cfg%thkd, cfg%thtau_d)

    call jsonx_get(j_gains, 'p.da_min_deg', cfg%da_min_deg, -30.0)
    call jsonx_get(j_gains, 'p.da_max_deg', cfg%da_max_deg,  30.0)
    call jsonx_get(j_gains, 'q.de_min_deg', cfg%de_min_deg, -30.0)
    call jsonx_get(j_gains, 'q.de_max_deg', cfg%de_max_deg,  30.0)
    call jsonx_get(j_gains, 'r.dr_min_deg', cfg%dr_min_deg, -30.0)
    call jsonx_get(j_gains, 'r.dr_max_deg', cfg%dr_max_deg,  30.0)
    call jsonx_get(j_gains, 'throttle.th_min', cfg%th_min, 0.0)
    call jsonx_get(j_gains, 'throttle.th_max', cfg%th_max, 1.0)

    ! outer / mid loops
    call jsonx_get(j_gains, 'bank.kp', cfg%bkp, 2.0)
    call jsonx_get(j_gains, 'bank.ki', cfg%bki, 0.09)
    call jsonx_get(j_gains, 'bank.kd', cfg%bkd, 0.0)
    call jsonx_get(j_gains, 'bank.tau_d', cfg%btau_d, 0.0)

    ! pitch-attitude gains; fall back to legacy altitude.kp_theta names if present
    call jsonx_get(j_gains, 'pitch.kp', cfg%tkp, 2.0)
    call jsonx_get(j_gains, 'pitch.ki', cfg%tki, 0.1)
    call jsonx_get(j_gains, 'pitch.kd', cfg%tkd, 0.0)
    call jsonx_get(j_gains, 'pitch.tau_d', cfg%ttau_d, 0.0)

    call jsonx_get(j_gains, 'sideslip.kp', cfg%sskp, 1.0)
    call jsonx_get(j_gains, 'sideslip.ki', cfg%sski, 0.1)
    call jsonx_get(j_gains, 'sideslip.kd', cfg%sskd, 0.0)
    call jsonx_get(j_gains, 'sideslip.tau_d', cfg%sstau_d, 0.0)
    call jsonx_get(j_gains, 'sideslip.tau_beta', cfg%ss_tau_beta, 0.5)

    call jsonx_get(j_gains, 'altitude.kp_h', cfg%alt_kp_h, 0.1)
    call jsonx_get(j_gains, 'altitude.ki_h', cfg%alt_ki_h, 0.01)
    call jsonx_get(j_gains, 'altitude.kd_h', cfg%alt_kd_h, 0.0)
    call jsonx_get(j_gains, 'altitude.tau_hdot', cfg%alt_tau_hdot, 0.5)
    call jsonx_get(j_gains, 'altitude.theta_cmd_max_deg', cfg%alt_theta_max_deg, 20.0)

    ! manual-mode surface authority = deflection limits
    pm%da_max_deg = cfg%da_max_deg
    pm%de_max_deg = cfg%de_max_deg
    pm%dr_max_deg = cfg%dr_max_deg

    ctrl = controls_t()
  end subroutine load_pid_config

  subroutine load_pid_block(j_gains, prefix, kp, ki, kd, tau_d)
    type(json_value), pointer, intent(in) :: j_gains
    character(*), intent(in) :: prefix
    real, intent(out) :: kp, ki, kd, tau_d
    call jsonx_get(j_gains, trim(prefix)//'.kp', kp, 0.0)
    call jsonx_get(j_gains, trim(prefix)//'.ki', ki, 0.0)
    call jsonx_get(j_gains, trim(prefix)//'.kd', kd, 0.0)
    call jsonx_get(j_gains, trim(prefix)//'.tau_d', tau_d, 0.0)
  end subroutine load_pid_block

end module config_m
