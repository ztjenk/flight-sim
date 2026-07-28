! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! vehicle JSON loading and configuration parsing
! split from vehicle_m.f90 — Phase 2 refactor
module vehicle_io_m
    use constants_m
    use math_m
    use json_m
    use jsonx_m
    use battery_m
    use force_source_m
    use aero_database_m
    use units_m, only: parse_variable_and_units, conversion_factor_from, conversion_factor_to, &
                       is_angular_unit, is_force_unit, is_torque_unit
    use atmosphere_m, only: std_atm_english
    use jsonx_units_m, only: jsonx_get_u
    use sensor_m, only: sensor_init, sensor_n_outputs, SENSOR_IMU
    use ekf_m, only: ekf_params_t
    use vehicle_types_m
    use equations_m
    implicit none
    private

    ! public procedures
    public :: vehicles_init  ! main entry point for loading from json
    public :: load_telemetry_configs
    public :: wire_equation_targets
    public :: wire_battery_pointers  ! re-bind motor->battery pointers after deep copy

contains

    ! json loading: main entry point
    subroutine vehicles_init(filename, n_vehicles, configs, ctrls, passives, states, &
                             sim_settings, atmo_settings, trim_settings_arr, is_trim_arr, &
                             analysis_settings_arr, run_analysis_arr, &
                             json_root, eqsets)
        character(*), intent(in) :: filename
        integer, intent(out) :: n_vehicles
        type(vehicle_config_t), allocatable, intent(out) :: configs(:)
        type(control_inputs_t), allocatable, intent(out) :: ctrls(:)
        type(passive_inputs_t), allocatable, intent(out) :: passives(:)
        type(vehicle_state_t), allocatable, intent(out) :: states(:)
        type(simulation_settings_t), intent(out) :: sim_settings
        type(atmosphere_settings_t), intent(out) :: atmo_settings
        type(trim_settings_t), allocatable, intent(out) :: trim_settings_arr(:)
        logical, allocatable, intent(out) :: is_trim_arr(:)
        type(analysis_settings_t), allocatable, intent(out) :: analysis_settings_arr(:)
        logical, allocatable, intent(out) :: run_analysis_arr(:)
        type(json_value), pointer, intent(out) :: json_root
        type(equation_set_t), allocatable, intent(out) :: eqsets(:)

        type(json_value), pointer :: root, j_sim, j_atmo, j_vehicles, j_veh
        logical :: run_physics, found
        integer :: i, k, n_children, n_atmo
        character(len=:), allocatable :: geo_model_str
        real, allocatable :: arr(:)

        ! load json and count active vehicles
        call jsonx_load(filename, root)
        call jsonx_get(root, 'vehicles', j_vehicles)
        call json_info(j_vehicles, n_children=n_children)

        n_vehicles = 0
        do i = 1, n_children
            call json_value_get(j_vehicles, i, j_veh)
            call jsonx_get(j_veh, 'run_physics', run_physics, .true.)   ! default to true if user doesn't specify
            if (run_physics) n_vehicles = n_vehicles + 1
        end do

        if (n_vehicles == 0) then
            write(*,*) 'ERROR: No vehicle with run_physics=true found'
            stop
        end if

        ! allocate arrays
        allocate(configs(n_vehicles), ctrls(n_vehicles), passives(n_vehicles), states(n_vehicles))
        allocate(trim_settings_arr(n_vehicles), is_trim_arr(n_vehicles))
        allocate(analysis_settings_arr(n_vehicles), run_analysis_arr(n_vehicles))
        allocate(eqsets(n_vehicles))

        ! load simulation settings
        call jsonx_get(root, 'simulation', j_sim)
        call jsonx_get_u(j_sim, 'time_step', sim_settings%dt)
        call jsonx_get_u(j_sim, 'end_time', sim_settings%t_final)
        call jsonx_get(j_sim, 'rk4_verbose', sim_settings%rk4_verbose, .false.)
        call jsonx_get(j_sim, 'save_states', sim_settings%save_states, .true.)
        call jsonx_get(j_sim, 'realtime', sim_settings%realtime, .false.)
        call jsonx_get(j_sim, 'time_scale', sim_settings%time_scale, 1.0)
        geo_model_str = 'flat'
        call jsonx_get(j_sim, 'geographic_model', geo_model_str)
        sim_settings%geographic_model = geo_model_str
        sim_settings%geographic_model_ID = 0
        if(geo_model_str == 'sphere')  sim_settings%geographic_model_ID = 1
        if(geo_model_str == 'ellipse') sim_settings%geographic_model_ID = 2
        call jsonx_get_u(j_sim, 'print_states_rate', sim_settings%print_states_rate, 0.0)
        call jsonx_get_u(j_sim, 'save_states_rate', sim_settings%save_states_rate, 0.0)
        call jsonx_get_u(j_sim, 'hold_time', sim_settings%hold_time, 0.0)

        ! backward compat: time_step[s]=0.0 triggers real-time mode with default dt
        if (sim_settings%dt <= 1.0e-13 .and. .not. sim_settings%realtime) then
            sim_settings%realtime = .true.
            sim_settings%dt = 0.01
            write(*,*) 'NOTE: time_step[s]=0.0 detected. Using realtime mode with dt=0.01s.'
            write(*,*) '      Prefer: "time_step[s]": 0.01, "realtime": true'
        else if (sim_settings%dt <= 1.0e-13 .and. sim_settings%realtime) then
            sim_settings%dt = 0.01
            write(*,*) 'NOTE: time_step[s]=0.0 with realtime=true. Defaulting dt to 0.01s.'
        end if

        ! load atmosphere settings (optional section)
        call json_get(root, 'atmosphere', j_atmo, found)
        if (found) then
            call jsonx_get_u(j_atmo, 'constant_wind', arr, 0.0, 3)
            if (allocated(arr)) then
                atmo_settings%wind = arr
                deallocate(arr)
            end if
            call load_turbulence_config(j_atmo, atmo_settings%turbulence)

            ! World Magnetic Model (optional): use_wmm toggles the WMM for the magnetometer field;
            ! date is the decimal year (e.g. 2026.5) for the secular variation. Requires the vehicle's
            ! initial latitude/longitude to be set (constant on flat earth, tracked on round earth).
            call jsonx_get(j_atmo, 'use_wmm', atmo_settings%use_wmm, .false.)
            call jsonx_get(j_atmo, 'date', atmo_settings%date, 2025.0)

            ! non-standard day: parse temperature_at_altitude[unit] and pressure_at_altitude[unit]
            block
                character(len=:), allocatable :: var_part, unit_part
                real :: raw_val
                integer :: nc, ic
                type(json_value), pointer :: j_child
                logical :: found_temp, found_pres

                found_temp = .false.
                found_pres = .false.

                ! scan atmosphere keys for temperature_at_altitude[unit] and pressure_at_altitude[unit]
                call json_info(j_atmo, n_children=nc)
                do ic = 1, nc
                    call json_value_get(j_atmo, ic, j_child)
                    if (.not. allocated(j_child%name)) cycle

                    call parse_variable_and_units(trim(j_child%name), var_part, unit_part)

                    if (trim(var_part) == 'temperature_at_altitude') then
                        if (j_child%data%var_type == json_real) then
                            raw_val = j_child%data%dbl_value
                        else if (j_child%data%var_type == json_integer) then
                            raw_val = real(j_child%data%int_value)
                        else
                            cycle
                        end if
                        ! convert absolute temperature to Rankine
                        if (.not. allocated(unit_part)) then
                            atmo_settings%user_temp_R = raw_val  ! assume Rankine
                        else
                            select case (trim(unit_part))
                            case ('F', 'degF')
                                atmo_settings%user_temp_R = raw_val + 459.67
                            case ('C', 'degC')
                                atmo_settings%user_temp_R = (raw_val + 273.15) * 1.8
                            case ('K')
                                atmo_settings%user_temp_R = raw_val * 1.8
                            case ('R')
                                atmo_settings%user_temp_R = raw_val
                            case default
                                write(*,*) 'ERROR: Unknown temperature unit ['//trim(unit_part)//']'
                                write(*,*) '  Supported: F, C, K, R'
                                stop
                            end select
                        end if
                        atmo_settings%has_temp_offset = .true.
                        found_temp = .true.
                    end if

                    if (trim(var_part) == 'pressure_at_altitude') then
                        if (j_child%data%var_type == json_real) then
                            raw_val = j_child%data%dbl_value
                        else if (j_child%data%var_type == json_integer) then
                            raw_val = real(j_child%data%int_value)
                        else
                            cycle
                        end if
                        ! convert to psf using units system
                        if (.not. allocated(unit_part)) then
                            atmo_settings%user_pres_psf = raw_val  ! assume psf
                        else
                            atmo_settings%user_pres_psf = raw_val * conversion_factor_from(unit_part)
                        end if
                        atmo_settings%has_pres_offset = .true.
                        found_pres = .true.
                    end if

                    if (allocated(var_part)) deallocate(var_part)
                    if (allocated(unit_part)) deallocate(unit_part)
                end do

                if (found_temp) write(*,*) '  Non-standard day temperature: ', &
                    atmo_settings%user_temp_R, ' R'
                if (found_pres) write(*,*) '  Non-standard day pressure: ', &
                    atmo_settings%user_pres_psf, ' psf'
            end block
        end if

        ! scan atmosphere section for equations (applied to all vehicles)
        if (found .and. associated(j_atmo)) then
            call scan_for_equations(j_atmo, 'atmosphere', eqsets(1))
        end if

        ! snapshot the atmosphere-only equation count BEFORE any vehicle config is loaded.
        ! load_vehicle_config(k=1) appends vehicle 1's own mass/source equations onto eqsets(1),
        ! so reading eqsets(1)%n later would pollute vehicles 2..N with vehicle 1's equations.
        n_atmo = eqsets(1)%n

        ! load each active vehicle
        k = 0
        do i = 1, n_children
            call json_value_get(j_vehicles, i, j_veh)
            call jsonx_get(j_veh, 'run_physics', run_physics, .true.)
            if (.not. run_physics) cycle

            k = k + 1
            ! copy ONLY the atmosphere equations to each vehicle's eqset (if more than one).
            ! Use the pre-loop snapshot n_atmo, not eqsets(1)%n, because eqsets(1) has by now
            ! also accumulated vehicle 1's mass/source equations (the multi-vehicle pollution bug).
            if (k > 1 .and. n_atmo > 0) then
                eqsets(k)%eqs(1:n_atmo) = eqsets(1)%eqs(1:n_atmo)
                eqsets(k)%n = n_atmo
            end if
            call load_vehicle_config(j_veh, configs(k), ctrls(k), passives(k), states(k), &
                                     trim_settings_arr(k), is_trim_arr(k), eqsets(k), &
                                     atmo_settings%wind)
            call load_analysis_config(j_veh, analysis_settings_arr(k), run_analysis_arr(k))
        end do

        ! return root for telemetry loading (caller must call json_destroy later)
        json_root => root
    end subroutine vehicles_init

    ! loads a vehicle from json
    subroutine load_vehicle_config(j_veh, config, ctrl, passive, state, trim_settings, is_trim, eqset, wind)
        type(json_value), pointer, intent(in) :: j_veh
        type(vehicle_config_t), intent(out) :: config
        type(control_inputs_t), intent(out) :: ctrl
        type(passive_inputs_t), intent(out) :: passive
        type(vehicle_state_t), intent(out) :: state
        type(trim_settings_t), intent(out) :: trim_settings
        logical, intent(out) :: is_trim
        type(equation_set_t), intent(inout) :: eqset
        real, target, intent(inout) :: wind(3)

        type(json_value), pointer :: j_init, j_sources, j_src
        real :: V0, alt, euler(3), alpha, beta
        real :: p, q, r, ref_b, ref_c
        integer :: n_src, is, k
        logical :: use_src

        ! vehicle name
        if (allocated(j_veh%name)) then
            config%name = trim(j_veh%name)
        else
            config%name = 'unknown'
        end if
        write(*,*) '  Loading vehicle: ', trim(config%name)

        ! optional kinematic flag (default false)
        call jsonx_get(j_veh, 'is_kinematic', config%is_kinematic, .false.)
        config%run_physics = .true.

        ! mass properties
        call load_mass_properties(j_veh, config%mass)

        ! scan mass section for equations (sines/polynomials)
        block
            type(json_value), pointer :: j_mass_eq
            call json_value_get(j_veh, 'mass', j_mass_eq)
            if (.not. json_failed() .and. associated(j_mass_eq)) then
                call scan_for_equations(j_mass_eq, 'mass', eqset)
            end if
            call json_clear_exceptions()
        end block

        ! control effectors
        call load_control_effectors(j_veh, ctrl)

        ! passive effectors (must be parsed before force sources for name resolution)
        call load_passive_effectors(j_veh, passive)

        ! batteries (must be loaded before force sources for name resolution)
        call load_batteries(j_veh, config)

        ! force sources
        call jsonx_get(j_veh, 'force_sources', j_sources)
        if (associated(j_sources)) then
            call json_info(j_sources, n_children=n_src)
            if (n_src > 0) then
                allocate(config%sources(n_src))
                k = 0
                do is = 1, n_src
                    call json_value_get(j_sources, is, j_src)
                    ! check use_source flag (defaults to true if absent)
                    call jsonx_get(j_src, 'use_source', use_src, .true.)
                    if (.not. use_src) cycle
                    k = k + 1
                    call load_force_source(j_src, config%sources(k), ctrl, passive, config)
                    ! scan this source's JSON for equations (sines/polynomials on any field)
                    call scan_for_equations(j_src, trim(config%sources(k)%src%name), eqset)
                end do
                config%n_sources = k
            else
                config%n_sources = 0
            end if
        else
            config%n_sources = 0
        end if

        ! wire battery pointers for electric motors
        call wire_battery_pointers(config)

        ! parse passive effector driving coefficients/databases (after force sources for pool layout)
        if (passive%n > 0) call parse_passive_driving(j_veh, ctrl, passive, config)

        ! wire any equation-defined fields and seed them with their IV=0 value
        ! BEFORE mass assembly so the assembled CG/inertia reflect the true
        ! initial state (e.g., a payload whose weight is defined by a step
        ! equation contributes its 'before' weight to the trim configuration).
        if (eqset%n > 0) call wire_equation_targets(eqset, config, wind)

        ! finalize configuration
        call config%initialize()

        ! load sensors (if present)
        call load_sensors(j_veh, config)

        ! extract reference lengths from first aero source (for pbar/qbar/rbar conversion)
        ref_b = 0.0; ref_c = 0.0
        do is = 1, config%n_sources
            ref_b = config%sources(is)%src%get_b_ref()
            ref_c = config%sources(is)%src%get_c_bar()
            if (ref_b > 0.0 .or. ref_c > 0.0) exit
        end do

        ! initial conditions + trim settings
        call jsonx_get(j_veh, 'initial', j_init)
        call load_initial_conditions(j_init, ctrl, passive, config%name, &
                                     V0, alt, euler, alpha, beta, &
                                     p, q, r, ref_b, ref_c, is_trim, &
                                     config%sources, config%n_sources)

        ! trim settings (only parse when trimming — otherwise leave effector values from state)
        if (is_trim) call load_trim_settings(j_init, ctrl, config%name, trim_settings)

        ! build state
        if (is_trim) then
            call init_to_trim(V0, alt, euler, state)
        else
            call init_to_state(V0, alpha, beta, p, q, r, alt, euler, state)
        end if

        call jsonx_get_u(j_init, 'latitude', state%latitude, 0.0)
        call jsonx_get_u(j_init, 'longitude', state%longitude, 0.0)

    end subroutine load_vehicle_config

    ! load mass properties from JSON
    subroutine load_mass_properties(j_veh, mass)
        type(json_value), pointer, intent(in) :: j_veh
        type(mass_properties_t), intent(inout) :: mass
        type(json_value), pointer :: j_mass
        real, allocatable :: arr(:)

        ! The vehicle-level "mass" block is OPTIONAL. When it is absent, the base
        ! mass stays at the type's zero defaults and the total mass / CG / inertia
        ! are assembled purely from the per-component "mass" blocks (a fully
        ! component-built vehicle). assemble_mass_properties handles base = 0.
        call json_value_get(j_veh, 'mass', j_mass)
        if (json_failed() .or. .not. associated(j_mass)) then
            call json_clear_exceptions()
            mass%weight_lbf = 0.0
            mass%mass = 0.0
            mass%I = 0.0
            mass%h = 0.0
            return
        end if
        call jsonx_get_u(j_mass, 'weight', mass%weight_lbf, 0.0)
        ! Diagonal inertias default to 0.0: they may be supplied directly here
        ! OR defined via a sines/polynomials/steps equation block (e.g. a BIRE
        ! whose Iyy/Izz vary with effector deflection). The equation system is
        ! scanned and seeded with each target's IV=0 value immediately after this
        ! routine returns (see wire_equation_targets), so a 0.0 here is replaced
        ! before any consumer (trim, mass assembly) reads it.
        call jsonx_get_u(j_mass, 'Ixx', mass%I(1,1), 0.0)
        call jsonx_get_u(j_mass, 'Iyy', mass%I(2,2), 0.0)
        call jsonx_get_u(j_mass, 'Izz', mass%I(3,3), 0.0)
        call jsonx_get_u(j_mass, 'Ixy', mass%I(1,2), 0.0)
        call jsonx_get_u(j_mass, 'Ixz', mass%I(1,3), 0.0)
        call jsonx_get_u(j_mass, 'Iyz', mass%I(2,3), 0.0)
        mass%I(2,1) = mass%I(1,2)
        mass%I(3,1) = mass%I(1,3)
        mass%I(3,2) = mass%I(2,3)

        call jsonx_get_u(j_mass, 'h', arr, 0.0, 3)
        if (allocated(arr)) then
            mass%h = arr
            deallocate(arr)
        end if
    end subroutine load_mass_properties

    ! load optional per-component mass properties from force source JSON
    subroutine load_component_mass(j_src, cm)
        type(json_value), pointer, intent(in) :: j_src
        type(component_mass_t), intent(inout) :: cm
        type(json_value), pointer :: j_mass
        real, allocatable :: arr(:)

        ! check if "mass" sub-object exists
        call json_value_get(j_src, 'mass', j_mass)
        if (.not. associated(j_mass)) return

        cm%has_mass = .true.

        ! weight may be a literal or supplied by an equation block; the
        ! equation system seeds the IV=0 value before mass assembly runs.
        call jsonx_get_u(j_mass, 'weight', cm%weight_lbf, 0.0)
        cm%mass = cm%weight_lbf / (G_SSL_SI * M_TO_FT)

        ! CG offset in component frame (optional, default [0,0,0])
        call jsonx_get_u(j_mass, 'cg', arr, 0.0, 3)
        if (allocated(arr)) then
            cm%cg = arr
            deallocate(arr)
        end if

        ! inertia tensor components (optional, default 0 = point mass)
        call jsonx_get_u(j_mass, 'Ixx', cm%I(1,1), 0.0)
        call jsonx_get_u(j_mass, 'Iyy', cm%I(2,2), 0.0)
        call jsonx_get_u(j_mass, 'Izz', cm%I(3,3), 0.0)
        call jsonx_get_u(j_mass, 'Ixy', cm%I(1,2), 0.0)
        call jsonx_get_u(j_mass, 'Ixz', cm%I(1,3), 0.0)
        call jsonx_get_u(j_mass, 'Iyz', cm%I(2,3), 0.0)
        cm%I(2,1) = cm%I(1,2)
        cm%I(3,1) = cm%I(1,3)
        cm%I(3,2) = cm%I(2,3)

        ! inertia reference point (optional, defaults to CG)
        call jsonx_get_u(j_mass, 'inertia_ref', arr, 0.0, 3)
        if (json_found .and. allocated(arr)) then
            cm%inertia_ref = arr
            cm%has_inertia_ref = .true.
            deallocate(arr)
        end if

        ! angular momentum from spinning parts (optional)
        call jsonx_get_u(j_mass, 'h', arr, 0.0, 3)
        if (allocated(arr)) then
            cm%h = arr
            deallocate(arr)
        end if
    end subroutine load_component_mass

    ! load control effectors from JSON
    subroutine load_control_effectors(j_veh, ctrl)
        type(json_value), pointer, intent(in) :: j_veh
        type(control_inputs_t), intent(out) :: ctrl

        type(json_value), pointer :: j_ctrl_eff, j_eff
        real, allocatable :: arr(:)
        character(len=:), allocatable :: units_str, eff_base, eff_units_part
        integer :: n_eff, ie

        call jsonx_get(j_veh, 'control_effectors', j_ctrl_eff)
        if (associated(j_ctrl_eff)) then
            call json_info(j_ctrl_eff, n_children=n_eff)
        else
            n_eff = 0
        end if

        ctrl%n = n_eff
        if (n_eff == 0) return

        allocate(ctrl%effectors(n_eff))
        do ie = 1, n_eff
            call json_value_get(j_ctrl_eff, ie, j_eff)

            ! effector name from json key (strip [units] brackets if present)
            if (allocated(j_eff%name)) then
                call parse_variable_and_units(trim(j_eff%name), eff_base, eff_units_part)
                ctrl%effectors(ie)%name = eff_base
            else
                write(ctrl%effectors(ie)%name, '(A,I0)') 'effector_', ie
            end if

            ! dynamics order (0=instant, 1=first order, 2=second order)
            call jsonx_get(j_eff, 'dynamics_order', ctrl%effectors(ie)%dynamics_order, 0)

            ! magnitude_limits — auto-detect angle from units
            call jsonx_get_u(j_eff, 'magnitude_limits', arr, 0.0, 2, units_str)
            if (allocated(arr)) then
                ctrl%effectors(ie)%min_val = arr(1)
                ctrl%effectors(ie)%max_val = arr(2)
                ctrl%effectors(ie)%is_angle = (allocated(units_str) .and. len_trim(units_str) > 0 &
                                               .and. is_angular_unit(units_str))
                if (allocated(units_str) .and. len_trim(units_str) > 0) then
                    ctrl%effectors(ie)%unit_str = units_str
                end if
                deallocate(arr)
            end if

            ! actuator dynamics parameters
            call jsonx_get_u(j_eff, 'time_constant', ctrl%effectors(ie)%time_constant, 0.0)
            call jsonx_get_u(j_eff, 'natural_frequency', ctrl%effectors(ie)%natural_frequency, 0.0)
            call jsonx_get_u(j_eff, 'damping_ratio', ctrl%effectors(ie)%damping_ratio, 0.0)

            ! rate limits (units auto-converted: deg/s -> rad/s, /s stays as-is)
            call jsonx_get_u(j_eff, 'rate_limits', arr, 0.0, 2)
            if (allocated(arr)) then
                ctrl%effectors(ie)%rate_min = arr(1)
                ctrl%effectors(ie)%rate_max = arr(2)
                deallocate(arr)
            end if

            ! acceleration limits (units auto-converted: deg/s^2 -> rad/s^2, /s^2 stays)
            call jsonx_get_u(j_eff, 'acceleration_limits', arr, 0.0, 2)
            if (allocated(arr)) then
                ctrl%effectors(ie)%accel_min = arr(1)
                ctrl%effectors(ie)%accel_max = arr(2)
                deallocate(arr)
            end if

            ctrl%effectors(ie)%value = 0.0
        end do

        ! validate actuator dynamics parameters
        do ie = 1, n_eff
            if (ctrl%effectors(ie)%dynamics_order == 1) then
                if (ctrl%effectors(ie)%time_constant <= 0.0) then
                    write(*,*) 'ERROR: Control effector "', trim(ctrl%effectors(ie)%name), &
                               '" has dynamics_order=1 but time_constant[s] is missing or <= 0.'
                    stop
                end if
            else if (ctrl%effectors(ie)%dynamics_order == 2) then
                if (ctrl%effectors(ie)%natural_frequency <= 0.0) then
                    write(*,*) 'ERROR: Control effector "', trim(ctrl%effectors(ie)%name), &
                               '" has dynamics_order=2 but natural_frequency[rad/s] is missing or <= 0.'
                    stop
                end if
                if (ctrl%effectors(ie)%damping_ratio <= 0.0) then
                    write(*,*) 'ERROR: Control effector "', trim(ctrl%effectors(ie)%name), &
                               '" has dynamics_order=2 but damping_ratio is missing or <= 0.'
                    stop
                end if
            else if (ctrl%effectors(ie)%dynamics_order /= 0) then
                write(*,*) 'ERROR: Control effector "', trim(ctrl%effectors(ie)%name), &
                           '" has invalid dynamics_order=', ctrl%effectors(ie)%dynamics_order, &
                           '. Valid values: 0, 1, 2.'
                stop
            end if
        end do
    end subroutine load_control_effectors

    ! load initial conditions from JSON initial section
    ! b_ref and c_bar are reference lengths from the first aero source (for pbar/qbar/rbar conversion)
    subroutine load_initial_conditions(j_init, ctrl, passive, veh_name, &
                                       V0, alt, euler, alpha, beta, &
                                       p, q, r, b_ref, c_bar, is_trim, &
                                       sources, n_sources)
        type(json_value), pointer, intent(in) :: j_init
        type(control_inputs_t), intent(inout) :: ctrl
        type(passive_inputs_t), intent(inout) :: passive
        character(len=*), intent(in) :: veh_name
        real, intent(out) :: V0, alt, euler(3), alpha, beta
        real, intent(out) :: p, q, r
        real, intent(in) :: b_ref, c_bar
        logical, intent(out) :: is_trim
        type(force_source_wrapper_t), intent(in), optional :: sources(:)
        integer, intent(in), optional :: n_sources

        type(json_value), pointer :: j_state, j_ctrl_init, j_ctrl_val
        real, allocatable :: arr(:)
        character(len=:), allocatable :: init_type
        character(len=32) :: eff_name
        character(len=:), allocatable :: var_part, units_part
        real :: temp_val, pbar_val, qbar_val, rbar_val
        integer :: ie, ic, idx
        logical :: has_p, has_q, has_r, has_pbar, has_qbar, has_rbar

        call jsonx_get_u(j_init, 'airspeed', V0)
        call jsonx_get_u(j_init, 'altitude', alt)
        call jsonx_get_u(j_init, 'Euler_angles', arr, 0.0, 3)
        if (allocated(arr)) then
            euler = arr
            deallocate(arr)
        else
            euler = 0.0
        end if

        call jsonx_get(j_init, 'type', init_type, 'state')
        is_trim = (trim(init_type) == 'trim')

        ! state values (all in internal units — radians, rad/s)
        alpha = 0.0; beta = 0.0
        p = 0.0; q = 0.0; r = 0.0

        call jsonx_get(j_init, 'state', j_state)
        if (.not. associated(j_state)) return

        call jsonx_get_u(j_state, 'angle_of_attack', alpha, 0.0)
        call jsonx_get_u(j_state, 'sideslip_angle', beta, 0.0)

        ! rotation rates: user can specify p/q/r (dimensional) or pbar/qbar/rbar (nondimensional)
        ! try both forms for each axis; error if both are specified for the same axis
        ! rotation rates: user can specify p/q/r (dimensional, with optional [units])
        ! or pbar/qbar/rbar (nondimensional). Cannot specify both for the same axis.
        call jsonx_get_u(j_state, 'p', p, 0.0);          has_p = json_found
        call json_get(j_state, 'pbar', pbar_val, has_pbar)
        if (.not. has_pbar) call json_clear_exceptions()
        if (has_p .and. has_pbar) then
            write(*,*) 'ERROR: Vehicle "', trim(veh_name), &
                       '": cannot specify both "p" and "pbar" in initial state'
            stop
        end if
        if (has_pbar) then
            if (V0 <= 0.0 .or. b_ref <= 0.0) then
                write(*,*) 'ERROR: pbar requires airspeed > 0 and lateral_length > 0'
                stop
            end if
            p = pbar_val * 2.0 * V0 / b_ref
        end if

        call jsonx_get_u(j_state, 'q', q, 0.0);          has_q = json_found
        call json_get(j_state, 'qbar', qbar_val, has_qbar)
        if (.not. has_qbar) call json_clear_exceptions()
        if (has_q .and. has_qbar) then
            write(*,*) 'ERROR: Vehicle "', trim(veh_name), &
                       '": cannot specify both "q" and "qbar" in initial state'
            stop
        end if
        if (has_qbar) then
            if (V0 <= 0.0 .or. c_bar <= 0.0) then
                write(*,*) 'ERROR: qbar requires airspeed > 0 and longitudinal_length > 0'
                stop
            end if
            q = qbar_val * 2.0 * V0 / c_bar
        end if

        call jsonx_get_u(j_state, 'r', r, 0.0);          has_r = json_found
        call json_get(j_state, 'rbar', rbar_val, has_rbar)
        if (.not. has_rbar) call json_clear_exceptions()
        if (has_r .and. has_rbar) then
            write(*,*) 'ERROR: Vehicle "', trim(veh_name), &
                       '": cannot specify both "r" and "rbar" in initial state'
            stop
        end if
        if (has_rbar) then
            if (V0 <= 0.0 .or. b_ref <= 0.0) then
                write(*,*) 'ERROR: rbar requires airspeed > 0 and lateral_length > 0'
                stop
            end if
            r = rbar_val * 2.0 * V0 / b_ref
        end if

        ! load initial control values from control_effectors dict in state
        if (ctrl%n > 0) then
            call json_value_get(j_state, 'control_effectors', j_ctrl_init)
            if (.not. associated(j_ctrl_init)) then
                write(*,*) 'ERROR: Vehicle "', trim(veh_name), &
                           '" has control effectors but state section is missing "control_effectors" dict'
                stop
            end if
            call json_info(j_ctrl_init, n_children=ic)
            do ie = 1, ic
                call json_value_get(j_ctrl_init, ie, j_ctrl_val)

                ! parse key: extract effector name and optional units
                call parse_variable_and_units(trim(j_ctrl_val%name), var_part, units_part)
                eff_name = var_part

                ! find matching effector and set value
                idx = ctrl%get_index(trim(eff_name))
                if (idx == 0) then
                    write(*,*) 'ERROR: Unknown control effector "', trim(eff_name), &
                               '" in state.control_effectors of vehicle "', trim(veh_name), '"'
                    stop
                end if
                if (j_ctrl_val%data%var_type == json_real) then
                    temp_val = j_ctrl_val%data%dbl_value
                else if (j_ctrl_val%data%var_type == json_integer) then
                    temp_val = real(j_ctrl_val%data%int_value)
                else
                    temp_val = 0.0
                end if
                if (allocated(units_part)) then
                    ! check if specifying thrust or torque for a propeller effector
                    if ((is_force_unit(units_part) .or. is_torque_unit(units_part)) &
                        .and. present(sources) .and. present(n_sources)) then
                        ! convert thrust/torque value to internal force/moment units
                        temp_val = temp_val * conversion_factor_from(units_part)
                        ! invert propeller equation to get rad/s
                        call propeller_invert_effector(sources, n_sources, idx, &
                                                      temp_val, alt, &
                                                      is_force_unit(units_part), &
                                                      veh_name, eff_name)
                    else
                        temp_val = temp_val * conversion_factor_from(units_part)
                    end if
                end if
                ctrl%effectors(idx)%value = temp_val
            end do
        end if

        ! load initial passive effector values from state
        call load_passive_initial_conditions(j_state, passive, veh_name)
    end subroutine load_initial_conditions

    ! convert thrust or torque initial value to rad/s for a propeller effector
    subroutine propeller_invert_effector(sources, n_sources, eff_idx, &
                                         val, alt, is_thrust, veh_name, eff_name)
        type(force_source_wrapper_t), intent(in) :: sources(:)
        integer, intent(in) :: n_sources, eff_idx
        real, intent(inout) :: val
        real, intent(in) :: alt
        logical, intent(in) :: is_thrust
        character(len=*), intent(in) :: veh_name, eff_name

        real :: rho, Z, T_atm, P_atm, a_atm, mu_atm
        real :: d, CT_0, CPb_0, n_rev
        integer :: is

        ! find the propeller source that uses this effector
        do is = 1, n_sources
            select type (src => sources(is)%src)
            type is (propeller_source_t)
                if (src%effector_idx == eff_idx) then
                    ! get atmospheric density at initial altitude
                    call std_atm_english(alt, Z, T_atm, P_atm, rho, a_atm, mu_atm)
                    d = src%diameter
                    if (is_thrust) then
                        ! T = rho * n^2 * d^4 * CT(J=0)
                        CT_0 = src%CT_coef(1)
                        if (abs(CT_0) < 1.0e-12 .or. abs(rho) < 1.0e-12 &
                            .or. abs(d) < 1.0e-12) then
                            write(*,*) 'ERROR: Cannot invert thrust for "', &
                                trim(eff_name), '" — zero CT_0, rho, or diameter'
                            stop
                        end if
                        n_rev = sqrt(abs(val) / (rho * d**4 * CT_0))
                    else
                        ! torque = rho * n^2 * d^5 * CPb_0 / (2*pi)
                        CPb_0 = src%CPb_coef(1)
                        if (abs(CPb_0) < 1.0e-12 .or. abs(rho) < 1.0e-12 &
                            .or. abs(d) < 1.0e-12) then
                            write(*,*) 'ERROR: Cannot invert torque for "', &
                                trim(eff_name), '" — zero CPb_0, rho, or diameter'
                            stop
                        end if
                        n_rev = sqrt(abs(val) * 2.0 * PI / (rho * d**5 * CPb_0))
                    end if
                    ! convert rev/s → rad/s (internal units for effector)
                    val = n_rev * 2.0 * PI
                    return
                end if
            end select
        end do
        ! no matching propeller found — error
        write(*,*) 'ERROR: Effector "', trim(eff_name), '" in vehicle "', &
            trim(veh_name), '" specified in force/torque units but no propeller uses it'
        stop
    end subroutine propeller_invert_effector

    ! load trim settings from JSON initial.trim section
    subroutine load_trim_settings(j_init, ctrl, veh_name, trim_settings)
        type(json_value), pointer, intent(in) :: j_init
        type(control_inputs_t), intent(inout) :: ctrl
        character(len=*), intent(in) :: veh_name
        type(trim_settings_t), intent(out) :: trim_settings

        type(json_value), pointer :: j_trim, j_solver, j_fixed_ctrl, j_fixed_val
        character(len=:), allocatable :: trim_type_str, var_part, units_part
        real :: temp_val
        integer :: n_trim_vars, idx_phi, ctrl_idx, ie, ic
        logical :: found

        call jsonx_get(j_init, 'trim', j_trim)
        if (.not. associated(j_trim)) return

        trim_type_str = 'sct'
        call jsonx_get(j_trim, 'type', trim_type_str, 'sct')
        trim_settings%trim_type = trim_type_str

        ! compute dynamic trim vector size: x = [alpha, beta, ctrl(1..n), phi]
        n_trim_vars = 3 + ctrl%n
        trim_settings%n_trim_vars = n_trim_vars
        idx_phi = n_trim_vars

        ! default: all variables free except phi (phi is fixed from euler angles)
        allocate(trim_settings%free_vars(n_trim_vars))
        trim_settings%free_vars = .true.
        trim_settings%free_vars(idx_phi) = .false.

        ! hover: fix alpha, beta, phi at zero — only control effectors are free
        if (trim_type_str == 'hover') then
            trim_settings%free_vars(TRIM_IDX_ALPHA) = .false.
            trim_settings%free_vars(TRIM_IDX_BETA)  = .false.
            trim_settings%free_vars(idx_phi)         = .false.
        end if

        ! sideslip angle - read value but only fix beta for shss mode
        ! for sct, beta is always free
        call jsonx_get_u(j_trim, 'sideslip_angle', temp_val, 0.0)
        if (json_found) then
            trim_settings%sideslip_angle = temp_val
            ! only fix beta for shss mode, not sct
            if (trim_type_str == 'shss') then
                trim_settings%free_vars(TRIM_IDX_BETA) = .false.
                ! when beta is specified for shss, phi becomes a free variable
                trim_settings%free_vars(idx_phi) = .true.
            end if
        end if

        ! fixed_control_effectors: hold listed effectors at specified values during trim
        call json_get(j_trim, 'fixed_control_effectors', j_fixed_ctrl, found)
        if (found .and. associated(j_fixed_ctrl)) then
            call json_info(j_fixed_ctrl, n_children=ic)
            do ie = 1, ic
                call json_value_get(j_fixed_ctrl, ie, j_fixed_val)
                ! parse key: strip [deg] suffix if present
                call parse_variable_and_units(trim(j_fixed_val%name), var_part, units_part)
                ! find matching effector
                ctrl_idx = ctrl%get_index(trim(var_part))
                if (ctrl_idx == 0) then
                    write(*,*) 'ERROR: Unknown effector "', trim(var_part), &
                               '" in fixed_control_effectors of vehicle "', trim(veh_name), '"'
                    stop
                end if
                ! mark as fixed in trim vector
                trim_settings%free_vars(TRIM_IDX_CTRL_BASE + ctrl_idx) = .false.
                ! set the effector to the specified value
                if (j_fixed_val%data%var_type == json_real) then
                    temp_val = j_fixed_val%data%dbl_value
                else if (j_fixed_val%data%var_type == json_integer) then
                    temp_val = real(j_fixed_val%data%int_value)
                else
                    temp_val = 0.0
                end if
                if (allocated(units_part)) then
                    ctrl%effectors(ctrl_idx)%value = temp_val * conversion_factor_from(units_part)
                else
                    ctrl%effectors(ctrl_idx)%value = temp_val
                end if
            end do
        end if

        ! fixed earth climb angle constraint - can add relative wind climb angle later if I add constant wind
        call jsonx_get_u(j_trim, 'fixed_climb_angle', temp_val, 0.0)
        if (json_found) then
            trim_settings%gamma_specified = temp_val
            trim_settings%gamma_is_set = .true.
        end if

        ! load factor (eq 7.3.4 - solved with eqs 7.3.5 and 7.3.6)
        call json_get(j_trim, 'load_factor', temp_val, found)
        if (found) then
            trim_settings%loadfactor_specified = temp_val
            ! only set load factor for sct
            if (trim_type_str == 'sct') then
                trim_settings%loadfactor_is_set = .true.
            end if
        end if

        ! vbr settings
        call jsonx_get_u(j_trim, 'vbr_pw', temp_val, 0.0)
        trim_settings%vbr_pw = temp_val
        ! determine ascending/descending from sign of vbr_direction (default ascending)
        call json_get(j_trim, 'vbr_direction', temp_val, found)
        if (found .and. temp_val < 0.0) then
            trim_settings%vbr_ascending = .false.
        else
            trim_settings%vbr_ascending = .true.
        end if

        ! solver settings
        call jsonx_get(j_trim, 'solver', j_solver)
        if (associated(j_solver)) then
            call jsonx_get(j_solver, 'finite_difference_step_size', trim_settings%fd_step, 0.01)
            call jsonx_get(j_solver, 'relaxation_factor', trim_settings%relaxation, 0.9)
            call jsonx_get(j_solver, 'tolerance', trim_settings%tolerance, 1.0e-12)
            call jsonx_get(j_solver, 'max_iterations', trim_settings%max_iterations, 2000)
            call jsonx_get(j_solver, 'verbose', trim_settings%verbose, .true.)
        end if
    end subroutine load_trim_settings

    ! initialize to state mode (controls already set from json before this call)
    ! all angles/rates are in internal units (radians, rad/s)
    subroutine init_to_state(V0, alpha, beta, p, q, r, alt, euler, state)
        real, intent(in) :: V0, alpha, beta, p, q, r
        real, intent(in) :: alt, euler(3)
        type(vehicle_state_t), intent(out) :: state

        state%velocity = compute_body_velocity(V0, alpha, beta)
        state%omega = [p, q, r]
        state%position = [0.0, 0.0, -alt]
        state%quaternion = euler_to_quat(euler)
    end subroutine init_to_state

    ! initialize to trim mode (partial state for trim solver)
    ! euler angles are in internal units (radians)
    subroutine init_to_trim(V0, alt, euler, state)
        real, intent(in) :: V0, alt, euler(3)
        type(vehicle_state_t), intent(out) :: state

        state%velocity = [V0, 0.0, 0.0]
        state%position(3) = -alt
        state%quaternion = euler_to_quat(euler)
    end subroutine init_to_trim

    ! find vehicle index by name
    function find_vehicle_index(name, configs, n_vehicles) result(idx)
        character(*), intent(in) :: name
        type(vehicle_config_t), intent(in) :: configs(:)
        integer, intent(in) :: n_vehicles
        integer :: idx
        integer :: i

        idx = 0
        do i = 1, n_vehicles
            if (trim(configs(i)%name) == trim(name)) then
                idx = i
                return
            end if
        end do
    end function find_vehicle_index

    ! load telemetry connection configs from pre-parsed json root
    subroutine load_telemetry_configs(json_root, configs, ctrls, passives, n_vehicles, conn_configs, n_connections)
        type(json_value), pointer, intent(in) :: json_root
        type(vehicle_config_t), intent(in) :: configs(:)
        type(control_inputs_t), intent(in) :: ctrls(:)
        type(passive_inputs_t), intent(in) :: passives(:)
        integer, intent(in) :: n_vehicles
        type(telemetry_conn_config_t), allocatable, intent(out) :: conn_configs(:)
        integer, intent(out) :: n_connections

        type(json_value), pointer :: p_conns, p_conn
        integer :: n_children, i, count, idx, j, n_ctrl_vals
        logical :: enabled, has_imu
        character(len=:), allocatable :: conn_type, vehicle_name, data_type_str
        character(len=64) :: conn_name
        character(len=64), allocatable :: sensor_names_arr(:)
        integer :: k

        ! data type constants
        integer, parameter :: DATA_CONTROLS = 1
        integer, parameter :: DATA_STATE = 2
        integer, parameter :: DATA_BOTH = 3
        integer, parameter :: DATA_SENSORS = 4
        integer, parameter :: DATA_EKF_STATE = 5
        integer, parameter :: DATA_EKF_BOTH = 6
        integer, parameter :: STATE_PACKET_SIZE = 14

        n_connections = 0

        if (.not. associated(json_root)) return

        call jsonx_get(json_root, 'connections', p_conns)
        if (.not. associated(p_conns)) return

        ! single-pass: allocate to max, parse enabled, then trim
        call json_info(p_conns, n_children=n_children)
        if (n_children == 0) return
        allocate(conn_configs(n_children))

        count = 0
        do i = 1, n_children
            call json_value_get(p_conns, i, p_conn)
            call jsonx_get(p_conn, 'enabled', enabled, .false.)
            if (.not. enabled) cycle

            count = count + 1

            ! get connection name from JSON key
            if (allocated(p_conn%name)) then
                conn_name = trim(p_conn%name)
            else
                write(conn_name, '(A,I0)') 'connection_', count
            end if
            conn_configs(count)%name = trim(conn_name)

            ! get required vehicle name
            call jsonx_get(p_conn, 'vehicle', vehicle_name)
            if (.not. allocated(vehicle_name)) then
                write(*,*) 'ERROR: Connection "', trim(conn_name), '" missing required "vehicle" field'
                stop
            end if
            conn_configs(count)%vehicle_name = trim(vehicle_name)

            ! check vehicle exists
            idx = find_vehicle_index(vehicle_name, configs, n_vehicles)
            if (idx == 0) then
                write(*,*) 'ERROR: Connection "', trim(conn_name), '" references unknown vehicle: ', trim(vehicle_name)
                stop
            end if
            conn_configs(count)%vehicle_index = idx
            if (allocated(vehicle_name)) deallocate(vehicle_name)

            ! determine send/receive
            call jsonx_get(p_conn, 'type', conn_type)
            conn_configs(count)%is_sender = (conn_type == 'send')
            if (allocated(conn_type)) deallocate(conn_type)

            ! entity tagging: prepend 4-byte int32 entity_id to UDP packets
            call jsonx_get(p_conn, 'entity_tagged', conn_configs(count)%entity_tagged, .false.)

            ! get data_type and compute n_values dynamically from effector count
            call jsonx_get(p_conn, 'data_type', data_type_str, 'both')
            select case (trim(data_type_str))
            case ('controls')
                conn_configs(count)%data_type = DATA_CONTROLS
                conn_configs(count)%n_values = ctrls(idx)%n
            case ('state')
                conn_configs(count)%data_type = DATA_STATE
                conn_configs(count)%n_values = STATE_PACKET_SIZE
            case ('sensors')
                conn_configs(count)%data_type = DATA_SENSORS
                ! parse sensor names from "sensors" array
                call jsonx_get(p_conn, 'sensors', sensor_names_arr)
                if (json_found .and. allocated(sensor_names_arr)) then
                    conn_configs(count)%n_sensor_names = min(size(sensor_names_arr), MAX_SENSOR_NAMES)
                    do k = 1, conn_configs(count)%n_sensor_names
                        conn_configs(count)%sensor_names(k) = trim(sensor_names_arr(k))
                    end do
                    deallocate(sensor_names_arr)
                else
                    write(*,*) 'WARNING: Connection "', trim(conn_name), &
                        '" has data_type "sensors" but no "sensors" array specified'
                    conn_configs(count)%n_sensor_names = 0
                end if
                ! n_values will be computed in Phase 1 when sensors are loaded
                ! for now set to 0 (no sending until sensors exist)
                conn_configs(count)%n_values = 0
            case ('ekf_state')
                conn_configs(count)%data_type = DATA_EKF_STATE
                conn_configs(count)%n_values = STATE_PACKET_SIZE + 3   ! +3 EKF angular-accel
            case ('ekf_both')
                conn_configs(count)%data_type = DATA_EKF_BOTH
                n_ctrl_vals = 0
                do j = 1, ctrls(idx)%n
                    if (ctrls(idx)%effectors(j)%dynamics_order >= 1) then
                        n_ctrl_vals = n_ctrl_vals + 2
                    else
                        n_ctrl_vals = n_ctrl_vals + 1
                    end if
                end do
                ! +3 for the EKF angular-accel fields appended at the packet tail
                conn_configs(count)%n_values = STATE_PACKET_SIZE + n_ctrl_vals + 2 * passives(idx)%n + 3
            case default
                conn_configs(count)%data_type = DATA_BOTH
                n_ctrl_vals = 0
                do j = 1, ctrls(idx)%n
                    if (ctrls(idx)%effectors(j)%dynamics_order >= 1) then
                        n_ctrl_vals = n_ctrl_vals + 2
                    else
                        n_ctrl_vals = n_ctrl_vals + 1
                    end if
                end do
                conn_configs(count)%n_values = STATE_PACKET_SIZE + n_ctrl_vals + 2 * passives(idx)%n
            end select

            ! validate EKF connections require EKF + IMU sensor
            if (conn_configs(count)%data_type == DATA_EKF_STATE .or. &
                conn_configs(count)%data_type == DATA_EKF_BOTH) then
                if (.not. configs(idx)%use_ekf) then
                    write(*,*) &
                        "ERROR: Connection has ekf data_type but vehicle does not have EKF enabled"
                    write(*,*) "  Connection: ", trim(conn_name)
                    write(*,*) "  Vehicle:    ", trim(configs(idx)%name)
                    write(*,*) "  EKF requires a sensors block with ekf.enabled = true"
                    stop
                end if
                ! check that at least one IMU sensor exists (EKF needs IMU for prediction)
                has_imu = .false.
                do k = 1, configs(idx)%n_sensors
                    if (configs(idx)%sensors(k)%sensor%type_id == SENSOR_IMU) then
                        has_imu = .true.
                        exit
                    end if
                end do
                if (.not. has_imu) then
                    write(*,*) &
                        "ERROR: Connection sends EKF state but vehicle has no IMU sensor"
                    write(*,*) "  Connection: ", trim(conn_name)
                    write(*,*) "  Vehicle:    ", trim(configs(idx)%name)
                    write(*,*) "  EKF requires an IMU sensor for state prediction"
                    stop
                end if
            end if
            if (allocated(data_type_str)) deallocate(data_type_str)

            ! store json node for connection initialization
            conn_configs(count)%json_node => p_conn
        end do

        n_connections = count

        ! note: json_root is owned by the caller - do not destroy here
    end subroutine load_telemetry_configs

    ! force source factory — allocates the correct polymorphic type based on JSON "type" field
    subroutine load_force_source(j_src, wrapper, ctrl, passive, config)
        type(json_value), pointer, intent(in) :: j_src
        type(force_source_wrapper_t), intent(out) :: wrapper
        type(control_inputs_t), intent(in) :: ctrl
        type(passive_inputs_t), intent(in) :: passive
        type(vehicle_config_t), intent(in) :: config
        character(len=:), allocatable :: src_type
        character(len=64) :: src_name
        type(sd_source_t), allocatable :: sd_src
        type(sphere_source_t), allocatable :: sph_src
        type(cuboid_source_t), allocatable :: bod_src
        type(cylinder_source_t), allocatable :: cyl_src
        type(wing_source_t), allocatable :: wing_src
        type(database_source_t), allocatable :: db_src
        type(mass_source_t), allocatable :: mass_src

        ! source name from json key
        if (allocated(j_src%name)) then
            src_name = trim(j_src%name)
        else
            src_name = 'unnamed'
        end if

        ! dispatch by type string — allocate correct concrete type
        call json_clear_exceptions()
        call jsonx_get(j_src, 'type', src_type)
        select case (trim(src_type))
        case ('stability_derivatives')
            allocate(sd_src)
            sd_src%name = src_name
            call load_sd_source(j_src, sd_src, ctrl, passive)
            call move_alloc(sd_src, wrapper%src)
        case ('propulsion')
            call load_propulsion_source(j_src, src_name, ctrl, wrapper, config)
        case ('sphere')
            allocate(sph_src)
            sph_src%name = src_name
            call load_sphere_source(j_src, sph_src)
            call move_alloc(sph_src, wrapper%src)
        case ('cuboid')
            allocate(bod_src)
            bod_src%name = src_name
            call load_cuboid_source(j_src, bod_src)
            call move_alloc(bod_src, wrapper%src)
        case ('cylinder')
            allocate(cyl_src)
            cyl_src%name = src_name
            call load_cylinder_source(j_src, cyl_src)
            call move_alloc(cyl_src, wrapper%src)
        case ('wing')
            allocate(wing_src)
            wing_src%name = src_name
            call load_wing_source(j_src, wing_src, ctrl)
            call move_alloc(wing_src, wrapper%src)
        case ('database')
            allocate(db_src)
            db_src%name = src_name
            call load_database_source(j_src, db_src, ctrl, passive)
            call move_alloc(db_src, wrapper%src)
        case ('point_mass', 'mass', 'ballast')
            ! inert mass element (payload / ballast / battery / avionics):
            ! contributes mass + inertia only, zero aero/propulsive force
            allocate(mass_src)
            mass_src%name = src_name
            call load_mass_source(j_src, mass_src)
            call move_alloc(mass_src, wrapper%src)
        case default
            write(*,*) 'ERROR: Unknown force source type: ', trim(src_type)
            stop
        end select

        ! parse optional component frame orientation (Euler angles → quaternion)
        ! applies to all source types; JSON: "component_orientation[deg]": [phi, theta, psi]
        ! defines rotation from body frame to component frame (Eq 3.6.2)
        block
            real, allocatable :: orient_arr(:)
            call jsonx_get_u(j_src, 'component_orientation', orient_arr, 0.0, 3)
            if (json_found .and. allocated(orient_arr)) then
                wrapper%src%orientation_euler = orient_arr
                wrapper%src%orientation = euler_to_quat(orient_arr)
                wrapper%src%has_orientation = &
                    abs(wrapper%src%orientation(1) - 1.0) > 1.0e-10 .or. &
                    abs(wrapper%src%orientation(2)) > 1.0e-10 .or. &
                    abs(wrapper%src%orientation(3)) > 1.0e-10 .or. &
                    abs(wrapper%src%orientation(4)) > 1.0e-10
                if (wrapper%src%has_orientation) then
                    write(*,*) '    Component orientation: [', &
                               orient_arr(1)*180.0/PI, ', ', &
                               orient_arr(2)*180.0/PI, ', ', &
                               orient_arr(3)*180.0/PI, '] deg'
                end if
                deallocate(orient_arr)
            end if
        end block

        ! parse optional per-component mass properties
        ! JSON: "mass": { "weight[lbf]": ..., "cg[ft]": [...], "Ixx[slug-ft^2]": ..., ... }
        call load_component_mass(j_src, wrapper%src%comp_mass)
        if (wrapper%src%comp_mass%has_mass) then
            write(*,*) '    Component mass: ', wrapper%src%comp_mass%weight_lbf, ' lbf (', &
                       wrapper%src%comp_mass%mass, ' slug)'
        end if

        ! clear any lingering JSON exceptions from optional field lookups
        call json_clear_exceptions()
    end subroutine load_force_source

    subroutine load_sd_source(j_src, src, ctrl, passive)
        type(json_value), pointer, intent(in) :: j_src
        type(sd_source_t), intent(inout) :: src
        type(control_inputs_t), intent(in) :: ctrl
        type(passive_inputs_t), intent(in) :: passive
        type(json_value), pointer :: j_ref, j_stall, j_coef, j_group, j_custom
        real, allocatable :: arr(:)
        integer :: ig, nc
        character(len=6) :: group_names(N_GROUPS)

        group_names = [character(len=6) :: 'CL', 'CS', 'CD', 'Cl', 'Cm', 'Cn', &
                       'CLstab', 'CDstab', 'CSstab', 'Clstab', 'Cnstab']

        ! reference
        call jsonx_get(j_src, 'reference', j_ref)
        call jsonx_get_u(j_ref, 'area', src%S_ref)
        call jsonx_get_u(j_ref, 'longitudinal_length', src%c_bar)
        call jsonx_get_u(j_ref, 'lateral_length', src%b_ref)
        call jsonx_get_u(j_ref, 'location', arr, 0.0, 3)
        if (allocated(arr)) then
            src%location = arr
            deallocate(arr)
        end if

        ! stall model (alpha stall + rotation rate stall)
        call jsonx_get(j_src, 'stall', j_stall)
        if (associated(j_stall)) then
            call load_stall_model(j_stall, src%stall)
        end if

        ! generic coefficient pool layout (includes PE positions + rates)
        src%sd%n_ctrl = ctrl%n + 2 * passive%n
        src%sd%ctrl_offset = N_STD_VARS + 1
        src%sd%n_custom = 0
        src%sd%custom_offset = src%sd%ctrl_offset + src%sd%n_ctrl

        ! parse coefficients
        call jsonx_get(j_src, 'coefficients', j_coef)
        if (associated(j_coef)) then
            ! parse optional custom variables first
            call json_value_get(j_coef, 'custom', j_custom)
            if (associated(j_custom)) then
                call json_info(j_custom, n_children=nc)
                if (nc > MAX_CUSTOM) then
                    write(*,*) 'ERROR: Too many custom variables (max ', MAX_CUSTOM, ')'
                    stop
                end if
                src%sd%n_custom = nc
                do ig = 1, nc
                    call json_value_get(j_custom, ig, j_group)
                    if (allocated(j_group%name)) then
                        src%sd%custom_names(ig) = trim(j_group%name)
                    end if
                    call parse_group_from_json(j_group, ctrl, passive, src%sd, src%sd%custom(ig), src%name)
                end do
            end if

            ! compute group offset and pool size
            src%sd%group_offset = src%sd%custom_offset + src%sd%n_custom
            src%sd%pool_size = src%sd%group_offset + N_GROUPS - 1

            ! parse coefficient groups: CL, CS, CD, Cl, Cm, Cn
            do ig = 1, N_GROUPS
                call json_value_get(j_coef, trim(group_names(ig)), j_group)
                if (associated(j_group)) then
                    call parse_group_from_json(j_group, ctrl, passive, src%sd, src%sd%groups(ig), src%name)
                end if
            end do
        else
            src%sd%group_offset = src%sd%custom_offset
            src%sd%pool_size = src%sd%group_offset + N_GROUPS - 1
        end if
    end subroutine load_sd_source

    subroutine load_propulsion_source(j_src, src_name, ctrl, wrapper, config)
        type(json_value), pointer, intent(in) :: j_src
        character(len=64), intent(in) :: src_name
        type(control_inputs_t), intent(in) :: ctrl
        type(force_source_wrapper_t), intent(out) :: wrapper
        type(vehicle_config_t), intent(in) :: config
        type(json_value), pointer :: j_motor, j_solver
        real, allocatable :: arr(:)
        character(len=:), allocatable :: eff_name, prop_type_str, rotation_str, motor_type_str
        character(len=:), allocatable :: battery_name_str
        type(simple_thrust_t), allocatable :: thrust_src
        type(propeller_source_t), allocatable :: prop_src
        integer :: eff_idx, ib
        real :: loc(3), kV_raw

        ! resolve effector name to index (shared by all propulsion types)
        eff_idx = 0
        call jsonx_get(j_src, 'effector', eff_name)
        if (allocated(eff_name)) then
            eff_idx = ctrl%get_index(eff_name)
        end if

        ! location (shared)
        loc = 0.0
        call jsonx_get_u(j_src, 'location', arr, 0.0, 3)
        if (allocated(arr)) then
            loc = arr
            deallocate(arr)
        end if

        ! dispatch by propulsion_type
        call jsonx_get(j_src, 'propulsion_type', prop_type_str)
        select case (trim(prop_type_str))
        case ('simple')
            allocate(thrust_src)
            thrust_src%name = src_name
            thrust_src%location = loc
            thrust_src%effector_idx = eff_idx
            call jsonx_get_u(j_src, 'T0', thrust_src%T0, 0.0)
            call jsonx_get(j_src, 'Ta', thrust_src%T_alpha, 0.0)

            ! thrust direction from orientation angles [roll, pitch, yaw] in degrees
            call jsonx_get_u(j_src, 'orientation', arr, 0.0, 3)
            if (allocated(arr)) then
                thrust_src%direction(1) = cos(arr(2)) * cos(arr(3))
                thrust_src%direction(2) = cos(arr(2)) * sin(arr(3))
                thrust_src%direction(3) = -sin(arr(2))
                deallocate(arr)
            end if
            write(*,*) '    Propulsion: simple (T0=', thrust_src%T0, ' lbf, Ta=', thrust_src%T_alpha, ')'
            call move_alloc(thrust_src, wrapper%src)

        case ('propeller')
            allocate(prop_src)
            prop_src%name = src_name
            prop_src%location = loc
            prop_src%effector_idx = eff_idx
            call jsonx_get_u(j_src, 'diameter', prop_src%diameter)

            ! rotation direction
            rotation_str = 'right'
            call jsonx_get(j_src, 'rotation', rotation_str)
            if (trim(rotation_str) == 'left') then
                prop_src%delta = -1.0
            else
                prop_src%delta = 1.0
            end if

            ! coefficient arrays: CT(J), CPb(J), CNa(J), Cna(J)
            call load_coef_array(j_src, 'CT(J)',  prop_src%CT_coef,  arr)
            call load_coef_array(j_src, 'CPb(J)', prop_src%CPb_coef, arr)
            call load_coef_array(j_src, 'CNa(J)', prop_src%normal_coef, arr)
            call load_coef_array(j_src, 'Cna(J)', prop_src%yaw_coef, arr)

            ! motor section
            call json_value_get(j_src, 'motor', j_motor)
            if (.not. json_failed() .and. associated(j_motor)) then
                motor_type_str = 'rpm'
                call jsonx_get(j_motor, 'type', motor_type_str)
                select case (trim(motor_type_str))
                case ('rpm')
                    prop_src%motor_type = MOTOR_RPM
                    call json_get(j_motor, 'J_limits', arr, json_found)
                    call json_clear_exceptions()
                    if (allocated(arr)) then
                        if (size(arr) >= 2) prop_src%J_limits = arr(1:2)
                        deallocate(arr)
                    end if
                case ('electric')
                    prop_src%motor_type = MOTOR_ELECTRIC

                    ! kV: speed constant [rpm/V] -> internal [rev/s/V]
                    call jsonx_get(j_motor, 'kV', kV_raw)
                    prop_src%kV = kV_raw / 60.0
                    ! kT: torque constant [ft-lbf/A] per Phillips Eq 4.6.7/4.6.8
                    !   lm = (CI/Kv)*(Im - Im0) with CI = 7.04319971369755 for Kv in rpm/V.
                    !   Internally kV is rev/s/V (Kv_rpm/60), so:
                    !     kT [ft-lbf/A] = CI / Kv_rpm = (CI/60) / kV_internal
                    prop_src%kT = (7.04319971369755 / 60.0) / prop_src%kV

                    ! motor armature resistance [Ohm]
                    call jsonx_get(j_motor, 'resistance', prop_src%R_motor)

                    ! no-load current [A]
                    call jsonx_get(j_motor, 'no_load_current', prop_src%I_0, 0.0)

                    ! ESC resistance [Ohm]
                    call jsonx_get(j_motor, 'ESC_resistance', prop_src%R_esc, 0.0)

                    ! ESC max current [A] (Table 4.6.3); default huge -> no warnings
                    call jsonx_get(j_motor, 'Ic_max', prop_src%Ic_max, huge(0.0))

                    ! gearbox
                    call jsonx_get(j_motor, 'gearbox_ratio', prop_src%gear_ratio, 1.0)
                    call jsonx_get(j_motor, 'gearbox_efficiency', prop_src%eta_gear, 1.0)

                    ! J limits (optional, same as rpm motor)
                    call json_get(j_motor, 'J_limits', arr, json_found)
                    call json_clear_exceptions()
                    if (allocated(arr)) then
                        if (size(arr) >= 2) prop_src%J_limits = arr(1:2)
                        deallocate(arr)
                    end if

                    ! battery reference by name
                    call jsonx_get(j_motor, 'battery', battery_name_str)
                    if (allocated(battery_name_str)) then
                        prop_src%battery_index = 0
                        do ib = 1, config%n_batteries
                            if (trim(config%batteries(ib)%name) == trim(battery_name_str)) then
                                prop_src%battery_index = ib
                                exit
                            end if
                        end do
                        if (prop_src%battery_index == 0) then
                            write(*,*) 'ERROR: Battery "', trim(battery_name_str), &
                                       '" not found for motor in ', trim(src_name)
                            stop
                        end if
                        deallocate(battery_name_str)
                    else
                        write(*,*) 'ERROR: Electric motor requires "battery" field in ', trim(src_name)
                        stop
                    end if

                    ! optional solver settings (bisection on torque balance)
                    call json_value_get(j_motor, 'solver', j_solver)
                    if (.not. json_failed() .and. associated(j_solver)) then
                        call jsonx_get(j_solver, 'max_iterations', prop_src%elec_max_iter, 60)
                        call jsonx_get(j_solver, 'tolerance', prop_src%elec_tol, 1.0e-10)
                    end if
                    call json_clear_exceptions()

                    write(*,*) '    Motor: electric (kV=', kV_raw, ' rpm/V, battery=', &
                               trim(config%batteries(prop_src%battery_index)%name), ')'
                case default
                    write(*,*) 'ERROR: Unknown motor type: ', trim(motor_type_str)
                    stop
                end select
            else
                prop_src%motor_type = MOTOR_RPM  ! default
            end if
            call json_clear_exceptions()

            ! optional verbose flag
            call jsonx_get(j_src, 'propeller_verbose', prop_src%verbose, .false.)

            write(*,*) '    Propulsion: propeller (d=', prop_src%diameter, ' ft, ', &
                       trim(rotation_str), '-hand)'
            call move_alloc(prop_src, wrapper%src)

        case default
            write(*,*) 'ERROR: Unknown propulsion_type: ', trim(prop_type_str)
            stop
        end select

        ! clear any lingering JSON exceptions from optional field lookups
        call json_clear_exceptions()
    end subroutine load_propulsion_source

    subroutine load_sphere_source(j_src, src)
        type(json_value), pointer, intent(in) :: j_src
        type(sphere_source_t), intent(inout) :: src
        type(json_value), pointer :: j_ref
        real, allocatable :: radii(:), dims(:)
        real :: r_single

        call jsonx_get(j_src, 'reference', j_ref)

        ! try 3-element radii array first: [rx, ry, rz] for ellipsoid
        call jsonx_get_u(j_ref, 'radii', radii, 0.0, 3)
        if (json_found .and. allocated(radii)) then
            src%rx = radii(1)
            src%ry = radii(2)
            src%rz = radii(3)
            deallocate(radii)
        else
            ! fall back to single radius for sphere
            if (allocated(radii)) deallocate(radii)
            call jsonx_get_u(j_ref, 'radius', r_single, 0.0)
            src%rx = r_single
            src%ry = r_single
            src%rz = r_single
        end if

        ! optional location
        call jsonx_get_u(j_src, 'location', dims, 0.0, 3)
        if (allocated(dims)) then
            src%location = dims
            deallocate(dims)
        end if
    end subroutine load_sphere_source

    subroutine load_cuboid_source(j_src, src)
        type(json_value), pointer, intent(in) :: j_src
        type(cuboid_source_t), intent(inout) :: src
        type(json_value), pointer :: j_ref
        real, allocatable :: dims(:)

        call jsonx_get(j_src, 'reference', j_ref)

        ! cuboid dimensions: [lx, ly, lz] (Section 3.6, Eq 3.6.10)
        call jsonx_get_u(j_ref, 'dimensions', dims, 0.0, 3)
        if (allocated(dims)) then
            src%lx = dims(1)
            src%ly = dims(2)
            src%lz = dims(3)
            deallocate(dims)
        end if

        ! optional CD override (default 1.05, Eq 3.6.11)
        call jsonx_get(j_src, 'CD', src%CD, 1.05)

        ! optional location
        call jsonx_get_u(j_src, 'location', dims, 0.0, 3)
        if (allocated(dims)) then
            src%location = dims
            deallocate(dims)
        end if
    end subroutine load_cuboid_source

    ! load an inert mass element (payload / ballast / battery / avionics).
    ! A "location[ft]" and a "mass" block are REQUIRED; the inertia tensor inside
    ! the mass block is optional (omit it for a point mass). The mass block is
    ! parsed generically by load_component_mass after dispatch — here we read the
    ! location and enforce that both required fields are present.
    subroutine load_mass_source(j_src, src)
        type(json_value), pointer, intent(in) :: j_src
        type(mass_source_t), intent(inout) :: src
        type(json_value), pointer :: j_mass
        real, allocatable :: arr(:)

        ! location is required: an inert mass has no other geometry to place it
        call jsonx_get_u(j_src, 'location', arr, 0.0, 3)
        if (.not. json_found) then
            write(*,*) 'ERROR: mass source "', trim(src%name), &
                       '" requires a "location[ft]".'
            stop
        end if
        src%location = arr
        if (allocated(arr)) deallocate(arr)

        ! a "mass" block is required (otherwise the component contributes nothing)
        call json_value_get(j_src, 'mass', j_mass)
        if (.not. associated(j_mass)) then
            write(*,*) 'ERROR: mass source "', trim(src%name), &
                       '" requires a "mass" block (weight required, inertia optional).'
            stop
        end if
    end subroutine load_mass_source

    subroutine load_cylinder_source(j_src, src)
        type(json_value), pointer, intent(in) :: j_src
        type(cylinder_source_t), intent(inout) :: src
        type(json_value), pointer :: j_ref
        real, allocatable :: dims(:)
        real :: r_single

        call jsonx_get(j_src, 'reference', j_ref)

        ! length along cylinder axis (component x-axis)
        call jsonx_get_u(j_ref, 'length', src%length, 0.0)

        ! try separate r1/r2 for frustum
        call jsonx_get_u(j_ref, 'radius_1', src%r1, -1.0)
        call jsonx_get_u(j_ref, 'radius_2', src%r2, -1.0)

        ! fall back to single radius for uniform cylinder
        if (src%r1 < 0.0 .or. src%r2 < 0.0) then
            call jsonx_get_u(j_ref, 'radius', r_single, 0.0)
            src%r1 = r_single
            src%r2 = r_single
        end if

        ! optional location
        call jsonx_get_u(j_src, 'location', dims, 0.0, 3)
        if (allocated(dims)) then
            src%location = dims
            deallocate(dims)
        end if
    end subroutine load_cylinder_source

    subroutine load_wing_source(j_src, src, ctrl)
        type(json_value), pointer, intent(in) :: j_src
        type(wing_source_t), intent(inout) :: src
        type(control_inputs_t), intent(in) :: ctrl
        type(json_value), pointer :: j_ref, j_aero, j_ctrl, j_stall
        real, allocatable :: dims(:)
        character(len=:), allocatable :: side_str, eff_name
        real :: theta_f, delta

        ! geometry
        call jsonx_get(j_src, 'reference', j_ref)
        call jsonx_get_u(j_ref, 'semispan', src%semispan, 0.0)
        call jsonx_get_u(j_ref, 'root_chord', src%root_chord, 0.0)
        call jsonx_get_u(j_ref, 'tip_chord', src%tip_chord, 0.0)
        call jsonx_get_u(j_ref, 'sweep', src%sweep, 0.0)

        ! side: "right" (+1), "left" (-1), or "both" (0), default "both"
        call jsonx_get(j_src, 'side', side_str, 'both')
        select case (trim(side_str))
        case ('left');  src%side = -1
        case ('right'); src%side = 1
        case default;   src%side = 0   ! both
        end select

        ! dihedral specified once; sign handled by side
        call jsonx_get_u(j_ref, 'dihedral', src%dihedral, 0.0)

        ! derived geometry (Eqs 3.6.30-3.6.32)
        src%mean_chord = (src%root_chord + src%tip_chord) / 2.0          ! Eq 3.6.31
        src%S_w = src%semispan * src%mean_chord                           ! Eq 3.6.30
        if (src%mean_chord > TOLERANCE) then
            src%R_A = src%semispan / src%mean_chord                       ! Eq 3.6.32
        end if

        ! aerodynamic center in wing frame (Eqs 3.6.33-3.6.35)
        ! delta = +1 for right wing, -1 for left wing (Eq 2.4.29)
        delta = real(src%side)
        if (src%root_chord + src%tip_chord > TOLERANCE) then
            src%ac_local(1) = -src%semispan / 3.0 &
                * (src%root_chord + 2.0*src%tip_chord) / (src%root_chord + src%tip_chord) &
                * tan(src%sweep)                                          ! Eq 3.6.34
            src%ac_local(2) = delta * src%semispan / 3.0 &
                * (src%root_chord + 2.0*src%tip_chord) / (src%root_chord + src%tip_chord) ! Eq 3.6.33
            src%ac_local(3) = 0.0
        end if

        ! aerodynamic properties (optional section)
        call jsonx_get(j_src, 'aero', j_aero)
        if (associated(j_aero)) then
            call jsonx_get(j_aero, 'CL_alpha', src%CL_alpha, 0.0)       ! 0 = auto from R_A
            call jsonx_get_u(j_aero, 'alpha_L0', src%alpha_L0, 0.0)
            call jsonx_get(j_aero, 'CD0', src%CD0, 0.01)
            call jsonx_get(j_aero, 'CD1', src%CD1, 0.0)
            call jsonx_get(j_aero, 'e_O', src%e_O, 0.8)
            call jsonx_get(j_aero, 'Cm0', src%Cm0, 0.0)
            call jsonx_get(j_aero, 'Cm_alpha', src%Cm_alpha, 0.0)
        end if

        ! control surface (optional section)
        call jsonx_get(j_src, 'control_surface', j_ctrl)
        if (associated(j_ctrl)) then
            call jsonx_get(j_ctrl, 'effector', eff_name)
            if (allocated(eff_name)) then
                src%ctrl_idx = ctrl%get_index(eff_name)
            end if
            call jsonx_get(j_ctrl, 'flap_fraction', src%flap_frac, 0.25)
            call jsonx_get(j_ctrl, 'efficiency', src%eta_f, 0.8)
            call jsonx_get(j_ctrl, 'antisymmetric', src%antisymmetric, .false.)

            ! compute control surface effectiveness (Eqs 3.6.52-3.6.53)
            if (src%flap_frac > TOLERANCE) then
                theta_f = acos(2.0 * src%flap_frac - 1.0)               ! Eq 3.6.53
                src%eps_c = src%eta_f * (1.0 - (theta_f - sin(theta_f)) / PI)  ! Eq 3.6.52
                src%Cm_dc = src%eta_f * (sin(2.0*theta_f) - 2.0*sin(theta_f)) / 4.0  ! Eq 3.6.56
            end if
        end if

        ! stall parameters (optional section)
        call jsonx_get(j_src, 'stall', j_stall)
        if (associated(j_stall)) then
            call jsonx_get_u(j_stall, 'alpha_0', src%alpha_0_stall, 0.0)
            call jsonx_get_u(j_stall, 'alpha_s', src%alpha_s_stall, 0.436)
            call jsonx_get(j_stall, 'lambda_b', src%lambda_b_stall, 40.0)
        end if

        ! optional location
        call jsonx_get_u(j_src, 'location', dims, 0.0, 3)
        if (allocated(dims)) then
            src%location = dims
            deallocate(dims)
        end if

        write(*,*) '    Wing: b=', src%semispan, ' c_r=', src%root_chord, &
                   ' c_t=', src%tip_chord, ' S_w=', src%S_w, ' R_A=', src%R_A
    end subroutine load_wing_source

    ! generic coefficient parsing helpers
    function resolve_var_name(name, ctrl, passive, sd) result(slot)
        character(*), intent(in) :: name
        type(control_inputs_t), intent(in) :: ctrl
        type(passive_inputs_t), intent(in) :: passive
        type(generic_coef_t), intent(in) :: sd
        integer :: slot
        integer :: i

        ! try common state variables first (standard + ctrl + passive)
        slot = resolve_state_index(name, ctrl, passive)
        if (slot > 0) return

        ! SD-specific: custom variables
        do i = 1, sd%n_custom
            if (trim(sd%custom_names(i)) == trim(name)) then
                slot = sd%custom_offset + i - 1
                return
            end if
        end do

        ! SD-specific: coefficient group results
        select case (trim(name))
        case ('CL'); slot = sd%group_offset;     return
        case ('CS'); slot = sd%group_offset + 1; return
        case ('CD'); slot = sd%group_offset + 2; return
        case ('Cl'); slot = sd%group_offset + 3; return
        case ('Cm'); slot = sd%group_offset + 4; return
        case ('Cn'); slot = sd%group_offset + 5; return
        case ('CLstab'); slot = sd%group_offset + 6;  return
        case ('CDstab'); slot = sd%group_offset + 7;  return
        case ('CSstab'); slot = sd%group_offset + 8;  return
        case ('Clstab'); slot = sd%group_offset + 9;  return
        case ('Cnstab'); slot = sd%group_offset + 10; return
        end select

        slot = 0
    end function resolve_var_name

    subroutine parse_term_key(key, ctrl, passive, sd, term, src_name)
        character(*), intent(in) :: key
        type(control_inputs_t), intent(in) :: ctrl
        type(passive_inputs_t), intent(in) :: passive
        type(generic_coef_t), intent(in) :: sd
        type(coef_term_t), intent(out) :: term
        character(*), intent(in) :: src_name

        integer :: pos, start, key_len, slot
        character(len=32) :: part

        term%value = 0.0
        term%n_factors = 0
        term%factor = 0

        if (trim(key) == '0') return  ! constant term, no factors

        key_len = len_trim(key)
        start = 1

        do while (start <= key_len)
            pos = index(key(start:key_len), '_')
            if (pos == 0) then
                part = key(start:key_len)
                start = key_len + 1
            else
                part = key(start:start + pos - 2)
                start = start + pos
            end if

            slot = resolve_var_name(trim(part), ctrl, passive, sd)
            if (slot == 0) then
                write(*,*) 'ERROR: Unknown variable "', trim(part), &
                           '" in key "', trim(key), '" of source "', trim(src_name), '"'
                stop
            end if

            term%n_factors = term%n_factors + 1
            if (term%n_factors > 2) then
                write(*,*) 'ERROR: Too many factors in key "', trim(key), '"'
                stop
            end if
            term%factor(term%n_factors) = slot
        end do
    end subroutine parse_term_key

    subroutine parse_group_from_json(j_group, ctrl, passive, sd, group, src_name)
        type(json_value), pointer, intent(in) :: j_group
        type(control_inputs_t), intent(in) :: ctrl
        type(passive_inputs_t), intent(in) :: passive
        type(generic_coef_t), intent(in) :: sd
        type(coef_group_t), intent(out) :: group
        character(*), intent(in) :: src_name

        type(json_value), pointer :: j_term
        integer :: n_children, it
        character(len=32) :: key_name

        call json_info(j_group, n_children=n_children)
        if (n_children > MAX_TERMS) then
            write(*,*) 'ERROR: Too many terms in group (max ', MAX_TERMS, ')'
            stop
        end if

        group%n_terms = n_children
        do it = 1, n_children
            call json_value_get(j_group, it, j_term)

            if (allocated(j_term%name)) then
                key_name = trim(j_term%name)
            else
                write(*,*) 'ERROR: Coefficient term has no key name in source ', trim(src_name)
                stop
            end if

            ! parse the key into factor indices (sets n_factors and factor)
            call parse_term_key(key_name, ctrl, passive, sd, group%terms(it), src_name)

            ! set coefficient value (after parse_term_key which zeroes it)
            if (j_term%data%var_type == json_real) then
                group%terms(it)%value = j_term%data%dbl_value
            else if (j_term%data%var_type == json_integer) then
                group%terms(it)%value = real(j_term%data%int_value)
            else
                write(*,*) 'ERROR: Non-numeric value for key "', trim(key_name), &
                           '" in source ', trim(src_name)
                stop
            end if
        end do
    end subroutine parse_group_from_json

    subroutine load_stall_model(j_stall, stall)
        type(json_value), pointer, intent(in) :: j_stall
        type(stall_model_t), intent(inout) :: stall
        type(json_value), pointer :: j_sub

        ! alpha stall (CL, CD, Cm) — navigate to child objects, then use unit-aware getters
        call jsonx_get(j_stall, 'include_stall', stall%enabled, .false.)

        call jsonx_get(j_stall, 'CL', j_sub)
        if (associated(j_sub)) then
            call jsonx_get_u(j_sub, 'alpha_0', stall%CL_alpha0, 0.0)
            call jsonx_get_u(j_sub, 'alpha_s', stall%CL_alpha_s, 0.0)
            call jsonx_get(j_sub, 'lambda_b', stall%CL_lambda_b, 0.0)
        end if

        call jsonx_get(j_stall, 'CD', j_sub)
        if (associated(j_sub)) then
            call jsonx_get_u(j_sub, 'alpha_0', stall%CD_alpha0, 0.0)
            call jsonx_get_u(j_sub, 'alpha_s', stall%CD_alpha_s, 0.0)
            call jsonx_get(j_sub, 'lambda_b', stall%CD_lambda_b, 0.0)
        end if

        call jsonx_get(j_stall, 'Cm', j_sub)
        if (associated(j_sub)) then
            call jsonx_get_u(j_sub, 'alpha_0', stall%Cm_alpha0, 0.0)
            call jsonx_get_u(j_sub, 'alpha_s', stall%Cm_alpha_s, 0.0)
            call jsonx_get(j_sub, 'lambda_b', stall%Cm_lambda_b, 0.0)
            call jsonx_get(j_sub, 'min', stall%Cm_min, 0.0)
        end if

        ! lateral beta-stall sub-blocks (side force CS, yaw Cn) — parallel to the alpha-stall blocks
        call jsonx_get(j_stall, 'CS', j_sub)
        if (associated(j_sub)) then
            call jsonx_get_u(j_sub, 'beta_0', stall%CS_beta0, 0.0)
            call jsonx_get_u(j_sub, 'beta_s', stall%CS_beta_s, 0.0)
            call jsonx_get(j_sub, 'lambda_b', stall%CS_lambda_b, 0.0)
            call jsonx_get(j_sub, 'max', stall%CS_stall, 0.0)
        end if

        call jsonx_get(j_stall, 'Cn', j_sub)
        if (associated(j_sub)) then
            call jsonx_get_u(j_sub, 'beta_0', stall%Cn_beta0, 0.0)
            call jsonx_get_u(j_sub, 'beta_s', stall%Cn_beta_s, 0.0)
            call jsonx_get(j_sub, 'lambda_b', stall%Cn_lambda_b, 0.0)
            call jsonx_get(j_sub, 'min', stall%Cn_min_beta, 0.0)
        end if

        ! rotation rate stall (pbar, qbar, rbar)
        call jsonx_get(j_stall, 'pbar.stall', stall%pbar_stall, 0.0)
        call jsonx_get(j_stall, 'pbar.lambda', stall%lambda_pbar, 0.0)
        call jsonx_get(j_stall, 'pbar.Cl_stall', stall%Cl_pbar_stall, 0.0)
        call jsonx_get(j_stall, 'qbar.stall', stall%qbar_stall, 0.0)
        call jsonx_get(j_stall, 'qbar.lambda', stall%lambda_qbar, 0.0)
        call jsonx_get(j_stall, 'qbar.Cm_stall', stall%Cm_qbar_stall, 0.0)
        call jsonx_get(j_stall, 'rbar.stall', stall%rbar_stall, 0.0)
        call jsonx_get(j_stall, 'rbar.lambda', stall%lambda_rbar, 0.0)
        call jsonx_get(j_stall, 'rbar.Cn_stall', stall%Cn_rbar_stall, 0.0)
    end subroutine load_stall_model

    subroutine load_database_source(j_src, src, ctrl, passive)
        type(json_value), pointer, intent(in) :: j_src
        type(database_source_t), intent(inout) :: src
        type(control_inputs_t), intent(in) :: ctrl
        type(passive_inputs_t), intent(in) :: passive
        type(json_value), pointer :: j_ref, j_stall
        real, allocatable :: arr(:)
        character(len=:), allocatable :: db_dir
        character(len=200), allocatable :: filenames(:)
        logical :: saturate, presorted
        integer :: i, n_files

        ! reference geometry
        call jsonx_get(j_src, 'reference', j_ref)
        call jsonx_get_u(j_ref, 'area', src%S_ref)
        call jsonx_get_u(j_ref, 'longitudinal_length', src%c_bar)
        call jsonx_get_u(j_ref, 'lateral_length', src%b_ref)
        call jsonx_get_u(j_ref, 'location', arr, 0.0, 3)
        if (allocated(arr)) then
            src%location = arr
            deallocate(arr)
        end if

        ! shared settings
        call jsonx_get(j_src, 'saturate', saturate, .true.)
        call jsonx_get(j_src, 'presorted', presorted, .false.)

        ! database file list
        call jsonx_get(j_src, 'files', filenames)
        n_files = size(filenames)

        ! optional database directory prefix
        db_dir = ''
        call jsonx_get(j_src, 'database_directory', db_dir, '')

        ! allocate and load each database entry
        src%db_n_entries = n_files
        allocate(src%db_entries(n_files))

        do i = 1, n_files
            call load_single_db_entry(src%db_entries(i), trim(filenames(i)), db_dir, &
                                      saturate, presorted, ctrl, passive, src%name)
        end do

        ! stall model (alpha stall + rotation rate stall)
        call jsonx_get(j_src, 'stall', j_stall)
        if (associated(j_stall)) then
            call load_stall_model(j_stall, src%stall)
        end if

        write(*,*) '    Database source "'//trim(src%name)//'" loaded: ', &
                   n_files, ' database(s)'
    end subroutine load_database_source

    subroutine load_single_db_entry(entry, filename, db_dir, saturate, presorted, ctrl, passive, src_name)
        type(db_entry_t), intent(inout) :: entry
        character(len=*), intent(in) :: filename, db_dir, src_name
        logical, intent(in) :: saturate, presorted
        type(control_inputs_t), intent(in) :: ctrl
        type(passive_inputs_t), intent(in) :: passive
        character(len=:), allocatable :: var_name, unit_str
        integer :: i, n_dv

        ! load the CSV (aero_db_init supports pn= path prefix)
        if (len_trim(db_dir) > 0) then
            call entry%db%init(filename, pn=db_dir, saturate=saturate, presorted=presorted)
        else
            call entry%db%init(filename, saturate=saturate, presorted=presorted)
        end if

        ! cache IV count and allocate mapping arrays
        entry%n_iv = entry%db%n_iv
        allocate(entry%iv_map(entry%n_iv))
        allocate(entry%iv_scale(entry%n_iv))

        ! allocate per-column DV mapping array
        n_dv = entry%db%n_dv
        allocate(entry%dv_columns(n_dv))

        ! map independent variables to state indices
        do i = 1, entry%n_iv
            call parse_variable_and_units(trim(entry%db%ind_vars(i)), var_name, unit_str)
            call resolve_state_var(var_name, unit_str, ctrl, passive, &
                                   entry%iv_map(i), entry%iv_scale(i), src_name)
            if (allocated(var_name)) deallocate(var_name)
            if (allocated(unit_str)) deallocate(unit_str)
        end do

        ! map dependent variables (underscore-separated names auto-multiply)
        do i = 1, n_dv
            call map_db_entry_dv(trim(entry%db%dep_vars(i)), i, entry, ctrl, passive, src_name)
        end do
    end subroutine load_single_db_entry

    ! unified state variable name resolution
    ! maps a variable name to its index in aero_state_t%values
    ! handles: standard aero vars, control effectors, passive effectors
    function resolve_state_index(name, ctrl, passive) result(idx)
        character(len=*), intent(in) :: name
        type(control_inputs_t), intent(in) :: ctrl
        type(passive_inputs_t), intent(in) :: passive
        integer :: idx
        integer :: k

        ! standard variables
        select case (trim(name))
        case ('0');         idx = IDX_CONST; return
        case ('alpha');     idx = IDX_ALPHA; return
        case ('beta');      idx = IDX_BETA; return
        case ('pbar');      idx = IDX_PBAR; return
        case ('qbar');      idx = IDX_QBAR; return
        case ('rbar');      idx = IDX_RBAR; return
        case ('alphahat');  idx = IDX_ALPHAHAT; return
        case ('betaflank'); idx = IDX_BETAFLANK; return
        case ('betahat');   idx = IDX_BETAHAT; return
        end select

        ! control effectors
        do k = 1, ctrl%n
            if (trim(ctrl%effectors(k)%name) == trim(name)) then
                idx = N_STD_VARS + k
                return
            end if
        end do

        ! passive effector positions
        do k = 1, passive%n
            if (trim(passive%effectors(k)%name) == trim(name)) then
                idx = N_STD_VARS + ctrl%n + k
                return
            end if
        end do

        ! passive effector rate variables
        do k = 1, passive%n
            if (len_trim(passive%effectors(k)%rate_variable) > 0 .and. &
                trim(passive%effectors(k)%rate_variable) == trim(name)) then
                idx = N_STD_VARS + ctrl%n + passive%n + k
                return
            end if
        end do

        idx = 0  ! not found
    end function resolve_state_index

    ! resolve a variable name to a state index + unit scale (for database IV/factor mapping)
    subroutine resolve_state_var(var_name, unit_str, ctrl, passive, state_idx, scale, src_name)
        character(len=*), intent(in) :: var_name
        character(len=:), allocatable, intent(in) :: unit_str
        type(control_inputs_t), intent(in) :: ctrl
        type(passive_inputs_t), intent(in) :: passive
        integer, intent(out) :: state_idx
        real, intent(out) :: scale
        character(len=*), intent(in) :: src_name

        scale = 1.0
        state_idx = resolve_state_index(var_name, ctrl, passive)
        if (state_idx == 0) then
            write(*,*) 'ERROR: Unknown variable "'// &
                       trim(var_name)//'" in source "'//trim(src_name)//'"'
            stop
        end if

        if (allocated(unit_str)) then
            scale = conversion_factor_to(unit_str)
        end if
    end subroutine resolve_state_var

    ! map a DV column name to a coefficient slot + multiplier factors (as dep_var_t)
    ! e.g. "Cl_beta" -> slot=DV_CROLL, factors has ind_var_t for beta
    !      "Cx_elevator_elevator" -> slot=DV_CX, factors has ind_var_t for elevator twice
    !      "Cm" -> slot=DV_CM, no factors (plain additive)
    subroutine map_db_entry_dv(raw_name, col_idx, entry, ctrl, passive, src_name)
        character(len=*), intent(in) :: raw_name, src_name
        integer, intent(in) :: col_idx
        type(db_entry_t), intent(inout) :: entry
        type(control_inputs_t), intent(in) :: ctrl
        type(passive_inputs_t), intent(in) :: passive

        character(len=64), allocatable :: parts(:)
        character(len=:), allocatable :: fac_var, fac_unit, tmp_var, tmp_unit
        integer :: slot, n_parts, n_factors, i, state_idx
        real :: scale

        ! strip units from the full column name
        call parse_variable_and_units(raw_name, tmp_var, tmp_unit)
        if (allocated(tmp_unit)) deallocate(tmp_unit)

        ! split on underscore: first part = coefficient, rest = factors
        call split_on_char(trim(tmp_var), '_', parts, n_parts)
        if (allocated(tmp_var)) deallocate(tmp_var)

        if (n_parts == 0) return

        ! map coefficient name (first part) to DV slot
        slot = resolve_dv_slot(trim(parts(1)))
        if (slot == 0) then
            write(*,*) '    WARNING: Unknown database dependent variable "'// &
                       trim(parts(1))//'" in column "'//trim(raw_name)// &
                       '" - column will be ignored'
            deallocate(parts)
            return
        end if

        entry%dv_columns(col_idx)%slot = slot

        ! parse multiplier factors (remaining parts after the first)
        n_factors = n_parts - 1
        if (n_factors > 0) then
            entry%dv_columns(col_idx)%factors%n_factors = n_factors
            allocate(entry%dv_columns(col_idx)%factors%factors(n_factors))

            do i = 1, n_factors
                call parse_variable_and_units(trim(parts(i + 1)), fac_var, fac_unit)
                call resolve_state_var(fac_var, fac_unit, ctrl, passive, state_idx, scale, src_name)
                entry%dv_columns(col_idx)%factors%factors(i)%idx = state_idx
                entry%dv_columns(col_idx)%factors%factors(i)%cf  = scale
                if (allocated(fac_var)) deallocate(fac_var)
                if (allocated(fac_unit)) deallocate(fac_unit)
            end do
        end if

        deallocate(parts)
    end subroutine map_db_entry_dv

    ! resolve a coefficient base name to its DV slot index
    function resolve_dv_slot(name) result(slot)
        character(len=*), intent(in) :: name
        integer :: slot

        select case (trim(name))
        case ('Cx'); slot = DV_CX
        case ('Cy'); slot = DV_CY
        case ('Cz'); slot = DV_CZ
        case ('CL'); slot = DV_CL
        case ('CD'); slot = DV_CD
        case ('CS'); slot = DV_CS
        case ('Cl'); slot = DV_CROLL
        case ('Cm'); slot = DV_CM
        case ('Cn'); slot = DV_CN
        ! stability-axis force/moment coefficients (rotated to body by alpha only)
        case ('CLstab'); slot = DV_CL_STAB
        case ('CDstab'); slot = DV_CD_STAB
        case ('CSstab'); slot = DV_CS_STAB
        case ('Clstab'); slot = DV_CROLL_STAB
        case ('Cnstab'); slot = DV_CN_STAB
        case default; slot = 0
        end select
    end function resolve_dv_slot

    ! load passive effectors from json (names and physical properties only, not driving coefficients)
    subroutine load_passive_effectors(j_veh, passive)
        type(json_value), pointer, intent(in) :: j_veh
        type(passive_inputs_t), intent(out) :: passive

        type(json_value), pointer :: j_pe_section, j_pe
        real, allocatable :: arr(:)
        integer :: n_pe, ie
        logical :: found
        character(len=:), allocatable :: rate_var_str

        call json_get(j_veh, 'passive_effectors', j_pe_section, found)
        if (.not. found) then
            passive%n = 0
            return
        end if

        call json_info(j_pe_section, n_children=n_pe)
        passive%n = n_pe
        if (n_pe == 0) return

        allocate(passive%effectors(n_pe))

        do ie = 1, n_pe
            call json_value_get(j_pe_section, ie, j_pe)

            ! name from json key
            if (allocated(j_pe%name)) then
                passive%effectors(ie)%name = trim(j_pe%name)
            else
                write(passive%effectors(ie)%name, '(A,I0)') 'passive_', ie
            end if

            ! required: inertia and reference length
            call jsonx_get_u(j_pe, 'inertia', passive%effectors(ie)%inertia)
            call jsonx_get_u(j_pe, 'reference_length', passive%effectors(ie)%ref_length)

            ! optional: reference area (defaults to 0, resolved later from first aero source)
            call jsonx_get_u(j_pe, 'reference_area', passive%effectors(ie)%ref_area, 0.0)

            ! optional: damping
            call jsonx_get_u(j_pe, 'damping', passive%effectors(ie)%damping, 0.0)
            passive%effectors(ie)%has_damping = json_found .and. passive%effectors(ie)%damping > 0.0

            ! optional: magnitude limits (auto-converted if [deg] present)
            call jsonx_get_u(j_pe, 'magnitude_limits', arr, 0.0, 2)
            if (json_found .and. allocated(arr)) then
                passive%effectors(ie)%min_val = arr(1)
                passive%effectors(ie)%max_val = arr(2)
                passive%effectors(ie)%has_limits = .true.
                deallocate(arr)
            else
                if (allocated(arr)) deallocate(arr)
            end if

            ! optional: rate variable name
            rate_var_str = ''
            call jsonx_get(j_pe, 'rate_variable', rate_var_str, '')
            passive%effectors(ie)%rate_variable = rate_var_str

            ! optional: nondimensional rate flag (default true)
            call jsonx_get(j_pe, 'nondimensional_rate', passive%effectors(ie)%nondim_rate, .true.)

            write(*,*) '    Passive effector: ', trim(passive%effectors(ie)%name)
        end do
    end subroutine load_passive_effectors

    ! parse passive effector driving coefficients/databases (called after force sources are loaded)
    subroutine parse_passive_driving(j_veh, ctrl, passive, config)
        type(json_value), pointer, intent(in) :: j_veh
        type(control_inputs_t), intent(in) :: ctrl
        type(passive_inputs_t), intent(inout) :: passive
        type(vehicle_config_t), intent(in) :: config

        type(json_value), pointer :: j_pe_section, j_pe, j_driving, j_driving_db
        type(generic_coef_t) :: driving_sd
        character(len=:), allocatable :: db_dir, driving_var_name
        character(len=200), allocatable :: filenames(:)
        logical :: saturate, presorted, found
        integer :: ie, k, n_files, n_all, max_n_iv, max_n_dv
        type(polynomial_driving_t), allocatable :: poly_drv
        type(database_driving_t), allocatable :: db_drv

        call json_get(j_veh, 'passive_effectors', j_pe_section, found)
        if (.not. found) return

        ! n_ctrl for pool = ctrl%n + 2*passive%n (positions + rates)
        n_all = ctrl%n + 2 * passive%n

        do ie = 1, passive%n
            call json_value_get(j_pe_section, ie, j_pe)

            ! default ref_area from first aero source if not set
            if (passive%effectors(ie)%ref_area <= 0.0) then
                do k = 1, config%n_sources
                    if (config%sources(k)%src%get_S_ref() > 0.0) then
                        passive%effectors(ie)%ref_area = config%sources(k)%src%get_S_ref()
                        exit
                    end if
                end do
            end if

            ! check for database driving first, then polynomial
            call json_get(j_pe, 'driving_database', j_driving_db, found)
            if (found) then
                ! database driving coefficient
                call jsonx_get(j_driving_db, 'driving_variable', driving_var_name)
                call jsonx_get(j_driving_db, 'saturate', saturate, .true.)
                call jsonx_get(j_driving_db, 'presorted', presorted, .false.)
                db_dir = ''
                call jsonx_get(j_driving_db, 'database_directory', db_dir, '')
                call jsonx_get(j_driving_db, 'files', filenames)
                n_files = size(filenames)

                allocate(db_drv)
                db_drv%driving_db_n = n_files
                allocate(db_drv%driving_dbs(n_files))

                do k = 1, n_files
                    call load_driving_db_entry(db_drv%driving_dbs(k), &
                                              trim(filenames(k)), db_dir, saturate, presorted, &
                                              ctrl, passive, driving_var_name, &
                                              passive%effectors(ie)%name)
                end do

                ! pre-allocate work arrays sized to max across all entries
                max_n_iv = 0
                max_n_dv = 0
                do k = 1, n_files
                    max_n_iv = max(max_n_iv, db_drv%driving_dbs(k)%n_iv)
                    max_n_dv = max(max_n_dv, db_drv%driving_dbs(k)%db%n_dv)
                end do
                allocate(db_drv%iv_work(max_n_iv), db_drv%dv_work(max_n_dv))

                call move_alloc(db_drv, passive%effectors(ie)%driving)

                write(*,*) '    Driving database for "'//trim(passive%effectors(ie)%name)//'" loaded: ', &
                           n_files, ' file(s), DV: '//trim(driving_var_name)

                if (allocated(filenames)) deallocate(filenames)
                if (allocated(driving_var_name)) deallocate(driving_var_name)
                if (allocated(db_dir)) deallocate(db_dir)
            else
                ! polynomial driving coefficient
                call json_get(j_pe, 'driving_coefficient', j_driving, found)
                if (.not. found) then
                    write(*,*) 'ERROR: Passive effector "', trim(passive%effectors(ie)%name), &
                               '" must have either "driving_coefficient" or "driving_database"'
                    stop
                end if

                ! set up pool layout for the driving coefficient
                driving_sd%n_ctrl = n_all
                driving_sd%ctrl_offset = N_STD_VARS + 1
                driving_sd%n_custom = 0
                driving_sd%custom_offset = driving_sd%ctrl_offset + n_all
                driving_sd%group_offset = driving_sd%custom_offset
                driving_sd%pool_size = driving_sd%group_offset + N_GROUPS - 1

                allocate(poly_drv)
                call parse_group_from_json(j_driving, ctrl, passive, driving_sd, &
                                           poly_drv%driving_coef, &
                                           'passive:'//trim(passive%effectors(ie)%name))
                call move_alloc(poly_drv, passive%effectors(ie)%driving)
            end if
        end do
    end subroutine parse_passive_driving

    ! load a single driving database entry for a passive effector
    subroutine load_driving_db_entry(entry, filename, db_dir, saturate, presorted, &
                                      ctrl, passive, driving_var_name, pe_name)
        type(driving_db_entry_t), intent(inout) :: entry
        character(len=*), intent(in) :: filename, db_dir, pe_name
        logical, intent(in) :: saturate, presorted
        type(control_inputs_t), intent(in) :: ctrl
        type(passive_inputs_t), intent(in) :: passive
        character(len=*), intent(in) :: driving_var_name
        character(len=:), allocatable :: var_name, unit_str
        integer :: i

        ! load CSV
        if (len_trim(db_dir) > 0) then
            call entry%db%init(filename, pn=db_dir, saturate=saturate, presorted=presorted)
        else
            call entry%db%init(filename, saturate=saturate, presorted=presorted)
        end if

        ! map independent variables
        entry%n_iv = entry%db%n_iv
        allocate(entry%iv_map(entry%n_iv))
        allocate(entry%iv_scale(entry%n_iv))

        do i = 1, entry%n_iv
            call parse_variable_and_units(trim(entry%db%ind_vars(i)), var_name, unit_str)
            call resolve_state_var(var_name, unit_str, ctrl, passive, entry%iv_map(i), entry%iv_scale(i), &
                                   'passive:'//trim(pe_name))
            if (allocated(var_name)) deallocate(var_name)
            if (allocated(unit_str)) deallocate(unit_str)
        end do

        ! find the driving variable column
        entry%dv_index = 0
        do i = 1, entry%db%n_dv
            call parse_variable_and_units(trim(entry%db%dep_vars(i)), var_name, unit_str)
            if (trim(var_name) == trim(driving_var_name)) then
                entry%dv_index = i
            end if
            if (allocated(var_name)) deallocate(var_name)
            if (allocated(unit_str)) deallocate(unit_str)
        end do

        if (entry%dv_index == 0) then
            write(*,*) 'ERROR: Driving variable "'//trim(driving_var_name)// &
                       '" not found in database "'//trim(filename)// &
                       '" for passive effector "'//trim(pe_name)//'"'
            stop
        end if
    end subroutine load_driving_db_entry

    ! load initial passive effector values from state section
    subroutine load_passive_initial_conditions(j_state, passive, vehicle_name)
        type(json_value), pointer, intent(in) :: j_state
        type(passive_inputs_t), intent(inout) :: passive
        character(*), intent(in) :: vehicle_name

        type(json_value), pointer :: j_pe_init, j_val
        character(len=32) :: eff_name
        character(len=:), allocatable :: var_part, units_part
        integer :: ic, ie, idx
        real :: temp_val
        logical :: found

        if (passive%n == 0) return

        call json_get(j_state, 'passive_effectors', j_pe_init, found)
        if (.not. found) return

        call json_info(j_pe_init, n_children=ic)
        do ie = 1, ic
            call json_value_get(j_pe_init, ie, j_val)

            ! parse key: extract effector name and optional units
            call parse_variable_and_units(trim(j_val%name), var_part, units_part)
            eff_name = var_part

            ! find matching passive effector
            idx = find_passive_index(passive, trim(eff_name))
            if (idx == 0) then
                write(*,*) 'WARNING: Unknown passive effector "', trim(eff_name), &
                           '" in state.passive_effectors of vehicle "', trim(vehicle_name), '"'
                cycle
            end if

            if (j_val%data%var_type == json_real) then
                temp_val = j_val%data%dbl_value
            else if (j_val%data%var_type == json_integer) then
                temp_val = real(j_val%data%int_value)
            else
                temp_val = 0.0
            end if

            ! apply unit conversion if brackets present
            if (allocated(units_part)) then
                temp_val = temp_val * conversion_factor_from(units_part)
            end if
            passive%effectors(idx)%value = temp_val
        end do
    end subroutine load_passive_initial_conditions

    ! load turbulence configuration from atmosphere json section
    subroutine load_turbulence_config(j_atmo, turb)
        type(json_value), pointer, intent(in) :: j_atmo
        type(turbulence_config_t), intent(out) :: turb

        type(json_value), pointer :: j_turb
        logical :: found
        real :: sigma_val
        character(len=:), allocatable :: intensity_str

        call json_get(j_atmo, 'turbulence', j_turb, found)
        if (.not. found) return

        call jsonx_get(j_turb, 'enabled', turb%enabled, .false.)
        if (.not. turb%enabled) return

        ! sigma mode: if sigma[ft/s] is present, use fixed mode
        call jsonx_get_u(j_turb, 'sigma', sigma_val, 0.0)
        if (json_found) then
            turb%sigma_fixed = sigma_val
            turb%sigma_is_fixed = .true.
        else
            ! intensity mode: altitude dependent sigma from Tables 9.2.1-9.2.3
            turb%sigma_is_fixed = .false.
            call jsonx_get(j_turb, 'intensity', intensity_str, 'light')
            turb%intensity = intensity_str
        end if

        ! optional parameters
        call jsonx_get_u(j_turb, 'Vmin', turb%Vmin, 5.0)
        call jsonx_get_u(j_turb, 'wingspan', turb%wingspan, 0.0)
        call jsonx_get_u(j_turb, 'Lh_sep', turb%Lh_sep, 0.0)
        call jsonx_get_u(j_turb, 'Lv_sep', turb%Lv_sep, 0.0)
        call jsonx_get(j_turb, 'buffer_size', turb%buf_size, 20)
        call jsonx_get(j_turb, 'seed', turb%seed, 42)

        write(*,'(A)') '  Turbulence: enabled'
        if (turb%sigma_is_fixed) then
            write(*,'(A,F8.2,A)') '    Mode: fixed sigma = ', turb%sigma_fixed, ' ft/s'
        else
            write(*,'(A,A)') '    Mode: intensity = ', trim(turb%intensity)
        end if
        if (turb%wingspan > 0.0) write(*,'(A,F8.2,A)') '    Wingspan: ', turb%wingspan, ' ft (p-gust enabled)'
        if (turb%Lh_sep > 0.0) write(*,'(A,F8.2,A)') '    Lh_sep: ', turb%Lh_sep, ' ft (q-gust enabled)'
        if (turb%Lv_sep > 0.0) write(*,'(A,F8.2,A)') '    Lv_sep: ', turb%Lv_sep, ' ft (r-gust enabled)'
    end subroutine load_turbulence_config

    ! parse "analysis" section under a vehicle node
    subroutine load_analysis_config(j_veh, settings, run_analysis)
        type(json_value), pointer, intent(in) :: j_veh
        type(analysis_settings_t), intent(out) :: settings
        logical, intent(out) :: run_analysis

        type(json_value), pointer :: j_analysis
        character(len=:), allocatable :: state_form_str, prefix_str
        logical :: found

        run_analysis = .false.
        settings = analysis_settings_t()  ! default-initialize

        call json_get(j_veh, 'analysis', j_analysis, found)
        if (.not. found) return

        call jsonx_get(j_analysis, 'export_state_space', settings%export_state_space, .false.)
        state_form_str = 'euler'
        call jsonx_get(j_analysis, 'state_form', state_form_str)
        settings%state_form = trim(state_form_str)
        call jsonx_get(j_analysis, 'fd_step', settings%fd_step, 1.0e-5)
        prefix_str = ''
        call jsonx_get(j_analysis, 'output_prefix', prefix_str)
        settings%output_prefix = trim(prefix_str)

        run_analysis = settings%export_state_space
    end subroutine load_analysis_config

    ! load sensor configurations from vehicle JSON
    subroutine load_sensors(j_veh, config)
        type(json_value), pointer, intent(in) :: j_veh
        type(vehicle_config_t), intent(inout) :: config

        type(json_value), pointer :: j_sensors, j_sensor
        integer :: n_children, i, count
        character(len=64) :: sensor_name
        character(len=:), allocatable :: type_str
        real, allocatable :: arr(:)
        real :: refresh_rate

        call jsonx_get(j_veh, 'sensors', j_sensors)
        if (.not. associated(j_sensors)) then
            config%n_sensors = 0
            return
        end if

        ! save_outputs flag
        call jsonx_get(j_sensors, 'save_outputs', config%save_sensor_outputs, .false.)

        ! single-pass: allocate to max, parse sensors, then set count
        call json_info(j_sensors, n_children=n_children)
        if (n_children == 0) then
            config%n_sensors = 0
            return
        end if
        allocate(config%sensors(n_children))

        count = 0
        do i = 1, n_children
            call json_value_get(j_sensors, i, j_sensor)
            if (.not. allocated(j_sensor%name)) cycle
            if (trim(j_sensor%name) == 'save_outputs' .or. trim(j_sensor%name) == 'ekf') cycle
            count = count + 1

            sensor_name = trim(j_sensor%name)

            ! get type
            call jsonx_get(j_sensor, 'type', type_str)
            if (.not. allocated(type_str)) then
                write(*,*) 'ERROR: Sensor "', trim(sensor_name), '" missing required "type" field'
                stop
            end if

            ! allocate sensor
            allocate(config%sensors(count)%sensor)

            ! read location and attitude before init (init builds DCM from attitude)
            call jsonx_get_u(j_sensor, 'location', arr, 0.0, 3)
            config%sensors(count)%sensor%location = arr(1:3)
            deallocate(arr)

            call jsonx_get_u(j_sensor, 'attitude', arr, 0.0, 3)
            config%sensors(count)%sensor%attitude = arr(1:3)
            deallocate(arr)

            ! init sets type_id, n_outputs, allocates arrays, builds DCM, sets has_location
            call sensor_init(config%sensors(count)%sensor, type_str, sensor_name)

            ! magnetic field (for IMU/magnetometer — nT is not a convertible unit)
            call jsonx_get(j_sensor, 'magnetic_field[nT]', arr, 0.0, 3)
            if (json_found) then
                config%sensors(count)%sensor%mag_field = arr(1:3)
            end if
            deallocate(arr)

            ! refresh rate
            call jsonx_get_u(j_sensor, 'refresh_rate', refresh_rate, 0.0)
            if (refresh_rate > 0.0) then
                config%sensors(count)%sensor%refresh_interval = 1.0 / refresh_rate
            end if

            ! error model (all optional)
            call jsonx_get(j_sensor, 'bias', arr, 0.0, config%sensors(count)%sensor%n_outputs)
            if (json_found) then
                allocate(config%sensors(count)%sensor%error%bias(config%sensors(count)%sensor%n_outputs))
                config%sensors(count)%sensor%error%bias = arr(1:config%sensors(count)%sensor%n_outputs)
            end if
            deallocate(arr)

            call jsonx_get(j_sensor, 'noise_std', arr, 0.0, config%sensors(count)%sensor%n_outputs)
            if (json_found) then
                allocate(config%sensors(count)%sensor%error%noise_std(config%sensors(count)%sensor%n_outputs))
                config%sensors(count)%sensor%error%noise_std = arr(1:config%sensors(count)%sensor%n_outputs)
            end if
            deallocate(arr)

            call jsonx_get(j_sensor, 'min_value', arr, 0.0, config%sensors(count)%sensor%n_outputs)
            if (json_found) then
                allocate(config%sensors(count)%sensor%error%g_min(config%sensors(count)%sensor%n_outputs))
                config%sensors(count)%sensor%error%g_min = arr(1:config%sensors(count)%sensor%n_outputs)
            end if
            deallocate(arr)

            call jsonx_get(j_sensor, 'max_value', arr, 0.0, config%sensors(count)%sensor%n_outputs)
            if (json_found) then
                allocate(config%sensors(count)%sensor%error%g_max(config%sensors(count)%sensor%n_outputs))
                config%sensors(count)%sensor%error%g_max = arr(1:config%sensors(count)%sensor%n_outputs)
            end if
            deallocate(arr)

            call jsonx_get(j_sensor, 'bit_count', config%sensors(count)%sensor%error%bit_count, 0)

            write(*,'(A,A,A,A,A,I0,A)') '    Sensor: ', trim(sensor_name), &
                ' (', trim(type_str), ', ', config%sensors(count)%sensor%n_outputs, ' channels)'
            if (allocated(type_str)) deallocate(type_str)
        end do

        config%n_sensors = count

        ! parse EKF configuration (inside sensors section)
        call load_ekf_config(j_sensors, config)

    end subroutine load_sensors

    ! load EKF configuration from the sensors JSON block
    subroutine load_ekf_config(j_sensors, config)
        type(json_value), pointer, intent(in) :: j_sensors
        type(vehicle_config_t), intent(inout) :: config

        type(json_value), pointer :: j_ekf
        logical :: ekf_enabled

        call jsonx_get(j_sensors, 'ekf', j_ekf)
        if (.not. associated(j_ekf)) return

        call jsonx_get(j_ekf, 'enabled', ekf_enabled, .false.)
        if (.not. ekf_enabled) return

        config%use_ekf = .true.

        ! parse EKF parameters (all optional with defaults)
        call jsonx_get(j_ekf, 'gyro_noise', config%ekf%params%gyro_noise, 0.005)
        call jsonx_get(j_ekf, 'accel_noise', config%ekf%params%accel_noise, 0.05)
        call jsonx_get(j_ekf, 'gyro_bias_walk', config%ekf%params%gyro_bias_walk, 0.0001)
        call jsonx_get(j_ekf, 'accel_bias_walk', config%ekf%params%accel_bias_walk, 0.001)
        call jsonx_get(j_ekf, 'omega_dot_tau', config%ekf%params%omega_dot_tau, 0.015)
        call jsonx_get(j_ekf, 'gps_position_noise', config%ekf%params%gps_pos_noise, 5.0)
        call jsonx_get(j_ekf, 'gps_velocity_noise', config%ekf%params%gps_vel_noise, 0.3)
        call jsonx_get(j_ekf, 'mag_heading_noise', config%ekf%params%mag_heading_noise, 0.1)
        call jsonx_get(j_ekf, 'airspeed_noise', config%ekf%params%airspeed_noise, 3.0)
        call jsonx_get(j_ekf, 'alpha_noise', config%ekf%params%aero_alpha_noise, 0.01)
        call jsonx_get(j_ekf, 'beta_noise', config%ekf%params%aero_beta_noise, 0.01)
        call jsonx_get(j_ekf, 'save_output', config%save_ekf_output, .false.)

        write(*,'(A)') '    EKF: enabled (15-state error-state)'
    end subroutine load_ekf_config

    ! wire equation target pointers to actual config fields, and seed each
    ! target with its value at IV=0 so equation-defined fields have a sane
    ! initial value before trim/sim time stepping begins.
    subroutine wire_equation_targets(eqset, config, wind)
        type(equation_set_t), intent(inout) :: eqset
        type(vehicle_config_t), target, intent(inout) :: config
        real, target, intent(inout) :: wind(3)

        integer :: i

        eqset%has_mass_eqs = .false.

        do i = 1, eqset%n
            select case (trim(eqset%eqs(i)%section))
            case ('mass')
                eqset%has_mass_eqs = .true.
                select case (trim(eqset%eqs(i)%target_name))
                case ('weight');  eqset%eqs(i)%target => config%mass%weight_lbf
                case ('Ixx');     eqset%eqs(i)%target => config%mass%I(1,1)
                case ('Iyy');     eqset%eqs(i)%target => config%mass%I(2,2)
                case ('Izz');     eqset%eqs(i)%target => config%mass%I(3,3)
                case ('Ixy');     eqset%eqs(i)%target => config%mass%I(1,2)
                case ('Ixz');     eqset%eqs(i)%target => config%mass%I(1,3)
                case ('Iyz');     eqset%eqs(i)%target => config%mass%I(2,3)
                case default
                    write(*,*) 'ERROR [equations]: unknown mass target "', &
                        trim(eqset%eqs(i)%target_name), '"'
                    stop
                end select

            case ('atmosphere')
                select case (trim(eqset%eqs(i)%target_name))
                case ('constant_wind_N');  eqset%eqs(i)%target => wind(1)
                case ('constant_wind_E');  eqset%eqs(i)%target => wind(2)
                case ('constant_wind_D');  eqset%eqs(i)%target => wind(3)
                case default
                    write(*,*) 'ERROR [equations]: unknown atmosphere target "', &
                        trim(eqset%eqs(i)%target_name), '"'
                    stop
                end select

            case default
                ! treat as force source name — find by name and wire geometric fields
                call wire_source_equation(eqset%eqs(i), config)
                eqset%has_geometry_eqs = .true.
            end select

            ! seed the target with its IV=0 value so equation-defined fields are
            ! populated before any consumer (trim, mass assembly) reads them.
            if (associated(eqset%eqs(i)%target)) then
                eqset%eqs(i)%target = evaluate_at_zero(eqset%eqs(i)) * eqset%eqs(i)%unit_cf
            end if
        end do

        ! print summary
        if (eqset%n > 0) then
            write(*,'(A,I0,A)') '    Equations: ', eqset%n, ' dynamic value(s)'
        end if
    end subroutine wire_equation_targets

    ! wire a single equation to a force source geometric field
    subroutine wire_source_equation(eq, config)
        type(equation_t), intent(inout) :: eq
        type(vehicle_config_t), target, intent(inout) :: config

        integer :: j
        logical :: found

        found = .false.
        do j = 1, config%n_sources
            if (trim(config%sources(j)%src%name) /= trim(eq%section)) cycle
            found = .true.

            ! wire target pointer based on field name + concrete source type
            ! base type fields (all sources)
            select case (trim(eq%target_name))
            ! location
            case ('location_x');  eq%target => config%sources(j)%src%location(1); return
            case ('location_y');  eq%target => config%sources(j)%src%location(2); return
            case ('location_z');  eq%target => config%sources(j)%src%location(3); return
            ! orientation (Euler angles in rad; quaternion recomputed in recompute_source_geometry)
            case ('orientation_phi');   eq%target => config%sources(j)%src%orientation_euler(1); return
            case ('orientation_theta'); eq%target => config%sources(j)%src%orientation_euler(2); return
            case ('orientation_psi');   eq%target => config%sources(j)%src%orientation_euler(3); return
            ! component mass properties
            case ('weight');     eq%target => config%sources(j)%src%comp_mass%weight_lbf; return
            case ('comp_cg_x'); eq%target => config%sources(j)%src%comp_mass%cg(1); return
            case ('comp_cg_y'); eq%target => config%sources(j)%src%comp_mass%cg(2); return
            case ('comp_cg_z'); eq%target => config%sources(j)%src%comp_mass%cg(3); return
            case ('Ixx');       eq%target => config%sources(j)%src%comp_mass%I(1,1); return
            case ('Iyy');       eq%target => config%sources(j)%src%comp_mass%I(2,2); return
            case ('Izz');       eq%target => config%sources(j)%src%comp_mass%I(3,3); return
            case ('Ixy');       eq%target => config%sources(j)%src%comp_mass%I(1,2); return
            case ('Ixz');       eq%target => config%sources(j)%src%comp_mass%I(1,3); return
            case ('Iyz');       eq%target => config%sources(j)%src%comp_mass%I(2,3); return
            end select

            ! concrete type fields
            select type (src => config%sources(j)%src)
            type is (wing_source_t)
                select case (trim(eq%target_name))
                case ('semispan');    eq%target => src%semispan
                case ('root_chord'); eq%target => src%root_chord
                case ('tip_chord');  eq%target => src%tip_chord
                case ('sweep');      eq%target => src%sweep
                case ('dihedral');   eq%target => src%dihedral
                case default
                    write(*,*) 'ERROR [equations]: unknown wing target "', &
                        trim(eq%target_name), '" on source "', trim(eq%section), '"'
                    stop
                end select

            type is (sphere_source_t)
                select case (trim(eq%target_name))
                case ('rx');  eq%target => src%rx
                case ('ry');  eq%target => src%ry
                case ('rz');  eq%target => src%rz
                case default
                    write(*,*) 'ERROR [equations]: unknown sphere target "', &
                        trim(eq%target_name), '" on source "', trim(eq%section), '"'
                    stop
                end select

            type is (cuboid_source_t)
                select case (trim(eq%target_name))
                case ('lx');  eq%target => src%lx
                case ('ly');  eq%target => src%ly
                case ('lz');  eq%target => src%lz
                case default
                    write(*,*) 'ERROR [equations]: unknown cuboid target "', &
                        trim(eq%target_name), '" on source "', trim(eq%section), '"'
                    stop
                end select

            type is (cylinder_source_t)
                select case (trim(eq%target_name))
                case ('r1');     eq%target => src%r1
                case ('r2');     eq%target => src%r2
                case ('length'); eq%target => src%length
                case default
                    write(*,*) 'ERROR [equations]: unknown cylinder target "', &
                        trim(eq%target_name), '" on source "', trim(eq%section), '"'
                    stop
                end select

            type is (propeller_source_t)
                select case (trim(eq%target_name))
                case ('diameter');  eq%target => src%diameter
                case default
                    write(*,*) 'ERROR [equations]: unknown propeller target "', &
                        trim(eq%target_name), '" on source "', trim(eq%section), '"'
                    stop
                end select

            type is (simple_thrust_t)
                select case (trim(eq%target_name))
                case ('T0');  eq%target => src%T0
                case default
                    write(*,*) 'ERROR [equations]: unknown thrust target "', &
                        trim(eq%target_name), '" on source "', trim(eq%section), '"'
                    stop
                end select

            class default
                write(*,*) 'ERROR [equations]: source "', trim(eq%section), &
                    '" does not support variable geometry'
                stop
            end select
            return
        end do

        if (.not. found) then
            write(*,*) 'ERROR [equations]: no force source named "', &
                trim(eq%section), '" for equation target "', trim(eq%target_name), '"'
            stop
        end if
    end subroutine wire_source_equation

    ! load a JSON array into a fixed-size coefficient array
    subroutine load_coef_array(j_src, key, dest, arr)
        type(json_value), pointer, intent(in) :: j_src
        character(*), intent(in) :: key
        real, intent(inout) :: dest(:)
        real, allocatable, intent(inout) :: arr(:)
        integer :: n

        call jsonx_get(j_src, key, arr)
        if (allocated(arr)) then
            n = min(size(dest), size(arr))
            dest(1:n) = arr(1:n)
            deallocate(arr)
        end if
    end subroutine load_coef_array

    !===========================================================================
    ! Battery loading and wiring
    !===========================================================================

    subroutine load_batteries(j_veh, config)
        type(json_value), pointer, intent(in) :: j_veh
        type(vehicle_config_t), intent(inout) :: config

        type(json_value), pointer :: j_batts, j_batt, j_cell
        integer :: n_batts, i
        real :: P_aux, V_aux, cap_mAh, EC_per_Ah, C_rating_per_hr
        real :: pack_V, pack_cap_mAh, pack_R, nS_r, nP_r

        ! seconds per hour (for 1/hr and 1/Ah unit conversions)
        real, parameter :: SEC_PER_HR = 3600.0

        call json_value_get(j_veh, 'batteries', j_batts)
        if (json_failed() .or. .not. associated(j_batts)) then
            call json_clear_exceptions()
            config%n_batteries = 0
            return
        end if

        call json_info(j_batts, n_children=n_batts)
        if (n_batts == 0) then
            config%n_batteries = 0
            return
        end if

        allocate(config%batteries(n_batts))
        config%n_batteries = n_batts

        do i = 1, n_batts
            call json_value_get(j_batts, i, j_batt)

            ! name
            if (allocated(j_batt%name)) then
                config%batteries(i)%name = trim(j_batt%name)
            else
                write(config%batteries(i)%name, '(A,I0)') 'battery_', i
            end if

            ! cell configuration
            call jsonx_get(j_batt, 'cells_series', config%batteries(i)%nS, 1)
            call jsonx_get(j_batt, 'cells_parallel', config%batteries(i)%nP, 1)

            ! ---- electrical properties: PACK-level OR PER-CELL ----
            ! (a) PACK-level (as printed on the battery label): pack_voltage [V],
            !     pack_capacity [mAh], pack_resistance [ohm]. Divided down to
            !     per-cell by nS/nP. OCV is constant (no discharge curve).
            ! (b) PER-CELL "cell" block: cell_voltage [V], cell_capacity [mAh],
            !     cell_resistance [ohm], plus optional Maoquan/Haixin discharge
            !     constants EA/EB/EC (Eq 4.6.2), which are inherently per-cell.
            nS_r = real(config%batteries(i)%nS)
            nP_r = real(config%batteries(i)%nP)
            call json_value_get(j_batt, 'cell', j_cell)
            call json_clear_exceptions()
            call jsonx_get(j_batt, 'pack_voltage', pack_V, 0.0)

            if (pack_V > 0.0) then
                ! (a) pack-level -> per-cell (capacity [mAh] -> A*s via x3.6)
                call jsonx_get(j_batt, 'pack_capacity', pack_cap_mAh, 0.0)
                call jsonx_get(j_batt, 'pack_resistance', pack_R, 0.0)
                if (pack_cap_mAh <= 0.0) then
                    write(*,*) 'ERROR: battery "', trim(config%batteries(i)%name), &
                               '" has pack_voltage but missing/zero pack_capacity.'
                    stop
                end if
                config%batteries(i)%V_full = pack_V / nS_r
                config%batteries(i)%cell_Q = (pack_cap_mAh / nP_r) * 3.6
                config%batteries(i)%cell_R = pack_R * nP_r / nS_r
            else if (associated(j_cell)) then
                ! (b) per-cell block (capacity [mAh] -> A*s via x3.6)
                call jsonx_get(j_cell, 'cell_capacity', cap_mAh)
                config%batteries(i)%cell_Q = cap_mAh * 3.6
                call jsonx_get(j_cell, 'cell_resistance', config%batteries(i)%cell_R, 0.0)
                call jsonx_get(j_cell, 'cell_voltage', config%batteries(i)%V_full)
                call jsonx_get(j_cell, 'EA', config%batteries(i)%EA, 0.0)
                call jsonx_get(j_cell, 'EB', config%batteries(i)%EB, 0.0)
                ! EC is input as 1/(A*hr) but stored as 1/(A*s)
                call jsonx_get(j_cell, 'EC', EC_per_Ah, 0.0)
                config%batteries(i)%EC = EC_per_Ah / SEC_PER_HR
            else
                write(*,*) 'ERROR: battery "', trim(config%batteries(i)%name), &
                           '" needs pack-level fields (pack_voltage, pack_capacity, ', &
                           'pack_resistance) or a per-cell "cell" block.'
                stop
            end if

            ! C-rating: JSON in 1/hr, stored as 1/s (Eq 4.6.4)
            call jsonx_get(j_batt, 'C_rating', C_rating_per_hr, 0.0)
            config%batteries(i)%C_rating = C_rating_per_hr / SEC_PER_HR

            ! auxiliary power draw
            P_aux = 0.0
            V_aux = 5.0
            call jsonx_get(j_batt, 'power_aux', P_aux, 0.0)
            call jsonx_get(j_batt, 'voltage_aux', V_aux, 5.0)
            if (V_aux > 0.0) then
                config%batteries(i)%I_aux = P_aux / V_aux
            end if

            ! compute pack-level properties
            call config%batteries(i)%init_pack()

            write(*,'(A,A,A,I0,A,I0,A,F8.1,A)') '  Battery: ', &
                trim(config%batteries(i)%name), ' (', &
                config%batteries(i)%nS, 'S', config%batteries(i)%nP, 'P, ', &
                config%batteries(i)%Q_total / 3.6, ' mAh)'
        end do
        call json_clear_exceptions()
    end subroutine load_batteries

    subroutine wire_battery_pointers(config)
        type(vehicle_config_t), intent(inout), target :: config
        integer :: j

        do j = 1, config%n_sources
            select type (src => config%sources(j)%src)
            type is (propeller_source_t)
                if (src%motor_type == MOTOR_ELECTRIC .and. src%battery_index > 0 &
                    .and. src%battery_index <= config%n_batteries) then
                    src%battery_ptr => config%batteries(src%battery_index)
                end if
            end select
        end do
    end subroutine wire_battery_pointers

end module vehicle_io_m
