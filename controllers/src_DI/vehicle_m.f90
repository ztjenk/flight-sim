! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! Aircraft model + dynamic-inversion control laws (port of vehicle.py).
! NDI inverts the full aero/inertia model; INDI inverts only the increment using
! the measured angular acceleration, so it cancels model error except in B(alpha).
module vehicle_m
  use math_m, only: cross3
  use linalg_m, only: solve3, diag_solve, inv3
  implicit none
  private

  public :: vehicle_t, vehicle_set, ndi, indi

  type :: vehicle_t
    real :: Sw = 0.0, b = 0.0, cbar = 0.0
    real :: Imat(3,3) = 0.0
    real :: Iinv(3,3) = 0.0
    real :: hvec(3) = 0.0
    ! aero moment coefficients
    real :: Clbeta=0, Clpbar=0, Clrbar=0, Clarbar=0, Clda=0, Cldr=0
    real :: Cm0=0, Cmalpha=0, Cmqbar=0, Cmde=0
    real :: Cnbeta=0, Cnpbar=0, Cnapbar=0, Cnrbar=0, Cnda=0, Cnada=0, Cndr=0
  end type vehicle_t

contains

  subroutine vehicle_set(veh, Sw, b, cbar, Ixx, Iyy, Izz, Ixy, Ixz, Iyz, hx, hy, hz, ok)
    type(vehicle_t), intent(inout) :: veh
    real, intent(in) :: Sw, b, cbar, Ixx, Iyy, Izz, Ixy, Ixz, Iyz, hx, hy, hz
    logical, intent(out) :: ok
    veh%Sw = Sw; veh%b = b; veh%cbar = cbar
    veh%Imat = reshape([ Ixx, -Ixy, -Ixz, &
                        -Ixy,  Iyy, -Iyz, &
                        -Ixz, -Iyz,  Izz], [3,3])
    ! reshape fills column-major; the matrix above is symmetric so layout is exact
    call inv3(veh%Imat, veh%Iinv, ok)
    veh%hvec = [hx, hy, hz]
  end subroutine vehicle_set

  pure function nondim(veh, omega, V) result(nd)
    type(vehicle_t), intent(in) :: veh
    real, intent(in) :: omega(3), V
    real :: nd(3)
    nd(1) = omega(1) * veh%b    / (2.0*V)
    nd(2) = omega(2) * veh%cbar / (2.0*V)
    nd(3) = omega(3) * veh%b    / (2.0*V)
  end function nondim

  pure function aero_C0(veh, omega, V, alpha, beta) result(C0)
    type(vehicle_t), intent(in) :: veh
    real, intent(in) :: omega(3), V, alpha, beta
    real :: C0(3), nd(3), pbar, qbar, rbar
    nd = nondim(veh, omega, V); pbar = nd(1); qbar = nd(2); rbar = nd(3)
    C0(1) = veh%Clbeta*beta + veh%Clpbar*pbar + (veh%Clrbar + veh%Clarbar*alpha)*rbar
    C0(2) = veh%Cm0 + veh%Cmalpha*alpha + veh%Cmqbar*qbar
    C0(3) = veh%Cnbeta*beta + (veh%Cnpbar + veh%Cnapbar*alpha)*pbar + veh%Cnrbar*rbar
  end function aero_C0

  pure function Bmat(veh, alpha) result(B)
    type(vehicle_t), intent(in) :: veh
    real, intent(in) :: alpha
    real :: B(3,3)
    B = reshape([ veh%Clda,                0.0,       veh%Cnda + veh%Cnada*alpha, &  ! col 1
                  0.0,                     veh%Cmde,  0.0,                        &  ! col 2
                  veh%Cldr,                0.0,       veh%Cndr ], [3,3])              ! col 3
  end function Bmat

  pure function dim_diag(veh, qdyn) result(d)
    type(vehicle_t), intent(in) :: veh
    real, intent(in) :: qdyn
    real :: d(3)
    d = qdyn * veh%Sw * [veh%b, veh%cbar, veh%b]
  end function dim_diag

  ! NDI: full-model inversion. nu = desired angular acceleration -> control deflections.
  subroutine ndi(veh, nu, omega, V, alpha, beta, qdyn, delta, ok)
    type(vehicle_t), intent(in) :: veh
    real, intent(in) :: nu(3), omega(3), V, alpha, beta, qdyn
    real, intent(out) :: delta(3)
    logical, intent(out) :: ok
    real :: M_req(3), C_req(3), rhs(3)
    logical :: ok1, ok2

    M_req = matmul(veh%Imat, nu) + cross3(omega, matmul(veh%Imat, omega) + veh%hvec)
    call diag_solve(dim_diag(veh, qdyn), M_req, C_req, ok1)
    rhs = C_req - aero_C0(veh, omega, V, alpha, beta)
    call solve3(Bmat(veh, alpha), rhs, delta, ok2)
    ok = ok1 .and. ok2
  end subroutine ndi

  ! INDI: incremental inversion about the current deflection using measured wdot.
  subroutine indi(veh, nu, omega_dot_meas, delta_prev, alpha, qdyn, delta, ok)
    type(vehicle_t), intent(in) :: veh
    real, intent(in) :: nu(3), omega_dot_meas(3), delta_prev(3), alpha, qdyn
    real, intent(out) :: delta(3)
    logical, intent(out) :: ok
    real :: D(3,3), G(3,3), dd(3), dvec(3)
    integer :: i

    ! D = diag(dim_diag) @ Bmat  (scale each row i of B by dim_diag(i))
    D = Bmat(veh, alpha)
    dvec = dim_diag(veh, qdyn)
    do i = 1, 3
      D(i,:) = dvec(i) * D(i,:)
    end do
    G = matmul(veh%Iinv, D)
    call solve3(G, nu - omega_dot_meas, dd, ok)
    delta = delta_prev + dd
  end subroutine indi

end module vehicle_m
