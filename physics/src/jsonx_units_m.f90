! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! Unit-aware JSON getters — bridge between jsonx_m and units_m.
! Looks up keys by base name, auto-converts if [units] brackets are present.
! If no brackets, assumes internal units (no conversion).
module jsonx_units_m
    use json_m
    use jsonx_m
    use units_m, only: parse_variable_and_units, conversion_factor_from, is_angular_unit
    implicit none
    private

    public :: jsonx_get_u

    interface jsonx_get_u
        module procedure :: jsonx_get_u_real
        module procedure :: jsonx_get_u_real_array
    end interface jsonx_get_u

contains

    ! find a child of parent whose base name (stripping [units]) matches base_name
    subroutine find_child_by_base_name(parent, base_name, child, units_str, found)
        type(json_value), pointer, intent(in) :: parent
        character(len=*), intent(in) :: base_name
        type(json_value), pointer, intent(out) :: child
        character(len=:), allocatable, intent(out) :: units_str
        logical, intent(out) :: found

        type(json_value), pointer :: p
        character(len=:), allocatable :: var_part, unit_part
        integer :: n_children, i

        found = .false.
        nullify(child)
        if (.not. associated(parent)) return

        call json_info(parent, n_children=n_children)
        do i = 1, n_children
            call json_value_get(parent, i, p)
            if (.not. allocated(p%name)) cycle

            call parse_variable_and_units(trim(p%name), var_part, unit_part)
            if (trim(var_part) == trim(base_name)) then
                child => p
                found = .true.
                if (allocated(unit_part)) units_str = unit_part
                if (allocated(var_part)) deallocate(var_part)
                if (allocated(unit_part)) deallocate(unit_part)
                return
            end if
            if (allocated(var_part)) deallocate(var_part)
            if (allocated(unit_part)) deallocate(unit_part)
        end do
    end subroutine find_child_by_base_name

    ! scalar real: find key by base name, read value, convert if units present
    subroutine jsonx_get_u_real(json_in, base_name, value, default_value)
        type(json_value), pointer, intent(in) :: json_in
        character(len=*), intent(in) :: base_name
        real, intent(out) :: value
        real, intent(in), optional :: default_value

        type(json_value), pointer :: json, child
        character(len=:), allocatable :: units_str
        logical :: found

        call json_check_4_new_file(json_in, json)
        call find_child_by_base_name(json, base_name, child, units_str, found)

        if (found) then
            json_found = .true.
            if (child%data%var_type == json_real) then
                value = child%data%dbl_value
            else if (child%data%var_type == json_integer) then
                value = real(child%data%int_value)
            else
                write(*,*) 'ERROR: Non-numeric value for key "', trim(base_name), '"'
                stop
            end if
            if (allocated(units_str)) value = value * conversion_factor_from(units_str)
            return
        end if

        json_found = .false.
        if (present(default_value)) then
            value = default_value
        else
            write(*,*) 'ERROR: Unable to read required value: ', trim(base_name)
            stop
        end if
    end subroutine jsonx_get_u_real

    ! array real: find key by base name, read array, convert element-wise
    ! optional units_out returns the units string (for callers that need it)
    subroutine jsonx_get_u_real_array(json_in, base_name, value, default_value, l, units_out)
        type(json_value), pointer, intent(in) :: json_in
        character(len=*), intent(in) :: base_name
        real, allocatable, intent(out) :: value(:)
        real, intent(in), optional :: default_value
        integer, intent(in), optional :: l
        character(len=:), allocatable, intent(out), optional :: units_out

        type(json_value), pointer :: json, child
        character(len=:), allocatable :: units_str
        logical :: found

        call json_check_4_new_file(json_in, json)
        call find_child_by_base_name(json, base_name, child, units_str, found)

        if (found) then
            json_found = .true.
            ! read array via json_get using the child's full name
            call json_get(json, trim(child%name), value, found)
            if (.not. found .or. json_failed()) then
                call json_clear_exceptions()
                ! child might be a scalar — wrap in array
                if (child%data%var_type == json_real .or. child%data%var_type == json_integer) then
                    if (present(l)) then
                        allocate(value(l))
                    else
                        allocate(value(1))
                    end if
                    if (child%data%var_type == json_real) then
                        value = child%data%dbl_value
                    else
                        value = real(child%data%int_value)
                    end if
                else
                    write(*,*) 'ERROR: Cannot read array for key "', trim(base_name), '"'
                    stop
                end if
            end if
            if (allocated(units_str)) then
                value = value * conversion_factor_from(units_str)
                if (present(units_out)) units_out = units_str
            else
                if (present(units_out)) units_out = ''
            end if
            return
        end if

        ! not found — use default
        json_found = .false.
        if (present(default_value)) then
            if (present(l)) then
                allocate(value(l))
            else
                allocate(value(2))
            end if
            value = default_value
        else
            write(*,*) 'ERROR: Unable to read required array: ', trim(base_name)
            stop
        end if
        if (present(units_out)) units_out = ''
    end subroutine jsonx_get_u_real_array

end module jsonx_units_m
