! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! Convenience layer over the JSON-Fortran library (json_m).
!
! Every public getter is exposed through the generic `jsonx_get`, which reads a
! key from a json_value node (or a json_file) into a Fortran scalar/array and,
! when the key is absent, either substitutes a caller-supplied default or aborts.
! The module variable `json_found` reports whether the most recent lookup hit.
!
! Two conveniences beyond raw json_m:
!   * a node may transparently redirect to another file via a "filepath" key
!     (see resolve_node / json_check_4_new_file), and
!   * "spanwise" entries accept either a bare scalar (treated as constant over
!     span 0..1) or an explicit {"span":[...], "value":[...]} pair.
module jsonx_m
    use json_m
    implicit none

    ! Result of the most recent getter call (.true. = key present).
    logical :: json_found

    interface jsonx_get
        module procedure :: jsonx_value_get_real,    jsonx_file_get_real
        module procedure :: jsonx_value_get_integer, jsonx_file_get_integer
        module procedure :: jsonx_value_get_string,  jsonx_file_get_string
        module procedure :: jsonx_value_get_logical, jsonx_file_get_logical
        module procedure :: jsonx_value_get_real_array
        module procedure :: jsonx_value_get_char_array
        module procedure :: jsonx_value_get_real_spanwise_array
        module procedure :: jsonx_value_get_char_spanwise_array
        module procedure :: jsonx_value_get_logical_array
        module procedure :: jsonx_value_get_json
    end interface jsonx_get

contains

    !---------------------------------------------------------------------------
    ! Parse a JSON file into a root node and halt on any parse error.
    !---------------------------------------------------------------------------
    subroutine jsonx_load(fn, json)
        character(len=*), intent(in) :: fn
        type(json_value), pointer, intent(out) :: json
        call json_parse(fn, json)
        call json_check()
    end subroutine jsonx_load

    !---------------------------------------------------------------------------
    ! Shared miss handler. Returns .true. when the caller should fall back to a
    ! default (and clears the json error state so later reads keep working);
    ! aborts the program when a required key is missing.
    !---------------------------------------------------------------------------
    logical function use_default(key, missing, have_default) result(substitute)
        character(len=*), intent(in) :: key
        logical, intent(in) :: missing, have_default
        substitute = .false.
        if (.not. missing) return
        if (have_default) then
            call json_clear_exceptions()
            substitute = .true.
        else
            write(*,'(2A)') ' jsonx: required key not found -> ', trim(key)
            stop
        end if
    end function use_default

    ! Convenience: a node read "missed" if json errored OR the key was absent.
    logical function missed() result(m)
        m = json_failed() .or. (.not. json_found)
    end function missed

    !===========================================================================
    ! Scalar getters from a json_value node
    !===========================================================================
    subroutine jsonx_value_get_real(json_in, name, value, default_value)
        type(json_value), pointer, intent(in) :: json_in
        character(len=*), intent(in) :: name
        real, intent(out) :: value
        real, optional, intent(in) :: default_value
        type(json_value), pointer :: node
        call resolve_node(json_in, node)
        call json_get(node, name, value, json_found)
        if (use_default(name, missed(), present(default_value))) value = default_value
    end subroutine jsonx_value_get_real

    subroutine jsonx_value_get_integer(json_in, name, value, default_value)
        type(json_value), pointer, intent(in) :: json_in
        character(len=*), intent(in) :: name
        integer, intent(out) :: value
        integer, optional, intent(in) :: default_value
        type(json_value), pointer :: node
        call resolve_node(json_in, node)
        call json_get(node, name, value, json_found)
        if (use_default(name, missed(), present(default_value))) value = default_value
    end subroutine jsonx_value_get_integer

    subroutine jsonx_value_get_string(json_in, name, value, default_value)
        type(json_value), pointer, intent(in) :: json_in
        character(len=*), intent(in) :: name
        character(:), allocatable, intent(out) :: value
        character(len=*), optional, intent(in) :: default_value
        type(json_value), pointer :: node
        call resolve_node(json_in, node)
        call json_get(node, name, value, json_found)
        if (use_default(name, missed(), present(default_value))) value = default_value
    end subroutine jsonx_value_get_string

    subroutine jsonx_value_get_logical(json_in, name, value, default_value)
        type(json_value), pointer, intent(in) :: json_in
        character(len=*), intent(in) :: name
        logical, intent(out) :: value
        logical, optional, intent(in) :: default_value
        type(json_value), pointer :: node
        call resolve_node(json_in, node)
        call json_get(node, name, value, json_found)
        if (use_default(name, missed(), present(default_value))) value = default_value
    end subroutine jsonx_value_get_logical

    ! Fetch a child object node (no default; required).
    subroutine jsonx_value_get_json(json_in, name, value)
        type(json_value), pointer, intent(in) :: json_in
        character(len=*), intent(in) :: name
        type(json_value), pointer, intent(out) :: value
        type(json_value), pointer :: node
        call resolve_node(json_in, node)
        call json_value_get(node, name, value)
        if (json_failed()) then
            write(*,'(2A)') ' jsonx: required object not found -> ', trim(name)
            stop
        end if
    end subroutine jsonx_value_get_json

    !===========================================================================
    ! Scalar getters from a json_file
    !===========================================================================
    subroutine jsonx_file_get_real(json, name, value, default_value)
        type(json_file) :: json
        character(len=*), intent(in) :: name
        real, intent(out) :: value
        real, optional, intent(in) :: default_value
        call json%get(name, value)
        if (use_default(name, json_failed(), present(default_value))) value = default_value
    end subroutine jsonx_file_get_real

    subroutine jsonx_file_get_integer(json, name, value, default_value)
        type(json_file) :: json
        character(len=*), intent(in) :: name
        integer, intent(out) :: value
        integer, optional, intent(in) :: default_value
        call json%get(name, value)
        if (use_default(name, json_failed(), present(default_value))) value = default_value
    end subroutine jsonx_file_get_integer

    subroutine jsonx_file_get_string(json, name, value)
        type(json_file) :: json
        character(len=*), intent(in) :: name
        character(:), allocatable, intent(out) :: value
        call json%get(name, value)
        if (json_failed()) then
            write(*,'(2A)') ' jsonx: required key not found -> ', trim(name)
            stop
        end if
        value = trim(value)
    end subroutine jsonx_file_get_string

    subroutine jsonx_file_get_logical(json, name, value)
        type(json_file) :: json
        character(len=*), intent(in) :: name
        logical, intent(out) :: value
        call json%get(name, value)
        if (json_failed()) then
            write(*,'(2A)') ' jsonx: required key not found -> ', trim(name)
            stop
        end if
    end subroutine jsonx_file_get_logical

    !===========================================================================
    ! Array getters from a json_value node
    !===========================================================================
    subroutine jsonx_value_get_real_array(json_in, name, value, default_value, l)
        type(json_value), pointer, intent(in) :: json_in
        character(len=*), intent(in) :: name
        real, allocatable, dimension(:), intent(out) :: value
        real, optional, intent(in) :: default_value
        integer, optional, intent(in) :: l
        type(json_value), pointer :: node
        call resolve_node(json_in, node)
        call json_get(node, name, value, json_found)
        if (use_default(name, missed(), present(default_value))) then
            allocate(value(default_len(l)))
            value = default_value
        end if
    end subroutine jsonx_value_get_real_array

    subroutine jsonx_value_get_logical_array(json_in, name, value, default_value, l)
        type(json_value), pointer, intent(in) :: json_in
        character(len=*), intent(in) :: name
        logical, allocatable, dimension(:), intent(out) :: value
        logical, optional, intent(in) :: default_value
        integer, optional, intent(in) :: l
        type(json_value), pointer :: node
        call resolve_node(json_in, node)
        call json_get(node, name, value, json_found)
        if (use_default(name, missed(), present(default_value))) then
            allocate(value(default_len(l)))
            value = default_value
        end if
    end subroutine jsonx_value_get_logical_array

    ! Read a string list. A bare scalar string is returned as a length-1 list.
    subroutine jsonx_value_get_char_array(json_in, name, value, default_value)
        type(json_value), pointer, intent(in) :: json_in
        character(len=*), intent(in) :: name
        character(len=*), allocatable, dimension(:), intent(out) :: value
        character(len=*), optional, intent(in) :: default_value
        character(len=:), allocatable :: scalar
        type(json_value), pointer :: node
        call resolve_node(json_in, node)
        ! prefer a scalar string; if absent, try a list; else default to a 1-list
        call json_get(node, name, scalar, json_found)
        if (.not. missed()) then
            allocate(value(1)); value(1) = trim(scalar)
            call json_clear_exceptions()
            return
        end if
        call json_clear_exceptions()
        call json_get(node, name, value, json_found)
        if (use_default(name, missed(), present(default_value))) then
            allocate(value(1)); value(1) = default_value
        end if
    end subroutine jsonx_value_get_char_array

    !===========================================================================
    ! Spanwise getters: a scalar means "constant over span [0,1]"; otherwise the
    ! entry is an object with matching "span" and "value" arrays.
    !===========================================================================
    ! Real spanwise -> packed (n,2) with column 1 = span, column 2 = value.
    subroutine jsonx_value_get_real_spanwise_array(json_in, name, value, default_value)
        type(json_value), pointer, intent(in) :: json_in
        character(len=*), intent(in) :: name
        real, allocatable, dimension(:,:), intent(out) :: value
        real, optional, intent(in) :: default_value
        type(json_value), pointer :: node, entry
        real, allocatable :: span(:), vals(:)
        real :: scalar
        integer :: i, n

        call resolve_node(json_in, node)

        ! Case 1: a single scalar -> constant profile.
        call json_get(node, name, scalar, json_found)
        if (.not. missed()) then
            call const_span(value, scalar)
            return
        end if
        call json_clear_exceptions()

        ! Case 2: an object carrying "span" and "value" arrays.
        call json_get(node, name, entry, json_found)
        if (missed()) then
            if (use_default(name, .true., present(default_value))) call const_span(value, default_value)
            return
        end if
        call json_get(entry, 'value', vals, json_found)
        if (missed()) then
            if (use_default(name, .true., present(default_value))) call const_span(value, default_value)
            return
        end if
        call json_get(entry, 'span', span, json_found)
        if (missed()) then
            if (use_default(name, .true., present(default_value))) call const_span(value, default_value)
            return
        end if

        n = size(vals)
        if (n /= size(span)) then
            write(*,'(2A)') ' jsonx: span/value length mismatch for key -> ', trim(name)
            stop
        end if
        allocate(value(n, 2))
        do i = 1, n
            value(i, 1) = span(i)
            value(i, 2) = vals(i)
        end do
    end subroutine jsonx_value_get_real_spanwise_array

    ! Character spanwise -> separate span(:) and value(:) arrays.
    subroutine jsonx_value_get_char_spanwise_array(json_in, name, span, value, default_value)
        type(json_value), pointer, intent(in) :: json_in
        character(len=*), intent(in) :: name
        real, allocatable, dimension(:), intent(out) :: span
        character(len=*), allocatable, dimension(:), intent(out) :: value
        character(len=*), optional, intent(in) :: default_value
        type(json_value), pointer :: node, entry
        character(len=:), allocatable :: scalar
        real, allocatable :: s(:)

        call resolve_node(json_in, node)

        ! Case 1: scalar -> two endpoints holding the same string.
        call json_get(node, name, scalar, json_found)
        if (.not. missed()) then
            allocate(value(2), span(2))
            span = [0.0, 1.0]
            value(1) = trim(scalar); value(2) = trim(scalar)
            call json_clear_exceptions()
            return
        end if
        call json_clear_exceptions()

        ! Case 2: object with "span"/"value".
        call json_get(node, name, entry, json_found)
        if (missed()) then
            if (use_default(name, .true., present(default_value))) call const_char_span(span, value, default_value)
            return
        end if
        call json_get(entry, 'value', value, json_found)
        if (missed()) then
            if (use_default(name, .true., present(default_value))) call const_char_span(span, value, default_value)
            return
        end if
        call json_get(entry, 'span', s, json_found)
        if (missed()) then
            if (use_default(name, .true., present(default_value))) call const_char_span(span, value, default_value)
            return
        end if

        if (size(value) /= size(s)) then
            write(*,'(2A)') ' jsonx: span/value length mismatch for key -> ', trim(name)
            stop
        end if
        span = s
    end subroutine jsonx_value_get_char_spanwise_array

    !===========================================================================
    ! Internal helpers
    !===========================================================================
    ! Resolve a node, following a "filepath" redirect to another JSON file when
    ! present; otherwise the node passes straight through.
    subroutine resolve_node(s_in, s_out)
        type(json_value), pointer, intent(in) :: s_in
        type(json_value), pointer, intent(out) :: s_out
        character(len=:), allocatable :: fn
        logical :: exists
        call json_get(s_in, "filepath", fn, json_found)
        if (json_failed() .or. (.not. json_found)) then
            call json_clear_exceptions()
            s_out => s_in
        else
            inquire(file=fn, exist=exists)
            if (.not. exists) then
                write(*,'(3A)') ' jsonx: redirect file does not exist -> ', trim(fn), '  (quitting)'
                stop
            end if
            call json_parse(fn, s_out)
            call json_check()
        end if
    end subroutine resolve_node

    ! Backward-compatible alias (some callers, e.g. jsonx_units_m, use this name).
    subroutine json_check_4_new_file(s_in, s_out)
        type(json_value), pointer, intent(in) :: s_in
        type(json_value), pointer, intent(out) :: s_out
        call resolve_node(s_in, s_out)
    end subroutine json_check_4_new_file

    ! Halt on a pending json error, printing the message first.
    subroutine json_check()
        if (json_failed()) then
            call print_json_error_message()
            stop
        end if
    end subroutine json_check

    subroutine print_json_error_message()
        character(len=:), allocatable :: error_msg
        logical :: status_ok
        call json_check_for_errors(status_ok, error_msg)
        if (.not. status_ok) then
            write(*,'(A)') error_msg
            deallocate(error_msg)
            call json_clear_exceptions()
        end if
    end subroutine print_json_error_message

    ! Default array length: explicit `l` if given, otherwise 2.
    integer function default_len(l) result(n)
        integer, optional, intent(in) :: l
        n = 2
        if (present(l)) n = l
    end function default_len

    ! Build a 2x2 constant real profile: span = [0,1], value = [c,c].
    subroutine const_span(arr, c)
        real, allocatable, dimension(:,:), intent(out) :: arr
        real, intent(in) :: c
        allocate(arr(2, 2))
        arr(:, 1) = [0.0, 1.0]
        arr(:, 2) = c
    end subroutine const_span

    ! Build a 2-point constant character profile.
    subroutine const_char_span(span, value, c)
        real, allocatable, dimension(:), intent(out) :: span
        character(len=*), allocatable, dimension(:), intent(out) :: value
        character(len=*), intent(in) :: c
        allocate(span(2), value(2))
        span = [0.0, 1.0]
        value(1) = c; value(2) = c
    end subroutine const_char_span

end module jsonx_m
