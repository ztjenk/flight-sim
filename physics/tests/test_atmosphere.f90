! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins
!
! Assert (3): std_atm_english vs the tabulated US Standard Atmosphere 1976 at
! the layer boundaries. The model takes GEOMETRIC altitude and maps to
! geopotential internally, so each geopotential boundary Z is fed as the
! geometric altitude h = R*Z/(R-Z) that produces it.
!
! Reference (US Standard Atmosphere 1976, geopotential boundaries):
!   Z[m]      T[K]      P[Pa]
!   0         288.15    101325.0
!   11000     216.65    22632.06
!   20000     216.65    5474.889
!   32000     228.65    868.0187
!   47000     270.65    110.9063
program test_atmosphere
    use constants_m
    use atmosphere_m
    implicit none

    integer, parameter :: NB = 5
    real :: Zgp(NB), T_ref(NB), P_ref(NB)
    real :: R, hgeom, Zc, T, P, rho, a, mu
    real :: T_si, P_si
    real, parameter :: T_TOL = 1.0e-6   ! temperature: essentially exact
    real, parameter :: P_TOL = 1.0e-3   ! pressure: within 0.1% of canonical table
    integer :: i
    logical :: ok

    R = R_EARTH_SI
    Zgp   = [    0.0,  11000.0,  20000.0,   32000.0,   47000.0]  ! geopotential [m]
    T_ref = [ 288.15,   216.65,   216.65,    228.65,    270.65]  ! [K]
    P_ref = [101325.0, 22632.06, 5474.889,  868.0187,  110.9063] ! [Pa]

    ok = .true.
    do i = 1, NB
        if (Zgp(i) <= 0.0) then
            hgeom = 0.0
        else
            hgeom = R*Zgp(i)/(R - Zgp(i))   ! geometric altitude giving this geopotential
        end if

        call std_atm_english(hgeom*M_TO_FT, Zc, T, P, rho, a, mu)

        ! convert the English outputs back to SI for comparison to the table
        T_si = T / K_TO_RANKINE
        P_si = P / PA_TO_PSF

        if (abs(T_si - T_ref(i)) > T_TOL * T_ref(i)) then
            write(*,'(A,F8.0,A,F12.6,A,F12.6)') '  FAIL: T at Z=', Zgp(i), &
                ' m = ', T_si, ' K, expected ', T_ref(i)
            ok = .false.
        end if
        if (abs(P_si - P_ref(i)) > P_TOL * P_ref(i)) then
            write(*,'(A,F8.0,A,ES16.8,A,ES16.8)') '  FAIL: P at Z=', Zgp(i), &
                ' m = ', P_si, ' Pa, expected ', P_ref(i)
            ok = .false.
        end if
    end do

    if (ok) then
        write(*,'(A)') 'PASS: test_atmosphere (US Std Atm 1976 layer boundaries)'
    else
        write(*,'(A)') 'FAIL: test_atmosphere'
        error stop 1
    end if

end program test_atmosphere
