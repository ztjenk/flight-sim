! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! Small dense linear algebra for dynamic inversion (port of linalg.py).
! Cramer's rule for 3x3 systems and a diagonal solver — chosen for a direct,
! dependency-free translation. solve3 flags singular systems via an ok flag so
! callers can fall back / hold last command instead of producing NaNs.
module linalg_m
  use constants_m, only: TOLERANCE
  implicit none
  private
  public :: solve3, diag_solve, inv3

contains

  ! Invert a 3x3 matrix via the adjugate/determinant. ok = .false. if singular.
  pure subroutine inv3(A, Ainv, ok)
    real, intent(in)  :: A(3,3)
    real, intent(out) :: Ainv(3,3)
    logical, intent(out) :: ok
    real :: det, inv_det

    det = A(1,1)*(A(2,2)*A(3,3) - A(2,3)*A(3,2)) &
        - A(1,2)*(A(2,1)*A(3,3) - A(2,3)*A(3,1)) &
        + A(1,3)*(A(2,1)*A(3,2) - A(2,2)*A(3,1))
    if (abs(det) < TOLERANCE) then
      Ainv = 0.0
      ok = .false.
      return
    end if
    inv_det = 1.0 / det
    Ainv(1,1) =  (A(2,2)*A(3,3) - A(2,3)*A(3,2)) * inv_det
    Ainv(1,2) = -(A(1,2)*A(3,3) - A(1,3)*A(3,2)) * inv_det
    Ainv(1,3) =  (A(1,2)*A(2,3) - A(1,3)*A(2,2)) * inv_det
    Ainv(2,1) = -(A(2,1)*A(3,3) - A(2,3)*A(3,1)) * inv_det
    Ainv(2,2) =  (A(1,1)*A(3,3) - A(1,3)*A(3,1)) * inv_det
    Ainv(2,3) = -(A(1,1)*A(2,3) - A(1,3)*A(2,1)) * inv_det
    Ainv(3,1) =  (A(2,1)*A(3,2) - A(2,2)*A(3,1)) * inv_det
    Ainv(3,2) = -(A(1,1)*A(3,2) - A(1,2)*A(3,1)) * inv_det
    Ainv(3,3) =  (A(1,1)*A(2,2) - A(1,2)*A(2,1)) * inv_det
    ok = .true.
  end subroutine inv3

  ! Solve A x = b for a 3x3 system via Cramer's rule.
  ! ok = .false. (and x = 0) when |det(A)| is below tolerance (singular).
  pure subroutine solve3(A, b, x, ok)
    real, intent(in)  :: A(3,3)
    real, intent(in)  :: b(3)
    real, intent(out) :: x(3)
    logical, intent(out) :: ok

    real :: det, inv_det
    real :: c00, c01, c02   ! cofactors of row 0 (for the determinant)
    real :: d0, d1, d2      ! replaced-column determinants

    ! cofactor expansion along the first row
    c00 =  (A(2,2)*A(3,3) - A(2,3)*A(3,2))
    c01 = -(A(2,1)*A(3,3) - A(2,3)*A(3,1))
    c02 =  (A(2,1)*A(3,2) - A(2,2)*A(3,1))

    det = A(1,1)*c00 + A(1,2)*c01 + A(1,3)*c02

    if (abs(det) < TOLERANCE) then
      x  = 0.0
      ok = .false.
      return
    end if

    inv_det = 1.0 / det

    ! determinant with column 1 replaced by b
    d0 =  b(1)*(A(2,2)*A(3,3) - A(2,3)*A(3,2)) &
        - A(1,2)*(b(2)*A(3,3) - A(2,3)*b(3))   &
        + A(1,3)*(b(2)*A(3,2) - A(2,2)*b(3))
    ! determinant with column 2 replaced by b
    d1 =  A(1,1)*(b(2)*A(3,3) - A(2,3)*b(3))   &
        - b(1)*(A(2,1)*A(3,3) - A(2,3)*A(3,1)) &
        + A(1,3)*(A(2,1)*b(3) - b(2)*A(3,1))
    ! determinant with column 3 replaced by b
    d2 =  A(1,1)*(A(2,2)*b(3) - b(2)*A(3,2))   &
        - A(1,2)*(A(2,1)*b(3) - b(2)*A(3,1))   &
        + b(1)*(A(2,1)*A(3,2) - A(2,2)*A(3,1))

    x(1) = d0 * inv_det
    x(2) = d1 * inv_det
    x(3) = d2 * inv_det
    ok = .true.
  end subroutine solve3

  ! Solve diag(d) x = b element-wise. ok = .false. if any |d_i| < tolerance.
  pure subroutine diag_solve(d, b, x, ok)
    real, intent(in)  :: d(:), b(:)
    real, intent(out) :: x(size(b))
    logical, intent(out) :: ok
    integer :: i

    ok = .true.
    do i = 1, size(b)
      if (abs(d(i)) < TOLERANCE) then
        x(i) = 0.0
        ok = .false.
      else
        x(i) = b(i) / d(i)
      end if
    end do
  end subroutine diag_solve

end module linalg_m
