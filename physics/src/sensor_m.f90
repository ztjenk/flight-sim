! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! sensor simulation module — models realistic onboard sensors with error pipeline
! sensors read true vehicle state and output corrupted measurements
! Ch. 10.4 "Simulating Sensors" and 10.5 "Error and Quantization"
module sensor_m
    use constants_m
    use math_m
    use atmosphere_m
    use random_m
    implicit none
    private

    ! type ID constants
    integer, parameter, public :: SENSOR_GYROSCOPE     = 1
    integer, parameter, public :: SENSOR_ACCELEROMETER = 2
    integer, parameter, public :: SENSOR_IMU           = 3
    integer, parameter, public :: SENSOR_ADS           = 4
    integer, parameter, public :: SENSOR_GPS           = 5
    integer, parameter, public :: SENSOR_AERO_ANGLES   = 6
    integer, parameter, public :: SENSOR_MAGNETOMETER  = 7

    ! public types
    public :: sensor_error_model_t, sensor_t, sensor_wrapper_t

    ! public procedures
    public :: sensor_init, sensor_update, sensor_header, sensor_n_outputs

    ! --- types ---

    type :: sensor_error_model_t
        real, allocatable :: bias(:)           ! constant offset per channel
        real, allocatable :: noise_std(:)      ! Gaussian noise sigma per channel
        real, allocatable :: g_min(:)          ! saturation / quantization lower bound
        real, allocatable :: g_max(:)          ! saturation / quantization upper bound
        integer           :: bit_count = 0    ! ADC resolution (0 = disabled)
    end type sensor_error_model_t

    type :: sensor_t
        integer           :: type_id = 0       ! SENSOR_GYROSCOPE, etc.
        integer           :: n_outputs = 0     ! number of output channels
        character(len=64) :: name = ''         ! user-defined name (JSON key)
        real              :: location(3) = 0.0 ! position offset from CG [ft], body frame
        real              :: attitude(3) = 0.0 ! Euler angles [rad] of sensor relative to body
        real              :: rotation(3,3) = 0.0 ! DCM: body frame -> sensor frame
        type(sensor_error_model_t) :: error
        real, allocatable :: output(:)         ! current output (after error pipeline)
        real, allocatable :: true_output(:)    ! pre-error output
        real              :: mag_field(3) = [20225.1, 3919.4, 46952.8] ! Earth-frame magnetic field [nT]
        real              :: refresh_interval = 0.0 ! minimum time between updates [s]
        real              :: last_update_time = -1.0e30 ! last time sensor was updated [s]
        logical           :: has_location = .false. ! true if location is non-zero
    end type sensor_t

    type :: sensor_wrapper_t
        type(sensor_t), allocatable :: sensor
    end type sensor_wrapper_t

    ! --- sea-level reference values for ADS ---
    real, parameter :: T_SSL_R   = 518.67        ! sea level temperature [Rankine]
    real, parameter :: P_SSL_PSF = 2116.22       ! sea level pressure [psf]
    real, parameter :: RHO_SSL   = 0.002376892   ! sea level density [slug/ft^3]
    ! R_air in English: ft-lbf/(slug-R)
    real, parameter :: R_AIR_ENG = R_AIR * M_TO_FT * M_TO_FT / K_TO_RANKINE  ! ~1716.49

contains

    ! --- initialization ---

    subroutine sensor_init(s, type_string, name)
        type(sensor_t), intent(inout) :: s
        character(len=*), intent(in) :: type_string
        character(len=*), intent(in) :: name

        s%name = trim(name)

        ! determine type_id and n_outputs from type string
        select case (trim(type_string))
        case ('gyroscope')
            s%type_id = SENSOR_GYROSCOPE
            s%n_outputs = 3
        case ('accelerometer')
            s%type_id = SENSOR_ACCELEROMETER
            s%n_outputs = 3
        case ('imu')
            s%type_id = SENSOR_IMU
            s%n_outputs = 9
        case ('air_data_system')
            s%type_id = SENSOR_ADS
            s%n_outputs = 6
        case ('gps')
            s%type_id = SENSOR_GPS
            s%n_outputs = 6
        case ('aero_angles')
            s%type_id = SENSOR_AERO_ANGLES
            s%n_outputs = 2
        case ('magnetometer')
            s%type_id = SENSOR_MAGNETOMETER
            s%n_outputs = 3
        case default
            write(*,*) 'ERROR: Unknown sensor type: ', trim(type_string)
            stop
        end select

        ! allocate output arrays
        allocate(s%output(s%n_outputs))
        allocate(s%true_output(s%n_outputs))
        s%output = 0.0
        s%true_output = 0.0

        ! build rotation matrix from attitude Euler angles
        call build_sensor_dcm(s)

        ! check if location offset is non-zero
        s%has_location = (abs(s%location(1)) > TOLERANCE .or. &
                          abs(s%location(2)) > TOLERANCE .or. &
                          abs(s%location(3)) > TOLERANCE)
    end subroutine sensor_init

    ! return n_outputs for a given type string
    pure function sensor_n_outputs(type_string) result(n)
        character(len=*), intent(in) :: type_string
        integer :: n
        select case (trim(type_string))
        case ('gyroscope');       n = 3
        case ('accelerometer');   n = 3
        case ('imu');             n = 9
        case ('air_data_system'); n = 6
        case ('gps');             n = 6
        case ('aero_angles');     n = 2
        case ('magnetometer');    n = 3
        case default;             n = 0
        end select
    end function sensor_n_outputs

    ! build DCM from sensor Euler angles (body -> sensor frame)
    subroutine build_sensor_dcm(s)
        type(sensor_t), intent(inout) :: s
        real :: phi, theta, psi
        real :: cp, sp, ct, st, cpsi, spsi

        phi   = s%attitude(1)
        theta = s%attitude(2)
        psi   = s%attitude(3)

        cp = cos(phi);   sp = sin(phi)
        ct = cos(theta); st = sin(theta)
        cpsi = cos(psi); spsi = sin(psi)

        ! DCM: body -> sensor (Eq 1.2.5 / 10.4.13)
        s%rotation(1,1) = ct*cpsi
        s%rotation(1,2) = ct*spsi
        s%rotation(1,3) = -st
        s%rotation(2,1) = sp*st*cpsi - cp*spsi
        s%rotation(2,2) = sp*st*spsi + cp*cpsi
        s%rotation(2,3) = sp*ct
        s%rotation(3,1) = cp*st*cpsi + sp*spsi
        s%rotation(3,2) = cp*st*spsi - sp*cpsi
        s%rotation(3,3) = cp*ct
    end subroutine build_sensor_dcm

    ! rotate a 3-vector from body to sensor frame using the DCM
    pure function rotate_to_sensor(s, v_body) result(v_sensor)
        type(sensor_t), intent(in) :: s
        real, intent(in) :: v_body(3)
        real :: v_sensor(3)
        v_sensor(1) = s%rotation(1,1)*v_body(1) + s%rotation(1,2)*v_body(2) + s%rotation(1,3)*v_body(3)
        v_sensor(2) = s%rotation(2,1)*v_body(1) + s%rotation(2,2)*v_body(2) + s%rotation(2,3)*v_body(3)
        v_sensor(3) = s%rotation(3,1)*v_body(1) + s%rotation(3,2)*v_body(2) + s%rotation(3,3)*v_body(3)
    end function rotate_to_sensor

    ! --- main update routine ---

    subroutine sensor_update(s, velocity, omega, position, quaternion, &
                             F_total, M_total, I_inv, mass, &
                             altitude, gust, mag_field, wind, T_sl_R, P_sl_psf)
        type(sensor_t), intent(inout) :: s
        real, intent(in) :: velocity(3)    ! body-frame velocity [ft/s]
        real, intent(in) :: omega(3)       ! body-frame angular velocity [rad/s]
        real, intent(in) :: position(3)    ! Earth-frame position [ft]
        real, intent(in) :: quaternion(4)  ! attitude quaternion (e0, ex, ey, ez)
        real, intent(in) :: F_total(3)     ! total non-grav force [lbf], body frame
        real, intent(in) :: M_total(3)     ! total moment [ft-lbf], body frame
        real, intent(in) :: I_inv(3,3)     ! inverse inertia tensor [1/(slug-ft^2)]
        real, intent(in) :: mass           ! vehicle mass [slug]
        real, intent(in) :: altitude       ! geometric altitude [ft] (positive up)
        real, intent(in) :: gust(6)        ! [u,v,w,p,q,r] gust components
        real, intent(in) :: mag_field(3)   ! Earth-frame magnetic field [nT]
        real, intent(in) :: wind(3)        ! constant wind [N, E, D] in Earth frame [ft/s]
        real, intent(in), optional :: T_sl_R    ! sea-level temperature [Rankine] (non-standard day)
        real, intent(in), optional :: P_sl_psf  ! sea-level pressure [psf] (non-standard day)

        select case (s%type_id)
        case (SENSOR_GYROSCOPE)
            call update_gyroscope(s, omega)
        case (SENSOR_ACCELEROMETER)
            call update_accelerometer(s, omega, F_total, M_total, I_inv, mass)
        case (SENSOR_IMU)
            call update_imu(s, omega, F_total, M_total, I_inv, mass, quaternion, mag_field)
        case (SENSOR_ADS)
            call update_ads(s, velocity, altitude, gust, T_sl_R, P_sl_psf)
        case (SENSOR_GPS)
            call update_gps(s, position, velocity, quaternion, wind)
        case (SENSOR_AERO_ANGLES)
            call update_aero_angles(s, velocity, gust)
        case (SENSOR_MAGNETOMETER)
            call update_magnetometer(s, quaternion, mag_field)
        end select

        ! apply error pipeline
        call apply_errors(s)
    end subroutine sensor_update

    ! --- individual sensor physics ---

    ! Gyroscope: angular rates in sensor frame (Eq 10.4.11-10.4.13)
    subroutine update_gyroscope(s, omega)
        type(sensor_t), intent(inout) :: s
        real, intent(in) :: omega(3)

        s%true_output(1:3) = rotate_to_sensor(s, omega)
    end subroutine update_gyroscope

    ! Specific force at a sensor location with CG-offset correction (Eq 10.4.16-10.4.19)
    pure function specific_force_at_sensor(location, has_location, omega, F_total, M_total, I_inv, mass) result(a)
        real, intent(in) :: location(3), omega(3), F_total(3), M_total(3), I_inv(3,3), mass
        logical, intent(in) :: has_location
        real :: a(3)
        real :: a_cg(3), omega_dot(3), omega_cross_r(3)

        ! specific force at CG: F/m (Eq 10.4.16)
        if (mass > TOLERANCE) then
            a_cg = F_total / mass
        else
            a_cg = 0.0
        end if

        ! off-CG correction (Eq 10.4.18)
        if (has_location) then
            ! angular acceleration: omega_dot ≈ I_inv * M_total
            ! (omits gyroscopic coupling omega x I*omega which is small
            !  relative to sensor noise for most flight conditions)
            omega_dot(1) = I_inv(1,1)*M_total(1) + I_inv(1,2)*M_total(2) + I_inv(1,3)*M_total(3)
            omega_dot(2) = I_inv(2,1)*M_total(1) + I_inv(2,2)*M_total(2) + I_inv(2,3)*M_total(3)
            omega_dot(3) = I_inv(3,1)*M_total(1) + I_inv(3,2)*M_total(2) + I_inv(3,3)*M_total(3)

            ! omega_dot x r (Euler/tangential) + omega x (omega x r) (centripetal)
            omega_cross_r = cross3(omega, location)
            a = a_cg + cross3(omega_dot, location) + cross3(omega, omega_cross_r)
        else
            a = a_cg
        end if
    end function specific_force_at_sensor

    ! Accelerometer: specific force with CG-offset correction (Eq 10.4.16-10.4.19)
    subroutine update_accelerometer(s, omega, F_total, M_total, I_inv, mass)
        type(sensor_t), intent(inout) :: s
        real, intent(in) :: omega(3), F_total(3), M_total(3), I_inv(3,3), mass

        ! rotate to sensor frame (Eq 10.4.19)
        s%true_output(1:3) = rotate_to_sensor(s, &
            specific_force_at_sensor(s%location, s%has_location, omega, F_total, M_total, I_inv, mass))
    end subroutine update_accelerometer

    ! IMU: composite accel(3) + gyro(3) + mag(3) = 9 outputs
    subroutine update_imu(s, omega, F_total, M_total, I_inv, mass, quaternion, mag_field)
        type(sensor_t), intent(inout) :: s
        real, intent(in) :: omega(3), F_total(3), M_total(3), I_inv(3,3), mass
        real, intent(in) :: quaternion(4), mag_field(3)
        real :: B_body(3)

        ! accelerometer portion (channels 1-3)
        s%true_output(1:3) = rotate_to_sensor(s, &
            specific_force_at_sensor(s%location, s%has_location, omega, F_total, M_total, I_inv, mass))

        ! gyroscope portion (channels 4-6)
        s%true_output(4:6) = rotate_to_sensor(s, omega)

        ! magnetometer portion (channels 7-9)
        B_body = quat_rotate_inertial_to_body(mag_field, quaternion)
        s%true_output(7:9) = rotate_to_sensor(s, B_body)
    end subroutine update_imu

    ! Air Data System: pitot-static chain (Eq 10.4.1-10.4.7)
    ! outputs: [P0, P_inf, T_inf, V_IAS, V_CAS, V_EAS] in English units
    subroutine update_ads(s, velocity, altitude, gust, T_sl_R, P_sl_psf)
        type(sensor_t), intent(inout) :: s
        real, intent(in) :: velocity(3), altitude
        real, intent(in) :: gust(6)
        real, intent(in), optional :: T_sl_R    ! sea-level temperature [Rankine] (non-standard day)
        real, intent(in), optional :: P_sl_psf  ! sea-level pressure [psf] (non-standard day)
        real :: u_air, v_air, w_air, V_inf
        real :: Z, T_inf, P_inf, rho_inf, a_sound, mu_atm
        real :: P0, delta_P, V_IAS, V_EAS
        real :: gm1, gm1_over_g, g_over_gm1, pressure_ratio
        real :: T_sl_use, P_sl_use

        ! air-relative velocity (what the pitot tube sees)
        u_air = velocity(1) + gust(1)
        v_air = velocity(2) + gust(2)
        w_air = velocity(3) + gust(3)
        V_inf = sqrt(u_air*u_air + v_air*v_air + w_air*w_air)

        ! atmosphere at altitude (honor non-standard-day sea-level overrides so
        ! the ADS readout matches the air the vehicle actually flies through)
        T_sl_use = 0.0; P_sl_use = 0.0
        if (present(T_sl_R)) T_sl_use = T_sl_R
        if (present(P_sl_psf)) P_sl_use = P_sl_psf
        if (T_sl_use > 0.0 .or. P_sl_use > 0.0) then
            call std_atm_english(altitude, Z, T_inf, P_inf, rho_inf, a_sound, mu_atm, &
                                 T_sl_use, P_sl_use)
        else
            call std_atm_english(altitude, Z, T_inf, P_inf, rho_inf, a_sound, mu_atm)
        end if

        ! precompute gamma ratios
        gm1 = GAMMA_AIR - 1.0           ! 0.4
        gm1_over_g = gm1 / GAMMA_AIR    ! 0.4/1.4
        g_over_gm1 = GAMMA_AIR / gm1    ! 1.4/0.4 = 3.5

        ! stagnation pressure (Eq 10.4.2, solved for P0)
        if (T_inf > TOLERANCE) then
            pressure_ratio = 1.0 + gm1 / 2.0 * V_inf*V_inf / (GAMMA_AIR * R_AIR_ENG * T_inf)
            P0 = P_inf * pressure_ratio**g_over_gm1
        else
            P0 = P_inf
        end if

        ! indicated airspeed (Eq 10.4.5)
        delta_P = P0 - P_inf
        if (delta_P > 0.0) then
            V_IAS = sqrt(2.0 * GAMMA_AIR * R_AIR_ENG * T_SSL_R / gm1 * &
                        ((delta_P / P_SSL_PSF + 1.0)**gm1_over_g - 1.0))
        else
            V_IAS = 0.0
        end if

        ! equivalent airspeed (Eq 10.4.7)
        if (RHO_SSL > TOLERANCE) then
            V_EAS = V_inf * sqrt(rho_inf / RHO_SSL)
        else
            V_EAS = V_inf
        end if

        ! outputs: P0[psf], P_inf[psf], T_inf[R], V_IAS[ft/s], V_CAS[ft/s], V_EAS[ft/s]
        s%true_output(1) = P0
        s%true_output(2) = P_inf
        s%true_output(3) = T_inf
        s%true_output(4) = V_IAS
        s%true_output(5) = V_IAS   ! CAS = IAS when position/instrument errors are zero
        s%true_output(6) = V_EAS
    end subroutine update_ads

    ! GPS: position(3) + velocity(3) in Earth frame
    subroutine update_gps(s, position, velocity, quaternion, wind)
        type(sensor_t), intent(inout) :: s
        real, intent(in) :: position(3), velocity(3), quaternion(4), wind(3)

        ! position in Earth frame (direct)
        s%true_output(1:3) = position

        ! ground velocity = airspeed rotated to Earth frame + wind
        s%true_output(4:6) = quat_rotate_body_to_inertial(velocity, quaternion) + wind
    end subroutine update_gps

    ! Aerodynamic angles: alpha, beta using air-relative velocity (Eq 10.4.20-10.4.21)
    subroutine update_aero_angles(s, velocity, gust)
        type(sensor_t), intent(inout) :: s
        real, intent(in) :: velocity(3)
        real, intent(in) :: gust(6)
        real :: v_air(3)

        ! air-relative velocity
        v_air(1) = velocity(1) + gust(1)
        v_air(2) = velocity(2) + gust(2)
        v_air(3) = velocity(3) + gust(3)

        s%true_output(1) = calc_alpha(v_air)
        s%true_output(2) = calc_beta(v_air)
    end subroutine update_aero_angles

    ! Magnetometer: Earth magnetic field rotated to sensor frame
    subroutine update_magnetometer(s, quaternion, mag_field)
        type(sensor_t), intent(inout) :: s
        real, intent(in) :: quaternion(4), mag_field(3)
        real :: B_body(3)

        ! Earth -> body frame
        B_body = quat_rotate_inertial_to_body(mag_field, quaternion)
        ! body -> sensor frame
        s%true_output(1:3) = rotate_to_sensor(s, B_body)
    end subroutine update_magnetometer

    ! --- error pipeline (Sec 10.5) ---

    subroutine apply_errors(s)
        type(sensor_t), intent(inout) :: s
        integer :: i
        real :: delta_g

        ! start from true output
        s%output = s%true_output

        ! 1. bias
        if (allocated(s%error%bias)) then
            do i = 1, s%n_outputs
                s%output(i) = s%output(i) + s%error%bias(i)
            end do
        end if

        ! 2. Gaussian noise
        if (allocated(s%error%noise_std)) then
            do i = 1, s%n_outputs
                if (s%error%noise_std(i) > 0.0) then
                    s%output(i) = s%output(i) + rand_normal() * s%error%noise_std(i)
                end if
            end do
        end if

        ! 3. quantization (Eq 10.5.3)
        if (s%error%bit_count > 0 .and. allocated(s%error%g_min) .and. allocated(s%error%g_max)) then
            do i = 1, s%n_outputs
                delta_g = (s%error%g_max(i) - s%error%g_min(i)) / (2.0**s%error%bit_count)
                if (delta_g > TOLERANCE) then
                    s%output(i) = nint(s%output(i) / delta_g) * delta_g
                end if
            end do
        end if

        ! 4. saturation
        if (allocated(s%error%g_min) .and. allocated(s%error%g_max)) then
            do i = 1, s%n_outputs
                s%output(i) = max(s%error%g_min(i), min(s%error%g_max(i), s%output(i)))
            end do
        end if
    end subroutine apply_errors

    ! --- CSV header generation ---

    subroutine sensor_header(s, headers, n_headers)
        type(sensor_t), intent(in) :: s
        character(len=64), intent(out) :: headers(:)
        integer, intent(out) :: n_headers
        character(len=32) :: prefix

        prefix = trim(s%name) // '_'
        n_headers = s%n_outputs

        select case (s%type_id)
        case (SENSOR_GYROSCOPE)
            headers(1) = trim(prefix) // 'p[rad/s]'
            headers(2) = trim(prefix) // 'q[rad/s]'
            headers(3) = trim(prefix) // 'r[rad/s]'
        case (SENSOR_ACCELEROMETER)
            headers(1) = trim(prefix) // 'ax[ft/s^2]'
            headers(2) = trim(prefix) // 'ay[ft/s^2]'
            headers(3) = trim(prefix) // 'az[ft/s^2]'
        case (SENSOR_IMU)
            headers(1) = trim(prefix) // 'ax[ft/s^2]'
            headers(2) = trim(prefix) // 'ay[ft/s^2]'
            headers(3) = trim(prefix) // 'az[ft/s^2]'
            headers(4) = trim(prefix) // 'p[rad/s]'
            headers(5) = trim(prefix) // 'q[rad/s]'
            headers(6) = trim(prefix) // 'r[rad/s]'
            headers(7) = trim(prefix) // 'mx[nT]'
            headers(8) = trim(prefix) // 'my[nT]'
            headers(9) = trim(prefix) // 'mz[nT]'
        case (SENSOR_ADS)
            headers(1) = trim(prefix) // 'P0[psf]'
            headers(2) = trim(prefix) // 'Pinf[psf]'
            headers(3) = trim(prefix) // 'Tinf[R]'
            headers(4) = trim(prefix) // 'IAS[ft/s]'
            headers(5) = trim(prefix) // 'CAS[ft/s]'
            headers(6) = trim(prefix) // 'EAS[ft/s]'
        case (SENSOR_GPS)
            headers(1) = trim(prefix) // 'x[ft]'
            headers(2) = trim(prefix) // 'y[ft]'
            headers(3) = trim(prefix) // 'z[ft]'
            headers(4) = trim(prefix) // 'Vx[ft/s]'
            headers(5) = trim(prefix) // 'Vy[ft/s]'
            headers(6) = trim(prefix) // 'Vz[ft/s]'
        case (SENSOR_AERO_ANGLES)
            headers(1) = trim(prefix) // 'alpha[rad]'
            headers(2) = trim(prefix) // 'beta[rad]'
        case (SENSOR_MAGNETOMETER)
            headers(1) = trim(prefix) // 'Bx[nT]'
            headers(2) = trim(prefix) // 'By[nT]'
            headers(3) = trim(prefix) // 'Bz[nT]'
        end select
    end subroutine sensor_header

end module sensor_m
