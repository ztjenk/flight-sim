! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! unified simulation module - handles 1 to N vehicles with flexible telemetry
module simulation_m
    use constants_m
    use math_m
    use vehicle_types_m
    use vehicle_io_m
    use json_m, only: json_value
    use dynamics_m
    use atmosphere_m
    use connection_m, only: channel_t, udp_channel_t, file_channel_t, &
                             connection_t, net_initialize, net_finalize, &
                             create_channel, send_with_entity_id, recv_with_entity_id
    use force_source_m
    use sensor_m, only: sensor_update, sensor_header, &
                        SENSOR_IMU, SENSOR_GPS, SENSOR_ADS, SENSOR_MAGNETOMETER, &
                        SENSOR_AERO_ANGLES
    use ekf_m, only: ekf_t, ekf_init, ekf_predict, ekf_get_body_state, &
                     ekf_fuse_gps, ekf_fuse_mag_heading, ekf_fuse_airspeed, ekf_fuse_gravity, &
                     ekf_fuse_aero_angles
    use packet_builder_m
    use turbulence_m
    use random_m
    use wmm_m, only: wmm_field
    use equations_m
    use units_m, only: conversion_factor_to
    implicit none
    private

    ! public types
    public :: simulator_t

    ! named connection entry
    type :: connection_entry_t
        character(len=64) :: name = ''           ! from json key (user-defined)
        character(len=64) :: vehicle_name = ''   ! must match a run_physics=true vehicle
        integer :: vehicle_index = 0             ! index into simulator arrays
        type(connection_t) :: conn               ! the actual connection
        logical :: is_sender = .true.            ! send or receive
        integer :: data_type = DATA_BOTH         ! controls, state, both, or sensors
        integer :: n_values = 22                 ! computed from data_type
        logical :: entity_tagged = .false.       ! prepend 4-byte entity_id to UDP packets
        ! sensor connection fields (used when data_type = DATA_SENSORS)
        integer :: n_sensor_names = 0
        character(len=64) :: sensor_names(MAX_SENSOR_NAMES) = ''
    end type connection_entry_t

    ! telemetry manager
    type :: telemetry_manager_t
        type(connection_entry_t), allocatable :: connections(:)
        integer :: n_connections = 0
        integer :: max_recv_values = 0
    contains
        procedure :: load_from_json => telemetry_load_connections
        procedure :: send_all => telemetry_send_all
        procedure :: recv_all => telemetry_recv_all
        procedure :: sync_time => telemetry_sync_time
        procedure :: shutdown => telemetry_manager_shutdown
    end type telemetry_manager_t

    ! simulator type (works for 1 or N vehicles)
    type :: simulator_t
        integer :: n_vehicles = 0
        type(vehicle_config_t), allocatable :: configs(:)
        type(control_inputs_t), allocatable :: controls(:)           ! actual controls (used by dynamics)
        type(control_inputs_t), allocatable :: controls_commanded(:) ! last commanded
        type(passive_inputs_t), allocatable :: passives(:)           ! passive effectors
        type(vehicle_state_t), allocatable :: states(:)
        type(dynamics_engine_t), allocatable :: dynamics(:)
        type(actuator_map_t), allocatable :: act_maps(:)
        type(telemetry_manager_t) :: telemetry

        real :: dt = 0.01
        real :: t_final = 10.0
        real :: t_current = 0.0
        real :: hold_time = 0.0   ! rigid-body states frozen until this sim time [s]; actuators/PEs still integrate

        logical :: realtime_mode = .false.
        real :: time_scale = 1.0
        real :: dt_output = 0.01

        logical :: save_states = .true.
        logical :: rk4_verbose = .false.
        integer, allocatable :: csv_units(:)
        integer, allocatable :: rk4_units(:)
        integer, allocatable :: sensor_csv_units(:)  ! per-vehicle sensor output CSV
        integer, allocatable :: ekf_csv_units(:)     ! per-vehicle EKF output CSV

        ! turbulence (Ch 9)
        type(turbulence_config_t) :: turb_config
        type(dryden_beal_state), allocatable :: turb_states(:)  ! one per vehicle
        real, allocatable :: turb_gusts(:,:)    ! (6, n_vehicles) current gust values
        integer :: geographic_model_ID = 0   ! 0=flat, 1=sphere, 2=ellipse
        logical :: use_wmm = .false.         ! compute the magnetometer field from the WMM (Ch 10)
        real :: date = 2025.0                ! decimal year for the WMM secular variation
        real :: print_states_rate = 0.0      ! rate to print states to terminal [Hz], 0 = disabled
        real :: print_states_interval = 0.0  ! time interval between prints [s]
        real :: next_print_time = 0.0        ! next time to print states [s]
        ! pre-allocated work arrays for sim_step (sized to max state_dim across vehicles)
        real, allocatable :: y_work(:), y_new_work(:)

        ! equations system (dynamic values: sines, polynomials)
        type(equation_set_t), allocatable :: eqsets(:)
        type(var_table_t) :: var_table
    contains
        procedure :: print_states => sim_print_states
        procedure :: initialize => sim_init
        procedure :: run => sim_run
        procedure :: step => sim_step
        procedure :: write_headers => sim_write_headers
        procedure :: write_states => sim_write_states
        procedure :: update_sensors => sim_update_sensors
        procedure :: write_sensor_states => sim_write_sensor_states
        procedure :: update_ekf => sim_update_ekf
        procedure :: write_ekf_states => sim_write_ekf_states
        procedure :: shutdown => sim_shutdown
    end type simulator_t

contains


    ! initialize telemetry connections from pre-parsed configs
    subroutine telemetry_load_connections(self, conn_configs, n_connections)
        class(telemetry_manager_t), intent(inout) :: self
        type(telemetry_conn_config_t), intent(in) :: conn_configs(:)
        integer, intent(in) :: n_connections

        integer :: i

        if (n_connections == 0) return

        allocate(self%connections(n_connections))
        self%n_connections = n_connections

        do i = 1, n_connections
            self%connections(i)%name = conn_configs(i)%name
            self%connections(i)%vehicle_name = conn_configs(i)%vehicle_name
            self%connections(i)%vehicle_index = conn_configs(i)%vehicle_index
            self%connections(i)%is_sender = conn_configs(i)%is_sender
            self%connections(i)%data_type = conn_configs(i)%data_type
            self%connections(i)%n_values = conn_configs(i)%n_values
            self%connections(i)%entity_tagged = conn_configs(i)%entity_tagged
            self%connections(i)%n_sensor_names = conn_configs(i)%n_sensor_names
            self%connections(i)%sensor_names = conn_configs(i)%sensor_names

            ! initialize the connection using the json node
            call self%connections(i)%conn%init(conn_configs(i)%json_node, conn_configs(i)%n_values)

            write(*,'(A,A,A,A,A,I0,A)') '  Telemetry: ', trim(conn_configs(i)%name), &
                ' -> ', trim(conn_configs(i)%vehicle_name), &
                ' (', conn_configs(i)%n_values, ' values)'

            if (.not. conn_configs(i)%is_sender) then
                self%max_recv_values = max(self%max_recv_values, conn_configs(i)%n_values)
            end if
        end do
    end subroutine telemetry_load_connections

    ! sync simulation time to all connections for rate limiting
    subroutine telemetry_sync_time(self, t)
        class(telemetry_manager_t), intent(inout) :: self
        real, intent(in) :: t
        integer :: i

        do i = 1, self%n_connections
            call self%connections(i)%conn%set_time(t)
        end do
    end subroutine telemetry_sync_time

    ! send state to all enabled send connections
    subroutine telemetry_send_all(self, t, states, controls_cmd, controls_act, passives, configs)
        class(telemetry_manager_t), intent(inout) :: self
        real, intent(in) :: t
        type(vehicle_state_t), intent(in) :: states(:)
        type(control_inputs_t), intent(in) :: controls_cmd(:)
        type(control_inputs_t), intent(in) :: controls_act(:)
        type(passive_inputs_t), intent(in) :: passives(:)
        type(vehicle_config_t), intent(in) :: configs(:)

        integer :: i, v, max_n, n
        real, allocatable :: packet(:)

        ! find max packet size across all sender connections and pre-allocate once
        max_n = 0
        do i = 1, self%n_connections
            if (self%connections(i)%is_sender .and. self%connections(i)%data_type /= DATA_SENSORS) &
                max_n = max(max_n, self%connections(i)%n_values)
        end do
        if (max_n == 0) return
        allocate(packet(max_n))

        do i = 1, self%n_connections
            if (.not. self%connections(i)%is_sender) cycle

            v = self%connections(i)%vehicle_index
            n = self%connections(i)%n_values

            if (self%connections(i)%data_type == DATA_SENSORS) cycle
            call build_packet(self%connections(i)%data_type, t, states(v), configs(v), &
                              controls_cmd(v), controls_act(v), passives(v), packet(1:n))

            if (self%connections(i)%entity_tagged) then
                call send_with_entity_id(self%connections(i)%conn, v, packet(1:n))
            else
                call self%connections(i)%conn%send(packet(1:n))
            end if
        end do

        deallocate(packet)
    end subroutine telemetry_send_all

    ! receive control commands from all enabled receive connections
    subroutine telemetry_recv_all(self, controls_cmd)
        class(telemetry_manager_t), intent(inout) :: self
        type(control_inputs_t), intent(inout) :: controls_cmd(:)

        integer :: i, v, n, entity_id
        logical :: got_data
        real :: values(self%max_recv_values)

        do i = 1, self%n_connections
            if (self%connections(i)%is_sender) cycle

            v = self%connections(i)%vehicle_index
            n = self%connections(i)%conn%channel%n_values

            if (self%connections(i)%entity_tagged) then
                call recv_with_entity_id(self%connections(i)%conn, entity_id, values(:n), got_data)
                if (got_data .and. self%connections(i)%data_type == DATA_CONTROLS) then
                    if (entity_id >= 1 .and. entity_id <= size(controls_cmd)) then
                        call parse_controls_packet(values(:n), controls_cmd(entity_id))
                    end if
                end if
            else
                call self%connections(i)%conn%recv(values(:n))
                if (self%connections(i)%data_type == DATA_CONTROLS) then
                    call parse_controls_packet(values(:n), controls_cmd(v))
                end if
            end if
        end do
    end subroutine telemetry_recv_all

    ! shutdown all telemetry connections
    subroutine telemetry_manager_shutdown(self)
        class(telemetry_manager_t), intent(inout) :: self
        integer :: i

        if (allocated(self%connections)) then
            do i = 1, self%n_connections
                call self%connections(i)%conn%cleanup()
            end do
            deallocate(self%connections)
        end if
        self%n_connections = 0
    end subroutine telemetry_manager_shutdown


    ! initialize simulator
    subroutine sim_init(self, n_vehicles, configs, controls, passives, states, dt, t_final, &
                        save_states, rk4_verbose, json_root, geographic_model_ID, &
                        print_states_rate, wind, realtime, time_scale, turb_config, save_states_rate, &
                        T_sl_R, P_sl_psf, eqsets, use_wmm, date, hold_time)
        class(simulator_t), intent(inout) :: self
        integer, intent(in) :: n_vehicles
        type(vehicle_config_t), intent(in) :: configs(:)
        type(control_inputs_t), intent(in) :: controls(:)
        type(passive_inputs_t), intent(in) :: passives(:)
        type(vehicle_state_t), intent(in) :: states(:)
        real, intent(in) :: dt
        real, intent(in) :: t_final
        logical, intent(in) :: save_states
        logical, intent(in) :: rk4_verbose
        type(json_value), pointer, intent(in) :: json_root
        integer, intent(in), optional :: geographic_model_ID
        real, intent(in), optional :: print_states_rate
        real, intent(in), optional :: wind(3)
        logical, intent(in), optional :: realtime
        real, intent(in), optional :: time_scale
        type(turbulence_config_t), intent(in), optional :: turb_config
        real, intent(in), optional :: save_states_rate
        real, intent(in), optional :: T_sl_R, P_sl_psf
        type(equation_set_t), intent(in), optional :: eqsets(:)
        logical, intent(in), optional :: use_wmm
        real, intent(in), optional :: date
        real, intent(in), optional :: hold_time

        integer :: i, j, n_conn, n_max
        real :: dx_ff_init, sigma_init, V_init
        character(len=256) :: filename
        type(telemetry_conn_config_t), allocatable :: conn_configs(:)

        self%n_vehicles = n_vehicles
        self%dt = dt
        self%t_final = t_final
        self%t_current = 0.0
        self%save_states = save_states
        self%rk4_verbose = rk4_verbose
        if (present(realtime)) then
            self%realtime_mode = realtime
        else
            self%realtime_mode = .false.
        end if
        if (present(time_scale)) then
            self%time_scale = time_scale
        else
            self%time_scale = 1.0
        end if

        ! geographic model settings
        if (present(geographic_model_ID)) self%geographic_model_ID = geographic_model_ID

        ! World Magnetic Model settings
        if (present(use_wmm)) self%use_wmm = use_wmm
        if (present(date)) self%date = date

        ! ground-hold / frozen-state phase
        if (present(hold_time)) self%hold_time = hold_time

        ! print states settings
        if (present(print_states_rate)) then
            self%print_states_rate = print_states_rate
            if (print_states_rate > 0.0) then
                self%print_states_interval = 1.0 / print_states_rate
            else
                self%print_states_interval = 0.0
            end if
        end if
        self%next_print_time = 0.0

        ! CSV output rate (save_states_rate > 0 limits output frequency)
        if (present(save_states_rate)) then
            if (save_states_rate > 0.0) then
                self%dt_output = 1.0 / save_states_rate
            else
                self%dt_output = dt  ! every timestep (default)
            end if
        else
            self%dt_output = dt
        end if

        ! allocate arrays
        allocate(self%configs(n_vehicles))
        allocate(self%controls(n_vehicles))
        allocate(self%controls_commanded(n_vehicles))
        allocate(self%passives(n_vehicles))
        allocate(self%states(n_vehicles))
        allocate(self%dynamics(n_vehicles))
        allocate(self%act_maps(n_vehicles))

        if (save_states) allocate(self%csv_units(n_vehicles))
        if (rk4_verbose) allocate(self%rk4_units(n_vehicles))

        ! copy data
        self%configs = configs
        self%controls = controls
        self%passives = passives
        self%states = states

        ! re-bind battery pointers: the deep copy above leaves
        ! `src%battery_ptr` pointing to the caller's configs, so motor state
        ! updates and battery state updates end up on different objects.
        do i = 1, n_vehicles
            call wire_battery_pointers(self%configs(i))
        end do

        ! initialize commanded = actual so all actuator rates and accelerations
        ! start at zero (applies to all dynamics orders: 0th, 1st, 2nd)
        self%controls_commanded = controls

        ! build actuator maps and initialize dynamics engines
        do i = 1, n_vehicles
            call build_actuator_map(self%controls(i), self%passives(i), self%act_maps(i))

            if (self%act_maps(i)%n_actuators > 0) then
                write(*,'(A,A,A,I0,A)') '  Actuator dynamics: ', trim(self%configs(i)%name), &
                    ' (', self%act_maps(i)%n_actuators, ' dynamic effectors)'
            end if
            if (self%act_maps(i)%n_passive > 0) then
                write(*,'(A,A,A,I0,A)') '  Passive effectors: ', trim(self%configs(i)%name), &
                    ' (', self%act_maps(i)%n_passive, ' passive effectors)'
            end if

            call self%dynamics(i)%initialize(self%configs(i), self%controls(i), &
                                             self%controls_commanded(i), self%passives(i), &
                                             self%act_maps(i), wind, T_sl_R, P_sl_psf)

            if (self%save_states) then
                filename = trim(self%configs(i)%name) // '_datalog.csv'
                open(newunit=self%csv_units(i), file=trim(filename), &
                     status='replace', action='write', form='formatted')
                write(*,*) '  Output file: ', trim(filename)
            end if

            if (self%rk4_verbose) then
                filename = trim(self%configs(i)%name) // '_rk4.txt'
                open(newunit=self%rk4_units(i), file=trim(filename), &
                     status='replace', action='write', form='formatted')
                write(*,*) '  RK4 verbose file: ', trim(filename)
            end if
        end do

        ! open sensor CSV files
        allocate(self%sensor_csv_units(n_vehicles))
        self%sensor_csv_units = 0
        do i = 1, n_vehicles
            if (self%configs(i)%save_sensor_outputs .and. self%configs(i)%n_sensors > 0) then
                filename = trim(self%configs(i)%name) // '_sensors.csv'
                open(newunit=self%sensor_csv_units(i), file=trim(filename), &
                     status='replace', action='write', form='formatted')
                call write_sensor_headers(self%sensor_csv_units(i), self%configs(i))
                write(*,*) '  Sensor output: ', trim(filename)
            end if
        end do

        ! initialize EKF and open EKF CSV files
        allocate(self%ekf_csv_units(n_vehicles))
        self%ekf_csv_units = 0
        do i = 1, n_vehicles
            if (self%configs(i)%use_ekf) then
                block
                    real :: mag_init(3)
                    logical :: mag_found
                    mag_init = [20225.1, 3919.4, 46952.8]  ! default
                    if (self%use_wmm) then
                        ! seed the EKF declination from the WMM field at the initial position/date
                        block
                            real :: decl, incl, tot
                            call wmm_field(self%states(i)%latitude * RAD2DEG, &
                                           self%states(i)%longitude * RAD2DEG, &
                                           (-self%states(i)%position(3)) * FT_TO_M / 1000.0, &
                                           self%date, mag_init(1), mag_init(2), mag_init(3), &
                                           decl, incl, tot)
                        end block
                        mag_found = .true.
                    else
                        call find_mag_field(self%configs(i), mag_init, mag_found)
                    end if
                    call ekf_init(self%configs(i)%ekf, &
                        self%states(i)%quaternion, self%states(i)%velocity, &
                        self%states(i)%position, gravity_english(-self%states(i)%position(3)), mag_init)
                end block
                if (self%configs(i)%save_ekf_output) then
                    filename = trim(self%configs(i)%name) // '_ekf.csv'
                    open(newunit=self%ekf_csv_units(i), file=trim(filename), &
                         status='replace', action='write', form='formatted')
                    write(self%ekf_csv_units(i), '(A)') &
                        't[s],u[ft/s],v[ft/s],w[ft/s],p[rad/s],q[rad/s],r[rad/s],' // &
                        'x[ft],y[ft],z[ft],e0,ex,ey,ez,' // &
                        'gbias_x[rad/s],gbias_y[rad/s],gbias_z[rad/s],' // &
                        'abias_x[ft/s^2],abias_y[ft/s^2],abias_z[ft/s^2],' // &
                        'vel_N[ft/s],vel_E[ft/s],vel_D[ft/s],' // &
                        'pos_N[ft],pos_E[ft],pos_D[ft],' // &
                        'pdot_est[rad/s^2],qdot_est[rad/s^2],rdot_est[rad/s^2]'
                    write(*,*) '  EKF output: ', trim(filename)
                end if
            end if
        end do

        ! pre-allocate work arrays to max state_dim across all vehicles
        n_max = maxval(self%act_maps(1:n_vehicles)%state_dim)
        allocate(self%y_work(n_max), self%y_new_work(n_max))

        ! initialize turbulence (Ch 9)
        if (present(turb_config)) self%turb_config = turb_config
        allocate(self%turb_gusts(6, n_vehicles))
        self%turb_gusts = 0.0
        if (self%turb_config%enabled) then
            allocate(self%turb_states(n_vehicles))
            if (self%turb_config%seed < 0) then
                ! clock-based random seed for Monte Carlo
                call random_seed()
            else
                call seed_random(self%turb_config%seed)
            end if
            do i = 1, n_vehicles
                ! initial dx_ff estimate from Vmin (Eq. 9.2.1)
                V_init = max(self%turb_config%Vmin, norm3(states(i)%velocity))
                dx_ff_init = V_init * dt
                ! initial sigma
                if (self%turb_config%sigma_is_fixed) then
                    sigma_init = self%turb_config%sigma_fixed
                else
                    sigma_init = sigma_from_intensity(self%turb_config%intensity, -states(i)%position(3))
                end if
                ! Eqs. 9.3.4-9.3.5: high-altitude length scales
                call dryden_beal_init(self%turb_states(i), &
                    1750.0, 875.0, 875.0, &
                    sigma_init, sigma_init, sigma_init, dx_ff_init, &
                    self%turb_config%wingspan, &
                    self%turb_config%Lh_sep, &
                    self%turb_config%Lv_sep, &
                    self%turb_config%buf_size)
            end do
        end if

        ! equations system: store, wire pointers, and resolve independent variable indices
        allocate(self%eqsets(n_vehicles))
        if (present(eqsets)) then
            do i = 1, n_vehicles
                self%eqsets(i) = eqsets(i)
                if (self%eqsets(i)%n > 0) then
                    call wire_equation_targets(self%eqsets(i), self%configs(i), self%dynamics(i)%wind)

                    ! build var_table with all available variable names for index resolution
                    call self%var_table%set('time', 0.0)
                    call self%var_table%set('altitude', -self%states(i)%position(3))
                    call self%var_table%set('u', self%states(i)%velocity(1))
                    call self%var_table%set('v', self%states(i)%velocity(2))
                    call self%var_table%set('w', self%states(i)%velocity(3))
                    call self%var_table%set('p', self%states(i)%omega(1))
                    call self%var_table%set('q', self%states(i)%omega(2))
                    call self%var_table%set('r', self%states(i)%omega(3))
                    do j = 1, self%controls(i)%n
                        call self%var_table%set(self%controls(i)%effectors(j)%name, &
                            self%controls(i)%effectors(j)%value)
                    end do
                    do j = 1, self%passives(i)%n
                        call self%var_table%set(self%passives(i)%effectors(j)%name, &
                            self%passives(i)%effectors(j)%value)
                    end do

                    call self%eqsets(i)%resolve_indices(self%var_table)
                end if
            end do
        end if

        if (self%save_states) call self%write_headers()

        ! load telemetry connections from pre-parsed json root
        call load_telemetry_configs(json_root, self%configs, self%controls, self%passives, self%n_vehicles, conn_configs, n_conn)
        call self%telemetry%load_from_json(conn_configs, n_conn)

    end subroutine sim_init

    ! main simulation loop
    subroutine sim_run(self)
        class(simulator_t), intent(inout) :: self

        real :: dt_actual, next_output, t_wall_start, t_wall_target
        integer :: i, j

        ! fixed dt for both modes — identical integration
        dt_actual = self%dt
        next_output = self%dt_output

        ! record wall-clock origin for real-time pacing
        if (self%realtime_mode) t_wall_start = get_wall_time()

        ! write initial state
        if (self%save_states) call self%write_states()

        ! send initial state to telemetry
        call self%telemetry%sync_time(self%t_current)
        call self%telemetry%send_all(self%t_current, self%states, &
                                     self%controls_commanded, self%controls, self%passives, self%configs)

        ! main simulation loop
        do while (self%t_current < self%t_final)
            ! sync sim time for receive rate limiting
            call self%telemetry%sync_time(self%t_current)

            ! receive control updates (non-blocking)
            call self%telemetry%recv_all(self%controls_commanded)

            ! for dynamics_order=0 effectors: copy commanded to actual instantly
            ! for dynamics_order>=1: the RK4 integrator handles the transition
            do i = 1, self%n_vehicles
                do j = 1, self%controls(i)%n
                    if (self%controls(i)%effectors(j)%dynamics_order == 0) then
                        self%controls(i)%effectors(j)%value = &
                            self%controls_commanded(i)%effectors(j)%value
                    end if
                end do
            end do

            ! advance dynamics (same fixed dt in both modes)
            call self%step(dt_actual)

            ! update sensors for each vehicle
            call self%update_sensors()

            ! run EKF predict + fuse for each vehicle
            call self%update_ekf(dt_actual)

            ! sync sim time for send rate limiting (t_current advanced by step)
            call self%telemetry%sync_time(self%t_current)

            ! send telemetry
            call self%telemetry%send_all(self%t_current, self%states, &
                                         self%controls_commanded, self%controls, self%passives, self%configs)

            ! handle output timing
            if (self%t_current + TOLERANCE >= next_output) then
                if (self%save_states) call self%write_states()
                call self%write_sensor_states()
                call self%write_ekf_states()
                next_output = next_output + self%dt_output
            end if

            ! real-time pacing: busy-wait until wall clock catches up to sim time
            if (self%realtime_mode) then
                t_wall_target = t_wall_start + self%t_current / self%time_scale
                do while (get_wall_time() < t_wall_target)
                    ! spin — precise, cross-platform, no sleep granularity issues
                end do
            end if

            ! print states to terminal at configured rate
            if (self%print_states_rate > 0.0) then
                if (self%t_current + TOLERANCE >= self%next_print_time) then
                    call self%print_states()
                    self%next_print_time = self%next_print_time + self%print_states_interval
                end if
            end if
        end do

    end subroutine sim_run

    ! step all vehicles by dt
    subroutine sim_step(self, dt)
        class(simulator_t), intent(inout) :: self
        real, intent(in) :: dt

        integer :: i, j, n
        real :: V_air, dx_ff, sigma_now
        logical :: holding

        ! hold phase: any step that starts before hold_time keeps the rigid-body states frozen
        ! while actuator and passive-effector states integrate normally (see dynamics_step_rk4)
        holding = self%t_current + TOLERANCE < self%hold_time

        ! evaluate equations (dynamic values: sines, polynomials)
        do i = 1, self%n_vehicles
            if (self%eqsets(i)%n > 0) then
                ! populate var_table with current state
                call self%var_table%set('time', self%t_current)
                call self%var_table%set('altitude', -self%states(i)%position(3))
                call self%var_table%set('u', self%states(i)%velocity(1))
                call self%var_table%set('v', self%states(i)%velocity(2))
                call self%var_table%set('w', self%states(i)%velocity(3))
                call self%var_table%set('p', self%states(i)%omega(1))
                call self%var_table%set('q', self%states(i)%omega(2))
                call self%var_table%set('r', self%states(i)%omega(3))
                do j = 1, self%controls(i)%n
                    call self%var_table%set(self%controls(i)%effectors(j)%name, &
                        self%controls(i)%effectors(j)%value)
                end do
                do j = 1, self%passives(i)%n
                    call self%var_table%set(self%passives(i)%effectors(j)%name, &
                        self%passives(i)%effectors(j)%value)
                end do

                call self%eqsets(i)%evaluate_all(self%var_table)

                ! recompute derived geometry if any source equations changed
                if (self%eqsets(i)%has_geometry_eqs) then
                    call recompute_source_geometry(self%configs(i)%sources, &
                                                   self%configs(i)%n_sources)
                    ! reassemble mass properties from base + updated components
                    block
                        type(mass_properties_t) :: assembled
                        call assemble_mass_properties(self%configs(i)%base_mass, &
                            self%configs(i)%sources, self%configs(i)%n_sources, assembled)
                        self%configs(i)%mass = assembled
                        call self%configs(i)%mass%compute_inverse()
                    end block
                end if

                ! recompute derived mass properties if any mass equations changed
                if (self%eqsets(i)%has_mass_eqs) then
                    ! symmetric inertia: copy off-diagonals
                    self%configs(i)%mass%I(2,1) = self%configs(i)%mass%I(1,2)
                    self%configs(i)%mass%I(3,1) = self%configs(i)%mass%I(1,3)
                    self%configs(i)%mass%I(3,2) = self%configs(i)%mass%I(2,3)
                    call self%configs(i)%mass%compute_mass()
                    call self%configs(i)%mass%compute_inverse()
                end if
            end if
        end do

        ! update turbulence gusts once per full timestep, before RK4 (Section 9.8)
        ! gust values are held constant across all rk4 calls per timestep
        if (self%turb_config%enabled) then
            do i = 1, self%n_vehicles
                ! Eq. 9.2.1: dx_ff = V * dt
                V_air = norm3(self%states(i)%velocity)
                V_air = max(V_air, self%turb_config%Vmin)
                dx_ff = V_air * dt

                ! update sigma for altitude-dependent intensity mode
                if (self%turb_config%sigma_is_fixed) then
                    call dryden_beal_update_dx(self%turb_states(i), dx_ff)
                else
                    sigma_now = sigma_from_intensity(self%turb_config%intensity, &
                                                     -self%states(i)%position(3))
                    call dryden_beal_update_params(self%turb_states(i), dx_ff, sigma_now)
                end if

                call dryden_beal_step(self%turb_states(i), &
                    self%turb_gusts(1,i), self%turb_gusts(2,i), self%turb_gusts(3,i), &
                    self%turb_gusts(4,i), self%turb_gusts(5,i), self%turb_gusts(6,i))
            end do
        end if

        do i = 1, self%n_vehicles
            n = self%act_maps(i)%state_dim

            ! set gust values on dynamics engine
            self%dynamics(i)%gust = self%turb_gusts(:,i)

            ! alpha-hat / beta-hat (dimensionless alpha-dot / beta-dot, Eqs 3.4.20 / 3.4.21):
            ! backward difference of alpha and beta from the previous accepted state, computed once
            ! per timestep and held across the RK4 sub-steps (like the gusts above). Zero on the first
            ! step and during trim, so steady states are unaffected; ref_c/ref_b = 0 -> hat = 0, harmless.
            block
                real :: alpha_now, beta_now, V_now
                alpha_now = calc_alpha(self%states(i)%velocity)
                beta_now  = calc_beta(self%states(i)%velocity)
                if (self%dynamics(i)%alpha_init) then
                    V_now = max(norm3(self%states(i)%velocity), 1.0)
                    self%dynamics(i)%alpha_hat = ((alpha_now - self%dynamics(i)%alpha_prev) / dt) &
                                                 * self%configs(i)%ref_c / (2.0 * V_now)
                    self%dynamics(i)%beta_hat  = ((beta_now - self%dynamics(i)%beta_prev) / dt) &
                                                 * self%configs(i)%ref_b / (2.0 * V_now)
                end if
                self%dynamics(i)%alpha_prev = alpha_now
                self%dynamics(i)%beta_prev  = beta_now
                self%dynamics(i)%alpha_init = .true.
            end block

            ! pack: rigid body states
            self%y_work(1:RIGID_DIM) = self%states(i)%to_array()

            ! pack: actuator states from effector values
            call pack_actuator_states(self%controls(i), self%act_maps(i), self%y_work)
            call pack_passive_states(self%passives(i), self%y_work)

            if (self%rk4_verbose) then
                self%y_new_work(1:n) = self%dynamics(i)%step_rk4(self%t_current, self%y_work(1:n), dt, &
                                                                 self%rk4_units(i), hold_rigid=holding)
            else
                self%y_new_work(1:n) = self%dynamics(i)%step_rk4(self%t_current, self%y_work(1:n), dt, &
                                                                 hold_rigid=holding)
            end if

            ! update geographic coordinates if not using flat earth
            if (self%geographic_model_ID > 0) then
                self%states(i)%quaternion = self%y_new_work(10:13)
                call update_geographic(self%states(i), self%y_work, self%y_new_work, self%geographic_model_ID)
                ! copy corrected quaternion back to y_new so from_array doesn't overwrite it
                self%y_new_work(10:13) = self%states(i)%quaternion
            end if

            ! unpack: rigid body states
            call self%states(i)%from_array(self%y_new_work(1:RIGID_DIM))

            ! unpack: actuator states back to effector values
            call unpack_actuator_states(self%y_new_work, self%controls(i), self%act_maps(i))
            call unpack_passive_states(self%y_new_work, self%passives(i))

            ! while held, the vehicle is externally restrained: the restraint reaction cancels
            ! aero/thrust and gravity, so the net non-gravitational force the IMU feels is
            ! -m*g (earth frame), not the free-flight aero sum cached by the derivatives
            if (holding) then
                self%dynamics(i)%F_total_cache = quat_rotate_inertial_to_body( &
                    [0.0, 0.0, -gravity_english(-self%states(i)%position(3)) * self%configs(i)%mass%mass], &
                    self%states(i)%quaternion)
                self%dynamics(i)%M_total_cache = 0.0
            end if

            if (norm2(self%states(i)%omega) / (2.0*PI) * dt > 0.1) write(*,*) 'Warning: High Vehicle Rotation relative to integration time step. [abs(omega)/(2*PI)*dt > 0.1]'

        end do

        ! update battery SOC for all vehicles (Euler integration of current draw)
        do i = 1, self%n_vehicles
            call update_vehicle_batteries(self%configs(i), dt)
        end do

        self%t_current = self%t_current + dt
    end subroutine sim_step

    ! update battery SOC for a single vehicle after RK4 step
    subroutine update_vehicle_batteries(config, dt)
        type(vehicle_config_t), intent(inout) :: config
        real, intent(in) :: dt

        real :: I_motors
        integer :: j, k

        if (config%n_batteries == 0) return

        do k = 1, config%n_batteries
            ! sum battery-side current draw (Ib, not Im) for this battery
            I_motors = 0.0
            do j = 1, config%n_sources
                select type (src => config%sources(j)%src)
                type is (propeller_source_t)
                    if (src%motor_type == MOTOR_ELECTRIC .and. src%battery_index == k) then
                        I_motors = I_motors + src%I_battery_current
                    end if
                end select
            end do
            call config%batteries(k)%update_SOC(dt, I_motors)
        end do
    end subroutine update_vehicle_batteries

    ! pack actuator states from effector values into extended state vector
    subroutine pack_actuator_states(ctrl, act_map, y)
        type(control_inputs_t), intent(in) :: ctrl
        type(actuator_map_t), intent(in) :: act_map
        real, intent(inout) :: y(:)
        integer :: k, eff_idx

        do k = 1, act_map%n_actuators
            eff_idx = act_map%effector_idx(k)
            y(ctrl%effectors(eff_idx)%state_index) = ctrl%effectors(eff_idx)%value
            if (ctrl%effectors(eff_idx)%dynamics_order == 2) &
                y(ctrl%effectors(eff_idx)%rate_state_index) = ctrl%effectors(eff_idx)%rate_value
        end do
    end subroutine pack_actuator_states

    ! unpack actuator states from extended state vector to effector values
    subroutine unpack_actuator_states(y, ctrl, act_map)
        real, intent(in) :: y(:)
        type(control_inputs_t), intent(inout) :: ctrl
        type(actuator_map_t), intent(in) :: act_map
        integer :: k, eff_idx

        do k = 1, act_map%n_actuators
            eff_idx = act_map%effector_idx(k)
            ctrl%effectors(eff_idx)%value = y(ctrl%effectors(eff_idx)%state_index)
            if (ctrl%effectors(eff_idx)%dynamics_order == 2) &
                ctrl%effectors(eff_idx)%rate_value = y(ctrl%effectors(eff_idx)%rate_state_index)
        end do
    end subroutine unpack_actuator_states

    ! pack passive effector states into extended state vector
    subroutine pack_passive_states(passive, y)
        type(passive_inputs_t), intent(in) :: passive
        real, intent(inout) :: y(:)
        integer :: k
        do k = 1, passive%n
            y(passive%effectors(k)%state_index) = passive%effectors(k)%value
            y(passive%effectors(k)%rate_state_index) = passive%effectors(k)%rate_value
        end do
    end subroutine pack_passive_states

    ! unpack passive effector states from extended state vector
    subroutine unpack_passive_states(y, passive)
        real, intent(in) :: y(:)
        type(passive_inputs_t), intent(inout) :: passive
        integer :: k
        do k = 1, passive%n
            passive%effectors(k)%value = y(passive%effectors(k)%state_index)
            passive%effectors(k)%rate_value = y(passive%effectors(k)%rate_state_index)
        end do
    end subroutine unpack_passive_states

    ! write CSV headers for each vehicle
    subroutine sim_write_headers(self)
        class(simulator_t), intent(in) :: self

        character(len=2048) :: header
        character(len=20) :: unit_suffix
        integer :: i, j

        do i = 1, self%n_vehicles
            header = 't[s],u[ft/s],v[ft/s],w[ft/s],p[rad/s],q[rad/s],r[rad/s],' // &
                     'x[ft],y[ft],z[ft],e0,ex,ey,ez'

            ! append control effector column headers (with units from magnitude_limits)
            do j = 1, self%controls(i)%n
                if (len_trim(self%controls(i)%effectors(j)%unit_str) > 0) then
                    unit_suffix = '[' // trim(self%controls(i)%effectors(j)%unit_str) // ']'
                else
                    unit_suffix = ''
                end if
                if (self%controls(i)%effectors(j)%dynamics_order >= 1) then
                    header = trim(header) // ',' // trim(self%controls(i)%effectors(j)%name) // &
                             '_cmd' // trim(unit_suffix)
                    header = trim(header) // ',' // trim(self%controls(i)%effectors(j)%name) // &
                             '_act' // trim(unit_suffix)
                else
                    header = trim(header) // ',' // trim(self%controls(i)%effectors(j)%name) // &
                             trim(unit_suffix)
                end if
            end do

            ! append passive effector column headers
            do j = 1, self%passives(i)%n
                header = trim(header) // ',' // trim(self%passives(i)%effectors(j)%name) // '_pos[rad]'
                header = trim(header) // ',' // trim(self%passives(i)%effectors(j)%name) // '_rate[rad/s]'
            end do

            ! append turbulence gust column headers
            if (self%turb_config%enabled) then
                header = trim(header) // ',u_gust[ft/s],v_gust[ft/s],w_gust[ft/s]'
                header = trim(header) // ',p_gust[rad/s],q_gust[rad/s],r_gust[rad/s]'
            end if

            write(self%csv_units(i), '(A)') trim(header)
        end do
    end subroutine sim_write_headers

    ! write current state to each vehicle's csv file
    subroutine sim_write_states(self)
        class(simulator_t), intent(in) :: self

        real :: y(RIGID_DIM), csv_cf
        integer :: i, j, pos, buf_len
        character(len=:), allocatable :: buf

        do i = 1, self%n_vehicles
            y = self%states(i)%to_array()
            ! compute buffer size: 20 for time + 21 per column
            buf_len = 20 + 21 * (RIGID_DIM + 2*self%controls(i)%n + 2*self%passives(i)%n + 6)
            if (allocated(buf)) then
                if (len(buf) < buf_len) then
                    deallocate(buf)
                    allocate(character(len=buf_len) :: buf)
                end if
            else
                allocate(character(len=buf_len) :: buf)
            end if
            ! build entire CSV line in buffer, then write once
            write(buf(1:20), '(ES20.12)') self%t_current
            pos = 20
            do j = 1, RIGID_DIM
                write(buf(pos+1:pos+21), '(",",ES20.12)') y(j)
                pos = pos + 21
            end do

            ! append control effector values (converted to display units if unit_str set)
            do j = 1, self%controls(i)%n
                if (len_trim(self%controls(i)%effectors(j)%unit_str) > 0) then
                    csv_cf = conversion_factor_to(trim(self%controls(i)%effectors(j)%unit_str))
                else
                    csv_cf = 1.0
                end if
                if (self%controls(i)%effectors(j)%dynamics_order >= 1) then
                    write(buf(pos+1:pos+21), '(",",ES20.12)') &
                        self%controls_commanded(i)%effectors(j)%value * csv_cf
                    pos = pos + 21
                    write(buf(pos+1:pos+21), '(",",ES20.12)') &
                        self%controls(i)%effectors(j)%value * csv_cf
                    pos = pos + 21
                else
                    write(buf(pos+1:pos+21), '(",",ES20.12)') &
                        self%controls(i)%effectors(j)%value * csv_cf
                    pos = pos + 21
                end if
            end do

            ! append passive effector values
            do j = 1, self%passives(i)%n
                write(buf(pos+1:pos+21), '(",",ES20.12)') &
                    self%passives(i)%effectors(j)%value
                pos = pos + 21
                write(buf(pos+1:pos+21), '(",",ES20.12)') &
                    self%passives(i)%effectors(j)%rate_value
                pos = pos + 21
            end do

            ! append turbulence gust values
            if (self%turb_config%enabled) then
                do j = 1, 6
                    write(buf(pos+1:pos+21), '(",",ES20.12)') self%turb_gusts(j,i)
                    pos = pos + 21
                end do
            end if

            write(self%csv_units(i), '(A)') buf(1:pos)
        end do
    end subroutine sim_write_states

    ! cleanup simulator resources
    subroutine sim_shutdown(self)
        class(simulator_t), intent(inout) :: self
        integer :: i

        ! close CSV files
        if (self%save_states .and. allocated(self%csv_units)) then
            do i = 1, self%n_vehicles
                close(self%csv_units(i))
            end do
            deallocate(self%csv_units)
        end if

        ! close RK4 verbose files
        if (self%rk4_verbose .and. allocated(self%rk4_units)) then
            do i = 1, self%n_vehicles
                close(self%rk4_units(i))
            end do
            deallocate(self%rk4_units)
        end if

        ! close sensor CSV files
        if (allocated(self%sensor_csv_units)) then
            do i = 1, self%n_vehicles
                if (self%sensor_csv_units(i) /= 0) close(self%sensor_csv_units(i))
            end do
            deallocate(self%sensor_csv_units)
        end if

        ! close EKF CSV files
        if (allocated(self%ekf_csv_units)) then
            do i = 1, self%n_vehicles
                if (self%ekf_csv_units(i) /= 0) close(self%ekf_csv_units(i))
            end do
            deallocate(self%ekf_csv_units)
        end if

        ! shutdown telemetry
        call self%telemetry%shutdown()

        ! deallocate arrays
        if (allocated(self%configs)) deallocate(self%configs)
        if (allocated(self%controls)) deallocate(self%controls)
        if (allocated(self%controls_commanded)) deallocate(self%controls_commanded)
        if (allocated(self%passives)) deallocate(self%passives)
        if (allocated(self%states)) deallocate(self%states)
        if (allocated(self%dynamics)) deallocate(self%dynamics)
        if (allocated(self%act_maps)) deallocate(self%act_maps)
        if (allocated(self%turb_states)) deallocate(self%turb_states)
        if (allocated(self%turb_gusts)) deallocate(self%turb_gusts)
    end subroutine sim_shutdown


    ! compute aerodynamic coefficients for display purposes
    ! finds first stability-derivative source and computes body+wind axis coefficients
    subroutine compute_display_coefficients(config, controls, passives, state, &
                                            Cx, Cy, Cz, Croll, Cpitch, Cyaw, &
                                            Clift, Cside, Cdrag, has_aero)
        type(vehicle_config_t), intent(in) :: config
        type(control_inputs_t), intent(in) :: controls
        type(passive_inputs_t), intent(in) :: passives
        type(vehicle_state_t), intent(in) :: state
        real, intent(out) :: Cx, Cy, Cz, Croll, Cpitch, Cyaw
        real, intent(out) :: Clift, Cside, Cdrag
        logical, intent(out) :: has_aero

        integer :: j, k, n_ctrl
        real :: alpha, beta
        real, allocatable :: ctrl_vals(:)

        has_aero = .false.
        Cx = 0.0; Cy = 0.0; Cz = 0.0
        Croll = 0.0; Cpitch = 0.0; Cyaw = 0.0
        Clift = 0.0; Cside = 0.0; Cdrag = 0.0

        do j = 1, config%n_sources
            ! use polymorphic get_coefficients — non-aero sources return zeros
            n_ctrl = controls%n + 2 * passives%n
            allocate(ctrl_vals(n_ctrl))
            do k = 1, controls%n
                ctrl_vals(k) = controls%effectors(k)%value
            end do
            do k = 1, passives%n
                ctrl_vals(controls%n + k) = passives%effectors(k)%value
            end do
            do k = 1, passives%n
                ctrl_vals(controls%n + passives%n + k) = &
                    passives%effectors(k)%rate_var_value
            end do
            call config%sources(j)%src%get_coefficients( &
                state%velocity, state%omega, &
                ctrl_vals(1:n_ctrl), n_ctrl, &
                Clift, Cside, Cdrag, Croll, Cpitch, Cyaw, &
                Cx, Cy, Cz)
            deallocate(ctrl_vals)

            ! check if this source returned nonzero coefficients (i.e. is an aero source)
            if (abs(Clift) + abs(Cside) + abs(Cdrag) + &
                abs(Croll) + abs(Cpitch) + abs(Cyaw) + &
                abs(Cx) + abs(Cy) + abs(Cz) > 0.0) then
                alpha = calc_alpha(state%velocity)
                beta = calc_beta(state%velocity)

                ! combine: add any wind-axis contributions into body-axis totals
                Cx = Cx + (-Cdrag*cos(alpha)*cos(beta) - Cside*cos(alpha)*sin(beta) + Clift*sin(alpha))
                Cy = Cy + (Cside*cos(beta) - Cdrag*sin(beta))
                Cz = Cz + (-Clift*cos(alpha) - Cdrag*sin(alpha)*cos(beta) - Cside*sin(alpha)*sin(beta))

                ! compute wind-axis from total body-axis (body -> wind rotation)
                Cdrag = -Cx*cos(alpha)*cos(beta) - Cy*sin(beta) - Cz*sin(alpha)*cos(beta)
                Cside = -Cx*cos(alpha)*sin(beta) + Cy*cos(beta) - Cz*sin(alpha)*sin(beta)
                Clift =  Cx*sin(alpha)                          - Cz*cos(alpha)

                has_aero = .true.
                return
            end if
        end do

    end subroutine compute_display_coefficients


    ! print current state for all vehicles to terminal
    subroutine sim_print_states(self)
        class(simulator_t), intent(in) :: self
        integer :: i, j
        real :: euler(3)
        real :: Cx, Cy, Cz, Croll, Cpitch, Cyaw
        real :: Clift, Cside, Cdrag
        logical :: has_aero
        character(len=15) :: ctrl_label
        real :: alt_print, Z_atm, T_atm, P_atm, rho_print, a_snd, mu_atm
        real :: F_body_v(3), M_body_v(3), h_rotor_v(3), h_body_v(3)

        write(*,*) ''
        write(*,'(A,ES12.4,A)') ' === Simulation State at t = ', self%t_current, ' s ==='

        do i = 1, self%n_vehicles
            euler = quat_to_euler(self%states(i)%quaternion)

            write(*,*) '  Vehicle: ', trim(self%configs(i)%name)
            write(*,'(A,ES24.12,A)') '  Alpha:       ', calc_alpha(self%states(i)%velocity) * RAD2DEG, ' deg'
            write(*,'(A,ES24.12,A)') '  Beta:        ', calc_beta(self%states(i)%velocity) * RAD2DEG, ' deg'
            write(*,'(A,ES24.12,A)') '  Phi:         ', euler(1) * RAD2DEG, ' deg'
            write(*,'(A,ES24.12,A)') '  Theta:       ', euler(2) * RAD2DEG, ' deg'
            write(*,'(A,ES24.12,A)') '  Psi:         ', euler(3) * RAD2DEG, ' deg'

            ! print rotation rates
            write(*,'(A,ES24.12,A)') '  p            ', self%states(i)%omega(1) * RAD2DEG, ' deg/s'
            write(*,'(A,ES24.12,A)') '  q            ', self%states(i)%omega(2) * RAD2DEG, ' deg/s'
            write(*,'(A,ES24.12,A)') '  r            ', self%states(i)%omega(3) * RAD2DEG, ' deg/s'

            ! print control effectors dynamically (with units from magnitude_limits)
            do j = 1, self%controls(i)%n
                ctrl_label = '  ' // trim(self%controls(i)%effectors(j)%name) // ':'
                if (len_trim(self%controls(i)%effectors(j)%unit_str) > 0) then
                    write(*,'(A,ES24.12,A,A)') ctrl_label, &
                        self%controls(i)%effectors(j)%value * &
                        conversion_factor_to(trim(self%controls(i)%effectors(j)%unit_str)), &
                        ' ', trim(self%controls(i)%effectors(j)%unit_str)
                else
                    write(*,'(A,ES24.12)') ctrl_label, &
                        self%controls(i)%effectors(j)%value
                end if
            end do

            ! print passive effector angles
            do j = 1, self%passives(i)%n
                ctrl_label = '  ' // trim(self%passives(i)%effectors(j)%name) // ':'
                write(*,'(A,ES24.12,A)') ctrl_label, &
                    self%passives(i)%effectors(j)%value * RAD2DEG, ' deg'
            end do

            write(*,'(A,ES24.12,A)') '  V_mag:       ', norm3(self%states(i)%velocity), ' ft/s'
            write(*,'(A,ES24.12,A)') '  Altitude:    ', -self%states(i)%position(3), ' ft'
            write(*,'(A,ES24.12,A)') '  Latitude:    ', self%states(i)%latitude * RAD2DEG, ' deg'
            write(*,'(A,ES24.12,A)') '  Longitude:   ', self%states(i)%longitude * RAD2DEG, ' deg'

            alt_print = -self%states(i)%position(3)
            ! honor non-standard-day sea-level overrides so the printed density
            ! matches the air the vehicle actually flies through (Fix4)
            if (self%dynamics(i)%T_sl_R > 0.0 .or. self%dynamics(i)%P_sl_psf > 0.0) then
                call std_atm_english(alt_print, Z_atm, T_atm, P_atm, rho_print, a_snd, mu_atm, &
                                     self%dynamics(i)%T_sl_R, self%dynamics(i)%P_sl_psf)
            else
                call std_atm_english(alt_print, Z_atm, T_atm, P_atm, rho_print, a_snd, mu_atm)
            end if
            write(*,'(A,ES24.12,A)') '  Rho:         ', rho_print, ' slug/ft^3'

            call compute_display_coefficients(self%configs(i), self%controls(i), &
                self%passives(i), self%states(i), &
                Cx, Cy, Cz, Croll, Cpitch, Cyaw, &
                Clift, Cside, Cdrag, has_aero)

            if (has_aero) then
                write(*,*) '  --- Aerodynamic Coefficients ---'
                write(*,'(A,ES24.12)')   '  Cx:          ', Cx
                write(*,'(A,ES24.12)')   '  Cy:          ', Cy
                write(*,'(A,ES24.12)')   '  Cz:          ', Cz
                write(*,'(A,ES24.12)')   '  Cl:          ', Croll
                write(*,'(A,ES24.12)')   '  Cm:          ', Cpitch
                write(*,'(A,ES24.12)')   '  Cn:          ', Cyaw

                write(*,*) '  --- Wind-Axis Coefficients ---'
                write(*,'(A,ES24.12)')   '  CL:          ', Clift
                write(*,'(A,ES24.12)')   '  CS:          ', Cside
                write(*,'(A,ES24.12)')   '  CD:          ', Cdrag
            end if

            ! propeller verbose output
            do j = 1, self%configs(i)%n_sources
                select type (src => self%configs(i)%sources(j)%src)
                type is (propeller_source_t)
                    if (src%verbose) then
                        write(*,'(A,A)') '   --- Propeller: ', trim(src%name)
                        write(*,'(A,F12.2,A)')   '  RPM:         ', src%omega_current * 60.0, ' rev/min'
                        write(*,'(A,ES24.12)')   '  J:           ', src%J_current
                        write(*,'(A,ES24.12,A)') '  Thrust:      ', src%thrust_current, ' lbf'
                        write(*,'(A,ES24.12,A)') '  Torque:      ', src%torque_current, ' ft-lbf'
                        write(*,'(A,ES24.12,A)') '  Power:       ', src%power_current, ' ft-lbf/s'
                        write(*,'(A,ES24.12)')   '  Efficiency:  ', src%eta_current
                        write(*,'(A,ES24.12,A)') '  N_force:     ', src%N_force_current, ' lbf'
                        write(*,'(A,ES24.12,A)') '  n_moment:    ', src%n_moment_current, ' ft-lbf'
                        write(*,'(A,3ES16.8,A)') '  F_c:         ', src%F_comp, ' lbf'
                        write(*,'(A,3ES16.8,A)') '  M_c:         ', src%M_comp, ' ft-lbf'

                        ! body-frame force and moment (Eqs. 3.6.4-3.6.5)
                        if (src%has_orientation) then
                            F_body_v = quat_rotate_body_to_inertial(src%F_comp, src%orientation)
                            M_body_v = quat_rotate_body_to_inertial(src%M_comp, src%orientation) &
                                     + cross3(src%location, F_body_v)
                        else
                            F_body_v = src%F_comp
                            M_body_v = src%M_comp + cross3(src%location, src%F_comp)
                        end if
                        write(*,'(A,3ES16.8,A)') '  F_b:         ', F_body_v, ' lbf'
                        write(*,'(A,3ES16.8,A)') '  M_b:         ', M_body_v, ' ft-lbf'

                        ! angular momentum in rotor and body frames
                        h_rotor_v = [src%delta * src%comp_mass%I(1,1) * src%omega_current * 2.0 * PI, 0.0, 0.0]
                        write(*,'(A,3ES16.8,A)') '  h_c:         ', h_rotor_v, ' slug-ft^2/s'
                        if (src%has_orientation) then
                            h_body_v = quat_rotate_body_to_inertial(h_rotor_v, src%orientation)
                        else
                            h_body_v = h_rotor_v
                        end if
                        write(*,'(A,3ES16.8,A)') '  h_b:         ', h_body_v, ' slug-ft^2/s'

                        ! electric motor state
                        if (src%motor_type == MOTOR_ELECTRIC) then
                            write(*,'(A,F12.4,A)')   '  I_motor:     ', src%I_motor_current, ' A'
                            write(*,'(A,F12.4,A)')   '  V_motor:     ', src%V_motor_current, ' V'
                            write(*,'(A,F12.4,A)')   '  P_electric:  ', src%P_electric_current, ' W'
                            if (associated(src%battery_ptr)) then
                                write(*,'(A,F8.4)')  '  Battery SOC: ', src%battery_ptr%SOC
                                write(*,'(A,F12.4,A)') '  Battery V:   ', src%battery_ptr%V_terminal, ' V'
                                write(*,'(A,F12.4,A)') '  Battery I:   ', src%battery_ptr%I_total, ' A'
                            end if
                        end if
                    end if
                end select
            end do

            write(*,*) ''
        end do

    end subroutine sim_print_states


    ! update geographic coordinates for sphere or elliptic earth model
    subroutine update_geographic(state, y1, y2, geographic_model_ID)
        type(vehicle_state_t), intent(inout) :: state
        real, intent(in) :: y1(:), y2(:)
        integer, intent(in) :: geographic_model_ID

        real :: dx, dy, dz, d
        real :: theta, g1, xhat, yhat, zhat, xhp, yhp, zhp, rhat, Chat, Shat
        real :: cP, cT, sP, sT, cg, sg, dg
        real :: H1, Phi1, Psi1
        real :: quat(4)
        real :: temp, Rx, Ry, tx, ty, Re, Rp


        ! position changes in earth fixed frame
        dx = y2(7) - y1(7)
        dy = y2(8) - y1(8)
        dz = y2(9) - y1(9)

        d = sqrt(dx**2 + dy**2) ! horizontal distance traveled - algorithm 7.5.5 line 9

        if (d < TOLERANCE) then ! algorithm 7.5.5 line 10
            state%dPsi_g = 0.0
            return
        end if

        H1 = -y1(9)                    ! altitude
        Phi1 = state%latitude          ! current latitude
        Psi1 = state%longitude         ! current longitude
        cP = cos(Phi1)
        sP = sin(Phi1)

        if (geographic_model_ID == 1) then  ! spherical earth model (algorithm 7.5.5)
            theta = d / (R_MEAN_EARTH_ENGLISH + H1 - 0.5*dz) ! algorithm 7.5.5 line 15
            cT = cos(theta)
            sT = sin(theta)
            g1 = atan2(dy, dx)          ! algorithm 7.5.5 line 16
            cg = cos(g1)
            sg = sin(g1)

            xhat = cP*cT - sP*sT*cg         ! algorithm 7.5.5 line 17
            yhat = sT*sg                    ! algorithm 7.5.5 line 18
            zhat = sP*cT + cP*sT*cg         ! algorithm 7.5.5 line 19
            xhp = -cP*sT - sP*cT*cg         ! algorithm 7.5.5 line 20
            yhp = cT*sg                     ! algorithm 7.5.5 line 21
            zhp = -sP*sT + cP*cT*cg         ! algorithm 7.5.5 line 22
            rhat = sqrt(xhat**2 + yhat**2)  ! algorithm 7.5.5 line 23

            ! new latitude and longitude
            state%latitude = atan2(zhat, rhat)          ! algorithm 7.5.5 line 24
            state%longitude = Psi1 + atan2(yhat, xhat)  ! algorithm 7.5.5 line 25

            Chat = xhat**2 * zhp    ! algorithm 7.5.5 line 26
            Shat = (xhat*yhp - yhat*xhp) * cos(state%latitude)**2 * cos(state%longitude - Psi1)**2  ! line 27
            dg = atan2(Shat, Chat) - g1     ! line 28

        else if (geographic_model_ID == 2) then     ! ellipsoidal earth model (algorithm 7.5.6)
            Rp = R_POLAR_FT
            Re = R_EQUAT_FT

            temp = 1.0 - E2*sin(Phi1)**2        ! this term is repeated a lot
            Rx = Re*(1.0 - E2) / (temp**1.5)    ! algorithm 7.5.6 line 15
            Ry = Re / sqrt(temp)                ! algorithm 7.5.6 line 16
            tx = dx / (Rx + H1 - 0.5*dz)        ! algorithm 7.5.6 line 17
            ty = dy / (Ry + H1 - 0.5*dz)        ! algorithm 7.5.6 line 18

            ! lines 19-22
            xhat = (1.0 - E2) * (cos(Phi1 + tx) - cos(Phi1)) + temp*cos(ty)*cos(Phi1)
            yhat = (1.0 - E2*sin(Phi1)**2) * sin(ty)
            zhat = (1.0 - E2) * (sin(Phi1 + tx) - sin(Phi1)) + (1.0 - E2*sin(Phi1)**2) * (cos(ty) - E2) * sin(Phi1)
            rhat = sqrt(xhat**2 + yhat**2)

            ! lines 23-25
            state%latitude = atan2(zhat, (1.0 - E2)*rhat)
            state%longitude = Psi1 + atan2(yhat, xhat)
            dg = (state%longitude - Psi1) * sin(0.5*(state%latitude + Phi1)) * (1.0 - E2) / temp

        end if

        state%dPsi_g = dg

        ! limit geographic coordinates
        if (state%longitude > PI) state%longitude = state%longitude - 2.0*PI    ! latitude: -PI/2 to PI/2
        if (state%longitude < -PI) state%longitude = state%longitude + 2.0*PI   ! longitude: -PI to PI

        ! rotate flat earth quaternion according to delta bearing (eq 7.5.17)
        cg = cos(0.5*dg)
        sg = sin(0.5*dg)
        quat(1) = -state%quaternion(4)
        quat(2) = -state%quaternion(3)
        quat(3) = state%quaternion(2)
        quat(4) = state%quaternion(1)
        state%quaternion(1:4) = cg*state%quaternion(1:4) + sg*quat(:)

    end subroutine update_geographic

    ! update all sensors for all vehicles
    subroutine sim_update_sensors(self)
        class(simulator_t), intent(inout) :: self
        integer :: i, j
        real :: mag_earth(3), mag_use(3), decl, incl, tot

        do i = 1, self%n_vehicles
            ! Earth-frame magnetic field for this vehicle: from the WMM (lat/lon/alt/date) when
            ! enabled, computed once per vehicle and shared by all its sensors (the field is a
            ! property of location, not the sensor); else each sensor's configured constant.
            if (self%use_wmm) then
                call wmm_field(self%states(i)%latitude * RAD2DEG, &
                               self%states(i)%longitude * RAD2DEG, &
                               (-self%states(i)%position(3)) * FT_TO_M / 1000.0, &
                               self%date + self%t_current / SEC_PER_YEAR, &
                               mag_earth(1), mag_earth(2), mag_earth(3), decl, incl, tot)
            end if

            do j = 1, self%configs(i)%n_sensors
                associate(s => self%configs(i)%sensors(j)%sensor)
                ! check refresh rate. Fire on the NEAREST tick (half-dt tolerance): t_current is an
                ! accumulated sum (t_current = t_current + dt), so for refresh_interval == dt the bare
                ! `elapsed < interval` test lands at 0.00999.. < 0.01 on ~1/4 of ticks (float rounding)
                ! and spuriously skips the refresh -> the sensor holds its output -> the EKF integrates
                ! a stale gyro -> a staircase in the estimated rate -> the controller stutters. The
                ! tolerance makes 100 Hz fire every tick, 50 Hz every 2, 20 Hz every 5, drift-free.
                if (self%t_current - s%last_update_time < s%refresh_interval - 0.5*self%dt) cycle
                s%last_update_time = self%t_current

                if (self%use_wmm) then
                    mag_use = mag_earth
                else
                    mag_use = s%mag_field
                end if

                call sensor_update(s, &
                    self%states(i)%velocity, self%states(i)%omega, &
                    self%states(i)%position, self%states(i)%quaternion, &
                    self%dynamics(i)%F_total_cache, self%dynamics(i)%M_total_cache, &
                    self%configs(i)%mass%I_inv, self%configs(i)%mass%mass, &
                    -self%states(i)%position(3), &
                    self%dynamics(i)%gust, &
                    mag_use, &
                    self%dynamics(i)%wind, &
                    self%dynamics(i)%T_sl_R, self%dynamics(i)%P_sl_psf)
                end associate
            end do
        end do
    end subroutine sim_update_sensors

    ! write sensor CSV data for all vehicles
    subroutine sim_write_sensor_states(self)
        class(simulator_t), intent(inout) :: self
        integer :: i, j, k

        if (.not. allocated(self%sensor_csv_units)) return

        do i = 1, self%n_vehicles
            if (self%sensor_csv_units(i) == 0) cycle
            if (self%configs(i)%n_sensors == 0) cycle

            write(self%sensor_csv_units(i), '(ES20.12E3)', advance='no') self%t_current
            do j = 1, self%configs(i)%n_sensors
                do k = 1, self%configs(i)%sensors(j)%sensor%n_outputs
                    write(self%sensor_csv_units(i), '(",",ES20.12E3)', advance='no') &
                        self%configs(i)%sensors(j)%sensor%output(k)
                end do
            end do
            write(self%sensor_csv_units(i), *)
        end do
    end subroutine sim_write_sensor_states

    ! write sensor CSV header row
    subroutine write_sensor_headers(unit_num, config)
        integer, intent(in) :: unit_num
        type(vehicle_config_t), intent(in) :: config
        integer :: j, k, n_h
        character(len=64) :: headers(16)  ! max outputs per sensor is 9

        write(unit_num, '(A)', advance='no') 't[s]'
        do j = 1, config%n_sensors
            call sensor_header(config%sensors(j)%sensor, headers, n_h)
            do k = 1, n_h
                write(unit_num, '(",",A)', advance='no') trim(headers(k))
            end do
        end do
        write(unit_num, *)
    end subroutine write_sensor_headers

    ! run EKF prediction and measurement fusion for all vehicles
    subroutine sim_update_ekf(self, dt)
        class(simulator_t), intent(inout) :: self
        real, intent(in) :: dt

        integer :: i, j
        real :: g, alt
        real :: imu_accel(3), imu_gyro(3), imu_mag(3)
        real :: gps_pos(3), gps_vel(3)
        real :: TAS
        real :: aero_alpha, aero_beta
        logical :: has_imu, has_gps, has_ads, has_mag, has_aero

        do i = 1, self%n_vehicles
            if (.not. self%configs(i)%use_ekf) cycle
            if (.not. self%configs(i)%ekf%initialized) cycle

            alt = -self%states(i)%position(3)
            g = gravity_english(alt)

            ! find sensor outputs by type (only use data from sensors that updated this step)
            has_imu = .false.
            has_gps = .false.
            has_ads = .false.
            has_mag = .false.
            has_aero = .false.

            do j = 1, self%configs(i)%n_sensors
                associate(s => self%configs(i)%sensors(j)%sensor)
                ! check if sensor updated this timestep
                if (abs(s%last_update_time - self%t_current) > TOLERANCE) then
                    ! sensor didn't update — skip for EKF fusion
                    ! (prediction still runs, measurements only fuse when fresh)
                    select case (s%type_id)
                    case (SENSOR_IMU)
                        ! IMU always provides data for prediction (holds last value)
                        imu_accel = s%output(1:3)
                        imu_gyro = s%output(4:6)
                        has_imu = .true.
                    end select
                    cycle
                end if
                select case (s%type_id)
                case (SENSOR_IMU)
                    imu_accel = s%output(1:3)
                    imu_gyro = s%output(4:6)
                    imu_mag = s%output(7:9)
                    has_imu = .true.
                    has_mag = .true.
                case (SENSOR_GPS)
                    gps_pos = s%output(1:3)
                    gps_vel = s%output(4:6)
                    has_gps = .true.
                case (SENSOR_ADS)
                    TAS = compute_tas_from_ads(s%output(1), s%output(2), s%output(3))
                    has_ads = .true.
                case (SENSOR_AERO_ANGLES)
                    aero_alpha = s%output(1)
                    aero_beta  = s%output(2)
                    has_aero = .true.
                case (SENSOR_MAGNETOMETER)
                    if (.not. has_mag) then
                        imu_mag = s%output(1:3)
                        has_mag = .true.
                    end if
                end select
                end associate
            end do

            ! EKF prediction (requires IMU)
            if (has_imu) then
                call ekf_predict(self%configs(i)%ekf, imu_gyro, imu_accel, dt, g)

                ! gravity fusion from accelerometer (at IMU rate)
                call ekf_fuse_gravity(self%configs(i)%ekf, imu_accel, g)
            end if

            ! GPS fusion (at GPS rate — sensor refresh_rate handles the timing,
            ! GPS output holds last value between updates, but we only want to fuse
            ! when new data arrives. Use a simple check: fuse every call since
            ! the GPS sensor already rate-limits its output updates)
            if (has_gps) then
                call ekf_fuse_gps(self%configs(i)%ekf, gps_pos, gps_vel)
            end if

            ! magnetometer heading fusion
            if (has_mag) then
                call ekf_fuse_mag_heading(self%configs(i)%ekf, imu_mag)
            end if

            ! airspeed fusion
            if (has_ads) then
                call ekf_fuse_airspeed(self%configs(i)%ekf, TAS)
            end if

            ! aero angle (alpha/beta vane) fusion
            if (has_aero) then
                call ekf_fuse_aero_angles(self%configs(i)%ekf, aero_alpha, aero_beta)
            end if
        end do
    end subroutine sim_update_ekf

    ! compute TAS from ADS pressure outputs
    pure function compute_tas_from_ads(P0, P_inf, T_inf) result(TAS)
        real, intent(in) :: P0, P_inf, T_inf
        real :: TAS
        real :: gm1, ratio, R_air_eng

        R_air_eng = R_AIR * M_TO_FT * M_TO_FT / K_TO_RANKINE
        gm1 = GAMMA_AIR - 1.0

        if (P_inf > TOLERANCE .and. T_inf > TOLERANCE .and. P0 > P_inf) then
            ratio = (P0 / P_inf)**((gm1) / GAMMA_AIR) - 1.0
            TAS = sqrt(2.0 * GAMMA_AIR * R_air_eng * T_inf / gm1 * ratio)
        else
            TAS = 0.0
        end if
    end function compute_tas_from_ads

    ! write EKF state to CSV for all vehicles
    subroutine sim_write_ekf_states(self)
        class(simulator_t), intent(inout) :: self
        integer :: i
        real :: vel_body(3), omega_body(3), pos(3), quat(4)
        real :: imu_gyro(3), omega_dot(3)

        if (.not. allocated(self%ekf_csv_units)) return

        do i = 1, self%n_vehicles
            if (self%ekf_csv_units(i) == 0) cycle
            if (.not. self%configs(i)%use_ekf) cycle

            call find_imu_gyro(self%configs(i), imu_gyro)
            call ekf_get_body_state(self%configs(i)%ekf, vel_body, omega_body, pos, quat, imu_gyro, omega_dot)

            write(self%ekf_csv_units(i), '(ES20.12E3)', advance='no') self%t_current
            ! body-frame state (matches datalog order: u,v,w,p,q,r,x,y,z,e0,ex,ey,ez)
            write(self%ekf_csv_units(i), '(3(",",ES20.12E3))', advance='no') vel_body
            write(self%ekf_csv_units(i), '(3(",",ES20.12E3))', advance='no') omega_body
            write(self%ekf_csv_units(i), '(3(",",ES20.12E3))', advance='no') pos
            write(self%ekf_csv_units(i), '(4(",",ES20.12E3))', advance='no') quat
            ! biases
            write(self%ekf_csv_units(i), '(3(",",ES20.12E3))', advance='no') self%configs(i)%ekf%gyro_bias
            write(self%ekf_csv_units(i), '(3(",",ES20.12E3))', advance='no') self%configs(i)%ekf%accel_bias
            ! Earth-frame NED state
            write(self%ekf_csv_units(i), '(3(",",ES20.12E3))', advance='no') self%configs(i)%ekf%velocity
            write(self%ekf_csv_units(i), '(3(",",ES20.12E3))', advance='no') self%configs(i)%ekf%position
            ! estimated angular acceleration (tracker output)
            write(self%ekf_csv_units(i), '(3(",",ES20.12E3))') omega_dot
        end do
    end subroutine sim_write_ekf_states

end module simulation_m
