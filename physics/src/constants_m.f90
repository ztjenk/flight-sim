! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! physical constants and numerical tolerances used throughout the simulator
module constants_m
    implicit none
    ! table A.2.1 in flight sim book
    real, parameter :: M_TO_FT = 1.0 / 0.3048           ! meters to feet conversion factor
    real, parameter :: FT_TO_M = 0.3048                 ! feet to meters conversion factor
    real, parameter :: LBF_TO_N = 4.4482216152605       ! pounds force to Newtons conversion
    real, parameter :: SLUG_TO_KG = 14.5939029          ! slugs to kilograms conversion
    
    real, parameter :: TOLERANCE = 1.0e-13

    real, parameter :: PI = 3.1415926535897932384626433832795
    real, parameter :: DEG2RAD = PI / 180.0
    real, parameter :: RAD2DEG = 180.0 / PI
    
    real, parameter :: G_SSL_SI = 9.80665                           ! sea level gravitational acceleration [m/s^2]
    real, parameter :: R_EARTH_SI = 6356766.0                       ! earth's geopotential radius (m, for atmosphere model)
    real, parameter :: R_EARTH_ENGLISH = R_EARTH_SI * M_TO_FT
    real, parameter :: R_MEAN_EARTH_SI = 6366707.01949371           ! earth's mean radius at sea level (for gravity relief)
    real, parameter :: R_MEAN_EARTH_ENGLISH = R_MEAN_EARTH_SI * M_TO_FT
    real, parameter :: R_AIR = 287.0528                             ! specific gas constant for dry air [J/(kg·K)]
    real, parameter :: GAMMA_AIR = 1.4                              ! ratio of specific heats (Cp/Cv) for air
    real, parameter :: R_POLAR_M = 6356751.6                        ! polar radius for elliptic earth model
    real, parameter :: R_EQUAT_M = 6378136.3                        ! equatorial radius for elliptic earth model
    real, parameter :: R_POLAR_FT = R_POLAR_M * M_TO_FT
    real, parameter :: R_EQUAT_FT = R_EQUAT_M * M_TO_FT
    real, parameter :: E2 = 1.0 - (R_POLAR_M/R_EQUAT_M)**2          ! eq 7.5.19 for elliptic earth model

    ! unit conversion factors: SI to English
    real, parameter :: K_TO_RANKINE = 1.8                          ! Kelvin to Rankine
    real, parameter :: PA_TO_PSF = 1.0 / 47.880258                 ! Pascals to lbf/ft^2
    real, parameter :: KGM3_TO_SLUGFT3 = 1.0 / 515.379            ! kg/m^3 to slug/ft^3

    real, parameter :: SEC_PER_YEAR = 31557600.0                   ! Julian year [s] (for WMM decimal-year advance)

end module constants_m