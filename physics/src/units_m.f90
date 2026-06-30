! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! units_m
!
! Parses unit strings such as "deg", "ft/s", "slug-ft^2" or "kg/(m*s^2)" and
! returns the multiplicative factor that maps between the simulation's internal
! (English) unit system and the requested external units.
!
! Design: every recognized base unit is one row in a single flat table tagged
! with its physical category and its "external-per-internal" factor. A token is
! resolved by (1) an exact symbol match, then (2) a single SI-prefix peeled off
! the front followed by an exact symbol match. Compound strings are split into
! numerator and denominator term lists; the overall factor is the product of the
! numerator factors divided by the product of the denominator factors.
module units_m
    use constants_m, only: PI
    implicit none
    private

    public :: conversion_factor_to, conversion_factor_from, parse_variable_and_units
    public :: resolve_alias, is_angular_unit, is_force_unit, is_torque_unit

    ! physical category tags
    integer, parameter :: C_LEN=1, C_TIME=2, C_SPEED=3, C_ACCEL=4, C_MASS=5, &
                          C_ANGLE=6, C_FORCE=7, C_MOMENT=8, C_POWER=9, &
                          C_TEMP=10, C_PRESS=11, C_ROT=12, C_FREQ=13

    ! degrees per radian (the internal angular unit is the radian)
    real, parameter :: r2d = 180.0 / PI

    ! base-unit factors: how many external units make one internal unit
    ! lengths per foot
    real, parameter :: c_mile = 1.0/5280.0, c_yard = 1.0/3.0, c_inch = 12.0, &
                       c_nmi  = 1.0/6076.11549, c_meter = 0.3048
    ! times per second
    real, parameter :: c_min = 1.0/60.0, c_hr = c_min/60.0, c_day = c_hr/24.0, &
                       c_wk = c_day/7.0, c_yr = c_wk/52.0
    ! speed per ft/s, acceleration per ft/s^2
    real, parameter :: c_kts = 1.0/1.68781
    real, parameter :: c_gs  = 1.0/32.174048556430442
    ! masses per slug
    real, parameter :: c_gram = 14.5939029 / 1.0e-3
    real, parameter :: c_lbm  = 32.17404855643
    real, parameter :: c_oz   = 16.0 * c_lbm
    real, parameter :: c_ton  = (1.0/2000.0) * c_lbm
    ! force per lbf, moment/energy per lbf*ft
    real, parameter :: c_newton = 4.4482216152605
    real, parameter :: c_joule  = 1.35582
    ! power per lbf*ft/s
    real, parameter :: c_hp   = 550.0
    real, parameter :: c_watt = 735.499 * c_hp
    ! temperature delta per delta-F
    real, parameter :: c_Cdeg = 9.0/5.0
    ! pressures per psf
    real, parameter :: c_pascal = 47.880258
    real, parameter :: c_psi    = 1.0/144.0
    real, parameter :: c_atm    = 47.880258/101325.0
    real, parameter :: c_inHg   = 47.880258/3386.389
    real, parameter :: c_mbar   = 47.880258/100.0
    real, parameter :: c_mmHg   = 47.880258/133.322
    ! rotation rate per rad/s
    real, parameter :: c_rpm = 60.0/(2.0*PI)

    type :: unit_t
        character(len=5) :: sym
        real            :: fac
        integer         :: cat
    end type unit_t

    ! ordered by category so that, when an SI prefix is involved, ties resolve to
    ! the earliest category (length before time before ...), matching the legacy
    ! search order.
    type(unit_t), parameter :: TABLE(*) = [ &
        unit_t('ft   ', 1.0,      C_LEN),   &
        unit_t('mi   ', c_mile,   C_LEN),   &
        unit_t('yard ', c_yard,   C_LEN),   &
        unit_t('in   ', c_inch,   C_LEN),   &
        unit_t('nami ', c_nmi,    C_LEN),   &
        unit_t('m    ', c_meter,  C_LEN),   &
        unit_t('s    ', 1.0,      C_TIME),  &
        unit_t('min  ', c_min,    C_TIME),  &
        unit_t('hr   ', c_hr,     C_TIME),  &
        unit_t('day  ', c_day,    C_TIME),  &
        unit_t('wk   ', c_wk,     C_TIME),  &
        unit_t('yr   ', c_yr,     C_TIME),  &
        unit_t('kts  ', c_kts,    C_SPEED), &
        unit_t('gs   ', c_gs,     C_ACCEL), &
        unit_t('slug ', 1.0,      C_MASS),  &
        unit_t('g    ', c_gram,   C_MASS),  &
        unit_t('lbm  ', c_lbm,    C_MASS),  &
        unit_t('oz   ', c_oz,     C_MASS),  &
        unit_t('ton  ', c_ton,    C_MASS),  &
        unit_t('rad  ', 1.0,      C_ANGLE), &
        unit_t('deg  ', r2d,      C_ANGLE), &
        unit_t('lbf  ', 1.0,      C_FORCE), &
        unit_t('N    ', c_newton, C_FORCE), &
        unit_t('J    ', c_joule,  C_MOMENT),&
        unit_t('hp   ', c_hp,     C_POWER), &
        unit_t('W    ', c_watt,   C_POWER), &
        unit_t('F    ', 1.0,      C_TEMP),  &
        unit_t('R    ', 1.0,      C_TEMP),  &
        unit_t('C    ', c_Cdeg,   C_TEMP),  &
        unit_t('K    ', c_Cdeg,   C_TEMP),  &
        unit_t('psf  ', 1.0,      C_PRESS), &
        unit_t('Pa   ', c_pascal, C_PRESS), &
        unit_t('psi  ', c_psi,    C_PRESS), &
        unit_t('atm  ', c_atm,    C_PRESS), &
        unit_t('inHg ', c_inHg,   C_PRESS), &
        unit_t('mbar ', c_mbar,   C_PRESS), &
        unit_t('mmHg ', c_mmHg,   C_PRESS), &
        unit_t('rpm  ', c_rpm,    C_ROT),   &
        unit_t('hz   ', 1.0,      C_FREQ)   ]

    ! SI prefixes: symbol and the count of prefixed units per base unit
    character(len=1), parameter :: PREFIX_SYM(13) = &
        [ 'a','f','p','n','u','m','c','k','M','G','T','P','E' ]
    real, parameter :: PREFIX_FAC(13) = &
        [ 1.0e18, 1.0e15, 1.0e12, 1.0e9, 1.0e6, 1.0e3, 1.0e2, &
          1.0e-3, 1.0e-6, 1.0e-9, 1.0e-12, 1.0e-15, 1.0e-18 ]

contains

    ! map common spellings/aliases onto canonical unit symbols
    function resolve_alias(s) result(canon)
        character(len=*), intent(in) :: s
        character(len=:), allocatable :: canon

        select case (trim(s))
        case ('degrees', 'degree');                   canon = 'deg'
        case ('radians', 'radian');                   canon = 'rad'
        case ('feet', 'foot');                        canon = 'ft'
        case ('meters', 'meter', 'metres', 'metre');  canon = 'm'
        case ('inches', 'inch');                      canon = 'in'
        case ('seconds', 'second', 'sec');            canon = 's'
        case ('minutes', 'minute');                   canon = 'min'
        case ('hours', 'hour');                       canon = 'hr'
        case ('slugs');                               canon = 'slug'
        case ('knots', 'knot');                       canon = 'kts'
        case ('newtons', 'newton');                   canon = 'N'
        case ('joules', 'joule');                     canon = 'J'
        case ('watts', 'watt');                       canon = 'W'
        case ('Hz', 'hertz');                         canon = 'hz'
        case ('RPM');                                 canon = 'rpm'
        case ('hPa');                                 canon = 'mbar'
        case ('Torr', 'torr');                        canon = 'mmHg'
        case default
            canon = trim(s)
        end select
    end function resolve_alias

    ! resolve a single token to its factor and category.
    ! Tries an exact symbol match first, then a single SI prefix + exact symbol.
    function unit_lookup(token, fac, cat) result(found)
        character(len=*), intent(in) :: token
        real,    intent(out) :: fac
        integer, intent(out) :: cat
        logical :: found
        character(len=:), allocatable :: name
        integer :: k, p

        name = resolve_alias(trim(token))
        fac = 0.0; cat = 0; found = .false.

        do k = 1, size(TABLE)
            if (name == trim(TABLE(k)%sym)) then
                fac = TABLE(k)%fac; cat = TABLE(k)%cat; found = .true.
                return
            end if
        end do

        if (len(name) >= 2) then
            do p = 1, size(PREFIX_SYM)
                if (name(1:1) /= PREFIX_SYM(p)) cycle
                do k = 1, size(TABLE)
                    if (name(2:) == trim(TABLE(k)%sym)) then
                        fac = TABLE(k)%fac * PREFIX_FAC(p)
                        cat = TABLE(k)%cat; found = .true.
                        return
                    end if
                end do
            end do
        end if
    end function unit_lookup

    ! factor for a single unit token; aborts on an unrecognized unit
    function get_factor(token) result(fac)
        character(len=*), intent(in) :: token
        real :: fac
        integer :: cat
        if (.not. unit_lookup(token, fac, cat)) then
            write(*,*) 'ERROR: Unknown unit "'//trim(resolve_alias(trim(token)))//'"'
            stop
        end if
    end function get_factor

    ! .true. if the numerator of the unit string contains an angle (deg or rad)
    function is_angular_unit(unit_str) result(is_angle)
        character(len=*), intent(in) :: unit_str
        logical :: is_angle
        character(len=:), allocatable, dimension(:) :: numer, denom
        character(len=:), allocatable :: tok
        integer :: i

        is_angle = .false.
        if (len_trim(unit_str) == 0) return
        call parse_units(unit_str, numer, denom)
        do i = 1, size(numer)
            tok = resolve_alias(trim(numer(i)))
            if (tok == 'deg' .or. tok == 'rad') then
                is_angle = .true.
                return
            end if
        end do
    end function is_angular_unit

    ! .true. if the (possibly prefixed) unit is a bare force unit
    function is_force_unit(unit_str) result(is_force)
        character(len=*), intent(in) :: unit_str
        logical :: is_force
        real :: fac
        integer :: cat

        is_force = .false.
        if (len_trim(unit_str) == 0) return
        if (unit_lookup(unit_str, fac, cat)) is_force = (cat == C_FORCE)
    end function is_force_unit

    ! .true. for a moment/torque unit: the explicit moment unit (J) or a
    ! force*length product with no denominator (e.g. ft-lbf, N-m)
    function is_torque_unit(unit_str) result(is_torque)
        character(len=*), intent(in) :: unit_str
        logical :: is_torque
        character(len=:), allocatable, dimension(:) :: numer, denom
        real :: fac
        integer :: cat, k
        logical :: has_force, has_length

        is_torque = .false.
        if (len_trim(unit_str) == 0) return

        if (unit_lookup(unit_str, fac, cat)) then
            if (cat == C_MOMENT) then
                is_torque = .true.
                return
            end if
        end if

        if (index(unit_str, '-') > 0 .or. index(unit_str, '*') > 0) then
            call parse_units(unit_str, numer, denom)
            has_force = .false.; has_length = .false.
            do k = 1, size(numer)
                if (unit_lookup(numer(k), fac, cat)) then
                    if (cat == C_FORCE) has_force  = .true.
                    if (cat == C_LEN)   has_length = .true.
                end if
            end do
            is_torque = (has_force .and. has_length .and. size(denom) == 0)
        end if
    end function is_torque_unit

    ! left-to-right evaluation of a small integer expression with + - * (no
    ! precedence), used for parenthesized exponents like ft^(2*2)
    function eval_exponent(expr) result(val)
        character(len=*), intent(in) :: expr
        integer :: val, acc, i, n
        character(len=1) :: c, op
        logical :: digit

        val = 0; acc = 0; op = '+'
        n = len_trim(expr)
        do i = 1, n + 1
            digit = .false.
            if (i <= n) then
                c = expr(i:i)
                digit = (c >= '0' .and. c <= '9')
            end if
            if (digit) then
                acc = acc*10 + (ichar(c) - ichar('0'))
            else
                select case (op)
                case ('+'); val = val + acc
                case ('-'); val = val - acc
                case ('*'); val = val * acc
                end select
                acc = 0
                if (i <= n) op = expr(i:i)
            end if
        end do

        if (val <= 0) then
            write(*,*) 'ERROR: Exponent expression "'//trim(expr)//'" is non-positive'
            stop
        end if
    end function eval_exponent

    ! normalize a raw unit string before tokenizing:
    !   ** -> ^,  ^(expr) -> evaluated integer,  /(group) -> per-term division,
    !   bare grouping parens stripped
    function preprocess(raw) result(out)
        character(len=*), intent(in) :: raw
        character(len=:), allocatable :: out, s
        character(len=20) :: numbuf
        integer :: i, j, n, depth

        ! pass 1: ** -> ^
        n = len_trim(raw)
        s = ''
        i = 1
        do while (i <= n)
            if (i < n) then
                if (raw(i:i+1) == '**') then
                    s = s // '^'
                    i = i + 2
                    cycle
                end if
            end if
            s = s // raw(i:i)
            i = i + 1
        end do

        ! pass 2: exponents, denominator groups, bare parens
        n = len(s)
        out = ''
        i = 1
        do while (i <= n)
            if (i < n) then
                ! ^( ... ) parenthesized exponent
                if (s(i:i) == '^' .and. s(i+1:i+1) == '(') then
                    depth = 0
                    do j = i+1, n
                        if (s(j:j) == '(') depth = depth + 1
                        if (s(j:j) == ')') depth = depth - 1
                        if (depth == 0) exit
                    end do
                    if (depth /= 0) then
                        write(*,*) 'ERROR: Unmatched ( in exponent of "'//trim(raw)//'"'
                        stop
                    end if
                    write(numbuf, '(I0)') eval_exponent(s(i+2:j-1))
                    out = out // '^' // trim(numbuf)
                    i = j + 1
                    cycle
                end if
                ! /( ... ) denominator group: every term inside divides
                if (s(i:i) == '/' .and. s(i+1:i+1) == '(') then
                    depth = 0
                    do j = i+1, n
                        if (s(j:j) == '(') depth = depth + 1
                        if (s(j:j) == ')') depth = depth - 1
                        if (depth == 0) exit
                    end do
                    if (depth /= 0) then
                        write(*,*) 'ERROR: Unmatched ( in denominator group of "'//trim(raw)//'"'
                        stop
                    end if
                    out = out // '/'
                    do depth = i+2, j-1
                        if (s(depth:depth) == '*' .or. s(depth:depth) == '-') then
                            out = out // '/'
                        else
                            out = out // s(depth:depth)
                        end if
                    end do
                    i = j + 1
                    cycle
                end if
            end if
            ! drop bare grouping parens
            if (s(i:i) == '(' .or. s(i:i) == ')') then
                i = i + 1
                cycle
            end if
            out = out // s(i:i)
            i = i + 1
        end do
    end function preprocess

    ! split a normalized string into terms at * and /, recording for each term
    ! whether it belongs in the denominator (the delimiter that precedes it is /)
    subroutine split_terms(str, toks, flags, ntok)
        character(len=*), intent(in) :: str
        character(len=:), allocatable, dimension(:), intent(out) :: toks
        logical, allocatable, dimension(:), intent(out) :: flags
        integer, intent(out) :: ntok
        integer :: i, n, start, maxlen, tlen, count
        logical :: cur, atbreak

        n = len_trim(str)

        ! pass 1: count terms and longest term
        count = 0; start = 1; maxlen = 0
        do i = 1, n + 1
            atbreak = (i > n)
            if (.not. atbreak) atbreak = (str(i:i) == '*' .or. str(i:i) == '/')
            if (atbreak) then
                tlen = i - start
                if (tlen > 0) then
                    count = count + 1
                    if (tlen > maxlen) maxlen = tlen
                end if
                start = i + 1
            end if
        end do

        ntok = count
        if (maxlen < 1) maxlen = 1
        allocate(character(len=maxlen) :: toks(ntok))
        allocate(flags(ntok))

        ! pass 2: capture term text and denominator flags
        count = 0; start = 1; cur = .false.
        do i = 1, n + 1
            atbreak = (i > n)
            if (.not. atbreak) atbreak = (str(i:i) == '*' .or. str(i:i) == '/')
            if (atbreak) then
                tlen = i - start
                if (tlen > 0) then
                    count = count + 1
                    toks(count) = str(start:i-1)
                    flags(count) = cur
                end if
                if (i <= n) cur = (str(i:i) == '/')
                start = i + 1
            end if
        end do
    end subroutine split_terms

    ! parse a compound unit string into expanded numerator and denominator unit
    ! lists (one entry per power), e.g. "slug-ft^2/s^2" ->
    !   numer = [slug, ft, ft],  denom = [s, s]
    subroutine parse_units(line, numer, denom)
        character(len=*), intent(in) :: line
        character(len=:), allocatable, dimension(:), intent(out) :: numer, denom

        character(len=:), allocatable :: pp, work, base
        character(len=:), allocatable, dimension(:) :: toks
        logical, allocatable :: flags(:)
        integer :: i, j, n, ntok, hat, e, ios, cnt_num, cnt_den, base_max, blen
        integer :: in, id

        pp = preprocess(line)
        n  = len_trim(pp)

        ! negative exponents are expressed with /, not ^-
        do i = 1, n - 1
            if (pp(i:i+1) == '^-') then
                write(*,*) 'ERROR: Negative exponents not allowed in "'//trim(line)// &
                           '". Use / for denominator.'
                stop
            end if
        end do

        ! hyphen multiplies, like *
        work = pp(1:n)
        do i = 1, len(work)
            if (work(i:i) == '-') work(i:i) = '*'
        end do

        call split_terms(work, toks, flags, ntok)

        ! size the expanded lists, accounting for exponents
        cnt_num = 0; cnt_den = 0; base_max = 1
        do i = 1, ntok
            hat = index(toks(i), '^')
            if (hat == 0) then
                e = 1
                blen = len_trim(toks(i))
            else
                read(toks(i)(hat+1:), *, iostat=ios) e
                if (ios /= 0) then
                    write(*,*) 'ERROR: Bad exponent in "'//trim(line)//'"'
                    stop
                end if
                blen = hat - 1
            end if
            if (blen > base_max) base_max = blen
            if (flags(i)) then
                cnt_den = cnt_den + e
            else
                cnt_num = cnt_num + e
            end if
        end do

        allocate(character(len=base_max) :: numer(cnt_num), denom(cnt_den))

        ! fill, repeating each base once per power
        in = 0; id = 0
        do i = 1, ntok
            hat = index(toks(i), '^')
            if (hat == 0) then
                e = 1
                base = trim(toks(i))
            else
                read(toks(i)(hat+1:), *) e
                base = toks(i)(1:hat-1)
            end if
            do j = 1, e
                if (flags(i)) then
                    id = id + 1
                    denom(id) = base
                else
                    in = in + 1
                    numer(in) = base
                end if
            end do
        end do
    end subroutine parse_units

    ! factor to convert internal units to the given external units
    ! e.g. conversion_factor_to("deg") = 57.296,  conversion_factor_to("m") = 0.3048
    function conversion_factor_to(input) result(cf)
        character(len=*), intent(in) :: input
        real :: cf
        character(len=:), allocatable, dimension(:) :: numer, denom
        integer :: i

        call parse_units(input, numer, denom)
        cf = 1.0
        do i = 1, size(numer)
            cf = cf * get_factor(numer(i))
        end do
        do i = 1, size(denom)
            cf = cf / get_factor(denom(i))
        end do
    end function conversion_factor_to

    ! factor to convert the given external units to internal units
    function conversion_factor_from(input) result(cf)
        character(len=*), intent(in) :: input
        real :: cf
        cf = 1.0 / conversion_factor_to(input)
    end function conversion_factor_from

    ! split "alpha[deg]" into var="alpha", units="deg".
    ! With no bracket the units argument is left unallocated.
    subroutine parse_variable_and_units(mono, var, units)
        character(len=*), intent(in) :: mono
        character(len=:), allocatable, intent(out) :: var, units
        integer :: i, l, lb, rb, nlb, nrb

        l = len_trim(mono)
        lb = 0; rb = 0; nlb = 0; nrb = 0
        do i = 1, l
            if (mono(i:i) == '[') then
                lb = i; nlb = nlb + 1
            end if
            if (mono(i:i) == ']') then
                rb = i; nrb = nrb + 1
            end if
        end do

        if (nlb > 1 .or. nrb > 1) then
            write(*,*) 'ERROR: Multiple unit brackets in "'//trim(mono)//'"'
            stop
        end if

        if (nlb == 1 .and. nrb == 1) then
            if (rb /= l) then
                write(*,*) 'ERROR: Units must be at end of "'//trim(mono)//'"'
                stop
            end if
            var   = mono(1:lb-1)
            units = mono(lb+1:rb-1)
        else
            var = mono(1:l)
        end if
    end subroutine parse_variable_and_units

end module units_m
