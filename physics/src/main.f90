! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! use: flightsim input_physics.json (or whatever the json is called)
program main
    use constants_m
    use vehicle_types_m
    use vehicle_io_m
    use json_m, only: json_value, json_destroy
    use trim_m
    use analysis_m
    use simulation_m
    use atmosphere_m
    use connection_m
    use equations_m
    implicit none

    ! local variables
    character(len=256) :: filename
    integer :: num_configs, k, i, trim_result, n_vehicles

    ! multi-vehicle data (arrays)
    type(vehicle_config_t), allocatable :: configs(:)
    type(control_inputs_t), allocatable :: ctrls(:)
    type(passive_inputs_t), allocatable :: passives(:)
    type(vehicle_state_t), allocatable :: states(:)
    type(trim_settings_t), allocatable :: trim_settings_arr(:)
    logical, allocatable :: is_trim_arr(:)
    type(analysis_settings_t), allocatable :: analysis_settings_arr(:)
    logical, allocatable :: run_analysis_arr(:)
    type(simulation_settings_t) :: sim_settings
    type(atmosphere_settings_t) :: atmo_settings
    type(equation_set_t), allocatable :: eqsets(:)

    ! trim outputs
    type(vehicle_state_t) :: trim_state
    type(control_inputs_t) :: trim_controls

    ! simulator instance
    type(simulator_t) :: sim

    ! json root for telemetry loading (avoids double-parse)
    type(json_value), pointer :: json_root => null()

    ! build-flag guard: the whole engine assumes -fdefault-real-8 (all reals are
    ! double precision). a single-precision build would silently lose accuracy.
    if (precision(1.0) < 12) error stop 'build without -fdefault-real-8'

    ! initialize networking for windows
    call net_initialize()

    ! process each configuration file from command line
    num_configs = command_argument_count()
    if (num_configs == 0) then
        write(*,*) 'Usage: flightsim <config.json> [config2.json ...]'
        stop
    end if

    do k = 1, num_configs
        call get_command_argument(k, filename)

        write(*,*) ''
        write(*,*) 'LOADING CONFIGURATION: ', trim(filename)
        write(*,*) ''

        ! load ALL vehicles with run_physics=true from JSON
        call vehicles_init(trim(filename), n_vehicles, configs, ctrls, passives, states, &
                           sim_settings, atmo_settings, trim_settings_arr, is_trim_arr, &
                           analysis_settings_arr, run_analysis_arr, json_root, eqsets)

        write(*,*) '  Found ', n_vehicles, ' active vehicle(s)'

        ! compute non-standard day sea-level base values from user-specified conditions at altitude.
        ! MUST run before solve_trim / run_analysis so that trim and the exported A/B state-space
        ! linearization use the same (non-standard-day) atmosphere as the simulation. Altitude
        ! (states(1)%position(3)) is invariant across trim, so using the pre-trim state is correct.
        if (atmo_settings%has_temp_offset .or. atmo_settings%has_pres_offset) then
            block
                real :: init_alt, Z_geo, T_std, P_std, rho_std, a_std, mu_std
                real :: gsslR, Z_gp
                gsslR = G_SSL_SI / R_AIR

                init_alt = -states(1)%position(3)  ! NED: z is negative-down

                ! get standard-day values at initial altitude for reference
                call std_atm_english(init_alt, Z_geo, T_std, P_std, rho_std, a_std, mu_std)

                ! geopotential altitude in meters for back-computation
                Z_gp = R_EARTH_SI * (init_alt * FT_TO_M) / (R_EARTH_SI + init_alt * FT_TO_M)

                ! the back-computation below inverts the TROPOSPHERE-ONLY lapse model
                ! (constant LAPSE_0). That model is only valid up to the tropopause
                ! at 11 km geopotential; above it the inversion is physically wrong.
                if (Z_gp > 11000.0) then
                    write(*,*) 'ERROR: Non-standard-day sea-level back-computation is only '// &
                               'valid below the tropopause (11 km geopotential). Initial '// &
                               'geopotential altitude = ', Z_gp, ' m exceeds 11000 m.'
                    error stop 'atmosphere offset above tropopause is unsupported'
                end if

                if (atmo_settings%has_temp_offset) then
                    ! back-compute sea-level temperature from user's temp at altitude
                    ! troposphere: T = T_sl + L*Z  =>  T_sl = T_user - L*Z (in Kelvin)
                    ! convert user Rankine to Kelvin, subtract lapse, convert back
                    atmo_settings%T_sl_R = (atmo_settings%user_temp_R / K_TO_RANKINE &
                                           - LAPSE_0 * Z_gp) * K_TO_RANKINE
                    write(*,*) '  Atmosphere: sea-level temperature = ', atmo_settings%T_sl_R, &
                               ' R (standard = ', T_SL_STD * K_TO_RANKINE, ' R)'
                else
                    atmo_settings%T_sl_R = T_SL_STD * K_TO_RANKINE
                end if

                if (atmo_settings%has_pres_offset) then
                    ! back-compute sea-level pressure from user's pressure at altitude
                    ! troposphere: P = P_sl * (T/T_sl)^(-g/(R*L))
                    !   => P_sl = P_user / (T/T_sl)^(-g/(R*L))
                    block
                        real :: T_sl_K, T_at_alt_K, exponent
                        T_sl_K = atmo_settings%T_sl_R / K_TO_RANKINE
                        T_at_alt_K = T_sl_K + LAPSE_0 * Z_gp
                        exponent = -gsslR / LAPSE_0
                        atmo_settings%P_sl_psf = (atmo_settings%user_pres_psf / PA_TO_PSF) &
                                                 / (T_at_alt_K / T_sl_K) ** exponent * PA_TO_PSF
                    end block
                    write(*,*) '  Atmosphere: sea-level pressure = ', atmo_settings%P_sl_psf, &
                               ' psf (standard = ', P_SL_STD * PA_TO_PSF, ' psf)'
                else
                    atmo_settings%P_sl_psf = P_SL_STD * PA_TO_PSF
                end if
            end block
        end if

        ! perform trim for each vehicle that needs it
        do i = 1, n_vehicles
            if (is_trim_arr(i)) then
                write(*,*) 'Computing trim conditions for: ', trim(configs(i)%name)
                write(*,*) '  Type: ', trim(trim_settings_arr(i)%trim_type)

                ! solve_trim uses state/controls from JSON as initial guess
                call solve_trim(configs(i), &
                               states(i), &
                               ctrls(i), &
                               passives(i), &
                               trim_settings_arr(i), &
                               trim_state, trim_controls, trim_result, &
                               T_sl_R=atmo_settings%T_sl_R, P_sl_psf=atmo_settings%P_sl_psf)

                if (trim_result == 0) then
                    write(*,*) '  Trim converged successfully'
                    states(i) = trim_state
                    ctrls(i) = trim_controls
                else if (trim_result == 3) then
                    ! converged but outside effector limits: solve_trim has
                    ! zeroed the returned state/controls and already printed the
                    ! "running simulation" notice, so continue with those values
                    states(i) = trim_state
                    ctrls(i) = trim_controls
                else if (trim_result == 1) then
                    write(*,*) '  WARNING: Trim did not converge!'
                    stop
                else
                    write(*,*) '  ERROR: Singular Jacobian in trim solver'
                    stop
                end if
            end if
        end do

        ! perform state-space analysis for each vehicle that needs it
        do i = 1, n_vehicles
            if (run_analysis_arr(i)) then
                write(*,*) ''
                write(*,*) 'Running state-space analysis for: ', trim(configs(i)%name)
                call run_analysis(configs(i), states(i), ctrls(i), passives(i), &
                                  analysis_settings_arr(i), &
                                  T_sl_R=atmo_settings%T_sl_R, P_sl_psf=atmo_settings%P_sl_psf)
            end if
        end do

        ! initialize and run simulation
        write(*,*) ''
        write(*,*) 'Starting simulation...'
        write(*,*) '  Vehicles: ', n_vehicles
        write(*,*) '  Duration: ', sim_settings%t_final, ' s'
        write(*,*) '  Time step: ', sim_settings%dt, ' s'
        write(*,*) '  Save states: ', sim_settings%save_states
        write(*,*) '  RK4 verbose: ', sim_settings%rk4_verbose
        write(*,*) '  Geographic model: ', trim(sim_settings%geographic_model)
        write(*,*) '  Print states rate: ', sim_settings%print_states_rate, ' Hz'
        if (sim_settings%realtime) then
            if (abs(sim_settings%time_scale - 1.0) < 1.0e-6) then
                write(*,*) '  Mode: Real-time'
            else
                write(*,*) '  Mode: Real-time (', sim_settings%time_scale, 'x)'
            end if
        end if

        call sim%initialize(n_vehicles, configs, ctrls, passives, states, &
                            sim_settings%dt, sim_settings%t_final, &
                            sim_settings%save_states, sim_settings%rk4_verbose, &
                            json_root, sim_settings%geographic_model_ID, &
                            sim_settings%print_states_rate, atmo_settings%wind, &
                            sim_settings%realtime, sim_settings%time_scale, &
                            atmo_settings%turbulence, sim_settings%save_states_rate, &
                            atmo_settings%T_sl_R, atmo_settings%P_sl_psf, eqsets, &
                            atmo_settings%use_wmm, atmo_settings%date)

        ! json root no longer needed after telemetry loading
        if (associated(json_root)) call json_destroy(json_root)

        ! print initial state for all vehicles
        call sim%print_states()

        call sim%run()
        call sim%shutdown()

        ! cleanup arrays
        if (allocated(configs)) deallocate(configs)
        if (allocated(ctrls)) deallocate(ctrls)
        if (allocated(passives)) deallocate(passives)
        if (allocated(states)) deallocate(states)
        if (allocated(trim_settings_arr)) deallocate(trim_settings_arr)
        if (allocated(is_trim_arr)) deallocate(is_trim_arr)
        if (allocated(analysis_settings_arr)) deallocate(analysis_settings_arr)
        if (allocated(run_analysis_arr)) deallocate(run_analysis_arr)
        if (allocated(eqsets)) deallocate(eqsets)

        write(*,*) 'Simulation complete.'
        write(*,*) ''
    end do

    ! finalize networking for windows
    call net_finalize()
    
end program main