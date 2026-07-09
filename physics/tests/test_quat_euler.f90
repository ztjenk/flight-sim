! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins
!
! Assert (2): quat_to_euler at exactly +/- 90 deg pitch must return finite
! angles (no NaN). Locks the asin clamp / gimbal-lock handling in quat_to_euler.
program test_quat_euler
    use math_m, only: euler_to_quat, quat_to_euler
    use, intrinsic :: ieee_arithmetic, only: ieee_is_nan
    implicit none

    real, parameter :: PI = 3.1415926535897932384626433832795
    real, parameter :: TOL = 1.0e-9
    real :: q(4), eul(3)
    logical :: ok

    ok = .true.

    ! +90 deg pitch (nose straight up): theta = +pi/2
    q = euler_to_quat([0.0, PI*0.5, 0.0])
    eul = quat_to_euler(q)
    if (any(ieee_is_nan(eul))) then
        write(*,'(A,3ES16.8)') '  FAIL: +90 deg pitch produced NaN: ', eul
        ok = .false.
    else if (abs(eul(2) - PI*0.5) > TOL) then
        write(*,'(A,ES16.8,A)') '  FAIL: +90 deg pitch theta = ', eul(2), &
            ' expected +pi/2'
        ok = .false.
    end if

    ! -90 deg pitch (nose straight down): theta = -pi/2
    q = euler_to_quat([0.0, -PI*0.5, 0.0])
    eul = quat_to_euler(q)
    if (any(ieee_is_nan(eul))) then
        write(*,'(A,3ES16.8)') '  FAIL: -90 deg pitch produced NaN: ', eul
        ok = .false.
    else if (abs(eul(2) + PI*0.5) > TOL) then
        write(*,'(A,ES16.8,A)') '  FAIL: -90 deg pitch theta = ', eul(2), &
            ' expected -pi/2'
        ok = .false.
    end if

    ! a normal (non-singular) attitude round-trips through the asin clamp cleanly
    q = euler_to_quat([0.3, 0.4, 0.5])
    eul = quat_to_euler(q)
    if (any(ieee_is_nan(eul))) then
        write(*,'(A,3ES16.8)') '  FAIL: nominal attitude produced NaN: ', eul
        ok = .false.
    else if (abs(eul(1)-0.3) > TOL .or. abs(eul(2)-0.4) > TOL .or. abs(eul(3)-0.5) > TOL) then
        write(*,'(A,3ES16.8)') '  FAIL: nominal round-trip mismatch: ', eul
        ok = .false.
    end if

    if (ok) then
        write(*,'(A)') 'PASS: test_quat_euler (no NaN at +/-90 deg pitch)'
    else
        write(*,'(A)') 'FAIL: test_quat_euler'
        error stop 1
    end if

end program test_quat_euler
