! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! vehicle type definitions, type-bound procedures, and pure helpers
! split from vehicle_m.f90 — Phase 2 refactor
module vehicle_types_m
    use constants_m
    use math_m
    use json_m, only: json_value
    use battery_m
    use force_source_m
    use aero_database_m
    use sensor_m
    use ekf_m
    implicit none
    private

    ! public types
    public :: mass_properties_t, control_effector_t, actuator_map_t
    public :: vehicle_config_t, control_inputs_t, vehicle_state_t
    public :: trim_settings_t, simulation_settings_t, atmosphere_settings_t, analysis_settings_t
    public :: telemetry_conn_config_t
    public :: passive_effector_t, passive_inputs_t
    public :: turbulence_config_t

    ! public procedures
    public :: compute_body_velocity
    public :: build_actuator_map
    public :: find_passive_index
    public :: find_passive_rate_index
    public :: assemble_mass_properties

    ! mass properties
    type :: mass_properties_t
        real :: weight_lbf = 0.0
        real :: mass = 0.0
        real :: I(3,3) = 0.0
        real :: I_inv(3,3) = 0.0
        real :: h(3) = 0.0
    contains
        procedure :: compute_mass => mass_compute_mass
        procedure :: compute_inverse => mass_compute_inverse
    end type mass_properties_t

    type :: control_effector_t
        character(len=32) :: name = ''
        character(len=16) :: unit_str = ''  ! unit string from magnitude_limits bracket (e.g., "deg", "rpm")
        real :: value = 0.0
        integer :: dynamics_order = 0    ! 0=instant, 1=first order, 2=second order
        real :: min_val = -1.0e30
        real :: max_val = 1.0e30
        logical :: is_angle = .false.    ! true = stored in radians, parsed from [deg]
        ! actuator dynamics parameters
        real :: time_constant = 0.0      ! tau [s] (first-order)
        real :: natural_frequency = 0.0  ! omega_n [rad/s] (second-order)
        real :: damping_ratio = 0.0      ! zeta (second-order)
        real :: rate_min = -1.0e30       ! min rate
        real :: rate_max =  1.0e30       ! max rate
        real :: accel_min = -1.0e30      ! min acceleration (second-order)
        real :: accel_max =  1.0e30      ! max acceleration (second-order)
        integer :: state_index = 0       ! index into extended state vector (0 = not a state)
        integer :: rate_state_index = 0  ! index for rate state (second-order only)
        real :: rate_value = 0.0         ! current rate value (second-order pack/unpack)
    end type control_effector_t

    ! actuator state mapping (maps dynamic effectors to extended state vector slots)
    type :: actuator_map_t
        integer :: n_actuators = 0          ! number of effectors with dynamics_order >= 1
        integer :: n_passive = 0            ! number of passive effectors
        integer :: state_dim = 13           ! total state vector dimension (13 + n_actuators + 2*n_passive)
        integer, allocatable :: effector_idx(:)  ! effector_idx(k) = index into effectors array
    end type actuator_map_t

    ! passive effector (free-floating aerodynamic surface)
    type :: passive_effector_t
        character(len=32) :: name = ''
        real :: value = 0.0              ! current angle [rad]
        real :: rate_value = 0.0         ! current angular rate [rad/s]
        real :: inertia = 0.0            ! hinge moment of inertia [slug-ft^2]
        real :: damping = 0.0            ! bearing friction [slug-ft^2/s]
        logical :: has_damping = .false.
        real :: ref_area = 0.0           ! reference area [ft^2]
        real :: ref_length = 0.0         ! reference length [ft]
        real :: min_val = -1.0e30        ! position limits [rad]
        real :: max_val = 1.0e30
        logical :: has_limits = .false.
        integer :: state_index = 0       ! position in extended state vector
        integer :: rate_state_index = 0  ! rate in extended state vector
        ! rate variable (optional) — makes nondim rate available as DB IV / pool var
        character(len=32) :: rate_variable = ''
        logical :: nondim_rate = .true.  ! true: rate = theta_dot * L_ref / (2V)
        real :: rate_var_value = 0.0     ! computed rate value for current timestep
        ! driving coefficient — polymorphic model (polynomial or database)
        class(driving_model_t), allocatable :: driving
    end type passive_effector_t

    ! passive effector container (like control_inputs_t)
    type :: passive_inputs_t
        integer :: n = 0
        type(passive_effector_t), allocatable :: effectors(:)
    end type passive_inputs_t

    ! vehicle configuration
    type :: vehicle_config_t
        character(len=100) :: name = ''
        logical :: is_kinematic = .false.
        logical :: run_physics = .true.
        type(mass_properties_t) :: mass
        type(mass_properties_t) :: base_mass   ! vehicle-level mass before assembly (for reassembly)
        integer :: n_batteries = 0
        type(battery_t), allocatable :: batteries(:)
        integer :: n_sources = 0
        type(force_source_wrapper_t), allocatable :: sources(:)
        real :: ref_b = 0.0    ! reference lateral length for passive effectors [ft]
        real :: ref_c = 0.0    ! reference longitudinal length for passive effectors [ft]
        ! sensors
        integer :: n_sensors = 0
        type(sensor_wrapper_t), allocatable :: sensors(:)
        logical :: save_sensor_outputs = .false.
        ! EKF navigation filter
        type(ekf_t) :: ekf
        logical :: use_ekf = .false.
        logical :: save_ekf_output = .false.
    contains
        procedure :: initialize => vehicle_initialize
    end type vehicle_config_t

    ! control inputs - dynamic array of named effectors
    type :: control_inputs_t
        integer :: n = 0
        type(control_effector_t), allocatable :: effectors(:)
    contains
        procedure :: get_value => ctrl_get_value
        procedure :: set_value => ctrl_set_value
        procedure :: get_index => ctrl_get_index
        procedure :: copy_from => ctrl_copy_from
        procedure :: zero_all  => ctrl_zero_all
    end type control_inputs_t

    ! vehicle state
    type :: vehicle_state_t
        real :: velocity(3) = 0.0
        real :: omega(3) = 0.0
        real :: position(3) = 0.0
        real :: quaternion(4) = [1.0, 0.0, 0.0, 0.0]
        real :: latitude = 0.0      ! geographic latitude [rad], limited to [-PI/2, PI/2]
        real :: longitude = 0.0     ! geographic longitude [rad], limited to [-PI, PI]
        real :: dPsi_g = 0.0        ! ground track heading change [rad]
    contains
        procedure :: to_array => state_to_array
        procedure :: from_array => state_from_array
    end type vehicle_state_t

    ! trim variable indices: x = [alpha, beta, ctrl(1), ..., ctrl(n), phi]
    integer, parameter, public :: TRIM_IDX_ALPHA = 1
    integer, parameter, public :: TRIM_IDX_BETA = 2
    integer, parameter, public :: TRIM_IDX_CTRL_BASE = 2   ! effector i lives at index 2+i

    ! trim settings
    type :: trim_settings_t
        character(len=10) :: trim_type = 'sct'
        ! solver settings
        real :: fd_step = 0.01
        real :: relaxation = 0.9
        real :: tolerance = 1.0e-12
        integer :: max_iterations = 2000
        logical :: verbose = .true.
        ! free variables mask (true = solve for this variable)
        ! size = 3 + n_ctrl: [alpha, beta, ctrl(1..n), phi]
        ! phi is normally fixed, only free for SHSS with specified beta
        integer :: n_trim_vars = 0
        logical, allocatable :: free_vars(:)
        ! specified values for fixed variables
        real :: sideslip_angle = 0.0          ! beta [rad]
        real :: gamma_specified = 0.0         ! climb angle [rad]
        logical :: gamma_is_set = .false.
        ! load factor
        real :: loadfactor_specified = 0.0
        logical :: loadfactor_is_set = .false.
        ! vbr settings
        real :: vbr_pw = 0.0                  ! wind axis roll rate [rad/s]
        logical :: vbr_ascending = .true.     ! true = ascending (gamma=90), false = descending (gamma=-90)
    end type trim_settings_t

    ! analysis settings (parsed from json "analysis" section under each vehicle)
    type :: analysis_settings_t
        logical :: export_state_space = .false.   ! true = compute and export A, B matrices
        character(len=16) :: state_form = 'euler' ! 'euler' or 'quaternion'
        real :: fd_step = 1.0e-5                  ! central-difference step size
        character(len=256) :: output_prefix = ''  ! prefix for output files (empty = vehicle name)
    end type analysis_settings_t

    ! simulation settings
    type :: simulation_settings_t
        real :: dt = 0.01
        real :: t_final = 10.0
        logical :: rk4_verbose = .false.
        logical :: save_states = .true.
        logical :: realtime = .false.
        real :: time_scale = 1.0
        character(len=32) :: geographic_model = 'flat'
        integer :: geographic_model_ID = 0
        real :: print_states_rate = 0.0   ! rate to print states to terminal [Hz], 0 = disabled
        real :: save_states_rate = 0.0   ! rate to save states to CSV [Hz], 0 = every timestep
        real :: hold_time = 0.0   ! hold rigid-body states frozen until this sim time [s], 0 = disabled
    end type simulation_settings_t

    ! turbulence configuration (parsed from json "atmosphere.turbulence" section)
    type :: turbulence_config_t
        logical :: enabled = .false.
        real :: sigma_fixed = 0.0              ! fixed sigma [ft/s] (0 = use intensity mode)
        character(len=10) :: intensity = 'light'  ! "light", "moderate", "severe"
        logical :: sigma_is_fixed = .true.     ! .true. = fixed sigma; .false. = altitude-dependent
        real :: Vmin = 5.0                     ! minimum velocity floor [ft/s] (Eq. 9.2.1)
        real :: wingspan = 0.0                 ! for p-gust [ft] (0 = no p-gust)
        real :: Lh_sep = 0.0                   ! CG-to-htail distance [ft] (0 = no q-gust)
        real :: Lv_sep = 0.0                   ! CG-to-vtail distance [ft] (0 = no r-gust)
        integer :: buf_size = 20               ! circular buffer size for q/r gusts
        integer :: seed = 42                   ! random seed (set <0 for clock-based random seed)
    end type turbulence_config_t

    type :: atmosphere_settings_t
        real :: wind(3) = [0.0, 0.0, 0.0]  ! constant wind [N, E, D] in ft/s
        real :: T_sl_R = 0.0                ! sea-level temperature [Rankine] (0 = standard day)
        real :: P_sl_psf = 0.0             ! sea-level pressure [psf] (0 = standard day)
        logical :: has_temp_offset = .false.
        logical :: has_pres_offset = .false.
        real :: user_temp_R = 0.0           ! user-specified absolute temperature [Rankine]
        real :: user_pres_psf = 0.0         ! user-specified absolute pressure [psf]
        type(turbulence_config_t) :: turbulence
        logical :: use_wmm = .false.       ! use the World Magnetic Model for the magnetometer field
        real :: date = 2025.0              ! decimal year for the WMM secular variation (e.g. 2026.5)
    end type atmosphere_settings_t

    ! telemetry connection config (parsed from json)
    integer, parameter, public :: MAX_SENSOR_NAMES = 16
    type :: telemetry_conn_config_t
        character(len=64) :: name = ''
        character(len=64) :: vehicle_name = ''
        integer :: vehicle_index = 0
        logical :: is_sender = .true.
        integer :: data_type = 3      ! 1=controls, 2=state, 3=both, 4=sensors
        integer :: n_values = 22
        logical :: entity_tagged = .false.  ! prepend 4-byte int32 entity_id to UDP packets
        type(json_value), pointer :: json_node => null()
        ! sensor connection fields (used when data_type = 4)
        integer :: n_sensor_names = 0
        character(len=64) :: sensor_names(MAX_SENSOR_NAMES) = ''
    end type telemetry_conn_config_t

contains

    subroutine mass_compute_mass(self)
        class(mass_properties_t), intent(inout) :: self
        self%mass = self%weight_lbf / (G_SSL_SI * M_TO_FT)
    end subroutine mass_compute_mass

    subroutine mass_compute_inverse(self)
        class(mass_properties_t), intent(inout) :: self
        real :: det, Imat(3,3)

        Imat = self%I
        ! JSON stores raw products of inertia; negate off-diagonals to build
        ! the textbook inertia matrix form (Eq 5.4.6) before inverting
        Imat(1,2) = -Imat(1,2)
        Imat(2,1) = -Imat(2,1)
        Imat(1,3) = -Imat(1,3)
        Imat(3,1) = -Imat(3,1)
        Imat(2,3) = -Imat(2,3)
        Imat(3,2) = -Imat(3,2)
        det = Imat(1,1)*(Imat(2,2)*Imat(3,3) - Imat(2,3)*Imat(3,2)) &
            - Imat(1,2)*(Imat(2,1)*Imat(3,3) - Imat(2,3)*Imat(3,1)) &
            + Imat(1,3)*(Imat(2,1)*Imat(3,2) - Imat(2,2)*Imat(3,1))

        if (abs(det) > TOLERANCE) then      ! get inverse if determinant is not singular
            self%I_inv(1,1) = (Imat(2,2)*Imat(3,3) - Imat(2,3)*Imat(3,2)) / det
            self%I_inv(1,2) = (Imat(1,3)*Imat(3,2) - Imat(1,2)*Imat(3,3)) / det
            self%I_inv(1,3) = (Imat(1,2)*Imat(2,3) - Imat(1,3)*Imat(2,2)) / det
            self%I_inv(2,1) = (Imat(2,3)*Imat(3,1) - Imat(2,1)*Imat(3,3)) / det
            self%I_inv(2,2) = (Imat(1,1)*Imat(3,3) - Imat(1,3)*Imat(3,1)) / det
            self%I_inv(2,3) = (Imat(1,3)*Imat(2,1) - Imat(1,1)*Imat(2,3)) / det
            self%I_inv(3,1) = (Imat(2,1)*Imat(3,2) - Imat(2,2)*Imat(3,1)) / det
            self%I_inv(3,2) = (Imat(1,2)*Imat(3,1) - Imat(1,1)*Imat(3,2)) / det
            self%I_inv(3,3) = (Imat(1,1)*Imat(2,2) - Imat(1,2)*Imat(2,1)) / det
        else
            ! a singular inertia tensor would silently zero all angular acceleration; fail loudly
            write(*,*) 'ERROR: inertia tensor is singular (|det| <= TOLERANCE); cannot invert.'
            write(*,*) '       det = ', det
            error stop 'singular inertia tensor'
        end if
    end subroutine mass_compute_inverse

    subroutine vehicle_initialize(self)
        class(vehicle_config_t), intent(inout) :: self
        integer :: j
        type(mass_properties_t) :: assembled

        call self%mass%compute_mass()

        ! save vehicle-level mass for future reassembly (variable geometry)
        self%base_mass = self%mass

        ! assemble mass from vehicle-level + component contributions
        call assemble_mass_properties(self%mass, self%sources, self%n_sources, assembled, &
                                      verbose=.true.)
        self%mass = assembled
        call self%mass%compute_inverse()

        do j = 1, self%n_sources
            call self%sources(j)%src%init_rho0()
        end do

        ! cache reference geometry for passive effectors from first aero source
        self%ref_b = 0.0
        self%ref_c = 0.0
        do j = 1, self%n_sources
            if (self%sources(j)%src%get_b_ref() > 0.0 .or. &
                self%sources(j)%src%get_c_bar() > 0.0) then
                self%ref_b = self%sources(j)%src%get_b_ref()
                self%ref_c = self%sources(j)%src%get_c_bar()
                exit
            end if
        end do
    end subroutine vehicle_initialize

    pure function state_to_array(self) result(y)
        class(vehicle_state_t), intent(in) :: self
        real :: y(13)
        y(1:3) = self%velocity
        y(4:6) = self%omega
        y(7:9) = self%position
        y(10:13) = self%quaternion
    end function state_to_array

    subroutine state_from_array(self, y)
        class(vehicle_state_t), intent(inout) :: self
        real, intent(in) :: y(13)
        self%velocity = y(1:3)
        self%omega = y(4:6)
        self%position = y(7:9)
        self%quaternion = y(10:13)
        call quat_normalize(self%quaternion)
    end subroutine state_from_array

    ! compute body velocity from airspeed and aero angles (eq 3.4.12)
    pure function compute_body_velocity(V_mag, alpha, beta) result(velocity)
        real, intent(in) :: V_mag, alpha, beta
        real :: velocity(3)

        velocity(1) = V_mag * cos(alpha) * cos(beta)
        velocity(2) = V_mag * sin(beta)
        velocity(3) = V_mag * sin(alpha) * cos(beta)
    end function compute_body_velocity

    ! control_inputs_t typebound procedures
    pure function ctrl_get_value(self, name) result(val)
        class(control_inputs_t), intent(in) :: self
        character(*), intent(in) :: name
        real :: val
        integer :: idx
        idx = self%get_index(name)
        if (idx > 0) then
            val = self%effectors(idx)%value
        else
            val = 0.0
        end if
    end function ctrl_get_value

    subroutine ctrl_set_value(self, name, val)
        class(control_inputs_t), intent(inout) :: self
        character(*), intent(in) :: name
        real, intent(in) :: val
        integer :: idx
        idx = self%get_index(name)
        if (idx > 0) self%effectors(idx)%value = val
    end subroutine ctrl_set_value

    pure function ctrl_get_index(self, name) result(idx)
        class(control_inputs_t), intent(in) :: self
        character(*), intent(in) :: name
        integer :: idx, i
        idx = 0
        do i = 1, self%n
            if (trim(self%effectors(i)%name) == trim(name)) then
                idx = i
                return
            end if
        end do
    end function ctrl_get_index

    subroutine ctrl_copy_from(self, source)
        class(control_inputs_t), intent(inout) :: self
        type(control_inputs_t), intent(in) :: source
        integer :: i
        self%n = source%n
        if (allocated(self%effectors)) deallocate(self%effectors)
        if (source%n > 0) then
            allocate(self%effectors(source%n))
            do i = 1, source%n
                self%effectors(i) = source%effectors(i)
            end do
        end if
    end subroutine ctrl_copy_from

    subroutine ctrl_zero_all(self)
        class(control_inputs_t), intent(inout) :: self
        integer :: i
        do i = 1, self%n
            self%effectors(i)%value = 0.0
        end do
    end subroutine ctrl_zero_all

    ! build actuator map: maps dynamic effectors to extended state vector slots
    subroutine build_actuator_map(ctrl, passive, map)
        type(control_inputs_t), intent(inout) :: ctrl
        type(passive_inputs_t), intent(inout) :: passive
        type(actuator_map_t), intent(out) :: map

        integer :: i, k, slot

        ! count dynamic effectors and state slots (2nd order uses 2 slots)
        map%n_actuators = 0
        slot = 13
        do i = 1, ctrl%n
            if (ctrl%effectors(i)%dynamics_order >= 1) map%n_actuators = map%n_actuators + 1
            if (ctrl%effectors(i)%dynamics_order == 1) slot = slot + 1
            if (ctrl%effectors(i)%dynamics_order == 2) slot = slot + 2
        end do

        if (map%n_actuators > 0) then
            allocate(map%effector_idx(map%n_actuators))
            k = 0; slot = 13
            do i = 1, ctrl%n
                if (ctrl%effectors(i)%dynamics_order >= 1) then
                    k = k + 1
                    map%effector_idx(k) = i
                    slot = slot + 1
                    ctrl%effectors(i)%state_index = slot
                    if (ctrl%effectors(i)%dynamics_order == 2) then
                        slot = slot + 1
                        ctrl%effectors(i)%rate_state_index = slot
                    end if
                end if
            end do
        end if

        ! passive effector state slots: positions then rates
        map%n_passive = passive%n
        do i = 1, passive%n
            slot = slot + 1
            passive%effectors(i)%state_index = slot
        end do
        do i = 1, passive%n
            slot = slot + 1
            passive%effectors(i)%rate_state_index = slot
        end do

        map%state_dim = slot
    end subroutine build_actuator_map

    ! find passive effector index by position name
    pure function find_passive_index(passive, name) result(idx)
        type(passive_inputs_t), intent(in) :: passive
        character(*), intent(in) :: name
        integer :: idx, i
        idx = 0
        do i = 1, passive%n
            if (trim(passive%effectors(i)%name) == trim(name)) then
                idx = i
                return
            end if
        end do
    end function find_passive_index

    ! find passive effector index by rate variable name
    pure function find_passive_rate_index(passive, name) result(idx)
        type(passive_inputs_t), intent(in) :: passive
        character(*), intent(in) :: name
        integer :: idx, i
        idx = 0
        do i = 1, passive%n
            if (len_trim(passive%effectors(i)%rate_variable) > 0 .and. &
                trim(passive%effectors(i)%rate_variable) == trim(name)) then
                idx = i
                return
            end if
        end do
    end function find_passive_rate_index

    ! assemble vehicle mass properties from vehicle-level base mass + component masses
    ! vehicle-level mass is treated as a component at the body origin with cg=[0,0,0].
    ! component masses are added via parallel-axis theorem.
    ! result: total mass, total CG, total inertia about total CG, total h
    subroutine assemble_mass_properties(base_mass, sources, n_sources, total_mass, verbose)
        type(mass_properties_t), intent(in) :: base_mass
        type(force_source_wrapper_t), intent(in) :: sources(:)
        integer, intent(in) :: n_sources
        type(mass_properties_t), intent(out) :: total_mass
        logical, intent(in), optional :: verbose

        integer :: i, n_mass
        real :: m_total, cg_body(3), r_i(3), s(3)
        real :: I_total(3,3), I_comp(3,3), R(3,3), I_rotated(3,3)
        real :: h_total(3)
        real :: eye3(3,3)
        type(component_mass_t) :: cm
        logical :: do_print

        do_print = .false.
        if (present(verbose)) do_print = verbose

        eye3 = 0.0
        eye3(1,1) = 1.0; eye3(2,2) = 1.0; eye3(3,3) = 1.0

        ! start with vehicle-level mass as first contributor at body origin
        m_total = base_mass%mass
        cg_body = 0.0  ! vehicle-level mass has CG at body origin
        h_total = base_mass%h

        ! count components with mass
        n_mass = 0
        do i = 1, n_sources
            if (sources(i)%src%comp_mass%has_mass) n_mass = n_mass + 1
        end do

        if (n_mass == 0) then
            ! no component mass — use vehicle-level mass directly
            total_mass = base_mass
            return
        end if

        ! first pass: compute total mass and vehicle CG
        ! vehicle-level contribution: m_base at origin
        do i = 1, n_sources
            cm = sources(i)%src%comp_mass
            if (.not. cm%has_mass) cycle
            ! refresh slug mass from weight_lbf in case an equation has updated
            ! weight at runtime (or wired its IV=0 value at load time)
            cm%mass = cm%weight_lbf / (G_SSL_SI * M_TO_FT)
            ! treat zero-weight component as absent: skip mass, CG, h, and inertia
            ! contributions. Otherwise the cm%I tensor (which equations don't
            ! touch) would keep contributing after a payload-drop step fires.
            if (cm%mass - TOLERANCE <= 0.0) cycle

            ! component CG in body frame = location + R * cg_component
            if (sources(i)%src%has_orientation) then
                r_i = sources(i)%src%location + &
                      quat_rotate_body_to_inertial(cm%cg, sources(i)%src%orientation)
            else
                r_i = sources(i)%src%location + cm%cg
            end if

            cg_body = cg_body + cm%mass * r_i
            m_total = m_total + cm%mass
            ! rotate angular momentum from component frame to body frame
            if (sources(i)%src%has_orientation) then
                h_total = h_total + quat_rotate_body_to_inertial(cm%h, sources(i)%src%orientation)
            else
                h_total = h_total + cm%h
            end if
        end do

        if (m_total > 0.0) then
            ! weighted CG: base_mass at origin + component contributions
            cg_body = (base_mass%mass * 0.0 + cg_body) / m_total
        end if

        ! second pass: assemble inertia about vehicle CG via parallel-axis theorem
        ! start with vehicle-level inertia shifted from origin to vehicle CG
        I_total = 0.0

        ! vehicle-level inertia: already about origin, shift to CG
        ! build textbook form (negate off-diags stored as products of inertia)
        I_comp = base_mass%I
        I_comp(1,2) = -I_comp(1,2); I_comp(2,1) = -I_comp(2,1)
        I_comp(1,3) = -I_comp(1,3); I_comp(3,1) = -I_comp(3,1)
        I_comp(2,3) = -I_comp(2,3); I_comp(3,2) = -I_comp(3,2)
        s = cg_body  ! offset from origin (where base mass sits) to vehicle CG
        I_total = I_comp + base_mass%mass * (dot_product(s, s) * eye3 - outer3(s, s))

        do i = 1, n_sources
            cm = sources(i)%src%comp_mass
            if (.not. cm%has_mass) cycle
            ! refresh slug mass from weight_lbf (same reason as first pass)
            cm%mass = cm%weight_lbf / (G_SSL_SI * M_TO_FT)
            if (cm%mass - TOLERANCE <= 0.0) cycle

            ! component inertia in component frame (textbook form)
            I_comp = cm%I
            I_comp(1,2) = -I_comp(1,2); I_comp(2,1) = -I_comp(2,1)
            I_comp(1,3) = -I_comp(1,3); I_comp(3,1) = -I_comp(3,1)
            I_comp(2,3) = -I_comp(2,3); I_comp(3,2) = -I_comp(3,2)

            ! if inertia_ref differs from CG, shift inertia to component CG first
            if (cm%has_inertia_ref) then
                s = cm%cg - cm%inertia_ref
                I_comp = I_comp - cm%mass * (dot_product(s, s) * eye3 - outer3(s, s))
            end if

            ! rotate component inertia to body frame: I_body = R * I_comp * R^T
            if (sources(i)%src%has_orientation) then
                R = quat_to_dcm(sources(i)%src%orientation)
                I_rotated = matmul(R, matmul(I_comp, transpose(R)))
            else
                I_rotated = I_comp
            end if

            ! component CG in body frame
            if (sources(i)%src%has_orientation) then
                r_i = sources(i)%src%location + &
                      quat_rotate_body_to_inertial(cm%cg, sources(i)%src%orientation)
            else
                r_i = sources(i)%src%location + cm%cg
            end if

            ! parallel-axis theorem: shift from component CG to vehicle CG
            s = cg_body - r_i
            I_total = I_total + I_rotated + cm%mass * (dot_product(s, s) * eye3 - outer3(s, s))
        end do

        ! store results — convert back to products-of-inertia convention (negate off-diags)
        total_mass%weight_lbf = m_total * G_SSL_SI * M_TO_FT
        total_mass%mass = m_total
        total_mass%I = I_total
        total_mass%I(1,2) = -I_total(1,2); total_mass%I(2,1) = -I_total(2,1)
        total_mass%I(1,3) = -I_total(1,3); total_mass%I(3,1) = -I_total(3,1)
        total_mass%I(2,3) = -I_total(2,3); total_mass%I(3,2) = -I_total(3,2)
        total_mass%h = h_total

        if (do_print) then
            write(*,*) '  Mass assembly: ', n_mass, ' component(s) + vehicle base'
            write(*,*) '    Total mass: ', m_total, ' slug (', total_mass%weight_lbf, ' lbf)'
            write(*,*) '    Vehicle CG: [', cg_body(1), ', ', cg_body(2), ', ', cg_body(3), '] ft'
            write(*,*) '    Inertia about CG [slug-ft^2]: Ixx=', total_mass%I(1,1), &
                       ' Iyy=', total_mass%I(2,2), ' Izz=', total_mass%I(3,3)
            write(*,*) '                                  Ixy=', total_mass%I(1,2), &
                       ' Ixz=', total_mass%I(1,3), ' Iyz=', total_mass%I(2,3)
        end if

    end subroutine assemble_mass_properties

    ! outer product of two 3-vectors
    pure function outer3(a, b) result(C)
        real, intent(in) :: a(3), b(3)
        real :: C(3,3)
        integer :: i, j
        do j = 1, 3
            do i = 1, 3
                C(i,j) = a(i) * b(j)
            end do
        end do
    end function outer3

end module vehicle_types_m