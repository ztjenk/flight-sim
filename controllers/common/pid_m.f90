! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! Shared PID + cascade controller library used by all Fortran controllers.
! (Formerly controller_m.f90; renamed to pid_m and made controller-agnostic.)
! pid_step accepts an optional gain_factor multiplier so effectiveness-scheduled
! laws (e.g. BIRE) can reuse the same block without a separate copy.
module pid_m
  use constants_m, only: DEG2RAD, PI, TOLERANCE
  use math_m, only: clamp
  implicit none
  private

  public :: pid_ctrl
  public :: pid_init, pid_step, pid_reset, pid_reset_to
  public :: cascade_ctrl, cascade_init, cascade_step, cascade_reset
  public :: clamp
  ! pid controller type
  ! used for: p, q, r, throttle
  type :: pid_ctrl
    real :: kp = 0.0              ! proportional gain (reference, tuned at Vref)
    real :: ki = 0.0              ! integral gain
    real :: kd = 0.0              ! derivative gain
    real :: Qref = 0.0            ! reference dynamic pressure for gain scheduling [psf] (0 = no scheduling)
    real :: tau_d = 0.0           ! derivative low-pass filter time constant [s] (0 = unfiltered)

    ! output limits
    real :: out_min = -1.0        ! minimum output
    real :: out_max =  1.0        ! maximum output

    real :: integ = 0.0           ! integrator accumulator (output units, clamped for anti-windup)
    real :: prev_err = 0.0        ! previous error (for derivative on error)
    real :: d_filt = 0.0          ! filtered derivative
    real :: last_out = 0.0        ! previous output
    logical :: first = .true.     ! first call flag to avoid derivative spike
  end type pid_ctrl

  ! cascade controller type (PID with anti-windup and measurement filter)
  ! used for: bank (phi -> p_cmd), pitch (theta -> q_cmd), sideslip (beta -> r_cmd),
  !           altitude outer (h -> theta_cmd), altitude inner (theta -> q_cmd)
  type :: cascade_ctrl
    real :: kp = 0.0              ! proportional gain
    real :: ki = 0.0              ! integral gain
    real :: kd = 0.0              ! derivative gain
    real :: tau_d = 0.0           ! derivative low-pass filter time constant [s] (0 = unfiltered)
    real :: integ = 0.0           ! integrator accumulator
    real :: prev_err = 0.0        ! previous error (for derivative on error)
    real :: d_filt = 0.0          ! filtered derivative
    real :: out_max = 1.0         ! symmetric output limit (+-out_max)
    real :: tau_meas = 0.0        ! measurement filter time constant [s] (0 = no filter)
    real :: meas_filt = 0.0       ! filtered measurement state
    logical :: first = .true.     ! first call flag
  end type cascade_ctrl

contains

  ! initialize pid
  subroutine pid_init(pc, kp, ki, kd, out_min, out_max, Qref, tau_d)
    type(pid_ctrl), intent(inout) :: pc
    real, intent(in) :: kp, ki, kd
    real, intent(in), optional :: out_min, out_max, Qref, tau_d

    pc%kp = kp
    pc%ki = ki
    pc%kd = kd

    if (present(out_min))  pc%out_min = out_min
    if (present(out_max))  pc%out_max = out_max
    if (present(Qref))     pc%Qref    = Qref
    if (present(tau_d))    pc%tau_d   = tau_d

    call pid_reset(pc)
  end subroutine pid_init

  subroutine pid_step(pc, dt, cmd, meas, Qbar, output, gain_factor)
    type(pid_ctrl), intent(inout) :: pc
    real, intent(in)  :: dt
    real, intent(in)  :: cmd          ! commanded value
    real, intent(in)  :: meas         ! current measurement
    real, intent(in)  :: Qbar         ! current dynamic pressure [psf]
    real, intent(out) :: output       ! controller output
    real, intent(in), optional :: gain_factor  ! effectiveness multiplier (e.g. BIRE); default 1.0

    real :: err, raw_deriv, alpha
    real :: Q_scale, gf
    real :: kp_s, ki_s, kd_s
    real :: u_pd

    gf = 1.0
    if (present(gain_factor)) gf = gain_factor

    ! dynamic pressure gain scheduling: gain = Kref * (Qref / Q)
    if (pc%Qref > 0.0 .and. Qbar > 1.0) then
      Q_scale = pc%Qref / Qbar
    else
      Q_scale = 1.0
    end if

    ! scaled gains
    kp_s = pc%kp * Q_scale * gf
    ki_s = pc%ki * Q_scale * gf
    kd_s = pc%kd * Q_scale * gf

    ! error
    err = cmd - meas

    ! initialize on first call to avoid derivative spike
    if (pc%first) then
      pc%prev_err = err
      pc%d_filt = 0.0
      pc%first = .false.
    end if

    ! derivative on error with optional low-pass filter
    raw_deriv = (err - pc%prev_err) / max(dt, TOLERANCE)

    if (pc%tau_d > 0.0) then
      alpha = dt / (pc%tau_d + dt)
      pc%d_filt = alpha * raw_deriv + (1.0 - alpha) * pc%d_filt
    else
      pc%d_filt = raw_deriv
    end if

    ! PD contribution
    u_pd = kp_s * err + kd_s * pc%d_filt

    ! integrator with conditional-integration anti-windup: hold the integrator
    ! whenever the output is already saturated AND the error would drive it
    ! further into saturation; otherwise integrate (so it can always unwind).
    ! Behaviour is identical to a plain integrator while the output is unsaturated.
    if (abs(ki_s) > TOLERANCE) then
      output = clamp(u_pd + pc%integ, pc%out_min, pc%out_max)
      if (.not. ((output >= pc%out_max .and. err > 0.0) .or. &
                 (output <= pc%out_min .and. err < 0.0))) then
        pc%integ = pc%integ + ki_s * 0.5 * (err + pc%prev_err) * dt
        pc%integ = clamp(pc%integ, pc%out_min, pc%out_max)
      end if
      output = clamp(u_pd + pc%integ, pc%out_min, pc%out_max)
    else
      output = clamp(u_pd, pc%out_min, pc%out_max)
    end if

    pc%prev_err = err
    pc%last_out = output
  end subroutine pid_step

  subroutine pid_reset(pc)
    type(pid_ctrl), intent(inout) :: pc
    pc%integ = 0.0
    pc%prev_err = 0.0
    pc%d_filt = 0.0
    pc%last_out = 0.0
    pc%first = .true.
  end subroutine pid_reset

  ! reset pid and sync to current output for bumpless transfer
  subroutine pid_reset_to(pc, output)
    type(pid_ctrl), intent(inout) :: pc
    real, intent(in) :: output
    call pid_reset(pc)
    pc%last_out = output
  end subroutine pid_reset_to

  ! initialize cascade controller
  subroutine cascade_init(cc, kp, ki, kd, out_max, tau_meas, tau_d)
    type(cascade_ctrl), intent(inout) :: cc
    real, intent(in), optional :: kp, ki, kd, out_max, tau_meas, tau_d

    if (present(kp))       cc%kp = kp
    if (present(ki))       cc%ki = ki
    if (present(kd))       cc%kd = kd
    if (present(out_max))  cc%out_max = out_max
    if (present(tau_meas)) cc%tau_meas = tau_meas
    if (present(tau_d))    cc%tau_d = tau_d

    call cascade_reset(cc)
  end subroutine cascade_init

  ! run one step of the cascade controller
  ! PID with anti-windup, optional measurement filter, output saturation
  subroutine cascade_step(cc, dt, cmd, meas, out)
    type(cascade_ctrl), intent(inout) :: cc
    real, intent(in)  :: dt
    real, intent(in)  :: cmd          ! commanded value
    real, intent(in)  :: meas         ! raw measurement
    real, intent(out) :: out          ! controller output

    real :: meas_use, err, u_pd, alpha, raw_deriv, alpha_d

    ! initialize filter on first call
    if (cc%first) then
      cc%meas_filt = meas
      cc%first = .false.
    end if

    ! optional measurement low-pass filter
    if (cc%tau_meas > 0.0) then
      alpha = dt / (cc%tau_meas + dt)
      cc%meas_filt = alpha * meas + (1.0 - alpha) * cc%meas_filt
      meas_use = cc%meas_filt
    else
      meas_use = meas
    end if

    ! error
    err = cmd - meas_use

    ! initialize derivative state on first error to avoid spike
    if (abs(cc%prev_err) < TOLERANCE .and. abs(cc%d_filt) < TOLERANCE &
        .and. abs(cc%integ) < TOLERANCE) then
      cc%prev_err = err
    end if

    ! derivative on error with optional low-pass filter
    raw_deriv = (err - cc%prev_err) / max(dt, TOLERANCE)
    if (cc%tau_d > 0.0) then
      alpha_d = dt / (cc%tau_d + dt)
      cc%d_filt = alpha_d * raw_deriv + (1.0 - alpha_d) * cc%d_filt
    else
      cc%d_filt = raw_deriv
    end if

    ! PD contribution
    u_pd = cc%kp * err + cc%kd * cc%d_filt

    ! integrator with anti-windup: clamp integrator to output range
    cc%integ = cc%integ + cc%ki * err * dt
    cc%integ = clamp(cc%integ, -cc%out_max, cc%out_max)

    ! output with saturation
    out = clamp(u_pd + cc%integ, -cc%out_max, cc%out_max)

    cc%prev_err = err
  end subroutine cascade_step

  subroutine cascade_reset(cc)
    type(cascade_ctrl), intent(inout) :: cc
    cc%integ = 0.0
    cc%prev_err = 0.0
    cc%d_filt = 0.0
    cc%meas_filt = 0.0
    cc%first = .true.
  end subroutine cascade_reset

end module pid_m
