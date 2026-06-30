! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

!===============================================================================
! battery_m.f90 - Battery model for electric propulsion
!
! Implements the simple battery model from Phillips Sec 4.6:
!   - Series/parallel cell configuration
!   - Maoquan/Haixin no-load voltage model (Eq 4.6.2) with per-cell constants
!     V_full, EA, EB, EC
!   - Internal resistance / terminal voltage under load (Eq 4.6.3)
!   - Capacity tracking via Euler integration of current (Eq 4.6.1)
!   - C-rating overcurrent check (Eq 4.6.4), warn-once per battery
!   - Auxiliary current draw (avionics, payload)
!===============================================================================
module battery_m
    implicit none
    private

    public :: battery_t

    ! capacity floor to guard the Q_total/Q_remaining term in Eq 4.6.2
    real, parameter :: Q_EPS = 1.0e-9    ! [A*s]

    type :: battery_t
        character(len=64) :: name = ''

        ! cell configuration
        integer :: nS = 1                              ! cells in series
        integer :: nP = 1                              ! cells in parallel

        ! per-cell properties (Eqs 4.6.2, 4.6.3)
        real :: cell_R = 0.0                           ! single-cell resistance [Ohm]
        real :: cell_Q = 0.0                           ! single-cell capacity [A*s]
        real :: V_full = 0.0                           ! Eb0F per cell [V]
        real :: EA = 0.0                               ! Eq 4.6.2 constant [V]
        real :: EB = 0.0                               ! Eq 4.6.2 constant [V]
        real :: EC = 0.0                               ! Eq 4.6.2 constant [1/(A*s)]

        ! pack-level rating (Eq 4.6.4)
        real :: C_rating = 0.0                         ! [1/s] (JSON input in 1/hr, divided by 3600)

        ! pack-level derived properties (computed in init_pack)
        real :: R_pack = 0.0                           ! pack resistance [Ohm]
        real :: Q_total = 0.0                          ! pack capacity [A*s]

        ! auxiliary load
        real :: I_aux = 0.0                            ! auxiliary current draw [A]

        ! runtime state
        real :: Q_remaining = 0.0                      ! remaining charge [A*s]
        real :: SOC = 1.0                              ! state of charge [0..1]
        real :: V_terminal = 0.0                       ! last computed terminal voltage [V]
        real :: I_total = 0.0                          ! total current this timestep [A]

        ! warn-once flag for C-rating violation
        logical :: c_warn_issued = .false.
    contains
        procedure :: init_pack => battery_init_pack
        procedure :: open_circuit_voltage => battery_ocv
        procedure :: update_SOC => battery_update_SOC
    end type battery_t

contains

    !---------------------------------------------------------------------------
    ! Compute pack-level derived properties from cell properties.
    ! Call after cell properties and nS/nP are set.
    !---------------------------------------------------------------------------
    subroutine battery_init_pack(self)
        class(battery_t), intent(inout) :: self

        self%R_pack = real(self%nS) / real(self%nP) * self%cell_R
        self%Q_total = real(self%nP) * self%cell_Q
        self%Q_remaining = self%Q_total
        self%SOC = 1.0
        self%c_warn_issued = .false.
    end subroutine battery_init_pack

    !---------------------------------------------------------------------------
    ! No-load pack voltage via Maoquan/Haixin model (Eq 4.6.2), scaled by nS.
    ! Uses the per-cell form with Q_used_cell = (Q_total - Q_remaining)/nP,
    ! and Q_total/Q_remaining unchanged by nP (ratio cancels).
    !---------------------------------------------------------------------------
    pure function battery_ocv(self) result(V)
        class(battery_t), intent(in) :: self
        real :: V
        real :: Qr, Q_used_cell, cell_ocv

        Qr = max(self%Q_remaining, Q_EPS)
        Q_used_cell = (self%Q_total - self%Q_remaining) / real(self%nP)

        cell_ocv = self%V_full &
                   - self%EA * (self%Q_total / Qr) &
                   + self%EB * exp(-self%EC * Q_used_cell)

        V = real(self%nS) * cell_ocv
    end function battery_ocv

    !---------------------------------------------------------------------------
    ! Update battery state of charge after a timestep (Eq 4.6.1 Euler).
    ! Also checks C-rating and warns once per battery if exceeded (Eq 4.6.4).
    !   dt:       timestep [s]
    !   I_motors: total motor current draw this step [A]
    !---------------------------------------------------------------------------
    subroutine battery_update_SOC(self, dt, I_motors)
        class(battery_t), intent(inout) :: self
        real, intent(in) :: dt, I_motors
        real :: I_max

        self%I_total = self%I_aux + I_motors
        self%Q_remaining = self%Q_remaining - self%I_total * dt
        if (self%Q_remaining < 0.0) self%Q_remaining = 0.0

        if (self%Q_total > 0.0) then
            self%SOC = self%Q_remaining / self%Q_total
        else
            self%SOC = 0.0
        end if

        ! Eq 4.6.3 terminal voltage (uses new Maoquan/Haixin OCV)
        self%V_terminal = self%open_circuit_voltage() - self%I_total * self%R_pack

        ! Eq 4.6.4 C-rating check (warn-once)
        if (self%C_rating > 0.0 .and. .not. self%c_warn_issued) then
            I_max = self%C_rating * self%Q_remaining
            if (abs(self%I_total) > I_max) then
                write(*,'(A,A,A,ES12.4,A,ES12.4,A)') &
                    'WARNING: Battery "', trim(self%name), &
                    '" exceeded C-rating (I=', self%I_total, &
                    ' A, I_max=', I_max, ' A). Further warnings suppressed.'
                self%c_warn_issued = .true.
            end if
        end if
    end subroutine battery_update_SOC

end module battery_m
