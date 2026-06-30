! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! X-quad control mixer. Builds the 4x4 effectiveness matrix mapping the 4 rotor
! thrusts to the body wrench [T, L, M, N] from rotor geometry, and inverts it so
! the controller can solve a desired wrench for the 4 thrusts.
!
!   T = sum(f_i)                 (collective, +up)
!   L = sum(-y_i * f_i)          (roll about +x)
!   M = sum( x_i * f_i)          (pitch about +y)
!   N = sum(kappa*spin_i * f_i)  (yaw reaction torque)
!
! A thrust acts along body -z, so r x F gives L=-y*f, M=+x*f (see comments).
module mixer_m
  use constants_m, only: TOLERANCE
  implicit none
  private
  public :: mixer_t, mixer_build, mixer_solve

  type :: mixer_t
    real :: B(4,4)    = 0.0    ! wrench = B @ thrusts
    real :: Binv(4,4) = 0.0    ! thrusts = Binv @ wrench
    logical :: ok = .false.
  end type mixer_t

contains

  ! rotor_x/y: body-frame rotor positions [ft]; spin: +1 (CCW/RH) or -1 (CW/LH);
  ! kappa: yaw-torque per unit thrust.
  subroutine mixer_build(mx, rotor_x, rotor_y, spin, kappa)
    type(mixer_t), intent(out) :: mx
    real, intent(in) :: rotor_x(4), rotor_y(4), spin(4), kappa
    integer :: i
    do i = 1, 4
      mx%B(1,i) = 1.0
      mx%B(2,i) = -rotor_y(i)
      mx%B(3,i) =  rotor_x(i)
      mx%B(4,i) =  kappa * spin(i)
    end do
    call gauss_inv4(mx%B, mx%Binv, mx%ok)
  end subroutine mixer_build

  ! thrusts = Binv @ wrench
  pure function mixer_solve(mx, wrench) result(thrusts)
    type(mixer_t), intent(in) :: mx
    real, intent(in) :: wrench(4)
    real :: thrusts(4)
    thrusts = matmul(mx%Binv, wrench)
  end function mixer_solve

  ! 4x4 inverse via Gauss-Jordan elimination with partial pivoting.
  subroutine gauss_inv4(A, Ainv, ok)
    real, intent(in)  :: A(4,4)
    real, intent(out) :: Ainv(4,4)
    logical, intent(out) :: ok
    real :: M(4,8)
    integer :: i, j, k, piv
    real :: pv, factor

    ok = .true.
    M = 0.0
    M(:,1:4) = A
    do i = 1, 4
      M(i,4+i) = 1.0
    end do

    do k = 1, 4
      ! partial pivot
      piv = k
      do i = k+1, 4
        if (abs(M(i,k)) > abs(M(piv,k))) piv = i
      end do
      if (abs(M(piv,k)) < TOLERANCE) then
        ok = .false.; Ainv = 0.0; return
      end if
      if (piv /= k) then
        do j = 1, 8
          pv = M(k,j); M(k,j) = M(piv,j); M(piv,j) = pv
        end do
      end if
      ! normalize pivot row
      pv = M(k,k)
      M(k,:) = M(k,:) / pv
      ! eliminate other rows
      do i = 1, 4
        if (i /= k) then
          factor = M(i,k)
          M(i,:) = M(i,:) - factor * M(k,:)
        end if
      end do
    end do

    Ainv = M(:,5:8)
  end subroutine gauss_inv4

end module mixer_m
