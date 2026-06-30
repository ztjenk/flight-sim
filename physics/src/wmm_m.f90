! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! World Magnetic Model (WMM2025, epoch 2025.0).
!
! Evaluates the main geomagnetic field by spherical-harmonic synthesis to degree
! and order 12. Given geodetic latitude/longitude, altitude above the WGS84
! ellipsoid and a decimal year, it returns the field in local NED components
! (nT) together with declination, inclination and total intensity.
!
! Implementation follows the standard NOAA World Magnetic Model procedure:
!   1. linear secular variation of the Gauss coefficients to the requested year,
!   2. WGS84 geodetic-to-geocentric coordinate conversion,
!   3. Schmidt semi-normalized associated Legendre functions and derivatives
!      built from Gauss-normalized recursions,
!   4. summation of the field in the geocentric frame, and
!   5. rotation of the result back into the local geodetic NED frame.
!
! The g/h/dg/dh coefficient tables are the public-domain WMM2025 values released
! by NOAA/NCEI. Self-contained; depends only on constants_m.
module wmm_m
    use constants_m, only: d2r => DEG2RAD, r2d => RAD2DEG
    implicit none
    private
    public :: wmm_field

    integer, parameter :: NMAX = 12
    real,    parameter :: EPOCH = 2025.0     ! model epoch (decimal year)
    real,    parameter :: GEOMAG_R = 6371.2  ! geomagnetic reference radius [km]

    ! WGS84 ellipsoid (km)
    real, parameter :: WGS84_A = 6378.137
    real, parameter :: WGS84_F = 1.0 / 298.257223563
    real, parameter :: EPSSQ   = WGS84_F * (2.0 - WGS84_F)   ! first eccentricity squared

    real, parameter :: z = 0.0   ! filler for the upper triangle of the tables

    ! Gauss coefficients g(n,m) [nT]
    real, parameter :: g(NMAX,0:NMAX) = reshape([ &
        -29351.8, -1410.8,      z,      z,      z,      z,      z,      z,      z,      z,      z,      z,      z, & ! n = 1
         -2556.6,  2951.1, 1649.3,      z,      z,      z,      z,      z,      z,      z,      z,      z,      z, & ! n = 2
          1361.0, -2404.1, 1243.8,  453.6,      z,      z,      z,      z,      z,      z,      z,      z,      z, & ! n = 3
           895.0,   799.5,   55.7, -281.1,   12.1,      z,      z,      z,      z,      z,      z,      z,      z, & ! n = 4
          -233.2,   368.9,  187.2, -138.7, -142.0,   20.9,      z,      z,      z,      z,      z,      z,      z, & ! n = 5
            64.4,    63.8,   76.9, -115.7,  -40.9,   14.9,  -60.7,      z,      z,      z,      z,      z,      z, & ! n = 6
            79.5,   -77.0,   -8.8,   59.3,   15.8,    2.5,  -11.1,   14.2,      z,      z,      z,      z,      z, & ! n = 7
            23.2,    10.8,  -17.5,    2.0,  -21.7,   16.9,   15.0,  -16.8,    0.9,      z,      z,      z,      z, & ! n = 8
             4.6,     7.8,    3.0,   -0.2,   -2.5,  -13.1,    2.4,    8.6,   -8.7,  -12.9,      z,      z,      z, & ! n = 9
            -1.3,    -6.4,    0.2,    2.0,   -1.0,   -0.6,   -0.9,    1.5,    0.9,   -2.7,   -3.9,      z,      z, & ! n = 10
             2.9,    -1.5,   -2.5,    2.4,   -0.6,   -0.1,   -0.6,   -0.1,    1.1,   -1.0,   -0.2,    2.6,      z, & ! n = 11
            -2.0,    -0.2,    0.3,    1.2,   -1.3,    0.6,    0.6,    0.5,   -0.1,   -0.4,   -0.2,   -1.3,   -0.7  & ! n = 12
        ], shape=[NMAX,NMAX+1], order=[2,1])

    ! Gauss coefficients h(n,m) [nT]
    real, parameter :: h(NMAX,0:NMAX) = reshape([ &
        z,  4545.4,      z,      z,      z,     z,     z,    z,    z,    z,    z,    z,   z, & ! n = 1
        z, -3133.6, -815.1,      z,      z,     z,     z,    z,    z,    z,    z,    z,   z, & ! n = 2
        z,   -56.6,  237.5, -549.5,      z,     z,     z,    z,    z,    z,    z,    z,   z, & ! n = 3
        z,   278.6, -133.9,  212.0, -375.6,     z,     z,    z,    z,    z,    z,    z,   z, & ! n = 4
        z,    45.4,  220.2, -122.9,   43.0, 106.1,     z,    z,    z,    z,    z,    z,   z, & ! n = 5
        z,   -18.4,   16.8,   48.8,  -59.8,  10.9,  72.7,    z,    z,    z,    z,    z,   z, & ! n = 6
        z,   -48.9,  -14.4,   -1.0,   23.4,  -7.4, -25.1, -2.3,    z,    z,    z,    z,   z, & ! n = 7
        z,     7.1,  -12.6,   11.4,   -9.7,  12.7,   0.7, -5.2,  3.9,    z,    z,    z,   z, & ! n = 8
        z,   -24.8,   12.2,    8.3,   -3.3,  -5.2,   7.2, -0.6,  0.8, 10.0,    z,    z,   z, & ! n = 9
        z,     3.3,    0.0,    2.4,    5.3,  -9.1,   0.4, -4.2, -3.8,  0.9, -9.1,    z,   z, & ! n = 10
        z,     0.0,    2.9,   -0.6,    0.2,   0.5,  -0.3, -1.2, -1.7, -2.9, -1.8, -2.3,   z, & ! n = 11
        z,    -1.3,    0.7,    1.0,   -1.4,  -0.0,   0.6, -0.1,  0.8,  0.1, -1.0,  0.1, 0.2  & ! n = 12
        ], shape=[NMAX,NMAX+1], order=[2,1])

    ! secular variation of g [nT/yr]
    real, parameter :: dg(NMAX,0:NMAX) = reshape([ &
         12.0,    9.7,      z,      z,      z,      z,      z,      z,      z,      z,      z,      z,      z, & ! n = 1
        -11.6,   -5.2,   -8.0,      z,      z,      z,      z,      z,      z,      z,      z,      z,      z, & ! n = 2
         -1.3,   -4.2,    0.4,  -15.6,      z,      z,      z,      z,      z,      z,      z,      z,      z, & ! n = 3
         -1.6,   -2.4,   -6.0,    5.6,   -7.0,      z,      z,      z,      z,      z,      z,      z,      z, & ! n = 4
          0.6,    1.4,    0.0,    0.6,    2.2,    0.9,      z,      z,      z,      z,      z,      z,      z, & ! n = 5
         -0.2,   -0.4,    0.9,    1.2,   -0.9,    0.3,    0.9,      z,      z,      z,      z,      z,      z, & ! n = 6
         -0.0,   -0.1,   -0.1,    0.5,   -0.1,   -0.8,   -0.8,    0.8,      z,      z,      z,      z,      z, & ! n = 7
         -0.1,    0.2,    0.0,    0.5,   -0.1,    0.3,    0.2,   -0.0,    0.2,      z,      z,      z,      z, & ! n = 8
         -0.0,   -0.1,    0.1,    0.3,   -0.3,    0.0,    0.3,   -0.1,    0.1,   -0.1,      z,      z,      z, & ! n = 9
          0.1,    0.0,    0.1,    0.1,   -0.0,   -0.3,    0.0,   -0.1,   -0.1,   -0.0,   -0.0,      z,      z, & ! n = 10
          0.0,   -0.0,    0.0,    0.0,    0.0,   -0.1,    0.0,   -0.0,   -0.1,   -0.1,   -0.1,   -0.1,      z, & ! n = 11
          0.0,    0.0,   -0.0,   -0.0,   -0.0,   -0.0,    0.1,   -0.0,    0.0,    0.0,   -0.1,   -0.0,   -0.1  & ! n = 12
        ], shape=[NMAX,NMAX+1], order=[2,1])

    ! secular variation of h [nT/yr]
    real, parameter :: dh(NMAX,0:NMAX) = reshape([ &
        z,  -21.5,      z,      z,      z,      z,      z,      z,      z,      z,      z,      z,      z, & ! n = 1
        z,  -27.7,  -12.1,      z,      z,      z,      z,      z,      z,      z,      z,      z,      z, & ! n = 2
        z,    4.0,   -0.3,   -4.1,      z,      z,      z,      z,      z,      z,      z,      z,      z, & ! n = 3
        z,   -1.1,    4.1,    1.6,   -4.4,      z,      z,      z,      z,      z,      z,      z,      z, & ! n = 4
        z,   -0.5,    2.2,    0.4,    1.7,    1.9,      z,      z,      z,      z,      z,      z,      z, & ! n = 5
        z,    0.3,   -1.6,   -0.4,    0.9,    0.7,    0.9,      z,      z,      z,      z,      z,      z, & ! n = 6
        z,    0.6,    0.5,   -0.8,    0.0,   -1.0,    0.6,   -0.2,      z,      z,      z,      z,      z, & ! n = 7
        z,   -0.2,    0.5,   -0.4,    0.4,   -0.5,   -0.6,    0.3,    0.2,      z,      z,      z,      z, & ! n = 8
        z,   -0.3,    0.3,   -0.3,    0.3,    0.2,   -0.1,   -0.2,    0.4,    0.1,      z,      z,      z, & ! n = 9
        z,    0.0,   -0.0,   -0.2,    0.1,   -0.1,    0.1,    0.0,   -0.1,    0.2,   -0.0,      z,      z, & ! n = 10
        z,   -0.0,    0.1,   -0.0,    0.1,   -0.0,   -0.0,    0.1,   -0.0,    0.0,    0.0,    0.0,      z, & ! n = 11
        z,   -0.0,    0.0,   -0.1,    0.1,   -0.0,   -0.0,   -0.0,    0.0,   -0.0,   -0.0,    0.0,   -0.1  & ! n = 12
        ], shape=[NMAX,NMAX+1], order=[2,1])

    ! Schmidt quasi-normalization factors S(n,m); built once on first call.
    logical, save :: have_norm = .false.
    real,    save :: snorm(0:NMAX, 0:NMAX) = 0.0

contains

    ! Geomagnetic field at geodetic (lat_deg, lon_deg), altitude alt [km] above
    ! the WGS84 ellipsoid, at decimal year dec_year. Returns NED components
    ! [nT], declination/inclination [deg] and total intensity [nT]. The optional
    ! maxdegree truncates the expansion (default and maximum is 12).
    subroutine wmm_field(lat_deg, lon_deg, alt, dec_year, &
                         B_N, B_E, B_D, decl_deg, incl_deg, total_intensity, maxdegree)
        real, intent(in)  :: lat_deg, lon_deg, alt, dec_year
        real, intent(out) :: B_N, B_E, B_D
        real, intent(out) :: decl_deg, incl_deg, total_intensity
        integer, intent(in), optional :: maxdegree

        integer :: nmaxd, n, m
        real :: dt, rlat, rlon, sinlat, coslat
        real :: rc, xp, zp, r, phig, sphi, cphi
        real :: aor, rrp(0:NMAX), cosml(0:NMAX), sinml(0:NMAX)
        real :: p(0:NMAX,0:NMAX), dp(0:NMAX,0:NMAX)
        real :: gt, ht, cs, sc, term
        real :: bx, by, bz, psi, bxg, byg, bzg, bh

        nmaxd = NMAX
        if (present(maxdegree)) nmaxd = min(maxdegree, NMAX)

        if (.not. have_norm) call build_schmidt_norm()

        dt = dec_year - EPOCH

        ! --- WGS84 geodetic -> geocentric spherical -----------------------
        rlat = lat_deg * d2r
        rlon = lon_deg * d2r
        sinlat = sin(rlat)
        coslat = cos(rlat)

        rc = WGS84_A / sqrt(1.0 - EPSSQ*sinlat*sinlat)   ! prime-vertical radius
        xp = (rc + alt) * coslat
        zp = (rc*(1.0 - EPSSQ) + alt) * sinlat
        r    = sqrt(xp*xp + zp*zp)
        phig = asin(zp / r)                              ! geocentric latitude
        sphi = zp / r                                    ! sin(geocentric lat)
        cphi = sqrt((1.0 - sphi)*(1.0 + sphi))           ! cos(geocentric lat)

        ! --- radial power and longitude harmonics -------------------------
        aor    = GEOMAG_R / r
        rrp(0) = aor*aor
        do n = 1, nmaxd
            rrp(n) = rrp(n-1) * aor                      ! (a/r)^(n+2)
        end do

        cosml(0) = 1.0;  sinml(0) = 0.0
        cosml(1) = cos(rlon);  sinml(1) = sin(rlon)
        do m = 2, nmaxd
            cosml(m) = cosml(m-1)*cosml(1) - sinml(m-1)*sinml(1)
            sinml(m) = cosml(m-1)*sinml(1) + sinml(m-1)*cosml(1)
        end do

        ! --- Schmidt semi-normalized Legendre functions and derivatives ---
        call legendre(sphi, cphi, nmaxd, p, dp)

        ! --- field summation in the geocentric frame ----------------------
        bx = 0.0;  by = 0.0;  bz = 0.0
        do n = 1, nmaxd
            do m = 0, n
                gt = g(n,m) + dt*dg(n,m)
                ht = h(n,m) + dt*dh(n,m)
                cs = gt*cosml(m) + ht*sinml(m)
                sc = gt*sinml(m) - ht*cosml(m)
                term = rrp(n)
                bz = bz - term * cs * real(n+1) * p(n,m)
                bx = bx - term * cs * dp(n,m)
                by = by + term * sc * real(m) * p(n,m)
            end do
        end do

        if (abs(cphi) > 1.0e-10) then
            by = by / cphi
        else
            by = by_at_pole(sphi, dt, rrp, sinml(1), cosml(1), nmaxd)
        end if

        ! --- rotate geocentric NED into geodetic NED ----------------------
        psi = phig - rlat
        bxg =  bx*cos(psi) - bz*sin(psi)
        bzg =  bx*sin(psi) + bz*cos(psi)
        byg =  by

        B_N = bxg
        B_E = byg
        B_D = bzg

        bh = sqrt(bxg*bxg + byg*byg)
        total_intensity = sqrt(bh*bh + bzg*bzg)
        decl_deg = atan2(byg, bxg) * r2d
        incl_deg = atan2(bzg, bh)  * r2d
    end subroutine wmm_field

    ! Schmidt quasi-normalization ratios relating the Gauss-normalized Legendre
    ! functions to the Schmidt semi-normalized ones. Computed once and cached.
    subroutine build_schmidt_norm()
        integer :: n, m
        real :: fac

        snorm = 0.0
        snorm(0,0) = 1.0
        do n = 1, NMAX
            snorm(n,0) = snorm(n-1,0) * real(2*n-1) / real(n)
            do m = 1, n
                fac = real((n-m+1) * merge(2, 1, m == 1)) / real(n+m)
                snorm(n,m) = snorm(n,m-1) * sqrt(fac)
            end do
        end do
        have_norm = .true.
    end subroutine build_schmidt_norm

    ! Schmidt semi-normalized associated Legendre functions p(n,m) and their
    ! derivatives with respect to latitude dp(n,m), evaluated at sin(lat)=x,
    ! cos(lat)=zc. Built from the Gauss-normalized recursion, then rescaled.
    subroutine legendre(x, zc, nmaxd, p, dp)
        real,    intent(in)  :: x, zc
        integer, intent(in)  :: nmaxd
        real,    intent(out) :: p(0:NMAX,0:NMAX), dp(0:NMAX,0:NMAX)
        integer :: n, m
        real :: kf

        p = 0.0;  dp = 0.0
        p(0,0) = 1.0;  dp(0,0) = 0.0

        do n = 1, nmaxd
            do m = 0, n
                if (n == m) then
                    p(n,m)  = zc * p(n-1,m-1)
                    dp(n,m) = zc * dp(n-1,m-1) + x * p(n-1,m-1)
                else if (n == 1 .and. m == 0) then
                    p(n,m)  = x * p(0,0)
                    dp(n,m) = x * dp(0,0) - zc * p(0,0)
                else if (m == n-1) then
                    p(n,m)  = x * p(n-1,m)
                    dp(n,m) = x * dp(n-1,m) - zc * p(n-1,m)
                else
                    kf = real((n-1)*(n-1) - m*m) / real((2*n-1)*(2*n-3))
                    p(n,m)  = x * p(n-1,m) - kf * p(n-2,m)
                    dp(n,m) = x * dp(n-1,m) - zc * p(n-1,m) - kf * dp(n-2,m)
                end if
            end do
        end do

        ! convert Gauss-normalized -> Schmidt; flip derivative sign so that it is
        ! taken with respect to latitude rather than co-latitude
        do n = 1, nmaxd
            do m = 0, n
                p(n,m)  =  p(n,m)  * snorm(n,m)
                dp(n,m) = -dp(n,m) * snorm(n,m)
            end do
        end do
    end subroutine legendre

    ! Special evaluation of the east component By at the geographic poles, where
    ! the 1/cos(lat) factor in the general summation is singular.
    function by_at_pole(sphi, dt, rrp, sinlon, coslon, nmaxd) result(by)
        real,    intent(in) :: sphi, dt, rrp(0:NMAX), sinlon, coslon
        integer, intent(in) :: nmaxd
        real :: by
        integer :: n
        real :: ps(0:NMAX), s1, s2, s3, kf, gt, ht

        by = 0.0
        ps = 0.0
        ps(0) = 1.0
        s1 = 1.0
        do n = 1, nmaxd
            s2 = s1 * real(2*n-1) / real(n)
            s3 = s2 * sqrt(real(2*n) / real(n+1))
            s1 = s2
            if (n == 1) then
                ps(n) = ps(n-1)
            else
                kf = real((n-1)*(n-1) - 1) / real((2*n-1)*(2*n-3))
                ps(n) = sphi*ps(n-1) - kf*ps(n-2)
            end if
            gt = g(n,1) + dt*dg(n,1)
            ht = h(n,1) + dt*dh(n,1)
            by = by + rrp(n) * (gt*sinlon - ht*coslon) * ps(n) * s3
        end do
    end function by_at_pole

end module wmm_m
