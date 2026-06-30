! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! random number generation utilities
! uses Box-Muller transform for normally distributed random numbers
module random_m
    use constants_m
    implicit none
    private
    public :: rand_normal, seed_random

    ! Box-Muller cached state (module-level so seed_random can reset it)
    real    :: bm_z2 = 0.0
    logical :: bm_has_saved = .false.

contains

    ! seed the Fortran intrinsic RNG and clear any cached Box-Muller value
    subroutine seed_random(seed_val)
        integer, intent(in) :: seed_val
        integer :: n
        integer, allocatable :: seed_arr(:)
        call random_seed(size=n)
        allocate(seed_arr(n))
        seed_arr = seed_val
        call random_seed(put=seed_arr)
        bm_has_saved = .false.
    end subroutine seed_random

    ! return a single N(0,1) random number via Box-Muller transform
    ! generates two values per pair of uniform draws, caches the second
    function rand_normal() result(z)
        real :: z
        real :: u1, u2, r, theta
        if (bm_has_saved) then
            z = bm_z2
            bm_has_saved = .false.
        else
            call random_number(u1)
            call random_number(u2)
            ! guard against log(0)
            if (u1 <= 0.0) u1 = 1.0e-12
            if (u1 >  1.0) u1 = 1.0
            r     = sqrt(-2.0 * log(u1))
            theta = 2.0 * PI * u2
            z     = r * cos(theta)
            bm_z2 = r * sin(theta)
            bm_has_saved = .true.
        end if
    end function rand_normal

end module random_m
