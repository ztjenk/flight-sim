! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! Reads scripted command profiles from a CSV when pilot input type is "csv".
! Self-contained (no controller-specific deps) so it lives in common/.
! CSV columns: time_s,p_cmd_dps,q_cmd_dps,r_cmd_dps,V_cmd_fps,phi_cmd_deg,h_cmd_ft,beta_cmd_deg[,theta_cmd_deg]
! theta_cmd_deg is optional (defaults 0) for backward compatibility.
module command_profile_m
  implicit none
  private

  ! maximum number of data points in a command profile
  integer, parameter :: MAX_POINTS = 10000

  ! command profile type stores time series data for all commands
  type, public :: command_profile
    integer :: n_points = 0                    ! number of data points loaded
    real :: time_s(MAX_POINTS)
    real :: p_cmd_dps(MAX_POINTS)
    real :: q_cmd_dps(MAX_POINTS)
    real :: r_cmd_dps(MAX_POINTS)
    real :: V_cmd_fps(MAX_POINTS)
    real :: phi_cmd_deg(MAX_POINTS)
    real :: theta_cmd_deg(MAX_POINTS)          ! pitch-attitude command (angles mode)
    real :: h_cmd_ft(MAX_POINTS)
    real :: beta_cmd_deg(MAX_POINTS)           ! sideslip command
    logical :: loaded = .false.                ! profile has been loaded flag
    real :: start_time = -1.0                  ! simulation time when profile started
  end type command_profile

  type, public :: profile_commands
    real :: p_cmd_dps    = 0.0
    real :: q_cmd_dps    = 0.0
    real :: r_cmd_dps    = 0.0
    real :: V_cmd_fps    = 0.0
    real :: phi_cmd_deg  = 0.0
    real :: theta_cmd_deg= 0.0
    real :: h_cmd_ft     = -1.0
    real :: beta_cmd_deg = 0.0                 ! sideslip command (0 = coordinated flight)
  end type profile_commands

  public :: profile_load_csv
  public :: profile_get_commands
  public :: profile_reset_start_time

contains

  ! lines starting with # are comments; the header line (contains "time") is skipped
  subroutine profile_load_csv(prof, filename, iostat)
    type(command_profile), intent(inout) :: prof
    character(len=*), intent(in) :: filename
    integer, intent(out) :: iostat

    integer :: unit_num, i
    character(len=512) :: line
    real :: t, p, q, r, V, phi, h, beta, theta

    open(newunit=unit_num, file=filename, status='old', action='read', iostat=iostat)
    if (iostat /= 0) then
      print *, "ERROR: Cannot open command profile file: ", trim(filename)
      return
    end if

    prof%n_points = 0
    prof%loaded = .false.
    prof%start_time = -1.0

    ! read data lines
    do
      read(unit_num, '(A)', iostat=iostat) line
      if (iostat /= 0) exit                    ! end of file

      if (len_trim(line) == 0) cycle           ! skip blank lines
      if (line(1:1) == '#') cycle              ! skip comment lines
      if (index(line, 'time') > 0) cycle       ! skip header line

      ! parse data row. theta is optional; default to 0 if absent.
      theta = 0.0
      beta  = 0.0
      read(line, *, iostat=iostat) t, p, q, r, V, phi, h, beta, theta
      if (iostat /= 0) then
        theta = 0.0
        read(line, *, iostat=iostat) t, p, q, r, V, phi, h, beta   ! without theta
        if (iostat /= 0) then
          beta = 0.0
          read(line, *, iostat=iostat) t, p, q, r, V, phi, h       ! oldest format
          if (iostat /= 0) then
            print *, "WARNING: Could not parse line: ", trim(line)
            iostat = 0  ! Continue reading
            cycle
          end if
        end if
      end if

      ! store data point
      prof%n_points = prof%n_points + 1
      if (prof%n_points > MAX_POINTS) then
        print *, "WARNING: Command profile exceeds maximum points (", MAX_POINTS, ")"
        prof%n_points = MAX_POINTS
        exit
      end if

      i = prof%n_points
      prof%time_s(i)        = t
      prof%p_cmd_dps(i)     = p
      prof%q_cmd_dps(i)     = q
      prof%r_cmd_dps(i)     = r
      prof%V_cmd_fps(i)     = V
      prof%phi_cmd_deg(i)   = phi
      prof%theta_cmd_deg(i) = theta
      prof%h_cmd_ft(i)      = h
      prof%beta_cmd_deg(i)  = beta
    end do

    close(unit_num)
    iostat = 0

    if (prof%n_points > 0) then
      prof%loaded = .true.
      print '(A,I0,A)', " Command profile loaded: ", prof%n_points, " data points"
      print '(A,F8.2,A,F8.2,A)', "   Time range: ", prof%time_s(1), " to ", &
            prof%time_s(prof%n_points), " seconds"
    else
      print *, "WARNING: No data points found in command profile"
    end if

  end subroutine profile_load_csv

  ! reset the profile start time (call when you want the profile to restart)
  subroutine profile_reset_start_time(prof)
    type(command_profile), intent(inout) :: prof
    prof%start_time = -1.0
  end subroutine profile_reset_start_time

  ! get interpolated commands at a given simulation time
  ! on first call, captures sim_time as the profile start time
  subroutine profile_get_commands(prof, sim_time, cmds)
    type(command_profile), intent(inout) :: prof
    real, intent(in) :: sim_time              ! current simulation time
    type(profile_commands), intent(out) :: cmds

    real :: t_profile                         ! time within profile
    integer :: i, i_lo, i_hi
    real :: t_lo, t_hi, alpha

    cmds = profile_commands()

    if (.not. prof%loaded .or. prof%n_points == 0) return

    ! capture start time on first call
    if (prof%start_time < 0.0) then
      prof%start_time = sim_time
      print '(A,F10.3,A)', " Command profile started at sim time ", sim_time, " s"
    end if

    t_profile = sim_time - prof%start_time

    ! before profile start: return first values
    if (t_profile <= prof%time_s(1)) then
      call copy_point(prof, 1, cmds)
      return
    end if

    ! after profile end: hold last values
    if (t_profile >= prof%time_s(prof%n_points)) then
      call copy_point(prof, prof%n_points, cmds)
      return
    end if

    ! find bracketing indices for interpolation
    i_lo = 1
    i_hi = prof%n_points
    do i = 1, prof%n_points - 1
      if (t_profile >= prof%time_s(i) .and. t_profile < prof%time_s(i+1)) then
        i_lo = i
        i_hi = i + 1
        exit
      end if
    end do

    t_lo = prof%time_s(i_lo)
    t_hi = prof%time_s(i_hi)
    if (abs(t_hi - t_lo) < 1.0e-9) then
      alpha = 0.0
    else
      alpha = (t_profile - t_lo) / (t_hi - t_lo)
    end if

    cmds%p_cmd_dps     = lerp(prof%p_cmd_dps(i_lo),     prof%p_cmd_dps(i_hi),     alpha)
    cmds%q_cmd_dps     = lerp(prof%q_cmd_dps(i_lo),     prof%q_cmd_dps(i_hi),     alpha)
    cmds%r_cmd_dps     = lerp(prof%r_cmd_dps(i_lo),     prof%r_cmd_dps(i_hi),     alpha)
    cmds%V_cmd_fps     = lerp(prof%V_cmd_fps(i_lo),     prof%V_cmd_fps(i_hi),     alpha)
    cmds%phi_cmd_deg   = lerp(prof%phi_cmd_deg(i_lo),   prof%phi_cmd_deg(i_hi),   alpha)
    cmds%theta_cmd_deg = lerp(prof%theta_cmd_deg(i_lo), prof%theta_cmd_deg(i_hi), alpha)
    cmds%h_cmd_ft      = lerp(prof%h_cmd_ft(i_lo),      prof%h_cmd_ft(i_hi),      alpha)
    cmds%beta_cmd_deg  = lerp(prof%beta_cmd_deg(i_lo),  prof%beta_cmd_deg(i_hi),  alpha)

  end subroutine profile_get_commands

  subroutine copy_point(prof, i, cmds)
    type(command_profile), intent(in) :: prof
    integer, intent(in) :: i
    type(profile_commands), intent(out) :: cmds
    cmds%p_cmd_dps     = prof%p_cmd_dps(i)
    cmds%q_cmd_dps     = prof%q_cmd_dps(i)
    cmds%r_cmd_dps     = prof%r_cmd_dps(i)
    cmds%V_cmd_fps     = prof%V_cmd_fps(i)
    cmds%phi_cmd_deg   = prof%phi_cmd_deg(i)
    cmds%theta_cmd_deg = prof%theta_cmd_deg(i)
    cmds%h_cmd_ft      = prof%h_cmd_ft(i)
    cmds%beta_cmd_deg  = prof%beta_cmd_deg(i)
  end subroutine copy_point

  ! linear interp
  pure real function lerp(a, b, t)
    real, intent(in) :: a, b, t
    lerp = a + t * (b - a)
  end function lerp

end module command_profile_m
