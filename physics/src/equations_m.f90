! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! universal equations system — allows any JSON numeric value to be a
! polynomial or sine function of simulation state variables.
! standalone module: no dependency on vehicle_types_m or force_source_m.
module equations_m
    use json_m
    use jsonx_m
    use units_m, only: parse_variable_and_units, conversion_factor_from
    implicit none
    private

    public :: equation_t, equation_set_t, var_table_t, poly_term_t
    public :: EQ_SINE, EQ_POLYNOMIAL, EQ_STEP
    public :: scan_for_equations
    public :: evaluate_at_zero

    integer, parameter :: EQ_SINE = 1
    integer, parameter :: EQ_POLYNOMIAL = 2
    integer, parameter :: EQ_STEP = 3

    integer, parameter :: MAX_VARS = 64
    integer, parameter :: MAX_FACTORS = 4
    integer, parameter :: MAX_EQUATIONS = 128

    ! independent variable lookup table — rebuilt each timestep
    type :: var_table_t
        integer :: n = 0
        character(len=32) :: names(MAX_VARS)
        real :: values(MAX_VARS) = 0.0
    contains
        procedure :: set => var_table_set
        procedure :: find_index => var_table_find_index
    end type var_table_t

    ! single monomial term: coef * prod(x_i ^ exp_i)
    type :: poly_term_t
        real :: coef = 0.0
        integer :: n_factors = 0
        integer :: iv_idx(MAX_FACTORS) = 0    ! var_table indices (resolved at init)
        integer :: iv_exp(MAX_FACTORS) = 0    ! exponents
        character(len=32) :: iv_names(MAX_FACTORS) = ''  ! names (for deferred resolution)
    end type poly_term_t

    ! single equation (tagged union: sine or polynomial)
    type :: equation_t
        integer :: type_id = 0
        real, pointer :: target => null()       ! points to the config field to update
        character(len=64) :: target_name = ''   ! for error messages
        character(len=32) :: section = ''       ! which section (mass, wind, ...)
        real :: unit_cf = 1.0                   ! conversion factor from JSON units

        ! sine: offset + amplitude * sin(frequency * x + phase)
        real :: amplitude = 0.0
        real :: frequency = 0.0
        real :: phase = 0.0
        real :: offset = 0.0
        integer :: sine_iv_idx = 0              ! var_table index (resolved at init)
        character(len=32) :: sine_iv_name = ''  ! name (for deferred resolution)

        ! polynomial: sum of monomial terms
        integer :: n_terms = 0
        type(poly_term_t), allocatable :: terms(:)

        ! step: before if iv < trigger_value, after if iv >= trigger_value
        real :: step_before = 0.0
        real :: step_after = 0.0
        real :: step_trigger = 0.0
        integer :: step_iv_idx = 0              ! var_table index (resolved at init)
        character(len=32) :: step_iv_name = ''  ! name (for deferred resolution)
    end type equation_t

    ! collection of equations for one vehicle
    type :: equation_set_t
        integer :: n = 0
        type(equation_t) :: eqs(MAX_EQUATIONS)
        logical :: has_mass_eqs = .false.
        logical :: has_geometry_eqs = .false.
    contains
        procedure :: evaluate_all => eqset_evaluate_all
        procedure :: resolve_indices => eqset_resolve_indices
        procedure :: append_equation => eqset_append
    end type equation_set_t

contains

    ! ================================================================
    ! var_table_t
    ! ================================================================

    ! set or update a named value in the table
    subroutine var_table_set(self, name, value)
        class(var_table_t), intent(inout) :: self
        character(len=*), intent(in) :: name
        real, intent(in) :: value

        integer :: i

        ! update if exists
        do i = 1, self%n
            if (trim(self%names(i)) == trim(name)) then
                self%values(i) = value
                return
            end if
        end do

        ! add new
        if (self%n >= MAX_VARS) then
            write(*,*) 'ERROR [equations_m]: var_table overflow (MAX_VARS=', MAX_VARS, ')'
            stop
        end if
        self%n = self%n + 1
        self%names(self%n) = name
        self%values(self%n) = value
    end subroutine var_table_set

    ! find index of a named variable (0 if not found)
    function var_table_find_index(self, name) result(idx)
        class(var_table_t), intent(in) :: self
        character(len=*), intent(in) :: name
        integer :: idx

        integer :: i
        idx = 0
        do i = 1, self%n
            if (trim(self%names(i)) == trim(name)) then
                idx = i
                return
            end if
        end do
    end function var_table_find_index

    ! ================================================================
    ! equation evaluation
    ! ================================================================

    function evaluate_sine(eq, vt) result(val)
        type(equation_t), intent(in) :: eq
        type(var_table_t), intent(in) :: vt
        real :: val

        real :: x
        x = vt%values(eq%sine_iv_idx)
        val = eq%offset + eq%amplitude * sin(eq%frequency * x + eq%phase)
    end function evaluate_sine

    function evaluate_step(eq, vt) result(val)
        type(equation_t), intent(in) :: eq
        type(var_table_t), intent(in) :: vt
        real :: val

        if (vt%values(eq%step_iv_idx) >= eq%step_trigger) then
            val = eq%step_after
        else
            val = eq%step_before
        end if
    end function evaluate_step

    ! evaluate an equation with all independent variables held at zero.
    ! used at JSON load time to seed an equation-defined field with the
    ! value it would have at the start of the simulation, before any state
    ! is known. caller still multiplies by eq%unit_cf to convert to internal units.
    function evaluate_at_zero(eq) result(val)
        type(equation_t), intent(in) :: eq
        real :: val

        integer :: i

        select case (eq%type_id)
        case (EQ_SINE)
            ! IV = 0  =>  offset + amplitude * sin(phase)
            val = eq%offset + eq%amplitude * sin(eq%phase)
        case (EQ_POLYNOMIAL)
            ! IVs = 0  =>  only the constant term (zero factors) survives
            val = 0.0
            do i = 1, eq%n_terms
                if (eq%terms(i)%n_factors == 0) val = val + eq%terms(i)%coef
            end do
        case (EQ_STEP)
            ! IV = 0 < trigger_value (assuming positive trigger)  =>  before
            val = eq%step_before
        case default
            val = 0.0
        end select
    end function evaluate_at_zero

    function evaluate_polynomial(eq, vt) result(val)
        type(equation_t), intent(in) :: eq
        type(var_table_t), intent(in) :: vt
        real :: val

        integer :: i, j
        real :: prod

        val = 0.0
        do i = 1, eq%n_terms
            prod = eq%terms(i)%coef
            do j = 1, eq%terms(i)%n_factors
                prod = prod * vt%values(eq%terms(i)%iv_idx(j)) ** eq%terms(i)%iv_exp(j)
            end do
            val = val + prod
        end do
    end function evaluate_polynomial

    ! ================================================================
    ! equation_set_t
    ! ================================================================

    ! append one equation to the set
    subroutine eqset_append(self, eq)
        class(equation_set_t), intent(inout) :: self
        type(equation_t), intent(in) :: eq

        if (self%n >= MAX_EQUATIONS) then
            write(*,*) 'ERROR [equations_m]: equation_set overflow (MAX_EQUATIONS=', MAX_EQUATIONS, ')'
            stop
        end if
        self%n = self%n + 1
        self%eqs(self%n) = eq
    end subroutine eqset_append

    ! evaluate all equations, writing results through target pointers
    subroutine eqset_evaluate_all(self, vt)
        class(equation_set_t), intent(inout) :: self
        type(var_table_t), intent(in) :: vt

        integer :: i
        real :: val

        do i = 1, self%n
            select case (self%eqs(i)%type_id)
            case (EQ_SINE)
                val = evaluate_sine(self%eqs(i), vt)
            case (EQ_POLYNOMIAL)
                val = evaluate_polynomial(self%eqs(i), vt)
            case (EQ_STEP)
                val = evaluate_step(self%eqs(i), vt)
            case default
                cycle
            end select

            self%eqs(i)%target = val * self%eqs(i)%unit_cf
        end do
    end subroutine eqset_evaluate_all

    ! resolve independent variable name strings to var_table indices
    ! call once after var_table is populated with all variable names
    subroutine eqset_resolve_indices(self, vt)
        class(equation_set_t), intent(inout) :: self
        type(var_table_t), intent(in) :: vt

        integer :: i, j, idx

        do i = 1, self%n
            select case (self%eqs(i)%type_id)
            case (EQ_SINE)
                idx = vt%find_index(self%eqs(i)%sine_iv_name)
                if (idx == 0) then
                    write(*,*) 'ERROR [equations_m]: unknown independent variable "', &
                        trim(self%eqs(i)%sine_iv_name), '" in sine equation for "', &
                        trim(self%eqs(i)%target_name), '"'
                    stop
                end if
                self%eqs(i)%sine_iv_idx = idx

            case (EQ_POLYNOMIAL)
                do j = 1, self%eqs(i)%n_terms
                    call resolve_poly_term(self%eqs(i)%terms(j), vt, self%eqs(i)%target_name)
                end do

            case (EQ_STEP)
                idx = vt%find_index(self%eqs(i)%step_iv_name)
                if (idx == 0) then
                    write(*,*) 'ERROR [equations_m]: unknown independent variable "', &
                        trim(self%eqs(i)%step_iv_name), '" in step equation for "', &
                        trim(self%eqs(i)%target_name), '"'
                    stop
                end if
                self%eqs(i)%step_iv_idx = idx
            end select
        end do
    end subroutine eqset_resolve_indices

    subroutine resolve_poly_term(term, vt, eq_name)
        type(poly_term_t), intent(inout) :: term
        type(var_table_t), intent(in) :: vt
        character(len=*), intent(in) :: eq_name

        integer :: j, idx

        do j = 1, term%n_factors
            idx = vt%find_index(term%iv_names(j))
            if (idx == 0) then
                write(*,*) 'ERROR [equations_m]: unknown independent variable "', &
                    trim(term%iv_names(j)), '" in polynomial equation for "', &
                    trim(eq_name), '"'
                stop
            end if
            term%iv_idx(j) = idx
        end do
    end subroutine resolve_poly_term

    ! ================================================================
    ! JSON parsing
    ! ================================================================

    ! scan a JSON section for "sines", "polynomials", and "steps" dictionaries
    ! and append any found equations to eqset. Recurses into nested JSON
    ! objects so equation blocks can be placed at any depth alongside the
    ! literal field they replace (e.g., a "steps" block inside "mass").
    recursive subroutine scan_for_equations(j_section, section_name, eqset)
        type(json_value), pointer, intent(in) :: j_section
        character(len=*), intent(in) :: section_name
        type(equation_set_t), intent(inout) :: eqset

        type(json_value), pointer :: j_sines, j_polys, j_steps, j_eq, j_child
        integer :: n, i, child_type

        if (.not. associated(j_section)) return

        ! scan for sines at this level
        call json_value_get(j_section, 'sines', j_sines)
        if (.not. json_failed() .and. associated(j_sines)) then
            call json_info(j_sines, n_children=n)
            do i = 1, n
                call json_value_get(j_sines, i, j_eq)
                call parse_sine_entry(j_eq, section_name, eqset)
            end do
        end if
        call json_clear_exceptions()

        ! scan for polynomials at this level
        call json_value_get(j_section, 'polynomials', j_polys)
        if (.not. json_failed() .and. associated(j_polys)) then
            call json_info(j_polys, n_children=n)
            do i = 1, n
                call json_value_get(j_polys, i, j_eq)
                call parse_polynomial_entry(j_eq, section_name, eqset)
            end do
        end if
        call json_clear_exceptions()

        ! scan for steps at this level
        call json_value_get(j_section, 'steps', j_steps)
        if (.not. json_failed() .and. associated(j_steps)) then
            call json_info(j_steps, n_children=n)
            do i = 1, n
                call json_value_get(j_steps, i, j_eq)
                call parse_step_entry(j_eq, section_name, eqset)
            end do
        end if
        call json_clear_exceptions()

        ! recurse into nested object children. Skip the equation blocks
        ! themselves (already processed above) so we don't try to parse
        ! their inner entries as new sections.
        call json_info(j_section, n_children=n)
        do i = 1, n
            call json_value_get(j_section, i, j_child)
            if (.not. associated(j_child)) cycle
            call json_info(j_child, var_type=child_type)
            if (child_type /= json_object) cycle
            if (.not. allocated(j_child%name)) cycle
            if (trim(j_child%name) == 'sines') cycle
            if (trim(j_child%name) == 'polynomials') cycle
            if (trim(j_child%name) == 'steps') cycle
            call scan_for_equations(j_child, section_name, eqset)
        end do
        call json_clear_exceptions()
    end subroutine scan_for_equations

    ! parse one sine entry from JSON
    subroutine parse_sine_entry(j_eq, section_name, eqset)
        type(json_value), pointer, intent(in) :: j_eq
        character(len=*), intent(in) :: section_name
        type(equation_set_t), intent(inout) :: eqset

        type(equation_t) :: eq
        character(len=:), allocatable :: var_part, unit_part, iv_name

        eq%type_id = EQ_SINE
        eq%section = section_name

        ! extract target name and units from key (e.g., "Izz[slug-ft^2]")
        call parse_variable_and_units(trim(j_eq%name), var_part, unit_part)
        eq%target_name = var_part
        if (allocated(unit_part)) then
            eq%unit_cf = conversion_factor_from(unit_part)
        else
            eq%unit_cf = 1.0
        end if

        ! parse sine parameters
        call jsonx_get(j_eq, 'amplitude', eq%amplitude)
        call jsonx_get(j_eq, 'frequency', eq%frequency)
        call jsonx_get(j_eq, 'phase[rad]', eq%phase, 0.0)
        call jsonx_get(j_eq, 'offset', eq%offset)
        call jsonx_get(j_eq, 'independent_variable', iv_name)
        eq%sine_iv_name = iv_name

        call eqset%append_equation(eq)
    end subroutine parse_sine_entry

    ! parse one step entry from JSON
    ! key format: "weight[lbf]" (target field with optional units)
    ! body: { "before": <value>, "after": <value>,
    !         "trigger_value": <iv threshold>, "independent_variable": "time" }
    ! semantics: target = before if iv < trigger_value, after if iv >= trigger_value.
    ! trigger_value is in the independent variable's native (internal) units.
    subroutine parse_step_entry(j_eq, section_name, eqset)
        type(json_value), pointer, intent(in) :: j_eq
        character(len=*), intent(in) :: section_name
        type(equation_set_t), intent(inout) :: eqset

        type(equation_t) :: eq
        character(len=:), allocatable :: var_part, unit_part, iv_name

        eq%type_id = EQ_STEP
        eq%section = section_name

        ! extract target name and units from key (e.g., "weight[lbf]")
        call parse_variable_and_units(trim(j_eq%name), var_part, unit_part)
        eq%target_name = var_part
        if (allocated(unit_part)) then
            eq%unit_cf = conversion_factor_from(unit_part)
        else
            eq%unit_cf = 1.0
        end if

        ! parse step parameters
        call jsonx_get(j_eq, 'before', eq%step_before)
        call jsonx_get(j_eq, 'after', eq%step_after)
        call jsonx_get(j_eq, 'trigger_value', eq%step_trigger)
        call jsonx_get(j_eq, 'independent_variable', iv_name)
        eq%step_iv_name = iv_name

        call eqset%append_equation(eq)
    end subroutine parse_step_entry

    ! parse one polynomial entry from JSON
    ! key format: "0" (constant), "alpha" (linear), "alpha^2" (power),
    !             "alpha_qbar" (product), "alpha^2_qbar" (mixed)
    subroutine parse_polynomial_entry(j_eq, section_name, eqset)
        type(json_value), pointer, intent(in) :: j_eq
        character(len=*), intent(in) :: section_name
        type(equation_set_t), intent(inout) :: eqset

        type(equation_t) :: eq
        type(json_value), pointer :: j_term
        character(len=:), allocatable :: var_part, unit_part
        integer :: n_terms, i

        eq%type_id = EQ_POLYNOMIAL
        eq%section = section_name

        ! extract target name and units from key
        call parse_variable_and_units(trim(j_eq%name), var_part, unit_part)
        eq%target_name = var_part
        if (allocated(unit_part)) then
            eq%unit_cf = conversion_factor_from(unit_part)
        else
            eq%unit_cf = 1.0
        end if

        ! count terms
        call json_info(j_eq, n_children=n_terms)
        eq%n_terms = n_terms
        allocate(eq%terms(n_terms))

        ! parse each monomial term
        do i = 1, n_terms
            call json_value_get(j_eq, i, j_term)
            call parse_monomial_term(j_term, eq%terms(i))
        end do

        call eqset%append_equation(eq)
    end subroutine parse_polynomial_entry

    ! parse a single monomial term from its JSON key and value
    ! key examples: "0", "alpha", "alpha^2", "alpha_qbar", "alpha^2_qbar^3"
    subroutine parse_monomial_term(j_term, term)
        type(json_value), pointer, intent(in) :: j_term
        type(poly_term_t), intent(out) :: term

        character(len=256) :: key
        integer :: slen, i, start, count, caret_pos, exp_val, ios

        ! read coefficient value
        if (j_term%data%var_type == json_real) then
            term%coef = j_term%data%dbl_value
        else if (j_term%data%var_type == json_integer) then
            term%coef = real(j_term%data%int_value)
        else
            write(*,*) 'ERROR [equations_m]: non-numeric coefficient in polynomial term "', &
                trim(j_term%name), '"'
            stop
        end if

        key = trim(j_term%name)
        slen = len_trim(key)

        ! constant term: key = "0"
        if (trim(key) == '0') then
            term%n_factors = 0
            return
        end if

        ! split on '_' and parse each factor
        count = 0
        start = 1
        do i = 1, slen + 1
            if (i > slen .or. key(i:i) == '_') then
                if (i > start) then
                    count = count + 1
                    if (count > MAX_FACTORS) then
                        write(*,*) 'ERROR [equations_m]: too many factors in term "', &
                            trim(key), '" (max=', MAX_FACTORS, ')'
                        stop
                    end if

                    ! check for exponent (^N)
                    caret_pos = index(key(start:i-1), '^')
                    if (caret_pos > 0) then
                        caret_pos = start + caret_pos - 1  ! absolute position
                        term%iv_names(count) = key(start:caret_pos-1)
                        read(key(caret_pos+1:i-1), *, iostat=ios) exp_val
                        if (ios /= 0) then
                            write(*,*) 'ERROR [equations_m]: bad exponent in "', trim(key), '"'
                            stop
                        end if
                        term%iv_exp(count) = exp_val
                    else
                        term%iv_names(count) = key(start:i-1)
                        term%iv_exp(count) = 1
                    end if
                end if
                start = i + 1
            end if
        end do
        term%n_factors = count
    end subroutine parse_monomial_term

end module equations_m
