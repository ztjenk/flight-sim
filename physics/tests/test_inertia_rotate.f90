! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins
!
! Assert (1): rotating a known diagonal inertia tensor by 90 deg and checking
! the R I R^T similarity transform. Locks the RIRᵀ moment-of-inertia rotation.
!
! For a rotation of +90 deg about the body x-axis, the y and z principal axes
! swap, so diag(Ixx,Iyy,Izz) -> diag(Ixx,Izz,Iyy) with no off-diagonal terms.
program test_inertia_rotate
    use math_m, only: quat_to_dcm
    implicit none

    real :: I0(3,3), R(3,3), I_rot(3,3), I_expected(3,3)
    real :: q(4)
    real, parameter :: TOL = 1.0e-10
    integer :: i, j
    logical :: ok

    ! diagonal inertia tensor (F16-like principal moments) [slug-ft^2]
    I0 = 0.0
    I0(1,1) = 9496.0
    I0(2,2) = 55814.0
    I0(3,3) = 63100.0

    ! +90 deg rotation about the x-axis: q = [cos(45), sin(45), 0, 0]
    q = [sqrt(0.5), sqrt(0.5), 0.0, 0.0]
    R = quat_to_dcm(q)

    ! similarity transform I' = R I R^T (rotates the tensor into the new frame)
    I_rot = matmul(matmul(R, I0), transpose(R))

    ! expected: y and z swap -> diag(Ixx, Izz, Iyy), off-diagonals ~ 0
    I_expected = 0.0
    I_expected(1,1) = 9496.0
    I_expected(2,2) = 63100.0
    I_expected(3,3) = 55814.0

    ok = .true.
    do i = 1, 3
        do j = 1, 3
            if (abs(I_rot(i,j) - I_expected(i,j)) > TOL) then
                write(*,'(A,I0,A,I0,A,ES20.12,A,ES20.12)') &
                    '  FAIL: I_rot(', i, ',', j, ') = ', I_rot(i,j), &
                    ' expected ', I_expected(i,j)
                ok = .false.
            end if
        end do
    end do

    if (ok) then
        write(*,'(A)') 'PASS: test_inertia_rotate (R I R^T about x by 90 deg)'
    else
        write(*,'(A)') 'FAIL: test_inertia_rotate'
        error stop 1
    end if

end program test_inertia_rotate
