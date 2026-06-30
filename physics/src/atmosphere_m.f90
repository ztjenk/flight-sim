! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

module atmosphere_m
    use constants_m
    implicit none
    public :: gravity_english
    public :: std_atm_si, std_atm_english       ! atmosphere models

    ! standard sea-level values
    real, parameter :: T_SL_STD = 288.15    ! standard sea-level temperature [K]
    real, parameter :: P_SL_STD = 101325.0  ! standard sea-level pressure [Pa]

    ! lapse rates for each layer [K/m]
    real, parameter :: LAPSE_0 = -0.0065   ! troposphere (0-11 km)
    real, parameter :: LAPSE_2 =  0.001    ! stratosphere (20-32 km)
    real, parameter :: LAPSE_3 =  0.0028   ! upper stratosphere (32-47 km)
    real, parameter :: LAPSE_5 = -0.002    ! mesosphere (52-61 km)
    real, parameter :: LAPSE_6 = -0.004    ! upper mesosphere (61-79 km)

    ! layer boundary altitudes [m geopotential]
    real, parameter :: Z1 = 11000.0, Z2 = 20000.0, Z3 = 32000.0
    real, parameter :: Z4 = 47000.0, Z5 = 52000.0, Z6 = 61000.0
    real, parameter :: Z7 = 79000.0, Z8 = 90000.0

contains

    ! gravity_english: returns gravity magnitude in English units
    pure function gravity_english(alt) result(g)
        real, intent(in) :: alt  ! altitude above sea level (ft)
        real :: g
        real :: r_ft              ! Earth radius in feet
        r_ft = R_EARTH_SI * M_TO_FT
        g = G_SSL_SI * M_TO_FT * (r_ft / (r_ft + alt))**2       ! eq 3.2.1
    end function gravity_english

    ! std_atm_si: computes atmospheric properties in SI units
    ! Recomputes the full atmosphere profile from sea-level base values.
    ! Optional T_sl_override and P_sl_override replace the standard 288.15 K / 101325 Pa.
    subroutine std_atm_si(geom_alt, Z, T, P, rho, a, mu, T_sl_override, P_sl_override)
        real, intent(in)  :: geom_alt  ! geometric altitude [m] (true height above MSL)
        real, intent(out) :: Z         ! geopotential altitude [m] (gravity-adjusted)
        real, intent(out) :: T         ! static temperature [K]
        real, intent(out) :: P         ! static pressure [Pa]
        real, intent(out) :: rho       ! air density [kg/m^3]
        real, intent(out) :: a         ! speed of sound [m/s]
        real, intent(out) :: mu        ! dynamic viscosity [Pa*s]
        real, intent(in), optional :: T_sl_override  ! sea-level temperature [K]
        real, intent(in), optional :: P_sl_override  ! sea-level pressure [Pa]

        real :: gsslR
        real :: T_sl, P_sl
        real :: T_b, P_b  ! temperature and pressure at current layer base

        gsslR = G_SSL_SI / R_AIR

        T_sl = T_SL_STD
        P_sl = P_SL_STD
        if (present(T_sl_override)) T_sl = T_sl_override
        if (present(P_sl_override)) P_sl = P_sl_override

        Z = R_EARTH_SI * geom_alt / (R_EARTH_SI + geom_alt)     ! eq 3.2.2

        if (Z < 0.0) then
            T = T_sl
            P = P_sl
        else if (Z < Z1) then
            ! troposphere: lapse rate -6.5 K/km
            T = T_sl + LAPSE_0 * Z
            P = P_sl * (T / T_sl) ** (-gsslR / LAPSE_0)
        else
            ! cascade through layers from modified base values
            ! layer 0 -> layer 1 boundary (Z=11000)
            T_b = T_sl + LAPSE_0 * Z1
            P_b = P_sl * (T_b / T_sl) ** (-gsslR / LAPSE_0)

            if (Z < Z2) then
                ! lower stratosphere: isothermal
                T = T_b
                P = P_b * exp(-gsslR * (Z - Z1) / T_b)
            else
                ! layer 1 -> layer 2 boundary (Z=20000)
                P_b = P_b * exp(-gsslR * (Z2 - Z1) / T_b)
                ! T_b stays the same (isothermal layer)

                if (Z < Z3) then
                    ! stratosphere: lapse rate +1.0 K/km
                    T = T_b + LAPSE_2 * (Z - Z2)
                    P = P_b * (T / T_b) ** (-gsslR / LAPSE_2)
                else
                    ! layer 2 -> layer 3 boundary (Z=32000)
                    T_b = T_b + LAPSE_2 * (Z3 - Z2)
                    P_b = P_b * ((T_b) / (T_b - LAPSE_2 * (Z3 - Z2))) ** (-gsslR / LAPSE_2)

                    if (Z < Z4) then
                        ! upper stratosphere: lapse rate +2.8 K/km
                        T = T_b + LAPSE_3 * (Z - Z3)
                        P = P_b * (T / T_b) ** (-gsslR / LAPSE_3)
                    else
                        ! layer 3 -> layer 4 boundary (Z=47000)
                        T_b = T_b + LAPSE_3 * (Z4 - Z3)
                        P_b = P_b * ((T_b) / (T_b - LAPSE_3 * (Z4 - Z3))) ** (-gsslR / LAPSE_3)

                        if (Z < Z5) then
                            ! stratopause: isothermal
                            T = T_b
                            P = P_b * exp(-gsslR * (Z - Z4) / T_b)
                        else
                            ! layer 4 -> layer 5 boundary (Z=52000)
                            P_b = P_b * exp(-gsslR * (Z5 - Z4) / T_b)

                            if (Z < Z6) then
                                ! mesosphere: lapse rate -2.0 K/km
                                T = T_b + LAPSE_5 * (Z - Z5)
                                P = P_b * (T / T_b) ** (-gsslR / LAPSE_5)
                            else
                                ! layer 5 -> layer 6 boundary (Z=61000)
                                T_b = T_b + LAPSE_5 * (Z6 - Z5)
                                P_b = P_b * ((T_b) / (T_b - LAPSE_5 * (Z6 - Z5))) ** (-gsslR / LAPSE_5)

                                if (Z < Z7) then
                                    ! upper mesosphere: lapse rate -4.0 K/km
                                    T = T_b + LAPSE_6 * (Z - Z6)
                                    P = P_b * (T / T_b) ** (-gsslR / LAPSE_6)
                                else
                                    ! layer 6 -> layer 7 boundary (Z=79000)
                                    T_b = T_b + LAPSE_6 * (Z7 - Z6)
                                    P_b = P_b * ((T_b) / (T_b - LAPSE_6 * (Z7 - Z6))) ** (-gsslR / LAPSE_6)

                                    if (Z <= Z8) then
                                        ! thermosphere: isothermal
                                        T = T_b
                                        P = P_b * exp(-gsslR * (Z - Z7) / T_b)
                                    else
                                        T = T_b
                                        P = 0.0
                                    end if
                                end if
                            end if
                        end if
                    end if
                end if
            end if
        end if

        rho = P / (R_AIR * T)               ! density, eq 3.2.8
        a = sqrt(GAMMA_AIR * R_AIR * T)     ! speed of sound, eq 3.2.9
        mu = 1.716e-5 * ((110.4 + 273.15)/(T + 110.4)) * (T/273.15)**1.5    ! eq 3.2.10
    end subroutine std_atm_si

    subroutine std_atm_english(geom_alt, Z, T, P, rho, a, mu, T_sl_R, P_sl_psf)
        real, intent(in)  :: geom_alt
        real, intent(out) :: Z
        real, intent(out) :: T
        real, intent(out) :: P
        real, intent(out) :: rho
        real, intent(out) :: a
        real, intent(out) :: mu
        real, intent(in), optional :: T_sl_R      ! sea-level temperature [Rankine]
        real, intent(in), optional :: P_sl_psf    ! sea-level pressure [psf]

        real :: T_sl_K, P_sl_Pa

        if (present(T_sl_R) .and. present(P_sl_psf)) then
            T_sl_K = T_sl_R / K_TO_RANKINE
            P_sl_Pa = P_sl_psf / PA_TO_PSF
            call std_atm_si(geom_alt * FT_TO_M, Z, T, P, rho, a, mu, T_sl_K, P_sl_Pa)
        else if (present(T_sl_R)) then
            T_sl_K = T_sl_R / K_TO_RANKINE
            call std_atm_si(geom_alt * FT_TO_M, Z, T, P, rho, a, mu, T_sl_K)
        else if (present(P_sl_psf)) then
            P_sl_Pa = P_sl_psf / PA_TO_PSF
            call std_atm_si(geom_alt * FT_TO_M, Z, T, P, rho, a, mu, P_sl_override=P_sl_Pa)
        else
            call std_atm_si(geom_alt * FT_TO_M, Z, T, P, rho, a, mu)
        end if
        ! convert all outputs to English units
        Z   = Z * M_TO_FT
        T   = T * K_TO_RANKINE
        P   = P * PA_TO_PSF
        rho = rho * KGM3_TO_SLUGFT3
        a   = a * M_TO_FT
        mu  = mu * PA_TO_PSF
    end subroutine std_atm_english

end module atmosphere_m
