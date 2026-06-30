! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! Aerodynamic database: multilinear interpolation over a rectilinear grid.
!
! Loads a coefficient table from CSV, discovers (or trusts) its rectilinear grid
! structure, and evaluates dependent variables at arbitrary query points by
! successive one-dimensional linear interpolation across the bounding hypercube.
! A binary side-cache (checksum-guarded) skips the CSV parse on subsequent loads.
!
! CSV layout:
!   * lines beginning with '#' are comments,
!   * a "parameter,independent_variables,<k>" line declares the count of
!     independent-variable columns,
!   * the first ordinary line is the column-name header (independent variables
!     first, then dependent variables),
!   * every following line is one data point.
module aero_database_m
    use constants_m, only: TOLERANCE
    implicit none
    private

    integer, parameter :: DB_CHAR_LEN  = 200
    integer, parameter :: CACHE_MAGIC   = 1718185061   ! 'fsdb'
    integer, parameter :: CACHE_VERSION = 3            ! v3: original reader/cache rewrite

    type, public :: aero_db_t
        integer :: n_iv = 0           ! number of independent variables
        integer :: n_dv = 0           ! number of dependent variables
        integer :: n_pts = 0          ! total data points
        real, allocatable :: x(:,:)   ! x(n_pts, n_iv) independent-variable data
        real, allocatable :: y(:,:)   ! y(n_pts, n_dv) dependent-variable data
        character(len=DB_CHAR_LEN), allocatable, dimension(:) :: ind_vars
        character(len=DB_CHAR_LEN), allocatable, dimension(:) :: dep_vars
        logical :: saturate = .true.
        ! rectilinear grid description
        integer, allocatable :: n_pts_ind_vars(:)   ! breakpoints per dimension
        real, allocatable :: unique_ind_vars(:,:)   ! sorted breakpoint values
        integer :: max_corners = 0                  ! 2**n_iv
    contains
        procedure :: init        => aero_db_init
        procedure :: interpolate => aero_db_interpolate
    end type aero_db_t

contains

    ! ---------------------------------------------------------------------
    ! small utilities
    ! ---------------------------------------------------------------------

    function int_to_str(i) result(s)
        integer, intent(in) :: i
        character(len=:), allocatable :: s
        character(len=32) :: buf
        write(buf, '(I0)') i
        s = trim(buf)
    end function int_to_str

    ! join a directory and file name with a single separator
    function join_path(dir, name) result(full)
        character(len=*), intent(in) :: dir, name
        character(len=:), allocatable :: full
        integer :: n
        n = len_trim(dir)
        if (n == 0) then
            full = trim(name)
        else if (dir(n:n) == '/' .or. dir(n:n) == '\') then
            full = dir(1:n) // trim(name)
        else
            full = dir(1:n) // '/' // trim(name)
        end if
    end function join_path

    ! split a delimited line into trimmed-length tokens (empty fields dropped)
    subroutine tokenize(line, tokens, sep)
        character(len=*), intent(in) :: line
        character(len=:), allocatable, dimension(:), intent(out) :: tokens
        character(len=1), intent(in), optional :: sep
        character(len=1) :: d
        integer :: i, n, first, count, width, fieldlen

        d = ','
        if (present(sep)) d = sep
        n = len_trim(line)

        ! measure: number of non-empty fields and the longest one
        count = 0; width = 0; first = 1
        do i = 1, n + 1
            if (i > n .or. line(i:i) == d) then
                fieldlen = i - first
                if (fieldlen > 0) then
                    count = count + 1
                    if (fieldlen > width) width = fieldlen
                end if
                first = i + 1
            end if
        end do

        allocate(character(len=width) :: tokens(count))

        ! emit
        count = 0; first = 1
        do i = 1, n + 1
            if (i > n .or. line(i:i) == d) then
                fieldlen = i - first
                if (fieldlen > 0) then
                    count = count + 1
                    tokens(count) = line(first:i-1)
                end if
                first = i + 1
            end if
        end do
    end subroutine tokenize

    ! number of comma-separated fields in a line
    pure function field_count(line) result(n)
        character(len=*), intent(in) :: line
        integer :: n, i, l
        l = len_trim(line)
        if (l == 0) then
            n = 0
        else
            n = 1
            do i = 1, l
                if (line(i:i) == ',') n = n + 1
            end do
        end if
    end function field_count

    ! ---------------------------------------------------------------------
    ! grid helpers
    ! ---------------------------------------------------------------------

    ! row-major flat index (last dimension varies fastest) into a dims-shaped grid
    pure function flat_index(coord, dims) result(j)
        integer, intent(in) :: coord(:), dims(:)
        integer :: j, v, w, stride, nd
        nd = size(dims)
        j = 1
        do v = 1, nd
            stride = 1
            do w = v + 1, nd
                stride = stride * dims(w)
            end do
            j = j + (coord(v) - 1) * stride
        end do
    end function flat_index

    ! collect the distinct values of `raw` into ascending order, treating values
    ! within TOLERANCE of each other as identical
    subroutine sorted_unique(raw, n, vals, m)
        real, intent(in) :: raw(:)
        integer, intent(in) :: n
        real, allocatable, intent(out) :: vals(:)
        integer, intent(out) :: m
        real :: buf(n)
        integer :: i, lo, hi, mid, pos
        logical :: present_already

        m = 0
        do i = 1, n
            lo = 1; hi = m; present_already = .false.
            do while (lo <= hi)
                mid = (lo + hi) / 2
                if (abs(buf(mid) - raw(i)) <= TOLERANCE) then
                    present_already = .true.
                    exit
                else if (buf(mid) < raw(i)) then
                    lo = mid + 1
                else
                    hi = mid - 1
                end if
            end do
            if (present_already) cycle
            pos = lo                       ! ascending insertion point
            buf(pos+1:m+1) = buf(pos:m)    ! open a gap
            buf(pos) = raw(i)
            m = m + 1
        end do

        allocate(vals(m))
        vals = buf(1:m)
    end subroutine sorted_unique

    ! index of the breakpoint equal (within TOLERANCE) to val
    function breakpoint_index(a, n, val) result(idx)
        real, intent(in) :: a(:)
        integer, intent(in) :: n
        real, intent(in) :: val
        integer :: idx, lo, hi, mid
        lo = 1; hi = n
        do while (lo <= hi)
            mid = (lo + hi) / 2
            if (abs(a(mid) - val) < TOLERANCE) then
                idx = mid
                return
            else if (a(mid) < val) then
                lo = mid + 1
            else
                hi = mid - 1
            end if
        end do
        write(*,*) 'ERROR: breakpoint not found while gridding value: ', val
        stop
    end function breakpoint_index

    ! locate the bracket [il, ih] and interpolation fraction f for query s in the
    ! ascending breakpoint array a(1:n). Out-of-range queries clamp (f=0 or 1)
    ! when saturating, otherwise abort.
    subroutine bracket(a, n, s, il, ih, f, do_saturate)
        real, intent(in) :: a(:)
        integer, intent(in) :: n
        real, intent(in) :: s
        integer, intent(out) :: il, ih
        real, intent(out) :: f
        logical, intent(in) :: do_saturate
        integer :: lo, hi, mid

        if (s <= a(1)) then
            il = 1; ih = 2; f = 0.0
            if (.not. do_saturate .and. s < a(1)) then
                write(*,*) 'ERROR: Value below table range: ', s, ' < ', a(1)
                stop
            end if
            return
        end if
        if (s >= a(n)) then
            il = n - 1; ih = n; f = 1.0
            if (.not. do_saturate .and. s > a(n)) then
                write(*,*) 'ERROR: Value above table range: ', s, ' > ', a(n)
                stop
            end if
            return
        end if

        lo = 1; hi = n
        do while (hi - lo > 1)
            mid = (lo + hi) / 2
            if (a(mid) <= s) then
                lo = mid
            else
                hi = mid
            end if
        end do
        il = lo; ih = hi
        f = (s - a(il)) / (a(ih) - a(il))
    end subroutine bracket

    ! ---------------------------------------------------------------------
    ! CSV loading
    ! ---------------------------------------------------------------------

    subroutine load_csv(t, fn, pn, verbose)
        type(aero_db_t), intent(inout) :: t
        character(len=*), intent(in) :: fn
        character(len=*), intent(in), optional :: pn
        logical, intent(in), optional :: verbose

        character(len=:), allocatable :: path
        character(len=:), allocatable, dimension(:) :: cols
        character(len=DB_CHAR_LEN*100) :: line
        logical :: verb, exists, in_data
        integer :: fid, ios, i, ncol, ncol_expect, npts, cap, n_rows
        real, allocatable :: row(:), xb(:,:), yb(:,:), xg(:,:), yg(:,:)
        integer, parameter :: CAP0 = 1024

        verb = .true.;  if (present(verbose)) verb = verbose
        if (verb) write(*,*) '  Reading database: '//trim(fn)

        if (present(pn)) then
            path = join_path(pn, fn)
        else
            path = trim(fn)
        end if

        inquire(file=path, exist=exists)
        if (.not. exists) then
            write(*,*) 'ERROR: Database CSV file does not exist: '//trim(path)
            stop
        end if

        open(newunit=fid, file=path, status='old', action='read', iostat=ios)
        if (ios /= 0) then
            write(*,*) 'ERROR: Cannot open file '//trim(path)
            stop
        end if

        t%n_iv = 0; t%n_dv = 0
        npts = 0; cap = 0; n_rows = 0; ncol_expect = 0
        in_data = .false.

        do
            read(fid, '(A)', iostat=ios) line
            if (ios /= 0) exit
            n_rows = n_rows + 1
            if (line(1:1) == '#') cycle

            if (in_data) then
                ncol = field_count(line)
                if (ncol /= ncol_expect) then
                    write(*,*) 'ERROR: Row '//int_to_str(n_rows)//' has '//int_to_str(ncol)// &
                               ' columns (expected '//int_to_str(ncol_expect)//') in '//trim(path)
                    stop
                end if
                if (npts >= cap) then
                    if (cap == 0) then
                        cap = CAP0
                        allocate(xb(cap, t%n_iv), yb(cap, t%n_dv))
                    else
                        cap = cap * 2
                        allocate(xg(cap, t%n_iv), yg(cap, t%n_dv))
                        xg(1:npts, :) = xb(1:npts, :)
                        yg(1:npts, :) = yb(1:npts, :)
                        call move_alloc(xg, xb)
                        call move_alloc(yg, yb)
                    end if
                end if
                npts = npts + 1
                read(line, *) row
                xb(npts, :) = row(1:t%n_iv)
                yb(npts, :) = row(t%n_iv+1:)
                cycle
            end if

            ! still in the header section
            call tokenize(line, cols)
            if (trim(cols(1)) == 'parameter') then
                if (trim(cols(2)) == 'independent_variables') read(cols(3), *) t%n_iv
            else
                in_data = .true.
                if (t%n_iv == 0) then
                    write(*,*) 'ERROR: Number of independent variables not specified in '//trim(path)
                    close(fid)
                    stop
                end if
                t%n_dv = size(cols) - t%n_iv
                ncol_expect = t%n_iv + t%n_dv
                allocate(t%ind_vars(t%n_iv), t%dep_vars(t%n_dv), row(ncol_expect))
                do i = 1, t%n_iv
                    t%ind_vars(i) = trim(adjustl(cols(i)))
                end do
                do i = 1, t%n_dv
                    t%dep_vars(i) = trim(adjustl(cols(t%n_iv + i)))
                end do
            end if
            deallocate(cols)
        end do
        close(fid)

        if (verb) write(*,*) '    Rows: '//int_to_str(n_rows)//', Points: '//int_to_str(npts)// &
                             ', IVs: '//int_to_str(t%n_iv)//', DVs: '//int_to_str(t%n_dv)

        t%n_pts = npts
        allocate(t%x(npts, t%n_iv), t%y(npts, t%n_dv))
        t%x = xb(1:npts, :)
        t%y = yb(1:npts, :)
        deallocate(xb, yb, row)
    end subroutine load_csv

    ! ---------------------------------------------------------------------
    ! initialization
    ! ---------------------------------------------------------------------

    subroutine aero_db_init(t, fn, pn, verbose, saturate, presorted)
        class(aero_db_t), intent(out) :: t
        character(len=*), intent(in) :: fn
        character(len=*), intent(in), optional :: pn
        logical, intent(in), optional :: verbose, saturate, presorted

        real, allocatable :: xr(:,:), yr(:,:), col_unique(:), stage(:,:)
        integer, allocatable :: coord(:)
        integer :: i, j, d, m, k, stride, max_bp
        logical :: verb, do_sort
        character(len=:), allocatable :: path, cache
        integer(8) :: csv_size

        verb = .true.;   if (present(verbose)) verb = verbose
        t%saturate = .true.;  if (present(saturate)) t%saturate = saturate
        do_sort = .true.;     if (present(presorted)) do_sort = .not. presorted

        if (present(pn)) then
            path = join_path(pn, fn)
        else
            path = trim(fn)
        end if

        ! fast path: load the binary cache if it matches the CSV
        cache = cache_name(path)
        inquire(file=path, size=csv_size)
        if (read_cache(t, cache, csv_size, fnv1a_file(path))) then
            if (present(saturate)) t%saturate = saturate
            if (verb) write(*,*) '  Loaded from cache: '//trim(fn)//' ('// &
                                 int_to_str(t%n_pts)//' points)'
            return
        end if

        call load_csv(t, fn, pn, verb)
        k = t%n_pts
        allocate(t%n_pts_ind_vars(t%n_iv))

        if (do_sort) then
            ! keep a copy of the raw rows, then place each into grid order
            allocate(xr(k, t%n_iv), yr(k, t%n_dv))
            xr = t%x;  yr = t%y
            t%x = 0.0; t%y = 0.0

            ! extract each dimension's breakpoints once, staging into a (k x n_iv)
            ! scratch, then pack into the right-sized table
            if (verb) write(*,*) '    Determining unique breakpoint values'
            allocate(stage(k, t%n_iv))
            do i = 1, t%n_iv
                call sorted_unique(xr(:,i), k, col_unique, m)
                t%n_pts_ind_vars(i) = m
                stage(1:m, i) = col_unique(1:m)
                deallocate(col_unique)
            end do

            max_bp = maxval(t%n_pts_ind_vars)
            allocate(t%unique_ind_vars(max_bp, t%n_iv))
            t%unique_ind_vars = -1.0e9
            do i = 1, t%n_iv
                m = t%n_pts_ind_vars(i)
                t%unique_ind_vars(1:m, i) = stage(1:m, i)
            end do
            deallocate(stage)

            if (verb) write(*,*) '    Sorting '//int_to_str(k)//' points into rectilinear grid'
            allocate(coord(t%n_iv))
            do i = 1, k
                do d = 1, t%n_iv
                    coord(d) = breakpoint_index(t%unique_ind_vars(:,d), t%n_pts_ind_vars(d), xr(i,d))
                end do
                j = flat_index(coord, t%n_pts_ind_vars)
                if (j < 1 .or. j > k) then
                    write(*,*) 'ERROR: Computed grid index out of range during sorting'
                    write(*,*) '  Point ', i, ' maps to j =', j, ' (max =', k, ')'
                    stop
                end if
                t%x(j,:) = xr(i,:)
                t%y(j,:) = yr(i,:)
            end do
            deallocate(coord, xr, yr)
        else
            ! presorted: read the grid shape straight off the column strides
            if (verb) write(*,*) '    Presorted: discovering grid structure'
            stride = 1
            do i = t%n_iv, 1, -1
                m = 1
                j = 1 + stride
                do while (j <= k)
                    if (abs(t%x(j,i) - t%x(1,i)) < TOLERANCE) exit
                    m = m + 1
                    j = j + stride
                end do
                t%n_pts_ind_vars(i) = m
                stride = stride * m
            end do

            if (product(t%n_pts_ind_vars) /= k) then
                write(*,*) 'ERROR: Presorted grid dimensions do not match point count'
                write(*,*) '  Grid product =', product(t%n_pts_ind_vars), ', n_pts =', k
                stop
            end if

            max_bp = maxval(t%n_pts_ind_vars)
            allocate(t%unique_ind_vars(max_bp, t%n_iv))
            t%unique_ind_vars = -1.0e9
            stride = 1
            do i = t%n_iv, 1, -1
                do j = 1, t%n_pts_ind_vars(i)
                    t%unique_ind_vars(j,i) = t%x(1 + (j-1)*stride, i)
                end do
                stride = stride * t%n_pts_ind_vars(i)
            end do
        end if

        t%max_corners = 2 ** t%n_iv

        call write_cache(t, cache, csv_size, fnv1a_file(path))
        if (verb) write(*,*) '    Wrote cache: '//trim(cache)
        if (verb) write(*,*) '    Database initialized: '//int_to_str(k)//' points on '// &
                             int_to_str(t%n_iv)//'-D grid'
    end subroutine aero_db_init

    ! ---------------------------------------------------------------------
    ! interpolation
    ! ---------------------------------------------------------------------

    function aero_db_interpolate(t, x) result(y)
        class(aero_db_t), intent(in) :: t
        real, intent(in) :: x(t%n_iv)
        real :: y(t%n_dv)

        integer :: il(t%n_iv), ih(t%n_iv), corner(t%n_iv)
        real :: f(t%n_iv), xx(t%n_iv)
        real :: cube(t%max_corners, t%n_dv)
        integer :: i, c, ncur, half

        ! clamp the query to the grid when saturating
        do i = 1, t%n_iv
            if (t%saturate) then
                xx(i) = max(t%unique_ind_vars(1, i), &
                            min(t%unique_ind_vars(t%n_pts_ind_vars(i), i), x(i)))
            else
                xx(i) = x(i)
            end if
        end do

        ! per-dimension bracket and fraction
        do i = 1, t%n_iv
            call bracket(t%unique_ind_vars(:t%n_pts_ind_vars(i), i), t%n_pts_ind_vars(i), &
                         xx(i), il(i), ih(i), f(i), t%saturate)
        end do

        ! gather the 2**n_iv hypercube corners; bit (i-1) of c chooses high/low in dim i
        do c = 0, t%max_corners - 1
            do i = 1, t%n_iv
                if (btest(c, i-1)) then
                    corner(i) = ih(i)
                else
                    corner(i) = il(i)
                end if
            end do
            cube(c+1, :) = t%y(flat_index(corner, t%n_pts_ind_vars), :)
        end do

        ! collapse one dimension at a time: blend adjacent low/high pairs
        ncur = t%max_corners
        do i = 1, t%n_iv
            half = ncur / 2
            do c = 0, half - 1
                cube(c+1, :) = cube(2*c+1, :) + (cube(2*c+2, :) - cube(2*c+1, :)) * f(i)
            end do
            ncur = half
        end do

        y = cube(1, :)
    end function aero_db_interpolate

    ! ---------------------------------------------------------------------
    ! binary cache
    ! ---------------------------------------------------------------------

    ! cache file name: CSV path with its extension replaced by .dat
    function cache_name(csv) result(path)
        character(len=*), intent(in) :: csv
        character(len=:), allocatable :: path
        integer :: i, dot
        dot = 0
        do i = len_trim(csv), 1, -1
            if (csv(i:i) == '.') then
                dot = i
                exit
            end if
        end do
        if (dot > 0) then
            path = csv(1:dot) // 'dat'
        else
            path = trim(csv) // '.dat'
        end if
    end function cache_name

    ! FNV-1a hash of the raw file bytes; detects in-place edits that leave the
    ! file size unchanged
    function fnv1a_file(path) result(hash)
        character(len=*), intent(in) :: path
        integer(8) :: hash
        integer(8), parameter :: OFFSET = 1469598103934665603_8
        integer(8), parameter :: PRIME  = 1099511628211_8
        integer(8) :: fsize, pos
        integer :: fid, ios, i, got
        logical :: exists
        integer, parameter :: BUFN = 65536
        integer(1) :: bytes(BUFN)

        hash = OFFSET
        inquire(file=path, exist=exists, size=fsize)
        if (.not. exists .or. fsize <= 0) return

        open(newunit=fid, file=path, form='unformatted', access='stream', &
             status='old', action='read', iostat=ios)
        if (ios /= 0) return

        pos = 1
        do while (pos <= fsize)
            got = int(min(int(BUFN, 8), fsize - pos + 1))
            read(fid, pos=pos, iostat=ios) bytes(1:got)
            if (ios /= 0) exit
            do i = 1, got
                hash = ieor(hash, iand(int(bytes(i), 8), 255_8))
                hash = hash * PRIME
            end do
            pos = pos + got
        end do
        close(fid)
    end function fnv1a_file

    subroutine write_cache(t, cache, csv_size, csv_hash)
        type(aero_db_t), intent(in) :: t
        character(len=*), intent(in) :: cache
        integer(8), intent(in) :: csv_size, csv_hash
        integer :: fid, ios

        open(newunit=fid, file=cache, form='unformatted', access='stream', &
             status='replace', iostat=ios)
        if (ios /= 0) return

        write(fid) CACHE_MAGIC, CACHE_VERSION
        write(fid) csv_size, csv_hash
        write(fid) t%n_iv, t%n_dv, t%n_pts, t%max_corners, size(t%unique_ind_vars, 1)
        write(fid) t%saturate
        write(fid) t%n_pts_ind_vars
        write(fid) t%ind_vars
        write(fid) t%dep_vars
        write(fid) t%unique_ind_vars
        write(fid) t%x
        write(fid) t%y
        close(fid)
    end subroutine write_cache

    function read_cache(t, cache, csv_size, csv_hash) result(ok)
        type(aero_db_t), intent(out) :: t
        character(len=*), intent(in) :: cache
        integer(8), intent(in) :: csv_size, csv_hash
        logical :: ok

        integer :: fid, ios, magic, version, max_bp
        integer(8) :: stored_size, stored_hash
        logical :: exists

        ok = .false.
        inquire(file=cache, exist=exists)
        if (.not. exists) return

        open(newunit=fid, file=cache, form='unformatted', access='stream', &
             status='old', iostat=ios)
        if (ios /= 0) return

        ! validate the entire header before allocating anything
        read(fid, iostat=ios) magic, version
        if (ios /= 0 .or. magic /= CACHE_MAGIC .or. version /= CACHE_VERSION) then
            close(fid); return
        end if
        read(fid, iostat=ios) stored_size, stored_hash
        if (ios /= 0 .or. stored_size /= csv_size .or. stored_hash /= csv_hash) then
            close(fid); return
        end if
        read(fid, iostat=ios) t%n_iv, t%n_dv, t%n_pts, t%max_corners, max_bp
        if (ios /= 0) then; close(fid); return; end if
        read(fid, iostat=ios) t%saturate
        if (ios /= 0) then; close(fid); return; end if

        allocate(t%n_pts_ind_vars(t%n_iv))
        read(fid, iostat=ios) t%n_pts_ind_vars
        if (ios /= 0) then; close(fid); return; end if

        allocate(t%ind_vars(t%n_iv), t%dep_vars(t%n_dv))
        read(fid, iostat=ios) t%ind_vars
        if (ios /= 0) then; close(fid); return; end if
        read(fid, iostat=ios) t%dep_vars
        if (ios /= 0) then; close(fid); return; end if

        allocate(t%unique_ind_vars(max_bp, t%n_iv))
        read(fid, iostat=ios) t%unique_ind_vars
        if (ios /= 0) then; close(fid); return; end if

        allocate(t%x(t%n_pts, t%n_iv), t%y(t%n_pts, t%n_dv))
        read(fid, iostat=ios) t%x
        if (ios /= 0) then; close(fid); return; end if
        read(fid, iostat=ios) t%y
        if (ios /= 0) then; close(fid); return; end if

        close(fid)
        ok = .true.
    end function read_cache

end module aero_database_m
