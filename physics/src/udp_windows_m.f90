! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

module udp_m
    use iso_c_binding
    implicit none

    private
    public :: udp_initialize, udp_finalize
    public :: udp_open_socket, udp_bind_socket, udp_close_socket
    public :: udp_send_real4, udp_send_real8
    public :: udp_recv_real4, udp_recv_real8
    public :: udp_recv_real4_nb, udp_recv_real8_nb
    public :: udp_send_real4_with_id, udp_send_real8_with_id
    public :: udp_recv_real4_nb_with_id, udp_recv_real8_nb_with_id
    public :: udp_set_nonblocking, udp_set_blocking

    ! Winsock constants
    integer(c_int), parameter :: AF_INET     = 2
    integer(c_int), parameter :: SOCK_DGRAM  = 2
    integer(c_int), parameter :: IPPROTO_UDP = 17
    integer(c_int), parameter :: INVALID_SOCKET = -1
    integer(c_int), parameter :: SOCKET_ERROR   = -1

    integer(c_long), parameter :: FIONBIO = int(Z'8004667E', c_long)

    !==========================================================
    ! Winsock2 data structures
    !==========================================================
    type, bind(C) :: in_addr
        integer(c_int) :: s_addr
    end type in_addr

    type, bind(C) :: sockaddr_in
        integer(c_short)         :: sin_family
        integer(c_short)        :: sin_port
        type(in_addr)            :: sin_addr
        character(kind=c_char)   :: sin_zero(8)
    end type sockaddr_in

    type, bind(C) :: WSAData
        integer(c_short) :: wVersion
        integer(c_short) :: wHighVersion
        character(kind=c_char) :: szDescription(257)
        character(kind=c_char) :: szSystemStatus(129)
        integer(c_short) :: iMaxSockets
        integer(c_short) :: iMaxUdpDg
        type(c_ptr) :: lpVendorInfo
    end type WSAData

    !==========================================================
    ! C Interfaces (Winsock2)
    !==========================================================
    interface
        function WSAStartup(wVersionRequested, lpWSAData) bind(C, name="WSAStartup")
            import :: c_int, c_short, c_ptr
            integer(c_short), value :: wVersionRequested
            type(c_ptr), value :: lpWSAData
            integer(c_int) :: WSAStartup
        end function

        subroutine WSACleanup() bind(C, name="WSACleanup")
        end subroutine

        function socket(domain, stype, protocol) bind(C, name="socket")
            import :: c_int
            integer(c_int), value :: domain, stype, protocol
            integer(c_int) :: socket
        end function

        function bind(sockfd, addr, addrlen) bind(C, name="bind")
            import :: c_int, c_size_t, c_ptr
            integer(c_int), value :: sockfd
            type(c_ptr), value :: addr
            integer(c_size_t), value :: addrlen
            integer(c_int) :: bind
        end function

        function sendto(sockfd, buf, len, flags, dest_addr, addrlen) bind(C, name="sendto")
            import :: c_int, c_size_t, c_ptr
            integer(c_int), value :: sockfd, flags
            type(c_ptr), value :: buf, dest_addr
            integer(c_size_t), value :: len, addrlen
            integer(c_int) :: sendto
        end function

        function recvfrom(sockfd, buf, len, flags, src_addr, addrlen) bind(C, name="recvfrom")
            import :: c_int, c_size_t, c_ptr
            integer(c_int), value :: sockfd, flags
            type(c_ptr), value :: buf, src_addr
            integer(c_size_t), value :: len, addrlen
            integer(c_int) :: recvfrom
        end function

        subroutine closesocket(sockfd) bind(C, name="closesocket")
            import :: c_int
            integer(c_int), value :: sockfd
!            integer(c_int) :: closesocket
        end subroutine

        function htons(port) bind(C, name="htons")
            import :: c_short
            integer(c_short), value :: port
            integer(c_short) :: htons
        end function

        function inet_addr(cp) bind(C, name="inet_addr")
            import :: c_char, c_int
            character(kind=c_char), dimension(*) :: cp
            integer(c_int) :: inet_addr
        end function

        function ioctlsocket(sockfd, cmd, argp) bind(C, name="ioctlsocket")
            import :: c_int, c_long, c_ptr
            integer(c_int), value :: sockfd
            integer(c_long), value :: cmd
            type(c_ptr), value :: argp
            integer(c_int) :: ioctlsocket
        end function
    end interface

contains

    !==========================================================
    ! Initialize and cleanup Winsock
    !==========================================================
    subroutine udp_initialize()
        type(WSAData), target :: wsa
        integer(c_int) :: ierr
        ierr = WSAStartup(int(Z'0202', c_short), c_loc(wsa))
        if (ierr /= 0) stop "WSAStartup failed"
    end subroutine

    subroutine udp_finalize()
        call WSACleanup()
    end subroutine

    !==========================================================
    ! Socket management
    !==========================================================
    function udp_open_socket() result(sockfd)
        integer(c_int) :: sockfd
        sockfd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if (sockfd == INVALID_SOCKET) stop "socket() failed"
    end function

    subroutine udp_bind_socket(sockfd, port)
        integer(c_int), value :: sockfd
        integer, value :: port
        type(sockaddr_in), target :: addr
        integer(c_int) :: ret
        integer :: i

        addr%sin_family = AF_INET
        addr%sin_port   = htons(int(port, c_short))
        addr%sin_addr%s_addr = 0_c_int
        addr%sin_zero = [(c_null_char, i=1,8)]

        ret = bind(sockfd, c_loc(addr), c_sizeof(addr))
        if (ret == SOCKET_ERROR) stop "bind() failed"
    end subroutine

    subroutine udp_close_socket(sockfd)
        integer(c_int), value :: sockfd
        call closesocket(sockfd)
    end subroutine

    subroutine udp_set_nonblocking(sockfd)
        integer(c_int), value :: sockfd
        integer(c_long), target :: nonblock
        integer(c_int) :: ret

        nonblock = 1_c_long
        ret = ioctlsocket(sockfd, FIONBIO, c_loc(nonblock))
        if (ret /= 0) stop "ioctlsocket(FIONBIO) failed"
    end subroutine

    subroutine udp_set_blocking(sockfd)
        integer(c_int), value :: sockfd
        integer(c_long), target :: nonblock
        integer(c_int) :: ret

        nonblock = 0_c_long
        ret = ioctlsocket(sockfd, FIONBIO, c_loc(nonblock))
        if (ret /= 0) stop "ioctlsocket(FIONBIO) failed"
    end subroutine

    !==========================================================
    ! Sending routines
    !==========================================================
    subroutine udp_send_real4(sockfd, host, port, ar)
        integer(c_int), value :: sockfd
        character(len=*), intent(in) :: host
        integer, value :: port
        real, dimension(:), intent(in) :: ar

        real(c_float), dimension(size(ar)), target :: arr
        type(sockaddr_in), target :: addr
        integer(c_int) :: ret
        integer :: i

        arr = real(ar, kind=c_float)
        addr%sin_family = AF_INET
        addr%sin_port   = htons(int(port, c_short))
        addr%sin_addr%s_addr = inet_addr(trim(host)//c_null_char)
        addr%sin_zero = [(c_null_char, i=1,8)]

        ret = sendto(sockfd, c_loc(arr), c_sizeof(arr), 0_c_int, c_loc(addr), c_sizeof(addr))
        if (ret == SOCKET_ERROR) stop "sendto() failed"
    end subroutine

    subroutine udp_send_real8(sockfd, host, port, ar)
        integer(c_int), value :: sockfd
        character(len=*), intent(in) :: host
        integer, value :: port
        real, dimension(:), intent(in) :: ar

        real(c_double), dimension(size(ar)), target :: arr
        type(sockaddr_in), target :: addr
        integer(c_int) :: ret
        integer :: i

        arr = ar
        addr%sin_family = AF_INET
        addr%sin_port   = htons(int(port, c_short))
        addr%sin_addr%s_addr = inet_addr(trim(host)//c_null_char)
        addr%sin_zero = [(c_null_char, i=1,8)]

        ret = sendto(sockfd, c_loc(arr), c_sizeof(arr), 0_c_int, c_loc(addr), c_sizeof(addr))
        if (ret == SOCKET_ERROR) stop "sendto() failed"
    end subroutine

    !==========================================================
    ! Blocking receive routines
    !==========================================================
    subroutine udp_recv_real4(sockfd, ar)
        integer(c_int), value :: sockfd
        real, dimension(:), intent(out) :: ar

        real(c_float), dimension(size(ar)), target :: arr
        integer(c_int) :: ret

        ret = recvfrom(sockfd, c_loc(arr), c_sizeof(arr), 0_c_int, c_null_ptr, 0_c_size_t)
        if (ret == SOCKET_ERROR) stop "recvfrom() failed"
        ar = real(arr, kind=c_double)
    end subroutine

    subroutine udp_recv_real8(sockfd, ar)
        integer(c_int), value :: sockfd
        real, dimension(:), intent(out) :: ar

        real(c_double), dimension(size(ar)), target :: arr
        integer(c_int) :: ret

        ret = recvfrom(sockfd, c_loc(arr), c_sizeof(arr), 0_c_int, c_null_ptr, 0_c_size_t)
        if (ret == SOCKET_ERROR) stop "recvfrom() failed"
        ar = arr
    end subroutine

    !==========================================================
    ! Non-blocking receive routines
    !==========================================================
    function udp_recv_real4_nb(sockfd, ar) result(status)
        integer(c_int), value :: sockfd
        real, dimension(:), intent(out) :: ar
        integer :: status

        real(c_float), dimension(size(ar)), target :: arr
        integer(c_int) :: ret

        ret = recvfrom(sockfd, c_loc(arr), c_sizeof(arr), 0_c_int, c_null_ptr, 0_c_size_t)
        if (ret == SOCKET_ERROR) then
            status = 0
        else
            ar = real(arr, kind=c_double)
            status = 1
        end if
    end function

    function udp_recv_real8_nb(sockfd, ar) result(status)
        integer(c_int), value :: sockfd
        real, dimension(:), intent(out) :: ar
        integer :: status

        real(c_double), dimension(size(ar)), target :: arr
        integer(c_int) :: ret

        ret = recvfrom(sockfd, c_loc(arr), c_sizeof(arr), 0_c_int, c_null_ptr, 0_c_size_t)
        if (ret == SOCKET_ERROR) then
            status = 0
        else
            ar = arr
            status = 1
        end if
    end function

    ! ------------------ Entity-ID-prefixed send (real8) ------------------
    subroutine udp_send_real8_with_id(sockfd, host, port, entity_id, ar)
        integer(c_int), value        :: sockfd
        character(len=*), intent(in) :: host
        integer, value               :: port, entity_id
        real, dimension(:), intent(in) :: ar

        integer :: n, nbytes, i
        integer(c_int32_t)               :: id32
        character(c_char), allocatable, target :: raw(:)
        type(sockaddr_in), target        :: addr
        integer(c_int)                   :: ret

        n      = size(ar)
        nbytes = 4 + 8*n
        allocate(raw(nbytes))

        id32          = int(entity_id, c_int32_t)
        raw(1:4)      = transfer(id32, [(c_null_char, i=1, 4)])
        raw(5:nbytes) = transfer(ar, [(c_null_char, i=1, 8*n)])

        addr%sin_family      = AF_INET
        addr%sin_port        = htons(int(port, c_short))
        addr%sin_addr%s_addr = inet_addr(trim(host) // c_null_char)
        addr%sin_zero        = [(c_null_char, i=1, 8)]

        ret = sendto(sockfd, c_loc(raw), int(nbytes, c_size_t), 0_c_int, c_loc(addr), c_sizeof(addr))
        deallocate(raw)
    end subroutine udp_send_real8_with_id

    ! ------------------ Entity-ID-prefixed send (real4) ------------------
    subroutine udp_send_real4_with_id(sockfd, host, port, entity_id, ar)
        integer(c_int), value        :: sockfd
        character(len=*), intent(in) :: host
        integer, value               :: port, entity_id
        real, dimension(:), intent(in) :: ar

        integer :: n, nbytes, i
        integer(c_int32_t)               :: id32
        real(c_float), dimension(size(ar)) :: arr4
        character(c_char), allocatable, target :: raw(:)
        type(sockaddr_in), target        :: addr
        integer(c_int)                   :: ret

        n      = size(ar)
        nbytes = 4 + 4*n
        arr4   = real(ar, kind=c_float)
        allocate(raw(nbytes))

        id32          = int(entity_id, c_int32_t)
        raw(1:4)      = transfer(id32, [(c_null_char, i=1, 4)])
        raw(5:nbytes) = transfer(arr4, [(c_null_char, i=1, 4*n)])

        addr%sin_family      = AF_INET
        addr%sin_port        = htons(int(port, c_short))
        addr%sin_addr%s_addr = inet_addr(trim(host) // c_null_char)
        addr%sin_zero        = [(c_null_char, i=1, 8)]

        ret = sendto(sockfd, c_loc(raw), int(nbytes, c_size_t), 0_c_int, c_loc(addr), c_sizeof(addr))
        deallocate(raw)
    end subroutine udp_send_real4_with_id

    ! ------------------ Entity-ID-prefixed non-blocking receive (real8) ------------------
    function udp_recv_real8_nb_with_id(sockfd, entity_id, ar) result(status)
        integer(c_int), value :: sockfd
        integer, intent(out)  :: entity_id
        real, dimension(:)    :: ar
        integer               :: status

        integer :: n, nbytes
        integer(c_int32_t)               :: id32
        character(c_char), allocatable, target :: raw(:)
        integer(c_int)                   :: ret

        n      = size(ar)
        nbytes = 4 + 8*n
        allocate(raw(nbytes))

        ret = recvfrom(sockfd, c_loc(raw), int(nbytes, c_size_t), 0_c_int, c_null_ptr, 0_c_size_t)
        if (ret == SOCKET_ERROR) then
            status    = 0
            entity_id = 0
        else
            id32      = transfer(raw(1:4), id32)
            entity_id = int(id32)
            ar        = transfer(raw(5:nbytes), ar)
            status    = 1
        end if
        deallocate(raw)
    end function udp_recv_real8_nb_with_id

    ! ------------------ Entity-ID-prefixed non-blocking receive (real4) ------------------
    function udp_recv_real4_nb_with_id(sockfd, entity_id, ar) result(status)
        integer(c_int), value :: sockfd
        integer, intent(out)  :: entity_id
        real, dimension(:)    :: ar
        integer               :: status

        integer :: n, nbytes
        integer(c_int32_t)               :: id32
        real(c_float), dimension(size(ar)) :: arr4
        character(c_char), allocatable, target :: raw(:)
        integer(c_int)                   :: ret

        n      = size(ar)
        nbytes = 4 + 4*n
        allocate(raw(nbytes))

        ret = recvfrom(sockfd, c_loc(raw), int(nbytes, c_size_t), 0_c_int, c_null_ptr, 0_c_size_t)
        if (ret == SOCKET_ERROR) then
            status    = 0
            entity_id = 0
        else
            id32      = transfer(raw(1:4), id32)
            entity_id = int(id32)
            arr4      = transfer(raw(5:nbytes), arr4)
            ar        = real(arr4, kind=c_double)
            status    = 1
        end if
        deallocate(raw)
    end function udp_recv_real4_nb_with_id

end module udp_m
