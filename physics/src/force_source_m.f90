! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! polymorphic force/moment source hierarchy
module force_source_m
    use constants_m
    use math_m
    use atmosphere_m
    use aero_database_m
    use aero_state_m
    use battery_m
    implicit none
    private

    ! public types — base hierarchy
    public :: force_source_t, aero_source_t, force_source_wrapper_t
    public :: component_mass_t
    ! public types — concrete source types
    public :: sd_source_t, database_source_t
    public :: simple_thrust_t, propeller_source_t
    public :: sphere_source_t, cuboid_source_t, cylinder_source_t
    public :: mass_source_t
    public :: MOTOR_RPM, MOTOR_ELECTRIC
    public :: wing_source_t
    ! public types — supporting
    public :: stall_model_t, db_entry_t, driving_db_entry_t
    public :: generic_coef_t, coef_group_t, coef_term_t
    ! public types — driving model hierarchy
    public :: driving_model_t, polynomial_driving_t, database_driving_t
    ! public constants
    public :: MAX_TERMS, MAX_CUSTOM, N_STD_VARS, N_GROUPS
    public :: aero_state_t, ind_var_t, dep_var_t, MAX_STATE_VARS
    public :: split_on_char
    public :: IDX_CONST, IDX_ALPHA, IDX_BETA, IDX_PBAR, IDX_QBAR, IDX_RBAR
    public :: IDX_ALPHAHAT, IDX_BETAFLANK, IDX_BETAHAT
    public :: DV_CX, DV_CY, DV_CZ, DV_CL, DV_CD, DV_CS, DV_CROLL, DV_CM, DV_CN, N_DV_MAP
    public :: DV_CL_STAB, DV_CD_STAB, DV_CS_STAB, DV_CROLL_STAB, DV_CN_STAB
    public :: dv_column_t
    ! public procedures
    public :: evaluate_group, compute_aero_vars, populate_aero_state
    public :: recompute_source_geometry
    public :: sigma_blend

    ! stall model (alpha stall for CL, CD, Cm + rotation rate stall for Cl, Cm, Cn)
    type :: stall_model_t
        logical :: enabled = .false.
        real :: CL_alpha0 = 0.0, CL_alpha_s = 0.0, CL_lambda_b = 0.0
        real :: CD_alpha0 = 0.0, CD_alpha_s = 0.0, CD_lambda_b = 0.0
        real :: Cm_alpha0 = 0.0, Cm_alpha_s = 0.0, Cm_lambda_b = 0.0
        real :: Cm_min = 0.0
        ! lateral beta-stall (Newtonian flat-plate side force CS and yaw Cn past sideslip stall)
        real :: CS_beta0 = 0.0, CS_beta_s = 0.0, CS_lambda_b = 0.0, CS_stall = 0.0
        real :: Cn_beta0 = 0.0, Cn_beta_s = 0.0, Cn_lambda_b = 0.0, Cn_min_beta = 0.0
        ! rotation rate stall (additive damping moments at high nondimensional rates)
        real :: pbar_stall = 0.0, lambda_pbar = 0.0, Cl_pbar_stall = 0.0
        real :: qbar_stall = 0.0, lambda_qbar = 0.0, Cm_qbar_stall = 0.0
        real :: rbar_stall = 0.0, lambda_rbar = 0.0, Cn_rbar_stall = 0.0
    contains
        procedure :: blend_factor => stall_blend_factor
    end type stall_model_t

    ! generic coefficient system constants
    integer, parameter :: MAX_TERMS  = 16   ! max terms per coefficient group
    integer, parameter :: MAX_CUSTOM = 8    ! max custom variables
    integer, parameter :: N_GROUPS   = 11   ! body/wind CL,CS,CD,Cl,Cm,Cn + stability CLstab,CDstab,CSstab,Clstab,Cnstab

    ! single term in a coefficient sum
    type :: coef_term_t
        real    :: value = 0.0         ! coefficient multiplier
        integer :: n_factors = 0       ! 0=constant, 1=one var, 2=two vars multiplied
        integer :: factor(2) = 0       ! indices into the pool array that identify which variables to multiply together
    end type coef_term_t

    ! coefficient group (like CL, CD, etc.)
    type :: coef_group_t
        integer :: n_terms = 0
        type(coef_term_t) :: terms(MAX_TERMS)
    end type coef_group_t

    ! generic coefficient data for stability_derivatives
    type :: generic_coef_t
        integer :: pool_size = 0
        integer :: n_ctrl = 0
        integer :: ctrl_offset = 0        ! first ctrl effector pool slot
        integer :: n_custom = 0
        integer :: custom_offset = 0      ! first custom var pool slot
        integer :: group_offset = 0       ! first group result pool slot (CL)
        character(len=32) :: custom_names(MAX_CUSTOM)
        type(coef_group_t) :: custom(MAX_CUSTOM)   ! custom variable formulas
        type(coef_group_t) :: groups(N_GROUPS)      ! CL, CS, CD, Cl, Cm, Cn
    end type generic_coef_t

    ! dependent variable map indices
    integer, parameter :: DV_CX = 1, DV_CY = 2, DV_CZ = 3
    integer, parameter :: DV_CL = 4, DV_CD = 5, DV_CS = 6
    integer, parameter :: DV_CROLL = 7, DV_CM = 8, DV_CN = 9
    ! stability-axis force/moment coefficients (rotated to body by alpha only; pitch is frame-invariant)
    integer, parameter :: DV_CL_STAB = 10, DV_CD_STAB = 11, DV_CS_STAB = 12
    integer, parameter :: DV_CROLL_STAB = 13, DV_CN_STAB = 14
    integer, parameter :: N_DV_MAP = 14
    ! SD coefficient-group index -> DV slot (groups 1-6 body/wind, 7-11 stability)
    integer, parameter :: GROUP_TO_DV(N_GROUPS) = [DV_CL, DV_CS, DV_CD, DV_CROLL, DV_CM, DV_CN, &
                                                   DV_CL_STAB, DV_CD_STAB, DV_CS_STAB, DV_CROLL_STAB, DV_CN_STAB]

    ! per-column DV mapping with multiplier factors
    ! e.g. "Cl_beta" -> slot=DV_CROLL, factors has one ind_var_t for beta
    !      "Cx_qbar_lef" -> slot=DV_CX, factors has ind_var_t for qbar and lef
    type :: dv_column_t
        integer :: slot = 0          ! DV coefficient slot (0=unused)
        type(dep_var_t) :: factors   ! multiplier factors (from underscore parsing)
    end type dv_column_t

    ! single database entry (one CSV file with its own IV/DV mappings)
    type :: db_entry_t
        type(aero_db_t) :: db
        integer :: n_iv = 0
        integer, allocatable :: iv_map(:)
        real, allocatable :: iv_scale(:)
        type(dv_column_t), allocatable :: dv_columns(:)  ! (n_dv) per-column mapping
    end type db_entry_t

    ! single database entry for passive effector driving coefficient
    type :: driving_db_entry_t
        type(aero_db_t) :: db
        integer :: n_iv = 0
        integer, allocatable :: iv_map(:)
        real, allocatable :: iv_scale(:)
        integer :: dv_index = 0     ! column index of the driving variable (e.g., Clemp)
    end type driving_db_entry_t

    ! ---- driving model hierarchy for passive effectors ----
    type, abstract :: driving_model_t
    contains
        procedure(evaluate_driving_iface), deferred :: evaluate
    end type driving_model_t

    abstract interface
        function evaluate_driving_iface(self, state) result(C_drive)
            import :: driving_model_t, aero_state_t
            class(driving_model_t), intent(in) :: self
            type(aero_state_t), intent(in) :: state
            real :: C_drive
        end function evaluate_driving_iface
    end interface

    type, extends(driving_model_t) :: polynomial_driving_t
        type(coef_group_t) :: driving_coef
    contains
        procedure :: evaluate => polynomial_evaluate
    end type polynomial_driving_t

    type, extends(driving_model_t) :: database_driving_t
        integer :: driving_db_n = 0
        type(driving_db_entry_t), allocatable :: driving_dbs(:)
        real, allocatable :: iv_work(:), dv_work(:)  ! pre-allocated work arrays
    contains
        procedure :: evaluate => database_driving_evaluate
    end type database_driving_t

    ! ---- abstract base type ----
    ! per-component mass properties (optional, stored on each force source)
    type :: component_mass_t
        logical :: has_mass = .false.         ! true if this component defines mass
        real :: weight_lbf = 0.0              ! weight [lbf]
        real :: mass = 0.0                    ! mass [slug] (computed from weight)
        real :: cg(3) = 0.0                   ! CG offset in component frame [ft]
        real :: I(3,3) = 0.0                  ! inertia tensor about CG (or inertia_ref) in component frame
        real :: inertia_ref(3) = 0.0          ! point inertia is measured about, in component frame
        logical :: has_inertia_ref = .false.  ! true if inertia_ref differs from CG
        real :: h(3) = 0.0                    ! angular momentum from spinning parts [slug-ft^2/s]
    end type component_mass_t

    type, abstract :: force_source_t
        character(len=64) :: name = ''
        real :: location(3) = 0.0     ! position relative to CG [ft]
        real :: orientation(4) = [1.0, 0.0, 0.0, 0.0]  ! component attitude quaternion (component frame relative to body frame)
        real :: orientation_euler(3) = 0.0  ! Euler angles [rad] for equation-driven orientation
        logical :: has_orientation = .false.  ! true if non-identity orientation
        type(component_mass_t) :: comp_mass   ! optional per-component mass properties
    contains
        procedure(compute_iface), deferred :: compute
        procedure :: get_coefficients => default_get_coefficients
        procedure :: init_rho0 => default_init_rho0
        procedure :: get_b_ref => default_get_b_ref
        procedure :: get_c_bar => default_get_c_bar
        procedure :: get_S_ref => default_get_S_ref
    end type force_source_t

    ! ---- abstract interface for force source compute ----
    abstract interface
        subroutine compute_iface(self, velocity, omega, rho, mu, ctrl_values, n_ctrl, F, M)
            import :: force_source_t
            class(force_source_t), intent(inout) :: self
            real, intent(in) :: velocity(3), omega(3)
            real, intent(in) :: rho, mu
            real, intent(in) :: ctrl_values(:)
            integer, intent(in) :: n_ctrl
            real, intent(out) :: F(3), M(3)
        end subroutine compute_iface
    end interface

    ! ---- wrapper for polymorphic arrays ----
    type :: force_source_wrapper_t
        class(force_source_t), allocatable :: src
    end type force_source_wrapper_t

    ! ---- abstract intermediate: aerodynamic sources with reference geometry ----
    type, abstract, extends(force_source_t) :: aero_source_t
        real :: S_ref = 0.0
        real :: c_bar = 0.0
        real :: b_ref = 0.0
        type(stall_model_t) :: stall
    contains
        procedure(eval_coefs_iface), deferred :: eval_coefs
        procedure :: compute => aero_compute
        procedure :: get_coefficients => aero_get_coefficients
        procedure :: get_b_ref => aero_get_b_ref
        procedure :: get_c_bar => aero_get_c_bar
        procedure :: get_S_ref => aero_get_S_ref
    end type aero_source_t

    abstract interface
        subroutine eval_coefs_iface(self, velocity, omega, ctrl_values, n_ctrl, &
                                    coefs, V_mag, alpha, beta)
            import :: aero_source_t, N_DV_MAP
            class(aero_source_t), intent(in) :: self
            real, intent(in) :: velocity(3), omega(3), ctrl_values(:)
            integer, intent(in) :: n_ctrl
            real, intent(out) :: coefs(N_DV_MAP)
            real, intent(out) :: V_mag, alpha, beta
        end subroutine eval_coefs_iface
    end interface

    ! ---- concrete: stability derivatives ----
    type, extends(aero_source_t) :: sd_source_t
        type(generic_coef_t) :: sd
    contains
        procedure :: eval_coefs => sd_eval_coefs
    end type sd_source_t

    ! ---- concrete: database aerodynamics ----
    type, extends(aero_source_t) :: database_source_t
        integer :: db_n_entries = 0
        type(db_entry_t), allocatable :: db_entries(:)
    contains
        procedure :: eval_coefs => database_eval_coefs
    end type database_source_t

    ! ---- motor type constants ----
    integer, parameter :: MOTOR_RPM = 1
    integer, parameter :: MOTOR_ELECTRIC = 2

    ! ---- concrete: simple thrust (Section 4.3, Eq 4.3.1) ----
    type, extends(force_source_t) :: simple_thrust_t
        real :: T0 = 0.0                      ! max thrust at sea level [lbf]
        real :: T_alpha = 0.0                 ! density exponent
        real :: direction(3) = [1.0, 0.0, 0.0]  ! thrust direction unit vector
        integer :: effector_idx = 0           ! cached control effector index
        real :: rho_0 = 0.0                   ! cached sea level density
    contains
        procedure :: compute => simple_thrust_compute
        procedure :: init_rho0 => simple_thrust_init_rho0
    end type simple_thrust_t

    ! ---- concrete: propeller (Section 4.5, polynomial coefficient model) ----
    type, extends(force_source_t) :: propeller_source_t
        real :: diameter = 0.0                ! [ft]
        real :: delta = 1.0                   ! +1 right-hand, -1 left-hand
        real :: CT_coef(3) = 0.0              ! CT(J) = c0 + c1*J + c2*J^2
        real :: CPb_coef(3) = 0.0             ! brake power coefficient
        real :: normal_coef(4) = 0.0            ! normal force slope (cubic)
        real :: yaw_coef(4) = 0.0             ! yaw moment slope (cubic)
        integer :: motor_type = MOTOR_RPM
        real :: J_limits(2) = [-10.0, 10.0]   ! advance ratio clamp
        integer :: effector_idx = 0           ! cached control effector index
        real :: rho_0 = 0.0                   ! cached sea level density
        ! runtime state (updated during compute)
        real :: omega_current = 0.0           ! current rotor speed [rev/s]
        real :: J_current = 0.0               ! current advance ratio
        real :: thrust_current = 0.0          ! last computed thrust [lbf]
        real :: torque_current = 0.0          ! last computed torque [ft-lbf]
        real :: power_current = 0.0           ! last computed brake power [ft-lbf/s]
        real :: eta_current = 0.0             ! propulsive efficiency
        real :: N_force_current = 0.0         ! normal force [lbf]
        real :: n_moment_current = 0.0        ! yaw moment [ft-lbf]
        real :: F_comp(3) = 0.0               ! total force in component frame [lbf]
        real :: M_comp(3) = 0.0               ! total moment in component frame [ft-lbf]
        logical :: verbose = .false.          ! print propeller state each print cycle
        ! electric motor parameters (used when motor_type = MOTOR_ELECTRIC)
        real :: kV = 0.0                      ! speed constant [rev/s/V]
        real :: kT = 0.0                      ! torque constant [ft-lbf/A]
        real :: R_motor = 0.0                 ! armature resistance [Ohm]
        real :: I_0 = 0.0                     ! no-load current [A]
        real :: R_esc = 0.0                   ! ESC resistance [Ohm]
        real :: gear_ratio = 1.0              ! Gm = Nm/Ns (motor rpm / prop rpm); Eq 4.6.9
        real :: eta_gear = 1.0                ! gearbox efficiency
        integer :: battery_index = 0          ! index into vehicle battery array
        type(battery_t), pointer :: battery_ptr => null()
        real :: Ic_max = huge(0.0)            ! ESC max current [A] (Table 4.6.3)
        integer :: elec_max_iter = 60         ! solver max bisection iterations
        real :: elec_tol = 1.0e-10            ! solver convergence tolerance [ft-lbf]
        logical :: ic_warn_issued = .false.   ! warn-once on ESC overcurrent
        ! electric motor runtime state
        real :: I_motor_current = 0.0         ! motor armature current Im [A]
        real :: V_motor_current = 0.0         ! motor terminal voltage Em [V]
        real :: P_electric_current = 0.0      ! electrical power Em*Im [W]
        real :: I_battery_current = 0.0       ! battery-side current Ib [A] (Eq 4.6.3/4.6.32)
    contains
        procedure :: compute => propeller_compute
        procedure :: init_rho0 => propeller_init_rho0
    end type propeller_source_t

    ! ---- concrete: sphere/ellipsoid drag (Section 3.6, Eqs 3.6.26-3.6.29) ----
    type, extends(force_source_t) :: sphere_source_t
        real :: rx = 0.0    ! radius along component x-axis [ft]
        real :: ry = 0.0    ! radius along component y-axis [ft]
        real :: rz = 0.0    ! radius along component z-axis [ft]
    contains
        procedure :: compute => sphere_compute
        procedure :: get_S_ref => sphere_get_S_ref
    end type sphere_source_t

    ! ---- concrete: rectangular cuboid (Section 3.6, Eqs 3.6.8-3.6.11) ----
    type, extends(force_source_t) :: cuboid_source_t
        real :: lx = 0.0    ! dimension along component x-axis [ft]
        real :: ly = 0.0    ! dimension along component y-axis [ft]
        real :: lz = 0.0    ! dimension along component z-axis [ft]
        real :: CD = 1.05   ! drag coefficient (Eq 3.6.11, default = bluff cube)
    contains
        procedure :: compute => cuboid_compute
        procedure :: get_S_ref => cuboid_get_S_ref
    end type cuboid_source_t

    ! ---- concrete: inert mass element (payload, ballast, battery, avionics) ----
    ! Contributes mass/inertia to the assembled vehicle (via comp_mass) only; it
    ! produces zero aerodynamic and propulsive force/moment. A "mass" block and a
    ! "location" are required; the inertia tensor is optional (a bare weight is
    ! treated as a point mass, with inertia accrued purely by the parallel-axis
    ! theorem about its location in assemble_mass_properties).
    type, extends(force_source_t) :: mass_source_t
    contains
        procedure :: compute => mass_source_compute
    end type mass_source_t

    ! ---- concrete: cylinder/frustum (Section 3.6, Eqs 3.6.12-3.6.25) ----
    type, extends(force_source_t) :: cylinder_source_t
        real :: r1 = 0.0       ! radius at end 1 [ft] (along -x in component frame)
        real :: r2 = 0.0       ! radius at end 2 [ft] (along +x in component frame)
        real :: length = 0.0   ! length along component x-axis [ft]
    contains
        procedure :: compute => cylinder_compute
        procedure :: get_S_ref => cylinder_get_S_ref
    end type cylinder_source_t

    ! ---- concrete: wing segment (Section 3.6, Eqs 3.6.30-3.6.65) ----
    ! Wing axis is along component y-axis (semispan direction).
    ! Root at y=0, tip at y=semispan. Chord along x-axis.
    type, extends(force_source_t) :: wing_source_t
        ! geometry
        real :: semispan = 0.0     ! semispan [ft] (one side)
        real :: root_chord = 0.0   ! root chord [ft]
        real :: tip_chord = 0.0    ! tip chord [ft]
        real :: sweep = 0.0        ! quarter-chord sweep angle [rad]
        real :: dihedral = 0.0     ! dihedral angle [rad] (defines side: +1 right, -1 left via delta in Eq 3.6.33)
        integer :: side = 1        ! +1 = right wing, -1 = left wing
        ! derived geometry (computed at init)
        real :: mean_chord = 0.0   ! c_bar = (c_r + c_t) / 2  (Eq 3.6.31)
        real :: S_w = 0.0          ! planform area = b * c_bar  (Eq 3.6.30)
        real :: R_A = 0.0          ! aspect ratio = b / c_bar  (Eq 3.6.32)
        real :: ac_local(3) = 0.0  ! aerodynamic center in wing frame (Eq 3.6.35)
        ! aerodynamic properties
        real :: CL_alpha = 0.0     ! lift slope [/rad] (0 = auto from R_A, Eq 3.6.51)
        real :: alpha_L0 = 0.0     ! zero-lift AoA [rad]
        real :: CD0 = 0.01         ! zero-lift drag coefficient
        real :: CD1 = 0.0          ! linear drag term
        real :: e_O = 0.8          ! Oswald efficiency factor
        real :: Cm0 = 0.0          ! pitching moment at zero AoA
        real :: Cm_alpha = 0.0     ! pitching moment slope [/rad]
        ! control surface
        integer :: ctrl_idx = 0    ! control effector index (0 = none)
        real :: flap_frac = 0.0    ! flap chord fraction c_f/c (0 = no flap)
        real :: eta_f = 0.8        ! flap efficiency
        real :: eps_c = 0.0        ! control surface lift effectiveness (computed at init, Eq 3.6.52)
        real :: Cm_dc = 0.0        ! control moment effectiveness (computed at init, Eq 3.6.56)
        logical :: antisymmetric = .false. ! true = sign-flip control for left wing (ailerons)
        ! stall parameters
        real :: alpha_0_stall = 0.0   ! stall center [rad] (Eq 3.6.65)
        real :: alpha_s_stall = 0.436 ! stall half-width [rad] (~25 deg, Eq 3.6.65)
        real :: lambda_b_stall = 40.0 ! stall blending rate (Eq 3.6.65)
    contains
        procedure :: compute => wing_compute
        procedure :: get_S_ref => wing_get_S_ref
        procedure :: get_b_ref => wing_get_b_ref
        procedure :: get_c_bar => wing_get_c_bar
    end type wing_source_t

contains

    ! ================================================================
    ! default (base) implementations
    ! ================================================================

    subroutine default_get_coefficients(self, velocity, omega, ctrl_values, n_ctrl, &
                                         lift_out, side_out, drag_out, roll_out, pitch_out, yaw_out, &
                                         cx_out, cy_out, cz_out)
        class(force_source_t), intent(in) :: self
        real, intent(in) :: velocity(3), omega(3), ctrl_values(:)
        integer, intent(in) :: n_ctrl
        real, intent(out) :: lift_out, side_out, drag_out, roll_out, pitch_out, yaw_out
        real, intent(out) :: cx_out, cy_out, cz_out
        lift_out = 0.0; side_out = 0.0; drag_out = 0.0
        roll_out = 0.0; pitch_out = 0.0; yaw_out = 0.0
        cx_out = 0.0; cy_out = 0.0; cz_out = 0.0
    end subroutine default_get_coefficients

    subroutine default_init_rho0(self)
        class(force_source_t), intent(inout) :: self
        ! no-op for non-thrust sources
    end subroutine default_init_rho0

    pure function default_get_b_ref(self) result(val)
        class(force_source_t), intent(in) :: self
        real :: val
        val = 0.0
    end function default_get_b_ref

    pure function default_get_c_bar(self) result(val)
        class(force_source_t), intent(in) :: self
        real :: val
        val = 0.0
    end function default_get_c_bar

    pure function default_get_S_ref(self) result(val)
        class(force_source_t), intent(in) :: self
        real :: val
        val = 0.0
    end function default_get_S_ref

    ! ================================================================
    ! aero_source_t accessors
    ! ================================================================

    pure function aero_get_b_ref(self) result(val)
        class(aero_source_t), intent(in) :: self
        real :: val
        val = self%b_ref
    end function aero_get_b_ref

    pure function aero_get_c_bar(self) result(val)
        class(aero_source_t), intent(in) :: self
        real :: val
        val = self%c_bar
    end function aero_get_c_bar

    pure function aero_get_S_ref(self) result(val)
        class(aero_source_t), intent(in) :: self
        real :: val
        val = self%S_ref
    end function aero_get_S_ref

    ! ================================================================
    ! sphere / cuboid S_ref accessors
    ! ================================================================

    pure function sphere_get_S_ref(self) result(val)
        class(sphere_source_t), intent(in) :: self
        real :: val
        ! max cross-sectional area as representative reference
        val = PI * max(self%ry * self%rz, self%rx * self%rz, self%rx * self%ry)
    end function sphere_get_S_ref

    pure function cuboid_get_S_ref(self) result(val)
        class(cuboid_source_t), intent(in) :: self
        real :: val
        ! return max face area as representative reference area
        val = max(self%ly * self%lz, self%lx * self%lz, self%lx * self%ly)
    end function cuboid_get_S_ref

    ! ================================================================
    ! stall model
    ! ================================================================

    ! standalone sigmoid blend (Eq 3.6.65) — used by stall model and wing
    pure function sigma_blend(alpha, alpha0, alpha_s, lambda_b) result(sigma)
        real, intent(in) :: alpha, alpha0, alpha_s, lambda_b
        real :: sigma, num, den
        num = 1.0 + exp(-lambda_b*(alpha - alpha0 - alpha_s)) &
            + exp(lambda_b*(alpha - alpha0 + alpha_s))
        den = (1.0 + exp(-lambda_b*(alpha - alpha0 - alpha_s))) &
            * (1.0 + exp(lambda_b*(alpha - alpha0 + alpha_s)))
        sigma = num / den
    end function sigma_blend

    pure function stall_blend_factor(self, alpha, alpha0, alpha_s, lambda_b) result(sigma)
        class(stall_model_t), intent(in) :: self
        real, intent(in) :: alpha, alpha0, alpha_s, lambda_b
        real :: sigma
        sigma = sigma_blend(alpha, alpha0, alpha_s, lambda_b)
    end function stall_blend_factor

    pure subroutine apply_stall_model(stall, alpha, beta, CL, CD, Cm)
        type(stall_model_t), intent(in) :: stall
        real, intent(in) :: alpha, beta
        real, intent(inout) :: CL, CD, Cm
        real :: sigma

        ! lift stall - eq 3.6.62 with sideslip reduction
        sigma = stall%blend_factor(alpha, stall%CL_alpha0, stall%CL_alpha_s, stall%CL_lambda_b)
        CL = (1.0 - sigma) * CL + sigma * 2.0 * sign(1.0, alpha) * sin(alpha)**2 * cos(alpha) * cos(beta)

        ! drag stall - eq 3.6.63 with sideslip drag
        sigma = stall%blend_factor(alpha, stall%CD_alpha0, stall%CD_alpha_s, stall%CD_lambda_b)
        CD = (1.0 - sigma) * CD + sigma * (2.0 * sin(abs(alpha))**3 * cos(beta) + 0.5 * sin(abs(beta))**3)

        ! pitch moment stall - eq 3.6.64
        sigma = stall%blend_factor(alpha, stall%Cm_alpha0, stall%Cm_alpha_s, stall%Cm_lambda_b)
        Cm = (1.0 - sigma) * Cm + sigma * (stall%Cm_min * sign(1.0, alpha) * sin(alpha)**2)
    end subroutine apply_stall_model

    ! lateral beta-stall: blend side force CS and yaw moment Cn toward Newtonian flat-plate-in-
    ! sideslip forms past sideslip stall, mirroring apply_stall_model on the alpha axis. The book
    ! (Sec 3.8) sanctions lateral post-stall modifications "if known"; the shapes follow the same
    ! Newtonian basis as Eqs 3.6.62 / 3.8.1, with magnitudes left as user coefficients.
    pure subroutine apply_beta_stall(stall, beta, CS, Cn)
        type(stall_model_t), intent(in) :: stall
        real, intent(in) :: beta
        real, intent(inout) :: CS, Cn
        real :: sigma

        ! side-force stall (analog of lift stall on alpha, Eq 3.6.62)
        sigma = stall%blend_factor(beta, stall%CS_beta0, stall%CS_beta_s, stall%CS_lambda_b)
        CS = (1.0 - sigma) * CS + sigma * stall%CS_stall * sign(1.0, beta) * sin(beta)**2 * cos(beta)

        ! yaw-moment stall (analog of pitch stall on alpha, Eq 3.8.1)
        sigma = stall%blend_factor(beta, stall%Cn_beta0, stall%Cn_beta_s, stall%Cn_lambda_b)
        Cn = (1.0 - sigma) * Cn + sigma * stall%Cn_min_beta * sign(1.0, beta) * sin(beta)**2
    end subroutine apply_beta_stall

    ! apply additive stall damping for a single rate axis
    pure subroutine apply_single_rate_stall(stall, rate, rate_stall, lambda, coef_stall, coef)
        type(stall_model_t), intent(in) :: stall
        real, intent(in) :: rate, rate_stall, lambda, coef_stall
        real, intent(inout) :: coef
        real :: sigma, rate_clamped

        if (rate_stall <= 0.0) return
        sigma = stall%blend_factor(rate, 0.0, rate_stall, lambda)
        rate_clamped = max(-rate_stall, min(rate_stall, rate))
        coef = coef + sigma * coef_stall * (rate - rate_clamped)
    end subroutine apply_single_rate_stall

    ! rotation rate stall: additive restoring moments at high nondimensional rates
    ! Uses same sigmoid blending as alpha stall. When rate exceeds stall bound,
    ! a damping moment is added proportional to how far the rate exceeds the bound.
    pure subroutine apply_rate_stall_model(stall, p_bar, q_bar, r_bar, Croll, Cm, Cn)
        type(stall_model_t), intent(in) :: stall
        real, intent(in) :: p_bar, q_bar, r_bar
        real, intent(inout) :: Croll, Cm, Cn

        call apply_single_rate_stall(stall, p_bar, stall%pbar_stall, stall%lambda_pbar, stall%Cl_pbar_stall, Croll)
        call apply_single_rate_stall(stall, q_bar, stall%qbar_stall, stall%lambda_qbar, stall%Cm_qbar_stall, Cm)
        call apply_single_rate_stall(stall, r_bar, stall%rbar_stall, stall%lambda_rbar, stall%Cn_rbar_stall, Cn)
    end subroutine apply_rate_stall_model

    ! ================================================================
    ! propulsion: init_rho0
    ! ================================================================

    subroutine simple_thrust_init_rho0(self)
        class(simple_thrust_t), intent(inout) :: self
        real :: Z, T, P, a, mu
        call std_atm_english(0.0, Z, T, P, self%rho_0, a, mu)
    end subroutine simple_thrust_init_rho0

    subroutine propeller_init_rho0(self)
        class(propeller_source_t), intent(inout) :: self
        real :: Z, T, P, a, mu
        call std_atm_english(0.0, Z, T, P, self%rho_0, a, mu)
    end subroutine propeller_init_rho0

    ! ================================================================
    ! shared utility functions
    ! ================================================================

    ! evaluates a single coefficient by summing up all its terms
    pure function evaluate_group(group, state) result(val)
        type(coef_group_t), intent(in) :: group
        type(aero_state_t), intent(in) :: state
        real :: val
        real :: term_val
        integer :: i, j

        val = 0.0
        do i = 1, group%n_terms
            term_val = group%terms(i)%value
            do j = 1, group%terms(i)%n_factors
                term_val = term_val * state%values(group%terms(i)%factor(j))
            end do
            val = val + term_val
        end do
    end function evaluate_group

    ! gets CL, CS, CD, Cl, Cm, Cn by multiplying all values given by user in json
    subroutine evaluate_sd_coefficients(sd, stall, alpha, beta, p_bar, q_bar, r_bar, &
                                         alpha_hat, beta_hat, beta_flank, ctrl_values, n_ctrl, coefs)
        type(generic_coef_t), intent(in) :: sd
        type(stall_model_t), intent(in) :: stall
        real, intent(in) :: alpha, beta, p_bar, q_bar, r_bar, alpha_hat, beta_hat, beta_flank
        real, intent(in) :: ctrl_values(:)
        integer, intent(in) :: n_ctrl
        real, intent(inout) :: coefs(N_DV_MAP)   ! caller pre-zeroes; SD writes its group slots

        type(aero_state_t) :: state
        integer :: i

        state%values = 0.0

        ! standard variables
        state%values(IDX_CONST)      = 1.0
        state%values(IDX_ALPHA)      = alpha
        state%values(IDX_BETA)       = beta
        state%values(IDX_PBAR)       = p_bar
        state%values(IDX_QBAR)       = q_bar
        state%values(IDX_RBAR)       = r_bar
        state%values(IDX_ALPHAHAT)   = alpha_hat
        state%values(IDX_BETAFLANK) = beta_flank
        state%values(IDX_BETAHAT)    = beta_hat

        ! control effector values
        do i = 1, min(sd%n_ctrl, n_ctrl)
            state%values(sd%ctrl_offset + i - 1) = ctrl_values(i)
        end do

        ! custom variables
        do i = 1, sd%n_custom
            state%values(sd%custom_offset + i - 1) = evaluate_group(sd%custom(i), state)
        end do

        ! coefficient groups: 1-6 body/wind (CL,CS,CD,Cl,Cm,Cn), 7-11 stability
        ! (CLstab,CDstab,CSstab,Clstab,Cnstab). Evaluate into the pool first (so terms may reference
        ! earlier group results), then scatter each group result to its DV slot.
        do i = 1, N_GROUPS
            state%values(sd%group_offset + i - 1) = evaluate_group(sd%groups(i), state)
        end do
        do i = 1, N_GROUPS
            coefs(GROUP_TO_DV(i)) = state%values(sd%group_offset + i - 1)
        end do

        if (stall%enabled) then
            ! stall acts on the body/wind coefficients only; stability-axis coefs are taken as given
            call apply_stall_model(stall, alpha, beta, coefs(DV_CL), coefs(DV_CD), coefs(DV_CM))
            call apply_beta_stall(stall, beta, coefs(DV_CS), coefs(DV_CN))
            call apply_rate_stall_model(stall, p_bar, q_bar, r_bar, coefs(DV_CROLL), coefs(DV_CM), coefs(DV_CN))
        end if
    end subroutine evaluate_sd_coefficients

    ! computes standard aero variables from body-frame velocity and rotation rates
    pure subroutine compute_aero_vars(velocity, omega, b_ref, c_bar, &
                                       V_mag, alpha, beta, beta_flank, p_bar, q_bar, r_bar)
        real, intent(in)  :: velocity(3), omega(3)
        real, intent(in)  :: b_ref, c_bar
        real, intent(out) :: V_mag, alpha, beta, beta_flank
        real, intent(out) :: p_bar, q_bar, r_bar

        V_mag      = norm3(velocity)
        alpha      = calc_alpha(velocity)
        beta       = calc_beta(velocity)
        beta_flank = calc_beta_flank(velocity)
        call calc_nondim_rates(omega, V_mag, b_ref, c_bar, p_bar, q_bar, r_bar)
    end subroutine compute_aero_vars

    ! wind-axis coefficients to body-axis forces — table 3.4.4
    pure subroutine wind_to_body_forces(qS, CL, CD, CS, alpha, beta, Fx, Fy, Fz)
        real, intent(in)  :: qS, CL, CD, CS, alpha, beta
        real, intent(out) :: Fx, Fy, Fz

        Fx = qS * (-CD * cos(alpha) * cos(beta) &
                  - CS * cos(alpha) * sin(beta) &
                  + CL * sin(alpha))
        Fy = qS * (CS * cos(beta) - CD * sin(beta))
        Fz = qS * (-CL * cos(alpha) &
                  - CD * sin(alpha) * cos(beta) &
                  - CS * sin(alpha) * sin(beta))
    end subroutine wind_to_body_forces

    ! convert aero coefficients to body-axis forces and moments
    ! handles both wind-axis (CL/CD/CS) and body-axis (Cx/Cy/Cz) contributions
    subroutine coefs_to_forces_moments(coefs, rho, V_mag, alpha, beta, S_ref, b_ref, c_bar, F, M)
        real, intent(in) :: coefs(N_DV_MAP)
        real, intent(in) :: rho, V_mag, alpha, beta, S_ref, b_ref, c_bar
        real, intent(out) :: F(3), M(3)
        real :: q_dyn, qS, Fw(3), Fs(3), ca, sa

        q_dyn = calc_dynamic_pressure(rho, V_mag)
        qS = q_dyn * S_ref

        ! wind-axis contributions (CL, CD, CS -> body frame, table 3.4.4)
        call wind_to_body_forces(qS, coefs(DV_CL), coefs(DV_CD), coefs(DV_CS), &
                                 alpha, beta, Fw(1), Fw(2), Fw(3))

        ! stability-axis contributions: stability -> body is the wind transform at beta = 0
        ! (stability axes are body rotated by alpha only). table 3.4.4 with beta = 0.
        call wind_to_body_forces(qS, coefs(DV_CL_STAB), coefs(DV_CD_STAB), coefs(DV_CS_STAB), &
                                 alpha, 0.0, Fs(1), Fs(2), Fs(3))

        ! body-axis contributions (Cx, Cy, Cz direct) + wind + stability
        F(1) = qS * coefs(DV_CX) + Fw(1) + Fs(1)
        F(2) = qS * coefs(DV_CY) + Fw(2) + Fs(2)
        F(3) = qS * coefs(DV_CZ) + Fw(3) + Fs(3)

        ! aerodynamic moments: body + stability-axis roll/yaw rotated to body by R_y(-alpha);
        ! pitch is invariant about the shared body/stability y-axis. roll & yaw share b_ref.
        ca = cos(alpha); sa = sin(alpha)
        M(1) = qS * b_ref * (coefs(DV_CROLL) + ca * coefs(DV_CROLL_STAB) - sa * coefs(DV_CN_STAB))
        M(2) = qS * c_bar * coefs(DV_CM)
        M(3) = qS * b_ref * (coefs(DV_CN)    + sa * coefs(DV_CROLL_STAB) + ca * coefs(DV_CN_STAB))
    end subroutine coefs_to_forces_moments

    ! unpack coefs array into named outputs (used by get_coefficients methods)
    pure subroutine unpack_coefs(coefs, lift_out, side_out, drag_out, roll_out, pitch_out, yaw_out, &
                                 cx_out, cy_out, cz_out)
        real, intent(in) :: coefs(N_DV_MAP)
        real, intent(out) :: lift_out, side_out, drag_out, roll_out, pitch_out, yaw_out
        real, intent(out) :: cx_out, cy_out, cz_out

        ! report wind + stability-axis contributions summed under the same coefficient name
        lift_out  = coefs(DV_CL) + coefs(DV_CL_STAB)
        drag_out  = coefs(DV_CD) + coefs(DV_CD_STAB)
        side_out  = coefs(DV_CS) + coefs(DV_CS_STAB)
        roll_out  = coefs(DV_CROLL) + coefs(DV_CROLL_STAB)
        yaw_out   = coefs(DV_CN) + coefs(DV_CN_STAB)
        pitch_out = coefs(DV_CM)
        cx_out = coefs(DV_CX); cy_out = coefs(DV_CY); cz_out = coefs(DV_CZ)
    end subroutine unpack_coefs

    ! interpolate a single database entry and accumulate coefficients
    ! coefs(1:9) = [Cx, Cy, Cz, CL, CD, CS, Croll, Cm, Cn]
    ! DV columns with underscore factors (e.g. Cl_beta, Cx_qbar) are automatically
    ! multiplied by the corresponding state variable values before accumulating.
    subroutine interpolate_db_entry(entry, state, coefs)
        type(db_entry_t), intent(in) :: entry
        type(aero_state_t), intent(in) :: state
        real, intent(inout) :: coefs(N_DV_MAP)

        real :: iv_values(entry%n_iv)
        real :: dv_result(entry%db%n_dv)
        real :: val
        integer :: k, i

        ! build independent variable vector: state lookup + unit conversion
        do i = 1, entry%n_iv
            iv_values(i) = state%values(entry%iv_map(i)) * entry%iv_scale(i)
        end do

        ! interpolate
        dv_result = entry%db%interpolate(iv_values)

        ! accumulate each column into its DV slot, applying multiplier factors
        do k = 1, entry%db%n_dv
            if (entry%dv_columns(k)%slot == 0) cycle
            val = dv_result(k) * entry%dv_columns(k)%factors%get_product(state)
            coefs(entry%dv_columns(k)%slot) = coefs(entry%dv_columns(k)%slot) + val
        end do
    end subroutine interpolate_db_entry

    ! sphere drag coefficient from Reynolds number (eq 3.6.29)
    ! sphere drag coefficient as function of Reynolds number (Eq 3.6.29)
    ! piecewise fit to experimental data on smooth spheres [20, 23]
    pure function sphere_cd(Re) result(CD)
        real, intent(in) :: Re
        real :: CD

        if (Re < 0.01) then
            CD = 2405.0                                           ! near-zero Re singularity avoidance
        else if (Re <= 450000.0) then
            CD = 24.0/Re + 6.0/(1.0 + sqrt(Re)) + 0.4           ! subcritical regime
        else if (Re <= 560000.0) then
            CD = 1.0e29 * Re**(-5.211)                           ! drag crisis transition
        else if (Re <= 14000000.0) then
            CD = -2.0e-23*Re**3 - 1.0e-16*Re**2 + 9.0e-09*Re + 0.069  ! supercritical
        else
            CD = 0.12                                             ! high-Re asymptote
        end if
    end function sphere_cd

    ! ================================================================
    ! sd_source_t — stability derivative compute
    ! ================================================================

    ! shared coefficient evaluation for sd_source_t (used by compute and get_coefficients)
    subroutine sd_eval_coefs(self, velocity, omega, ctrl_values, n_ctrl, &
                             coefs, V_mag, alpha, beta)
        class(sd_source_t), intent(in) :: self
        real, intent(in) :: velocity(3), omega(3), ctrl_values(:)
        integer, intent(in) :: n_ctrl
        real, intent(out) :: coefs(N_DV_MAP)
        real, intent(out) :: V_mag, alpha, beta

        real :: beta_flank, p_bar, q_bar, r_bar

        call compute_aero_vars(velocity, omega, self%b_ref, self%c_bar, &
                               V_mag, alpha, beta, beta_flank, p_bar, q_bar, r_bar)

        coefs = 0.0
        call evaluate_sd_coefficients(self%sd, self%stall, alpha, beta, &
            p_bar, q_bar, r_bar, get_alpha_hat(), get_beta_hat(), beta_flank, ctrl_values, n_ctrl, &
            coefs)
    end subroutine sd_eval_coefs

    ! ================================================================
    ! aero_source_t — shared compute and get_coefficients
    ! (delegates coefficient evaluation to the deferred eval_coefs method)
    ! ================================================================

    subroutine aero_compute(self, velocity, omega, rho, mu, ctrl_values, n_ctrl, F, M)
        class(aero_source_t), intent(inout) :: self
        real, intent(in) :: velocity(3), omega(3)
        real, intent(in) :: rho, mu
        real, intent(in) :: ctrl_values(:)
        integer, intent(in) :: n_ctrl
        real, intent(out) :: F(3), M(3)

        real :: V_mag, alpha, beta
        real :: coefs(N_DV_MAP)

        call self%eval_coefs(velocity, omega, ctrl_values, n_ctrl, &
                             coefs, V_mag, alpha, beta)
        call coefs_to_forces_moments(coefs, rho, V_mag, alpha, beta, &
                                     self%S_ref, self%b_ref, self%c_bar, F, M)
    end subroutine aero_compute

    subroutine aero_get_coefficients(self, velocity, omega, ctrl_values, n_ctrl, &
                                      lift_out, side_out, drag_out, roll_out, pitch_out, yaw_out, &
                                      cx_out, cy_out, cz_out)
        class(aero_source_t), intent(in) :: self
        real, intent(in) :: velocity(3), omega(3), ctrl_values(:)
        integer, intent(in) :: n_ctrl
        real, intent(out) :: lift_out, side_out, drag_out, roll_out, pitch_out, yaw_out
        real, intent(out) :: cx_out, cy_out, cz_out

        real :: V_mag, alpha, beta
        real :: coefs(N_DV_MAP)

        call self%eval_coefs(velocity, omega, ctrl_values, n_ctrl, &
                             coefs, V_mag, alpha, beta)
        call unpack_coefs(coefs, lift_out, side_out, drag_out, roll_out, pitch_out, yaw_out, &
                          cx_out, cy_out, cz_out)
    end subroutine aero_get_coefficients

    ! ================================================================
    ! database_source_t — database aerodynamics compute
    ! ================================================================

    ! shared coefficient evaluation for database_source_t (used by compute and get_coefficients)
    ! coefs(1:9) = [Cx, Cy, Cz, CL, CD, CS, Croll, Cm, Cn]
    subroutine database_eval_coefs(self, velocity, omega, ctrl_values, n_ctrl, &
                                   coefs, V_mag, alpha, beta)
        class(database_source_t), intent(in) :: self
        real, intent(in) :: velocity(3), omega(3), ctrl_values(:)
        integer, intent(in) :: n_ctrl
        real, intent(out) :: coefs(N_DV_MAP)
        real, intent(out) :: V_mag, alpha, beta

        type(aero_state_t) :: state
        integer :: k

        call populate_aero_state(state, velocity, omega, self%b_ref, self%c_bar, &
                                 ctrl_values, n_ctrl)

        alpha = state%values(IDX_ALPHA)
        beta  = state%values(IDX_BETA)
        V_mag = norm3(velocity)

        coefs = 0.0

        do k = 1, self%db_n_entries
            call interpolate_db_entry(self%db_entries(k), state, coefs)
        end do

        ! stall models (alpha stall + lateral beta stall + rotation rate stall)
        if (self%stall%enabled) then
            call apply_stall_model(self%stall, alpha, beta, coefs(DV_CL), coefs(DV_CD), coefs(DV_CM))
            call apply_beta_stall(self%stall, beta, coefs(DV_CS), coefs(DV_CN))
            call apply_rate_stall_model(self%stall, state%values(IDX_PBAR), &
                                        state%values(IDX_QBAR), state%values(IDX_RBAR), &
                                        coefs(DV_CROLL), coefs(DV_CM), coefs(DV_CN))
        end if
    end subroutine database_eval_coefs

    ! ================================================================
    ! thrust_source_t — thrust compute
    ! ================================================================

    subroutine simple_thrust_compute(self, velocity, omega, rho, mu, ctrl_values, n_ctrl, F, M)
        class(simple_thrust_t), intent(inout) :: self
        real, intent(in) :: velocity(3), omega(3)
        real, intent(in) :: rho, mu
        real, intent(in) :: ctrl_values(:)
        integer, intent(in) :: n_ctrl
        real, intent(out) :: F(3), M(3)

        real :: eff_val, thrust_mag

        eff_val = 0.0
        if (self%effector_idx > 0 .and. self%effector_idx <= n_ctrl) then
            eff_val = ctrl_values(self%effector_idx)
        end if

        ! simple thrust model (Eq. 4.3.1): T = T0 * throttle * (rho/rho0)^Ta
        if (self%rho_0 > TOLERANCE) then
            thrust_mag = self%T0 * eff_val * (rho / self%rho_0)**self%T_alpha
        else
            thrust_mag = 0.0
        end if
        F = thrust_mag * self%direction
        M = 0.0
    end subroutine simple_thrust_compute

    ! inert mass element: contributes no aerodynamic or propulsive load. Its mass
    ! and inertia are folded into the vehicle by assemble_mass_properties (via
    ! comp_mass), so compute simply returns zero force/moment. The state arguments
    ! are mandated by the deferred compute interface but unused here (as in
    ! simple_thrust_compute, which likewise ignores velocity/omega/mu).
    subroutine mass_source_compute(self, velocity, omega, rho, mu, ctrl_values, n_ctrl, F, M)
        class(mass_source_t), intent(inout) :: self
        real, intent(in) :: velocity(3), omega(3)
        real, intent(in) :: rho, mu
        real, intent(in) :: ctrl_values(:)
        integer, intent(in) :: n_ctrl
        real, intent(out) :: F(3), M(3)

        F = 0.0
        M = 0.0
    end subroutine mass_source_compute

    subroutine propeller_compute(self, velocity, omega, rho, mu, ctrl_values, n_ctrl, F, M)
        class(propeller_source_t), intent(inout) :: self
        real, intent(in) :: velocity(3), omega(3)
        real, intent(in) :: rho, mu
        real, intent(in) :: ctrl_values(:)
        integer, intent(in) :: n_ctrl
        real, intent(out) :: F(3), M(3)

        real :: eff_val
        real :: n_rev, J, d, CT_val, CPb_val, normal_val, yaw_val
        real :: thrust, torque, P_brake, V_axial, V_perp, alpha_c
        real :: N_force, n_moment, u_N(3)

        eff_val = 0.0
        if (self%effector_idx > 0 .and. self%effector_idx <= n_ctrl) then
            eff_val = ctrl_values(self%effector_idx)
        end if

        ! Propeller aerodynamics: polynomial coefficient model
        ! Mechanics of Flight, Section 4.5
        d = self%diameter

        ! determine rotor speed from motor type
        ! effector value is in internal units (rad/s if [rpm] bracket used)
        select case (self%motor_type)
        case (MOTOR_RPM)
            n_rev = eff_val / (2.0 * PI)  ! rad/s → rev/s
        case (MOTOR_ELECTRIC)
            call electric_motor_solve(self, eff_val, velocity, rho, d, n_rev)
        case default
            n_rev = 0.0
        end select

        ! advance ratio (Phillips Eq. 4.5.7): J = V_c / (n * d)
        ! V_c = total velocity magnitude at rotor, V_axial = component along rotor axis
        V_axial = velocity(1)
        if (abs(n_rev) > TOLERANCE .and. d > TOLERANCE) then
            J = sqrt(velocity(1)**2 + velocity(2)**2 + velocity(3)**2) / (n_rev * d)
            J = max(self%J_limits(1), min(self%J_limits(2), J))
        else
            J = 0.0
        end if

        ! polynomial coefficient evaluation (Phillips Eqs. 4.5.8-4.5.11)
        CT_val  = self%CT_coef(1)  + self%CT_coef(2)*J  + self%CT_coef(3)*J**2    ! Eq. 4.5.8
        CPb_val = self%CPb_coef(1) + self%CPb_coef(2)*J + self%CPb_coef(3)*J**2   ! Eq. 4.5.9
        normal_val = self%normal_coef(1) + self%normal_coef(2)*J + self%normal_coef(3)*J**2 + self%normal_coef(4)*J**3  ! Eq. 4.5.10
        yaw_val = self%yaw_coef(1) + self%yaw_coef(2)*J + self%yaw_coef(3)*J**2 + self%yaw_coef(4)*J**3       ! Eq. 4.5.11

        ! thrust (Phillips Eq. 4.5.2): T = rho * n^2 * d^4 * CT
        thrust = rho * n_rev**2 * d**4 * CT_val

        ! brake power (Phillips Eq. 4.5.4): Pb = rho * n^3 * d^5 * CPb
        P_brake = rho * n_rev**3 * d**5 * CPb_val

        ! torque (Phillips Eq. 4.5.29): tau = Pb / (2*pi*n)
        if (abs(n_rev) > TOLERANCE) then
            torque = P_brake / (2.0 * PI * n_rev)
        else
            torque = 0.0
        end if

        ! normal force and yaw moment from angle of attack
        ! (Phillips Eqs. 4.5.5-4.5.6)
        V_perp = sqrt(velocity(2)**2 + velocity(3)**2)
        if (V_perp > TOLERANCE) then
            alpha_c = atan2(V_perp, V_axial)
            u_N = [0.0, -velocity(2), -velocity(3)] / V_perp
            N_force  = rho * n_rev**2 * d**4 * normal_val * alpha_c   ! Eq. 4.5.5
            n_moment = rho * n_rev**2 * d**5 * yaw_val * alpha_c    ! Eq. 4.5.6
        else
            N_force = 0.0
            n_moment = 0.0
            u_N = 0.0
        end if

        ! force/moment assembly in component frame
        ! (Phillips Eqs. 4.5.26, 4.5.30; delta = +1 RH, -1 LH per Eq. 4.5.31)
        F = [thrust, 0.0, 0.0] + N_force * u_N
        M = [-self%delta * torque, 0.0, 0.0] - self%delta * n_moment * u_N

        ! store runtime state for gyroscopic h and verbose output
        self%omega_current = n_rev
        self%J_current = J
        self%thrust_current = thrust
        self%torque_current = torque
        self%power_current = P_brake
        self%N_force_current = N_force
        self%n_moment_current = n_moment
        self%F_comp = F
        self%M_comp = M
        if (abs(P_brake) > TOLERANCE) then
            self%eta_current = thrust * V_axial / P_brake  ! Phillips Eq. 4.5.33
        else
            self%eta_current = 0.0
        end if
    end subroutine propeller_compute

    !---------------------------------------------------------------------------
    ! Electric motor solver (Phillips Sec 4.6, Algorithm 4.6.2)
    !
    ! Finds the equilibrium prop rev/s Ns where shaft torque (from the motor,
    ! via ESC and battery) equals the propeller torque demand.
    !
    ! Inner step (closed-form, Eqs 4.6.34-4.6.37): given throttle tau and a
    ! guess for Ns, solves a quadratic for motor current Im (Eq 4.6.34), then
    ! Em (Eq 4.6.28), tau_m (Eq 4.6.7), and shaft torque tau_s (Eq 4.6.11)
    ! directly.
    ! Outer loop: bisects F(Ns) = tau_s(Ns) - tau_prop(Ns) on the bracket
    ! [0, Kv*Eb0/Gm]. F is monotonically decreasing: motor torque drops with
    ! Ns (back-EMF rises, Im falls, clamped at zero above no-load) while
    ! propeller torque grows as Ns^2. A single sign change guarantees
    ! convergence.
    !
    ! `gear_ratio` follows the textbook convention Gm = Nm/Ns (motor rpm per
    ! prop rpm). For direct drive Gm = 1; for a 4:1 reduction Gm = 4.
    !---------------------------------------------------------------------------
    subroutine electric_motor_solve(self, throttle, velocity, rho, d, n_rev_out)
        type(propeller_source_t), intent(inout) :: self
        real, intent(in) :: throttle       ! [0..1]
        real, intent(in) :: velocity(3)    ! component-frame velocity [ft/s]
        real, intent(in) :: rho            ! air density [slug/ft^3]
        real, intent(in) :: d              ! propeller diameter [ft]
        real, intent(out) :: n_rev_out     ! propeller rev/s

        real :: tau, eta_c, Eb0, Rb, Rm, Rc, Kv, Gm, eta_g, I_0, kT_loc
        real :: V_mag, K_prop, tau_Eb0
        real :: Ns, Ns_lo, Ns_hi, F, F_lo, F_hi
        real :: Im, Em, tau_s
        real :: Eb, Ib, disc_b
        integer :: it
        logical :: converged

        ! guard: missing battery or fully depleted
        if (.not. associated(self%battery_ptr)) then
            n_rev_out = 0.0
            return
        end if
        if (self%battery_ptr%SOC <= 0.0) then
            n_rev_out = 0.0
            self%I_motor_current = 0.0
            self%V_motor_current = 0.0
            self%P_electric_current = 0.0
            return
        end if

        tau = max(0.0, min(1.0, throttle))

        ! guard: zero throttle -> no torque, no rotation
        if (tau < TOLERANCE) then
            n_rev_out = 0.0
            self%omega_current = 0.0
            self%I_motor_current = 0.0
            self%V_motor_current = 0.0
            self%P_electric_current = 0.0
            self%I_battery_current = 0.0
            return
        end if

        ! cache battery / motor / ESC parameters
        Eb0    = self%battery_ptr%open_circuit_voltage()   ! Eq 4.6.2
        Rb     = self%battery_ptr%R_pack
        Rm     = self%R_motor
        Rc     = self%R_esc
        Kv     = self%kV                                    ! [rev/s/V]
        Gm     = self%gear_ratio                            ! textbook Gm = Nm/Ns
        eta_g  = self%eta_gear
        I_0    = self%I_0
        kT_loc = self%kT

        eta_c   = 1.0 - 0.078 * (1.0 - tau)                 ! Eq 4.6.14
        V_mag   = sqrt(velocity(1)**2 + velocity(2)**2 + velocity(3)**2)
        K_prop  = rho * d**5 / (2.0 * PI)                   ! rho*d^5/(2*pi)
        tau_Eb0 = tau * Eb0

        ! establish bracket [Ns_lo, Ns_hi] for bisection
        !   At Ns=0:        F > 0 (motor drives short-circuit current; prop torque 0)
        !   At Ns=Kv*Eb0/Gm (no-load): motor current ~ 0, F < 0
        Ns_lo = 0.0
        Ns_hi = Kv * Eb0 / Gm
        call solve_inner(Ns_lo, Im, Em, tau_s, F_lo)
        call solve_inner(Ns_hi, Im, Em, tau_s, F_hi)

        ! In the pathological case F_lo <= 0, the rotor is unstable at rest;
        ! return zero state. In the pathological case F_hi >= 0, something
        ! is far off (Im0 negative, unphysical CPb); take the upper bound.
        if (F_lo <= 0.0) then
            Ns = 0.0
            call solve_inner(Ns, Im, Em, tau_s, F)
            converged = .true.
        else if (F_hi >= 0.0) then
            Ns = Ns_hi
            call solve_inner(Ns, Im, Em, tau_s, F)
            converged = .true.
        else
            converged = .false.
            do it = 1, self%elec_max_iter
                Ns = 0.5 * (Ns_lo + Ns_hi)
                call solve_inner(Ns, Im, Em, tau_s, F)
                if (abs(F) < self%elec_tol) then
                    converged = .true.
                    exit
                end if
                if (F > 0.0) then
                    Ns_lo = Ns
                else
                    Ns_hi = Ns
                end if
            end do
        end if

        if (.not. converged) then
            write(*,*) 'WARNING: Electric motor solver did not converge for ', trim(self%name)
        end if

        ! battery-side voltage and current (Eqs 4.6.32, 4.6.3):
        ! account for ESC power conversion Em*Im = eta_c*Eb*Ib so that battery
        ! SOC depletion uses the correct current (generally less than Im).
        disc_b = Eb0*Eb0 - 4.0 * (Rb / eta_c) * Em * Im
        if (disc_b < 0.0 .or. Rb <= 0.0) then
            Eb = Eb0
            Ib = Em * Im / max(eta_c * Eb0, TOLERANCE)
        else
            Eb = 0.5 * (Eb0 + sqrt(disc_b))                         ! Eq 4.6.32
            Ib = (Eb0 - Eb) / Rb                                     ! Eq 4.6.3 rearranged
        end if

        ! ESC overcurrent (Table 4.6.3) -- warn once per source
        if (Im > self%Ic_max .and. .not. self%ic_warn_issued) then
            write(*,'(A,A,A,ES12.4,A,ES12.4,A)') &
                'WARNING: ESC overcurrent in "', trim(self%name), &
                '" (Im=', Im, ' A, Ic_max=', self%Ic_max, &
                ' A). Further warnings suppressed.'
            self%ic_warn_issued = .true.
        end if

        ! store results (omega_current in prop rev/s for gyroscopic h and warm-start)
        n_rev_out               = Ns
        self%omega_current      = Ns
        self%I_motor_current    = Im
        self%V_motor_current    = Em
        self%P_electric_current = Em * Im
        self%I_battery_current  = Ib

    contains

        !-----------------------------------------------------------------------
        ! Inner closed-form solve: at a given prop rev/s Ns, compute motor
        ! current Im (Eq 4.6.34), motor voltage Em (Eq 4.6.28), shaft torque
        ! tau_s (Eqs 4.6.7+4.6.11), and the prop-balance residual
        ! F = tau_s - tau_prop.
        !-----------------------------------------------------------------------
        subroutine solve_inner(Ns_in, Im_out, Em_out, tau_s_out, F_out)
            real, intent(in)  :: Ns_in
            real, intent(out) :: Im_out, Em_out, tau_s_out, F_out

            real :: Nm, Nm_over_Kv, Aq, Bq, Cq, disc
            real :: tau_m_loc, J_loc, CPb_loc, tau_prop_loc

            Nm         = Gm * Ns_in                                  ! Eq 4.6.9
            Nm_over_Kv = Nm / Kv                                      ! [V]

            Aq   = (Rm + Rc)**2 + tau**2 * Rb * Rm / eta_c             ! Eq 4.6.35
            Bq   = (2.0*Nm_over_Kv - tau_Eb0)*(Rm + Rc) &
                   + tau**2 * Rb * Nm_over_Kv / eta_c                  ! Eq 4.6.36
            Cq   = Nm_over_Kv * (Nm_over_Kv - tau_Eb0)                 ! Eq 4.6.37

            disc = Bq*Bq - 4.0*Aq*Cq
            if (disc < 0.0) then
                Im_out = 0.0                                          ! infeasible: no net current
            else
                Im_out = (-Bq + sqrt(disc)) / (2.0*Aq)                ! Eq 4.6.34 (larger root)
                if (Im_out < 0.0) Im_out = 0.0                        ! ESC is unidirectional
            end if

            Em_out    = Nm_over_Kv + Im_out * Rm                       ! Eq 4.6.28
            tau_m_loc = (Im_out - I_0) * kT_loc                        ! Eq 4.6.7
            tau_s_out = eta_g * Gm * tau_m_loc                         ! Eq 4.6.11

            if (Ns_in > TOLERANCE .and. d > TOLERANCE) then
                J_loc = V_mag / (Ns_in * d)
                J_loc = max(self%J_limits(1), min(self%J_limits(2), J_loc))
            else
                J_loc = 0.0
            end if
            CPb_loc      = self%CPb_coef(1) + self%CPb_coef(2)*J_loc + self%CPb_coef(3)*J_loc**2
            tau_prop_loc = CPb_loc * Ns_in*Ns_in * K_prop

            F_out = tau_s_out - tau_prop_loc
        end subroutine solve_inner
    end subroutine electric_motor_solve

    ! ================================================================
    ! sphere_source_t — sphere/ellipsoid aerodynamic drag
    ! Section 3.6 "Sphere" (Eqs 3.6.26-3.6.29)
    ! For ellipsoids (rx /= ry /= rz): projected cross-section normal to flow
    ! is used for S_ref; equivalent radius r_eq = sqrt(S/pi) for Re.
    ! Sphere C_D correlation applied (conservative for elongated shapes).
    ! ================================================================

    subroutine sphere_compute(self, velocity, omega, rho, mu, ctrl_values, n_ctrl, F, M)
        class(sphere_source_t), intent(inout) :: self
        real, intent(in) :: velocity(3), omega(3)
        real, intent(in) :: rho, mu
        real, intent(in) :: ctrl_values(:)
        integer, intent(in) :: n_ctrl
        real, intent(out) :: F(3), M(3)

        real :: V_mag, u_c(3), S_ref, r_eq, Re, CD_val, q_dyn

        V_mag = norm3(velocity)

        if (V_mag > TOLERANCE) then
            ! unit velocity vector: u_c = V_c / V_c  (Eq 3.6.3)
            u_c = velocity / V_mag

            ! projected cross-sectional area of ellipsoid normal to flow
            ! for a sphere (rx=ry=rz=r): S_ref = pi*r^2 regardless of direction
            ! for an ellipsoid: S = pi * sqrt((ry*rz*ux)^2 + (rx*rz*uy)^2 + (rx*ry*uz)^2)
            S_ref = PI * sqrt((self%ry * self%rz * u_c(1))**2 &
                            + (self%rx * self%rz * u_c(2))**2 &
                            + (self%rx * self%ry * u_c(3))**2)

            ! equivalent radius for Reynolds number
            r_eq = sqrt(S_ref / PI)

            ! Re = 2*rho*V_c*r / mu  (Eq 3.6.28)
            if (mu > TOLERANCE) then
                Re = 2.0 * rho * V_mag * r_eq / mu
            else
                Re = 0.0
            end if

            ! Reynolds-dependent C_D (Eq 3.6.29, piecewise fit)
            CD_val = sphere_cd(Re)

            ! F_c = -1/2 * rho * V_c^2 * S_ref * C_D * u_c  (Eq 3.6.27)
            q_dyn = calc_dynamic_pressure(rho, V_mag)
            F = -q_dyn * S_ref * CD_val * u_c
        else
            F = 0.0
        end if

        ! M_c = 0 for sphere (Eq 3.6.26)
        M = 0.0
    end subroutine sphere_compute

    ! ================================================================
    ! cylinder_source_t — cylinder/frustum aerodynamic forces
    ! Section 3.6 "Cylinder" (Eqs 3.6.12-3.6.25)
    ! Cylinder axis is along component x-axis. For frustums (r1 /= r2),
    ! average radius is used for reference area and Reynolds number.
    ! ================================================================

    ! cylinder cross-flow drag coefficient as function of Reynolds number (Eq 3.6.21)
    ! piecewise fit to experimental data [20, 23]
    pure function cylinder_cd0(Re) result(CD0)
        real, intent(in) :: Re
        real :: CD0

        if (Re < 0.01) then
            CD0 = 430.0                                              ! near-zero Re avoidance
        else if (Re <= 330000.0) then
            CD0 = 1.18 + 6.8/Re**0.89 + 1.96/sqrt(Re) &
                  - 0.0004*Re/(1.0 + 3.64e-7*Re**2)                 ! subcritical
        else if (Re <= 460000.0) then
            CD0 = 3.78e-11*Re**2 - 3.56e-5*Re + 8.7634              ! drag crisis
        else if (Re <= 10000000.0) then
            CD0 = -5.0e-15*Re**2 + 7.0e-8*Re + 0.346                ! supercritical
        else
            CD0 = 0.55                                               ! high-Re asymptote
        end if
    end function cylinder_cd0

    subroutine cylinder_compute(self, velocity, omega, rho, mu, ctrl_values, n_ctrl, F, M)
        class(cylinder_source_t), intent(inout) :: self
        real, intent(in) :: velocity(3), omega(3)
        real, intent(in) :: rho, mu
        real, intent(in) :: ctrl_values(:)
        integer, intent(in) :: n_ctrl
        real, intent(out) :: F(3), M(3)

        real :: V_mag, u_c(3), alpha_c, V_n, r_avg, S_ref
        real :: Re, CD0_val, CL_val, CD_val, q_n, L_force, D_force
        real :: u_D(3), v_L(3), u_L(3), v_L_mag

        V_mag = norm3(velocity)

        if (V_mag > TOLERANCE) then
            ! unit velocity vector: u_c = V_c / V_c  (Eq 3.6.3)
            u_c = velocity / V_mag

            ! angle of attack of cylinder: alpha_c = acos(u_cx)  (Eq 3.6.13)
            ! cylinder axis is along x in component frame
            alpha_c = acos(max(-1.0, min(1.0, u_c(1))))

            ! normal velocity: V_n = V_c * sin(alpha_c)  (Eq 3.6.14)
            V_n = V_mag * sin(alpha_c)

            ! average radius for frustum (r1=r2 for plain cylinder)
            r_avg = 0.5 * (self%r1 + self%r2)

            ! reference area normal to axis: S_ref = 2*r*h  (Eq 3.6.15)
            S_ref = 2.0 * r_avg * self%length

            ! Reynolds number based on cross-flow: Re = 2*rho*V_n*r / mu  (Eq 3.6.20)
            if (V_n > TOLERANCE .and. mu > TOLERANCE) then
                Re = 2.0 * rho * V_n * r_avg / mu
            else
                Re = 0.0
            end if

            ! cross-flow drag coefficient (Eq 3.6.21)
            CD0_val = cylinder_cd0(Re)

            ! lift and drag coefficients (Eqs 3.6.18-3.6.19)
            CL_val = CD0_val * sin(alpha_c)**2 * cos(alpha_c)     ! Eq 3.6.18
            CD_val = CD0_val * sin(alpha_c)**3 + 0.02              ! Eq 3.6.19

            ! dynamic pressure based on normal velocity (Eqs 3.6.16-3.6.17)
            q_n = calc_dynamic_pressure(rho, V_n)
            L_force = q_n * S_ref * CL_val                         ! Eq 3.6.16
            D_force = q_n * S_ref * CD_val                         ! Eq 3.6.17

            ! unit vector in direction of drag: u_D = -u_c  (Eq 3.6.23)
            u_D = -u_c

            ! unit vector in direction of lift (Eqs 3.6.24-3.6.25)
            ! v_L = u_D x ([1,0,0] x u_D)
            v_L = cross3(u_D, cross3([1.0, 0.0, 0.0], u_D))
            v_L_mag = norm3(v_L)
            if (v_L_mag > TOLERANCE) then
                u_L = v_L / v_L_mag                                 ! Eq 3.6.24
            else
                u_L = [0.0, 0.0, 0.0]  ! pure axial flow, no lift direction
            end if

            ! total force in component frame: F_c = D*u_D + L*u_L  (Eq 3.6.22)
            F = D_force * u_D + L_force * u_L
        else
            F = 0.0
        end if

        ! M_c approx 0 for symmetric cylinder (Eq 3.6.12)
        M = 0.0
    end subroutine cylinder_compute

    pure function cylinder_get_S_ref(self) result(val)
        class(cylinder_source_t), intent(in) :: self
        real :: val
        ! reference area normal to axis (Eq 3.6.15)
        val = (self%r1 + self%r2) * self%length
    end function cylinder_get_S_ref

    ! ================================================================
    ! wing_source_t — wing segment aerodynamic forces and moments
    ! Section 3.6 "Wing Segment" (Eqs 3.6.30-3.6.65)
    ! Wing semispan along component y-axis, chord along x-axis.
    ! Forces act in the x-z plane of the wing coordinate system.
    ! ================================================================

    subroutine wing_compute(self, velocity, omega, rho, mu, ctrl_values, n_ctrl, F, M)
        class(wing_source_t), intent(inout) :: self
        real, intent(in) :: velocity(3), omega(3)
        real, intent(in) :: rho, mu
        real, intent(in) :: ctrl_values(:)
        integer, intent(in) :: n_ctrl
        real, intent(out) :: F(3), M(3)

        real :: F_half(3), M_half(3), v_dihedral(3), q_dihedral(4)
        real :: delta_c, y_ac, ac_half(3), F_c(3), M_c(3)

        ! get control surface deflection (before side-dependent sign flip)
        delta_c = 0.0
        if (self%ctrl_idx > 0 .and. self%ctrl_idx <= n_ctrl) then
            delta_c = ctrl_values(self%ctrl_idx)
        end if

        ! spanwise root->AC distance magnitude for each half (Eq 3.6.33). recompute_source_geometry
        ! zeroes ac_local(2) for side==0, so it is rebuilt here; the +/- y sign is applied per half.
        if (self%root_chord + self%tip_chord > TOLERANCE) then
            y_ac = self%semispan / 3.0 &
                 * (self%root_chord + 2.0*self%tip_chord) / (self%root_chord + self%tip_chord)
        else
            y_ac = 0.0
        end if

        if (self%side == 0) then
            ! side = "both": each half is a panel tilted by the dihedral about the component x-axis.
            ! Solve each half in its OWN tilted frame (velocity rotated in), then rotate its force,
            ! pitching moment, and AC position BACK to the component frame and add the spanwise moment
            ! arm about the component origin. dynamics_m already adds cross3(src%location, F), so
            ! src%location must NOT appear here. CONVENTION: positive self%dihedral = tips UP; with
            ! z-down that rotates the RIGHT half by -dihedral and the LEFT half by +dihedral.

            ! --- right half (tips up: -dihedral about +x) ---
            q_dihedral = euler_to_quat([-self%dihedral, 0.0, 0.0])
            v_dihedral = quat_rotate_inertial_to_body(velocity, q_dihedral)
            call wing_compute_half(self, v_dihedral, rho, delta_c, 1, F_half, M_half)
            F_c = quat_rotate_body_to_inertial(F_half, q_dihedral)
            M_c = quat_rotate_body_to_inertial(M_half, q_dihedral)
            ac_half = quat_rotate_body_to_inertial([self%ac_local(1), y_ac, 0.0], q_dihedral)
            F = F_c
            M = M_c + cross3(ac_half, F_c)

            ! --- left half (+dihedral about +x; control sign flips inside wing_compute_half) ---
            q_dihedral = euler_to_quat([self%dihedral, 0.0, 0.0])
            v_dihedral = quat_rotate_inertial_to_body(velocity, q_dihedral)
            call wing_compute_half(self, v_dihedral, rho, delta_c, -1, F_half, M_half)
            F_c = quat_rotate_body_to_inertial(F_half, q_dihedral)
            M_c = quat_rotate_body_to_inertial(M_half, q_dihedral)
            ac_half = quat_rotate_body_to_inertial([self%ac_local(1), -y_ac, 0.0], q_dihedral)
            F = F + F_c
            M = M + M_c + cross3(ac_half, F_c)
        else
            ! single side: dihedral handled by the component orientation set by the user. ac_local
            ! already carries the correct +/- y sign (delta = side); add its moment arm about the
            ! component origin (previously unused -> the AC-offset moment was dropped).
            call wing_compute_half(self, velocity, rho, delta_c, self%side, F_half, M_half)
            F = F_half
            M = M_half + cross3(self%ac_local, F_half)
        end if
    end subroutine wing_compute

    ! compute forces/moments for one wing half
    ! side_sign: +1 = right, -1 = left (controls antisymmetric sign flip)
    subroutine wing_compute_half(self, velocity, rho, delta_c_in, side_sign, F, M)
        class(wing_source_t), intent(in) :: self
        real, intent(in) :: velocity(3), rho, delta_c_in
        integer, intent(in) :: side_sign
        real, intent(out) :: F(3), M(3)

        real :: V_cx, V_cz, V_w, u_wx, u_wz, alpha_w
        real :: q_dyn, delta_c, CL_a
        real :: CL_sub, CD_sub, Cm_sub
        real :: CL_stall, CD_stall, Cm_stall
        real :: sigma, CL_val, CD_val, Cm_val
        real :: L_force, D_force, m_moment
        real :: u_D(3), u_L(3)

        ! wing velocity: only x-z plane of component velocity (Eq 3.6.38)
        V_cx = velocity(1)
        V_cz = velocity(3)
        ! wing velocity magnitude (Eq 3.6.40)
        V_w = sqrt(V_cx**2 + V_cz**2)

        if (V_w < TOLERANCE .or. self%S_w < TOLERANCE .or. self%R_A < TOLERANCE) then
            F = 0.0
            M = 0.0
            return
        end if

        ! wing velocity unit vector (Eq 3.6.39)
        u_wx = V_cx / V_w
        u_wz = V_cz / V_w

        ! angle of attack in wing frame (Eq 3.6.49)
        alpha_w = atan2(u_wz, u_wx)

        ! dynamic pressure
        q_dyn = calc_dynamic_pressure(rho, V_w)

        ! control surface deflection with antisymmetric sign flip for left wing
        delta_c = delta_c_in
        if (self%antisymmetric .and. side_sign < 0) delta_c = -delta_c

        ! lift slope: use provided value or compute from aspect ratio (Eq 3.6.51)
        ! CL_alpha = 2*pi*R_A / (2 + sqrt(4 + R_A^2*(1 + tan^2(Lambda_c/4))))
        if (self%CL_alpha > TOLERANCE) then
            CL_a = self%CL_alpha
        else
            CL_a = 2.0 * PI * self%R_A &
                 / (2.0 + sqrt(4.0 + self%R_A**2 * (1.0 + tan(self%sweep)**2)))
        end if

        ! --- sub-stall coefficients ---

        ! lift coefficient (Eq 3.6.50)
        CL_sub = CL_a * (alpha_w - self%alpha_L0 + self%eps_c * delta_c)

        ! drag coefficient: drag polar (Eq 3.6.54)
        CD_sub = self%CD0 + self%CD1 * CL_sub &
               + CL_sub**2 / (PI * self%e_O * self%R_A)

        ! pitching moment coefficient (Eq 3.6.55)
        Cm_sub = self%Cm0 + self%Cm_alpha * alpha_w + self%Cm_dc * delta_c

        ! --- above-stall coefficients (Newtonian flat-plate theory) ---

        CL_stall = 2.0 * sign(1.0, alpha_w) * sin(alpha_w)**2 * cos(alpha_w)   ! Eq 3.6.59
        CD_stall = 2.0 * sin(abs(alpha_w))**3                                    ! Eq 3.6.60
        Cm_stall = -0.5 * sign(1.0, alpha_w) * sin(alpha_w)**2                   ! Eq 3.6.61

        ! --- stall blending (Eq 3.6.65) ---
        sigma = sigma_blend(alpha_w, self%alpha_0_stall, self%alpha_s_stall, self%lambda_b_stall)

        ! blended coefficients (Eqs 3.6.62-3.6.64)
        CL_val = (1.0 - sigma) * CL_sub + sigma * CL_stall
        CD_val = (1.0 - sigma) * CD_sub + sigma * CD_stall
        Cm_val = (1.0 - sigma) * Cm_sub + sigma * Cm_stall

        ! --- forces and moments in wing frame ---

        ! lift, drag, and moment magnitudes (Eqs 3.6.46-3.6.48)
        L_force = q_dyn * self%S_w * CL_val
        D_force = q_dyn * self%S_w * CD_val
        m_moment = q_dyn * self%S_w * self%mean_chord * Cm_val

        ! drag unit vector: u_D = -u_w  (Eq 3.6.41)
        u_D = [-u_wx, 0.0, -u_wz]

        ! lift unit vector: u_L = u_D x [0,1,0]  (Eq 3.6.42)
        u_L = [u_wz, 0.0, -u_wx]

        ! total force in wing frame: F = D*u_D + L*u_L  (Eq 3.6.44)
        F = D_force * u_D + L_force * u_L

        ! moment about aerodynamic center: M = m * u_m  (Eq 3.6.45)
        ! u_m = [0, 1, 0]  (Eq 3.6.43)
        M = [0.0, m_moment, 0.0]
    end subroutine wing_compute_half

    pure function wing_get_S_ref(self) result(val)
        class(wing_source_t), intent(in) :: self
        real :: val
        val = self%S_w  ! planform area (Eq 3.6.30)
    end function wing_get_S_ref

    pure function wing_get_b_ref(self) result(val)
        class(wing_source_t), intent(in) :: self
        real :: val
        val = self%semispan  ! semispan
    end function wing_get_b_ref

    pure function wing_get_c_bar(self) result(val)
        class(wing_source_t), intent(in) :: self
        real :: val
        val = self%mean_chord  ! mean chord (Eq 3.6.31)
    end function wing_get_c_bar

    ! ================================================================
    ! cuboid_source_t — rectangular cuboid aerodynamic drag
    ! Section 3.6 "Rectangular Cuboid" (Eqs 3.6.8-3.6.11)
    ! ================================================================

    subroutine cuboid_compute(self, velocity, omega, rho, mu, ctrl_values, n_ctrl, F, M)
        class(cuboid_source_t), intent(inout) :: self
        real, intent(in) :: velocity(3), omega(3)
        real, intent(in) :: rho, mu
        real, intent(in) :: ctrl_values(:)
        integer, intent(in) :: n_ctrl
        real, intent(out) :: F(3), M(3)

        real :: V_mag, u_c(3), S_ref, q_dyn

        V_mag = norm3(velocity)

        if (V_mag > TOLERANCE) then
            ! unit velocity vector in component frame: u_c = V_c / V_c  (Eq 3.6.3)
            u_c = velocity / V_mag

            ! velocity-direction-dependent reference area (Eq 3.6.10)
            ! S_ref = [ly*lz, lx*lz, lx*ly] . [|u_cx|, |u_cy|, |u_cz|]
            S_ref = self%ly * self%lz * abs(u_c(1)) &
                  + self%lx * self%lz * abs(u_c(2)) &
                  + self%lx * self%ly * abs(u_c(3))

            ! aerodynamic force: F_c = -1/2 * rho * V_c^2 * S_ref * C_D * u_c  (Eq 3.6.9)
            ! C_D = 1.05 for bluff body (Eq 3.6.11)
            q_dyn = calc_dynamic_pressure(rho, V_mag)
            F = -q_dyn * S_ref * self%CD * u_c
        else
            F = 0.0
        end if

        ! M_c approx 0 for symmetric cuboid (Eq 3.6.8)
        M = 0.0
    end subroutine cuboid_compute

    ! ================================================================
    ! driving model implementations
    ! ================================================================

    function polynomial_evaluate(self, state) result(C_drive)
        class(polynomial_driving_t), intent(in) :: self
        type(aero_state_t), intent(in) :: state
        real :: C_drive
        C_drive = evaluate_group(self%driving_coef, state)
    end function polynomial_evaluate

    function database_driving_evaluate(self, state) result(C_drive)
        class(database_driving_t), intent(in) :: self
        type(aero_state_t), intent(in) :: state
        real :: C_drive

        integer :: k, i
        real :: iv_values(size(self%iv_work))
        real :: dv_result(size(self%dv_work))

        C_drive = 0.0
        if (self%driving_db_n == 0) return

        do k = 1, self%driving_db_n
            associate(entry => self%driving_dbs(k))

            ! build IV values from state (state indices + unit scales)
            do i = 1, entry%n_iv
                iv_values(i) = state%values(entry%iv_map(i)) * entry%iv_scale(i)
            end do

            dv_result(1:entry%db%n_dv) = entry%db%interpolate(iv_values(1:entry%n_iv))
            if (entry%dv_index > 0) C_drive = C_drive + dv_result(entry%dv_index)

            end associate
        end do
    end function database_driving_evaluate

    ! recompute derived geometry for all sources that have variable parameters
    ! called after equations update geometric fields (semispan, chord, etc.)
    subroutine recompute_source_geometry(sources, n_sources)
        type(force_source_wrapper_t), intent(inout) :: sources(:)
        integer, intent(in) :: n_sources

        integer :: j
        real :: delta

        do j = 1, n_sources
            associate(src => sources(j)%src)

            ! recompute orientation quaternion from (possibly updated) Euler angles
            src%orientation = euler_to_quat(src%orientation_euler)
            src%has_orientation = &
                abs(src%orientation(1) - 1.0) > 1.0e-10 .or. &
                abs(src%orientation(2)) > 1.0e-10 .or. &
                abs(src%orientation(3)) > 1.0e-10 .or. &
                abs(src%orientation(4)) > 1.0e-10

            ! recompute component mass from weight and enforce inertia symmetry
            if (src%comp_mass%has_mass) then
                src%comp_mass%mass = src%comp_mass%weight_lbf / (G_SSL_SI * M_TO_FT)
                src%comp_mass%I(2,1) = src%comp_mass%I(1,2)
                src%comp_mass%I(3,1) = src%comp_mass%I(1,3)
                src%comp_mass%I(3,2) = src%comp_mass%I(2,3)
            end if

            end associate

            ! type-specific derived quantities
            select type (src => sources(j)%src)
            type is (wing_source_t)
                ! recompute derived quantities from (possibly updated) geometry
                ! Eqs 3.6.30-3.6.35
                src%mean_chord = (src%root_chord + src%tip_chord) / 2.0
                src%S_w = src%semispan * src%mean_chord
                if (src%mean_chord > TOLERANCE) then
                    src%R_A = src%semispan / src%mean_chord
                else
                    src%R_A = 0.0
                end if

                ! aerodynamic center
                delta = real(src%side)
                if (src%root_chord + src%tip_chord > TOLERANCE) then
                    src%ac_local(1) = -src%semispan / 3.0 &
                        * (src%root_chord + 2.0*src%tip_chord) &
                        / (src%root_chord + src%tip_chord) &
                        * tan(src%sweep)
                    src%ac_local(2) = delta * src%semispan / 3.0 &
                        * (src%root_chord + 2.0*src%tip_chord) &
                        / (src%root_chord + src%tip_chord)
                    src%ac_local(3) = 0.0
                else
                    src%ac_local = 0.0
                end if

            class default
                continue
            end select
        end do
    end subroutine recompute_source_geometry

end module force_source_m