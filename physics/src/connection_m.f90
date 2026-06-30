! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

!===============================================================================
! connection_m.f90 - Communication channels (UDP, file) with cross-platform support
!
! Cross-platform notes:
! - On POSIX (Linux/macOS): Network sockets work out of the box
! - On Windows: WSAStartup/WSACleanup must be called (handled by udp_m)
! 
! Build with appropriate preprocessor flag:
!   -DWINDOWS  for Windows builds
!===============================================================================
module connection_m
    use udp_m
    use iso_c_binding
    use json_m
    use jsonx_m
    implicit none
    private

    ! Relative slack on the rate-limit comparison.  Absorbs floating-point
    ! drift between the accumulated sim time and the accumulated last-update
    ! time so an update is not spuriously skipped when the controller rate
    ! matches the sim time step exactly (one part per million is far larger
    ! than realistic double-precision accumulation error, yet negligible for
    ! control timing).
    real, parameter :: REFRESH_REL_TOL = 1.0e-6

    ! Public types
    public :: channel_t, udp_channel_t, file_channel_t, connection_t
    
    ! Public procedures
    public :: net_initialize, net_finalize
    public :: create_channel
    public :: send_with_entity_id, recv_with_entity_id
    
    !---------------------------------------------------------------------------
    ! Abstract channel base type
    !---------------------------------------------------------------------------
    type, abstract :: channel_t
        integer :: n_values = 0          ! Number of values to send/receive
        logical :: is_sender = .true.    ! True for send, false for receive
        real, allocatable :: buffer(:)   ! Buffer for received values
    contains
        procedure(channel_init_if), deferred :: init
        procedure(channel_send_if), deferred :: send
        procedure(channel_recv_if), deferred :: recv
        procedure :: cleanup => channel_cleanup
    end type channel_t
    
    abstract interface
        subroutine channel_init_if(self, json_ptr, n_vals)
            import :: channel_t, json_value
            class(channel_t), intent(out) :: self
            type(json_value), pointer, intent(in) :: json_ptr
            integer, intent(in), optional :: n_vals
        end subroutine channel_init_if
        
        subroutine channel_send_if(self, values)
            import :: channel_t
            class(channel_t), intent(in) :: self
            real, intent(in) :: values(:)
        end subroutine channel_send_if
        
        subroutine channel_recv_if(self, values)
            import :: channel_t
            class(channel_t), intent(inout) :: self
            real, intent(out) :: values(:)
        end subroutine channel_recv_if
    end interface
    
    !---------------------------------------------------------------------------
    ! UDP channel implementation
    !---------------------------------------------------------------------------
    type, extends(channel_t) :: udp_channel_t
        integer(c_int) :: socket = 0
        character(len=64) :: ip_address = '127.0.0.1'
        integer :: port = 0
        logical :: double_precision = .false.
        logical :: blocking = .false.
    contains
        procedure :: init => udp_init
        procedure :: send => udp_send
        procedure :: recv => udp_recv
    end type udp_channel_t
    
    !---------------------------------------------------------------------------
    ! File channel implementation
    !---------------------------------------------------------------------------
    type, extends(channel_t) :: file_channel_t
        integer :: unit_num = -1
        character(len=256) :: filename = ''
    contains
        procedure :: init => file_init
        procedure :: send => file_send
        procedure :: recv => file_recv
        procedure :: cleanup => file_cleanup
    end type file_channel_t
    
    !---------------------------------------------------------------------------
    ! Connection wrapper with rate limiting
    !---------------------------------------------------------------------------
    type :: connection_t
        class(channel_t), allocatable :: channel
        real :: refresh_interval = 0.0   ! Minimum time between sends [s]
        real :: last_time = -1.0e30      ! Last send/recv sim time
        real :: current_time = 0.0       ! Current sim time (set externally)
    contains
        procedure :: init => connection_init
        procedure :: send => connection_send
        procedure :: recv => connection_recv
        procedure :: is_ready => connection_is_ready
        procedure :: set_time => connection_set_time
        procedure :: cleanup => connection_cleanup
    end type connection_t

contains

    !===========================================================================
    ! Cross-platform network initialization
    !===========================================================================
    subroutine net_initialize()
#ifdef WINDOWS
        call udp_initialize()
#endif
        ! POSIX: no initialization needed
    end subroutine net_initialize
    
    subroutine net_finalize()
#ifdef WINDOWS
        call udp_finalize()
#endif
        ! POSIX: no cleanup needed
    end subroutine net_finalize
    
    !===========================================================================
    ! Channel base class methods
    !===========================================================================
    subroutine channel_cleanup(self)
        class(channel_t), intent(inout) :: self
        if (allocated(self%buffer)) deallocate(self%buffer)
    end subroutine channel_cleanup
    
    !===========================================================================
    ! UDP channel implementation
    !===========================================================================
    subroutine udp_init(self, json_ptr, n_vals)
        class(udp_channel_t), intent(out) :: self
        type(json_value), pointer, intent(in) :: json_ptr
        integer, intent(in), optional :: n_vals
        
        character(len=:), allocatable :: type_str, channel_type, ip_temp
        
        ! Get number of values
        if (present(n_vals)) then
            self%n_values = n_vals
        else
            call jsonx_get(json_ptr, 'number_of_values', self%n_values)
        end if
        
        ! Determine send/receive mode
        call jsonx_get(json_ptr, 'type', type_str)
        self%is_sender = (type_str == 'send')
        if (.not. self%is_sender) then
            allocate(self%buffer(self%n_values))
            self%buffer = 0.0
        end if
        if (allocated(type_str)) deallocate(type_str)
        
        ! Verify channel type
        call jsonx_get(json_ptr, 'channel_type', channel_type)
        if (channel_type /= 'udp' .and. channel_type /= 'UDP') then
            write(*,*) 'ERROR: Expected UDP channel type'
            stop
        end if
        if (allocated(channel_type)) deallocate(channel_type)
        
        ! Open socket
        self%socket = udp_open_socket()
        
        ! Get port
        call jsonx_get(json_ptr, 'port_ID', self%port)
        
        ! Get precision
        call jsonx_get(json_ptr, 'double_precision', self%double_precision, .false.)
        
        if (self%is_sender) then
            ! Sender: get destination IP (use allocatable temp, then copy)
            self%ip_address = '127.0.0.1'  ! Default
            call jsonx_get(json_ptr, 'IP_address', ip_temp)
            if (allocated(ip_temp)) then
                self%ip_address = ip_temp
                deallocate(ip_temp)
            end if
        else
            ! Receiver: bind socket.  The socket is ALWAYS kept non-blocking;
            ! 'wait_for_input' is honoured in software (see udp_recv) instead of
            ! via an unbounded OS-level blocking recv.  This lets the simulator
            ! handle controller refresh rates faster or slower than the sim time
            ! step without freezing, and lets a blocking receive still drain a
            ! backed-up socket to the most recent sample.
            call jsonx_get(json_ptr, 'wait_for_input', self%blocking, .false.)
            call udp_bind_socket(self%socket, self%port)
            call udp_set_nonblocking(self%socket)
        end if
        
    end subroutine udp_init
    
    subroutine udp_send(self, values)
        class(udp_channel_t), intent(in) :: self
        real, intent(in) :: values(:)
        
        if (self%double_precision) then
            call udp_send_real8(self%socket, trim(self%ip_address), self%port, values)
        else
            call udp_send_real4(self%socket, trim(self%ip_address), self%port, values)
        end if
    end subroutine udp_send
    
    subroutine udp_recv(self, values)
        class(udp_channel_t), intent(inout) :: self
        real, intent(out) :: values(:)
        real :: temp(self%n_values)
        integer :: got_data
        logical :: received

        ! Drain every packet currently queued (non-blocking), keeping only the
        ! most recent sample, so a controller faster than the sim time step
        ! never piles up latency on the socket.
        !
        ! When 'wait_for_input' is set and nothing has arrived yet, block until
        ! the controller delivers exactly one packet, then resume draining in
        ! case more arrived meanwhile.  The wait uses a real OS blocking recv
        ! (the thread sleeps at ~0% CPU) rather than a busy-spin, so a slow
        ! same-machine controller is not starved of CPU while it computes its
        ! step.  This wait only runs on steps where the connection is actually
        ! due for fresh input (rate-limited by connection_is_ready), so a
        ! controller slower than the sim time step reuses the buffered sample on
        ! intermediate steps instead of freezing.
        received = .false.
        do
            if (self%double_precision) then
                got_data = udp_recv_real8_nb(self%socket, temp)
            else
                got_data = udp_recv_real4_nb(self%socket, temp)
            end if

            if (got_data /= 1) then
                if (self%blocking .and. .not. received) then
                    ! wait_for_input: sleep until the controller sends, then
                    ! loop back to drain any further queued packets.
                    call udp_set_blocking(self%socket)
                    if (self%double_precision) then
                        call udp_recv_real8(self%socket, temp)
                    else
                        call udp_recv_real4(self%socket, temp)
                    end if
                    call udp_set_nonblocking(self%socket)
                    received = .true.
                    self%buffer = temp
                    cycle
                end if
                exit
            end if

            received = .true.
            self%buffer = temp
        end do

        values = self%buffer
    end subroutine udp_recv
    
    !===========================================================================
    ! File channel implementation
    !===========================================================================
    subroutine file_init(self, json_ptr, n_vals)
        class(file_channel_t), intent(out) :: self
        type(json_value), pointer, intent(in) :: json_ptr
        integer, intent(in), optional :: n_vals
        
        character(len=:), allocatable :: type_str, channel_type
        character(len=:), allocatable :: fn, pathname
        character(len=512) :: full_path
        integer :: n
        
        ! Get number of values
        if (present(n_vals)) then
            self%n_values = n_vals
        else
            call jsonx_get(json_ptr, 'number_of_values', self%n_values)
        end if
        
        ! Determine send/receive mode
        call jsonx_get(json_ptr, 'type', type_str)
        self%is_sender = (type_str == 'send')
        if (.not. self%is_sender) then
            allocate(self%buffer(self%n_values))
            self%buffer = 0.0
        end if
        if (allocated(type_str)) deallocate(type_str)
        
        ! Verify channel type
        call jsonx_get(json_ptr, 'channel_type', channel_type)
        if (channel_type /= 'file') then
            write(*,*) 'ERROR: Expected file channel type'
            stop
        end if
        if (allocated(channel_type)) deallocate(channel_type)
        
        ! Get filename
        call jsonx_get(json_ptr, 'filename', fn)
        call jsonx_get(json_ptr, 'pathname', pathname)
        
        ! Build full path
        if (allocated(pathname) .and. len_trim(pathname) > 0) then
            n = len_trim(pathname)
            if (pathname(n:n) == '/' .or. pathname(n:n) == '\') then
                full_path = trim(pathname) // trim(fn)
            else
                full_path = trim(pathname) // '/' // trim(fn)
            end if
        else
            full_path = trim(fn)
        end if
        self%filename = trim(full_path)
        
        if (allocated(fn)) deallocate(fn)
        if (allocated(pathname)) deallocate(pathname)
        
        ! Open file for writing if sender
        if (self%is_sender) then
            open(newunit=self%unit_num, file=trim(self%filename), &
                 status='replace', action='write')
        end if
        
    end subroutine file_init
    
    subroutine file_send(self, values)
        class(file_channel_t), intent(in) :: self
        real, intent(in) :: values(:)
        
        if (.not. self%is_sender) then
            write(*,*) 'ERROR: Attempting to send on receive-only file channel'
            stop
        end if
        
        write(self%unit_num, '(*(ES20.12E3,:,","))') values
    end subroutine file_send
    
    subroutine file_recv(self, values)
        class(file_channel_t), intent(inout) :: self
        real, intent(out) :: values(:)

        ! File receive not implemented (would need database interpolation)
        values = self%buffer
    end subroutine file_recv
    
    subroutine file_cleanup(self)
        class(file_channel_t), intent(inout) :: self
        if (self%unit_num > 0) close(self%unit_num)
        ! Cleanup buffer (can't call parent abstract method directly)
        if (allocated(self%buffer)) deallocate(self%buffer)
    end subroutine file_cleanup
    
    !===========================================================================
    ! Channel factory function
    !===========================================================================
    function create_channel(json_ptr, n_vals) result(ch)
        type(json_value), pointer, intent(in) :: json_ptr
        integer, intent(in), optional :: n_vals
        class(channel_t), allocatable :: ch
        
        character(len=:), allocatable :: ch_type
        
        call jsonx_get(json_ptr, 'channel_type', ch_type)
        
        select case (trim(ch_type))
        case ('udp', 'UDP')
            allocate(udp_channel_t :: ch)
        case ('file')
            allocate(file_channel_t :: ch)
        case default
            write(*,*) 'ERROR: Unknown channel type: ', trim(ch_type)
            stop
        end select
        
        if (present(n_vals)) then
            call ch%init(json_ptr, n_vals)
        else
            call ch%init(json_ptr)
        end if
        
        if (allocated(ch_type)) deallocate(ch_type)
    end function create_channel
    
    !===========================================================================
    ! Connection wrapper implementation
    !===========================================================================
    subroutine connection_init(self, json_ptr, n_vals)
        class(connection_t), intent(out) :: self
        type(json_value), pointer, intent(in) :: json_ptr
        integer, intent(in), optional :: n_vals
        
        real :: refresh_rate
        
        ! Create appropriate channel
        if (present(n_vals)) then
            self%channel = create_channel(json_ptr, n_vals)
        else
            self%channel = create_channel(json_ptr)
        end if
        
        ! Set up rate limiting
        call jsonx_get(json_ptr, 'refresh_rate', refresh_rate, 0.0)
        if (refresh_rate > 0.0) then
            self%refresh_interval = 1.0 / refresh_rate
        else
            self%refresh_interval = 1.0e-12  ! Essentially no limit
        end if
        
        ! Initialize time tracking (sim-time based)
        self%last_time = -self%refresh_interval
        self%current_time = 0.0
        
    end subroutine connection_init
    
    subroutine connection_send(self, values)
        class(connection_t), intent(inout) :: self
        real, intent(in) :: values(:)

        if (self%is_ready()) then
            call self%channel%send(values)
            self%last_time = self%last_time + self%refresh_interval
        end if
    end subroutine connection_send
    
    subroutine connection_recv(self, values)
        class(connection_t), intent(inout) :: self
        real, intent(out) :: values(:)

        if (self%is_ready()) then
            call self%channel%recv(values)
            self%last_time = self%last_time + self%refresh_interval
        else
            values = self%channel%buffer
        end if
    end subroutine connection_recv
    
    function connection_is_ready(self) result(ready)
        class(connection_t), intent(in) :: self
        logical :: ready

        ! Relax the threshold by a small fraction of the refresh interval so
        ! floating-point drift between the accumulated current_time and the
        ! accumulated last_time does not spuriously skip an update when the
        ! controller rate matches the sim time step exactly.
        ready = (self%current_time - self%last_time) >= &
                self%refresh_interval * (1.0 - REFRESH_REL_TOL)
    end function connection_is_ready
    
    subroutine connection_cleanup(self)
        class(connection_t), intent(inout) :: self
        if (allocated(self%channel)) then
            call self%channel%cleanup()
            deallocate(self%channel)
        end if
    end subroutine connection_cleanup

    subroutine connection_set_time(self, t)
        class(connection_t), intent(inout) :: self
        real, intent(in) :: t
        self%current_time = t
    end subroutine connection_set_time

    !===========================================================================
    ! Entity-ID-aware send: prepends 4-byte int32 entity_id before payload.
    ! Mirrors connection_send but calls the entity-ID UDP variants.
    !===========================================================================
    subroutine send_with_entity_id(conn, entity_id, values)
        type(connection_t), intent(inout) :: conn
        integer, intent(in) :: entity_id
        real, intent(in) :: values(:)

        if (.not. conn%is_ready()) return

        select type (ch => conn%channel)
        type is (udp_channel_t)
            if (ch%double_precision) then
                call udp_send_real8_with_id(ch%socket, trim(ch%ip_address), ch%port, entity_id, values)
            else
                call udp_send_real4_with_id(ch%socket, trim(ch%ip_address), ch%port, entity_id, values)
            end if
        class default
            ! file channel: fall back to plain send (entity_id ignored)
            call conn%channel%send(values)
        end select

        conn%last_time = conn%last_time + conn%refresh_interval
    end subroutine send_with_entity_id

    !===========================================================================
    ! Entity-ID-aware receive: drains UDP buffer, extracts int32 entity_id from
    ! first 4 bytes of each packet.  Returns entity_id=1 when rate-limited.
    !===========================================================================
    subroutine recv_with_entity_id(conn, entity_id, values, got_data)
        type(connection_t), intent(inout) :: conn
        integer, intent(out) :: entity_id
        real, intent(out) :: values(:)
        logical, intent(out) :: got_data

        integer :: n, temp_id, status
        real :: temp_vals(conn%channel%n_values)

        entity_id = 1          ! safe default (single-vehicle entity)
        got_data  = .false.
        n = conn%channel%n_values
        values(:n) = conn%channel%buffer   ! return buffered data if rate-limited

        if (.not. conn%is_ready()) return

        select type (ch => conn%channel)
        type is (udp_channel_t)
            ! Drain all pending packets, keeping the latest.  When
            ! 'wait_for_input' is set, keep polling until at least one packet
            ! arrives; like udp_recv this only runs when the connection is due
            ! for fresh input, so it never freezes on a controller/sim rate
            ! mismatch.
            do
                if (ch%double_precision) then
                    status = udp_recv_real8_nb_with_id(ch%socket, temp_id, temp_vals)
                else
                    status = udp_recv_real4_nb_with_id(ch%socket, temp_id, temp_vals)
                end if
                if (status /= 1) then
                    if (ch%blocking .and. .not. got_data) then
                        ! wait_for_input: sleep until the controller delivers one
                        ! packet (efficient OS blocking recv, no busy-spin), then
                        ! loop back to drain any that arrived meanwhile.
                        call udp_set_blocking(ch%socket)
                        if (ch%double_precision) then
                            status = udp_recv_real8_nb_with_id(ch%socket, temp_id, temp_vals)
                        else
                            status = udp_recv_real4_nb_with_id(ch%socket, temp_id, temp_vals)
                        end if
                        call udp_set_nonblocking(ch%socket)
                        if (status == 1) then
                            got_data  = .true.
                            entity_id = temp_id
                            values    = temp_vals
                            cycle              ! drain any further queued packets
                        end if
                    end if
                    exit                       ! nothing (more) to read
                end if
                got_data  = .true.
                entity_id = temp_id
                values    = temp_vals
            end do
            if (got_data) then
                ch%buffer         = values
                conn%last_time    = conn%last_time + conn%refresh_interval
            end if
        class default
            ! file channel: use regular recv, assume entity 1
            call conn%channel%recv(values)
            entity_id = 1
            got_data  = .true.
            conn%last_time = conn%last_time + conn%refresh_interval
        end select
    end subroutine recv_with_entity_id

end module connection_m