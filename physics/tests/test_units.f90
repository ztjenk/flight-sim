! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins
!
! Assert: the units_m factor table follows its own convention
! (x_external = x_internal * conversion_factor_to(unit)), matches the exact
! definitions (1 ft = 0.3048 m, 1 lbf = 4.4482216152605 N, 1 kt = 1852 m/hr,
! 1 hp = 550 lbf*ft/s), and agrees with itself where definitions tie units
! together (1 W = 1 J/s = 1 N*m/s; a 1 F change = a 5/9 C change = a 5/9 K change).
program test_units
    use units_m
    implicit none

    real, parameter :: TOL = 1.0e-14   ! relative: a few roundings of exact definitions
    logical :: ok

    ok = .true.
    call check('m',        0.3048)
    call check('in',       12.0)
    call check('lbf*ft/s', 1.0)
    call check('hp',       1.0/550.0)
    call check('W',        conversion_factor_to('J/s'))
    call check('W',        conversion_factor_to('N*m/s'))
    call check('J',        conversion_factor_to('N*m'))
    call check('kg',       4.4482216152605/0.3048)
    call check('kts',      0.3048*3600.0/1852.0)
    call check('F',        1.0)
    call check('C',        5.0/9.0)
    call check('K',        conversion_factor_to('C'))

    if (ok) then
        write(*,'(A)') 'PASS: test_units (factor table: convention, exact definitions, self-consistency)'
    else
        write(*,'(A)') 'FAIL: test_units'
        error stop 1
    end if

contains

    subroutine check(unit_str, expected)
        character(len=*), intent(in) :: unit_str
        real, intent(in) :: expected
        real :: got

        got = conversion_factor_to(unit_str)
        if (abs(got - expected) > TOL * abs(expected)) then
            write(*,'(A,A,A,ES24.16,A,ES24.16)') '  FAIL: ', unit_str, ' = ', got, &
                ', expected ', expected
            ok = .false.
        end if
    end subroutine check

end program test_units
