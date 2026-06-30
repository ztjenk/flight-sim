! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! unified aerodynamic state variable system
! provides a single named-value array for all aero variables, control effectors,
! and passive effectors. replaces the dual pool/DB_IV index systems with one
! index space. ind_var_t and dep_var_t implement the underscore-as-multiplier
! pattern (e.g., "Cl_beta" = Cl * beta) used by both database and SD systems.
module aero_state_m
    use constants_m
    use math_m
    implicit none
    private

    public :: aero_state_t, ind_var_t, dep_var_t
    public :: MAX_STATE_VARS, N_STD_VARS
    public :: IDX_CONST, IDX_ALPHA, IDX_BETA, IDX_PBAR, IDX_QBAR, IDX_RBAR
    public :: IDX_ALPHAHAT, IDX_BETAFLANK, IDX_BETAHAT
    public :: populate_aero_state, split_on_char
    public :: set_alpha_hat, get_alpha_hat, set_beta_hat, get_beta_hat

    ! state layout constants
    integer, parameter :: MAX_STATE_VARS = 64
    integer, parameter :: N_STD_VARS     = 9

    ! standard variable slot indices
    integer, parameter :: IDX_CONST      = 1
    integer, parameter :: IDX_ALPHA      = 2
    integer, parameter :: IDX_BETA       = 3
    integer, parameter :: IDX_PBAR       = 4
    integer, parameter :: IDX_QBAR       = 5
    integer, parameter :: IDX_RBAR       = 6
    integer, parameter :: IDX_ALPHAHAT   = 7
    integer, parameter :: IDX_BETAFLANK = 8
    integer, parameter :: IDX_BETAHAT    = 9

    ! current dimensionless alpha-dot (Eq 3.4.20), set once per timestep by the dynamics engine and
    ! read when building the aero state. Module-scoped because the per-source compute interface does
    ! not carry it; the sim advances one vehicle at a time, so a single shared value is safe.
    real :: g_alpha_hat = 0.0

    ! current dimensionless beta-dot (Eq 3.4.21 = beta_dot*b/(2V)), set once per timestep by the
    ! dynamics engine (exact parallel to g_alpha_hat above).
    real :: g_beta_hat = 0.0

    ! flat named-value array. index-based O(1) access at runtime.
    ! name resolution happens once at init time via resolve_state_index (in vehicle_io_m).
    type :: aero_state_t
        real :: values(MAX_STATE_VARS) = 0.0
        integer :: n = 0   ! number of active slots
    contains
        procedure :: get => state_get
        procedure :: set => state_set
    end type aero_state_t

    ! independent variable reference: state index + unit conversion factor.
    ! initialized once from a variable name at JSON parse time.
    ! at runtime, get(state) returns state%values(idx) * cf.
    type :: ind_var_t
        integer :: idx = 0     ! index into aero_state_t%values
        real    :: cf = 1.0    ! conversion factor (unit scaling)
    contains
        procedure :: get => iv_get
    end type ind_var_t

    ! dependent variable multiplier: zero or more ind_var_t factors.
    ! e.g., "Cl_beta_pbar" has factors=[beta, pbar].
    ! get_product(state) returns product of all factor values.
    type :: dep_var_t
        integer :: n_factors = 0
        type(ind_var_t), allocatable :: factors(:)
    contains
        procedure :: get_product => dv_get_product
    end type dep_var_t

contains

    ! ================================================================
    ! aero_state_t methods
    ! ================================================================

    pure function state_get(self, idx) result(val)
        class(aero_state_t), intent(in) :: self
        integer, intent(in) :: idx
        real :: val
        val = self%values(idx)
    end function state_get

    pure subroutine state_set(self, idx, val)
        class(aero_state_t), intent(inout) :: self
        integer, intent(in) :: idx
        real, intent(in) :: val
        self%values(idx) = val
    end subroutine state_set

    ! ================================================================
    ! ind_var_t methods
    ! ================================================================

    pure function iv_get(self, state) result(val)
        class(ind_var_t), intent(in) :: self
        type(aero_state_t), intent(in) :: state
        real :: val
        val = state%values(self%idx) * self%cf
    end function iv_get

    ! ================================================================
    ! dep_var_t methods
    ! ================================================================

    pure function dv_get_product(self, state) result(val)
        class(dep_var_t), intent(in) :: self
        type(aero_state_t), intent(in) :: state
        real :: val
        integer :: i
        val = 1.0
        do i = 1, self%n_factors
            val = val * self%factors(i)%get(state)
        end do
    end function dv_get_product

    ! ================================================================
    ! utilities
    ! ================================================================

    ! populate an aero_state_t with standard aero variables and control values
    ! computed from body-frame velocity, angular velocity, and reference geometry.
    ! slots 1-8 = standard vars, slots 9..8+n_ctrl = control/passive values.
    subroutine populate_aero_state(state, velocity, omega, b_ref, c_bar, &
                                        ctrl_values, n_ctrl)
        type(aero_state_t), intent(out) :: state
        real, intent(in) :: velocity(3), omega(3)
        real, intent(in) :: b_ref, c_bar
        real, intent(in) :: ctrl_values(:)
        integer, intent(in) :: n_ctrl

        real :: V_mag, alpha, beta, beta_flank, p_bar, q_bar, r_bar
        integer :: i

        ! compute aero variables
        V_mag      = norm3(velocity)
        alpha      = calc_alpha(velocity)
        beta       = calc_beta(velocity)
        beta_flank = calc_beta_flank(velocity)
        call calc_nondim_rates(omega, V_mag, b_ref, c_bar, p_bar, q_bar, r_bar)

        ! standard variable slots
        state%values(IDX_CONST)      = 1.0
        state%values(IDX_ALPHA)      = alpha
        state%values(IDX_BETA)       = beta
        state%values(IDX_PBAR)       = p_bar
        state%values(IDX_QBAR)       = q_bar
        state%values(IDX_RBAR)       = r_bar
        state%values(IDX_ALPHAHAT)   = g_alpha_hat  ! set per-timestep by the dynamics engine
        state%values(IDX_BETAFLANK) = beta_flank
        state%values(IDX_BETAHAT)    = g_beta_hat   ! set per-timestep by the dynamics engine

        ! control + passive effector values
        do i = 1, min(n_ctrl, MAX_STATE_VARS - N_STD_VARS)
            state%values(N_STD_VARS + i) = ctrl_values(i)
        end do

        state%n = N_STD_VARS + n_ctrl
    end subroutine populate_aero_state

    ! set/get the current dimensionless alpha-dot (Eq 3.4.20). The dynamics engine sets it once per
    ! timestep before evaluating aero forces; populate_aero_state and the SD evaluator read it.
    subroutine set_alpha_hat(val)
        real, intent(in) :: val
        g_alpha_hat = val
    end subroutine set_alpha_hat

    function get_alpha_hat() result(val)
        real :: val
        val = g_alpha_hat
    end function get_alpha_hat

    ! set/get the current dimensionless beta-dot (Eq 3.4.21), exact parallel to alpha-hat above.
    subroutine set_beta_hat(val)
        real, intent(in) :: val
        g_beta_hat = val
    end subroutine set_beta_hat

    function get_beta_hat() result(val)
        real :: val
        val = g_beta_hat
    end function get_beta_hat

    ! split a string on a separator character into an array of trimmed parts.
    ! allocates parts(:) to exactly n_parts elements.
    subroutine split_on_char(str, sep, parts, n_parts)
        character(len=*), intent(in) :: str
        character(len=1), intent(in) :: sep
        character(len=64), allocatable, intent(out) :: parts(:)
        integer, intent(out) :: n_parts

        integer :: i, start, slen, count

        slen = len_trim(str)
        if (slen == 0) then
            n_parts = 0
            allocate(parts(0))
            return
        end if

        ! first pass: count parts
        count = 1
        do i = 1, slen
            if (str(i:i) == sep) count = count + 1
        end do

        allocate(parts(count))
        n_parts = count

        ! second pass: extract parts
        count = 0
        start = 1
        do i = 1, slen + 1
            if (i > slen) then
                ! end of string — capture final part
                if (i > start) then
                    count = count + 1
                    parts(count) = str(start:i-1)
                end if
            else if (str(i:i) == sep) then
                if (i > start) then
                    count = count + 1
                    parts(count) = str(start:i-1)
                else
                    count = count + 1
                    parts(count) = ''
                end if
                start = i + 1
            end if
        end do
    end subroutine split_on_char

end module aero_state_m
