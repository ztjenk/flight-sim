! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

module atmosphere_m
    use constants_m
    implicit none
    public :: gravity_english
    public :: std_atm_si, std_atm_english

contains

    ! gravity_si: returns gravity magnitude in SI units
    pure function gravity_si(alt) result(g)
        real, intent(in) :: alt  ! altitude above sea level (m)
        real :: g  
        g = G_SSL_SI * (R_EARTH_SI / (R_EARTH_SI + alt))**2     ! eq 3.2.1
    end function gravity_si
    
    ! gravity_english: returns gravity magnitude in English units
    pure function gravity_english(alt) result(g)
        real, intent(in) :: alt  ! altitude above sea level (ft)
        real :: g
        real :: r_ft              ! Earth radius in feet
        r_ft = R_EARTH_SI * M_TO_FT 
        g = G_SSL_SI * M_TO_FT * (r_ft / (r_ft + alt))**2       ! eq 3.2.1
    end function gravity_english

    ! std_atm_si: computes atmospheric properties in SI units
    subroutine std_atm_si(geom_alt, Z, T, P, rho, a, mu)
        real, intent(in)  :: geom_alt  ! geometric altitude [m] (true height above MSL)
        real, intent(out) :: Z         ! geopotential altitude [m] (gravity-adjusted)
        real, intent(out) :: T         ! static temperature [K]
        real, intent(out) :: P         ! static pressure [Pa]
        real, intent(out) :: rho       ! air density [kg/m^3]
        real, intent(out) :: a         ! speed of sound [m/s]
        real, intent(out) :: mu        ! dynamic viscosity [Pa*s]
        
        real :: gsslR  ! ratio g_ssl / R_air used in pressure calculations
        gsslR = G_SSL_SI / R_AIR
        
        Z = R_EARTH_SI * geom_alt / (R_EARTH_SI + geom_alt)     ! eq 3.2.2
        
        ! layer dependent temperature and pressure calculations (table 3.2.1 and 3.2.2)
        if (Z < 0.0) then
            ! below sea level: use sea-level values
            T = 288.15      ! temperate (K)
            P = 101325.0    ! pressure (Pa)
        else if (Z < 11000.0) then
            T = 288.15 - 0.0065*Z
            P = 101325.0 * (T/288.15)**(gsslR/0.0065)
        else if (Z < 20000.0) then
            T = 216.65
            P = 22632.031822221168 * exp(-gsslR*(Z - 11000.0)/T)
        else if (Z < 32000.0) then
            T = 216.65 + 0.001*(Z - 20000.0)
            P = 5474.8735282708267 * (T/216.65)**(-gsslR/0.001)
        else if (Z < 47000.0) then
            T = 228.65 + 0.0028*(Z - 32000.0)
            P = 868.01476908672271 * (T/228.65)**(-gsslR/0.0028)
        else if (Z < 52000.0) then
            T = 270.65
            P = 110.90558898922531 * exp(-gsslR*(Z - 47000.0)/T)
        else if (Z < 61000.0) then
            T = 270.65 - 0.002*(Z - 52000.0)
            P = 59.000524278924367 * (T/270.65)**(gsslR/0.002)
        else if (Z < 79000.0) then
            T = 252.65 - 0.004*(Z - 61000.0)
            P = 18.209924905017658 * (T/252.65)**(gsslR/0.004)
        else if (Z <= 90000.0) then
            T = 180.65
            P = 1.0377004548920223 * exp(-gsslR*(Z - 79000.0)/T)
        else
            T = 180.65
            P = 0.0
        end if
        
        rho = P / (R_AIR * T)               ! density, eq 3.2.8
        a = sqrt(GAMMA_AIR * R_AIR * T)     ! speed of sound, eq 3.2.9
        mu = 1.716e-5 * ((110.4 + 273.15)/(T + 110.4)) * (T/273.15)**1.5    ! eq 3.2.10
    end subroutine std_atm_si
    
    subroutine std_atm_english(geom_alt, Z, T, P, rho, a, mu)
        real, intent(in)  :: geom_alt  
        real, intent(out) :: Z         
        real, intent(out) :: T         
        real, intent(out) :: P         
        real, intent(out) :: rho       
        real, intent(out) :: a         
        real, intent(out) :: mu        
        
        ! compute in SI units first
        call std_atm_si(geom_alt * FT_TO_M, Z, T, P, rho, a, mu)
        ! convert all outputs to English units
        Z   = Z * M_TO_FT             
        T   = T * 1.8                 
        P   = P / 47.880258           
        rho = rho / 515.379           
        a   = a * M_TO_FT             
        mu  = mu / 47.880258
    end subroutine std_atm_english

end module atmosphere_m