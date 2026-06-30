! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

module udp_m
  use iso_c_binding
  implicit none

  private
  public :: udp_open_socket, udp_bind_socket, udp_close_socket
  public :: udp_send_real8, udp_recv_real8, udp_recv_real8_nb, udp_recv_real8_latest
  public :: udp_send_real8_with_id, udp_recv_real8_latest_with_id
  public :: udp_send_real4, udp_recv_real4_latest
  public :: udp_set_nonblocking, udp_set_recv_timeout
  public :: udp_recvfrom_raw
  public :: udp_initialize, udp_finalize

  integer(c_int), parameter :: AF_INET    = 2
  integer(c_int), parameter :: SOCK_DGRAM = 2

  ! ----- Linux in_addr / sockaddr_in -----
  type, bind(C) :: in_addr
     integer(c_int32_t) :: s_addr      ! in_addr_t (network order)
  end type

  type, bind(C) :: sockaddr_in
     integer(c_short)               :: sin_family   ! sa_family_t (16-bit)
     integer(c_short)               :: sin_port     ! in_port_t (network order)
     type(in_addr)                  :: sin_addr
     character(kind=c_char)         :: sin_zero(8)
  end type

  type, bind(C) :: timeval
     integer(c_long) :: tv_sec
     integer(c_long) :: tv_usec
  end type

  interface
     function socket(domain, stype, protocol) bind(C, name="socket")
       import :: c_int
       integer(c_int), value :: domain, stype, protocol
       integer(c_int)        :: socket
     end function

     function bind(sockfd, addr, addrlen) bind(C, name="bind")
       import :: c_int, c_ptr
       integer(c_int), value :: sockfd
       type(c_ptr),  value   :: addr
       ! socklen_t is typically 32-bit unsigned; using c_int works ABI-wise
       integer(c_int), value :: addrlen
       integer(c_int)        :: bind
     end function

     function sendto(sockfd, buf, len, flags, dest_addr, addrlen) bind(C, name="sendto")
       import :: c_int, c_size_t, c_ptr
       integer(c_int),   value :: sockfd, flags
       type(c_ptr),      value :: buf, dest_addr
       integer(c_size_t),value :: len        ! size_t
       integer(c_int),   value :: addrlen    ! socklen_t
       integer(c_int)           :: sendto
     end function

     function recvfrom(sockfd, buf, len, flags, src_addr, addrlen) bind(C, name="recvfrom")
       import :: c_int, c_size_t, c_ptr
       integer(c_int),   value :: sockfd, flags
       type(c_ptr),      value :: buf
       integer(c_size_t),value :: len        ! size_t
       type(c_ptr),      value :: src_addr   ! struct sockaddr *
       type(c_ptr),      value :: addrlen    ! socklen_t * (pass c_null_ptr)
       integer(c_int)           :: recvfrom
     end function

     function setsockopt(sockfd, level, optname, optval, optlen) bind(C, name="setsockopt")
       import :: c_int, c_ptr
       integer(c_int), value :: sockfd, level, optname
       type(c_ptr), value :: optval
       integer(c_int), value :: optlen
       integer(c_int) :: setsockopt
     end function

     subroutine close(sockfd) bind(C, name="close")
       import :: c_int
       integer(c_int), value :: sockfd
     end subroutine

     function htons(port) bind(C, name="htons")
       import :: c_short
       integer(c_short), value :: port       ! ok to use signed kind of same size
       integer(c_short)        :: htons
     end function

     function inet_addr(cp) bind(C, name="inet_addr")
       import :: c_char, c_int32_t
       character(kind=c_char), dimension(*) :: cp
       integer(c_int32_t) :: inet_addr      ! in_addr_t
     end function

     function fcntl(fd, cmd, arg) bind(C, name="fcntl")
       import :: c_int
       integer(c_int), value :: fd, cmd, arg
       integer(c_int)        :: fcntl
     end function
  end interface

  integer(c_int), parameter :: F_GETFL      = 3
  integer(c_int), parameter :: F_SETFL      = 4
  integer(c_int), parameter :: O_NONBLOCK   = 2048   ! Linux value (macOS/BSD is 4)
  integer(c_int), parameter :: MSG_DONTWAIT = 64     ! 0x40 on Linux
  integer(c_int), parameter :: SOL_SOCKET   = 1
  integer(c_int), parameter :: SO_RCVTIMEO  = 20

contains

  !==========================================================
  ! Cross-platform raw receive wrapper
  !==========================================================
  function udp_recvfrom_raw(sockfd, buf, bufsize) result(nbytes)
    integer(c_int), value :: sockfd
    character(c_char), dimension(*), target :: buf
    integer(c_size_t), value :: bufsize
    integer(c_int) :: nbytes

    ! Linux: pass c_null_ptr for addrlen
    nbytes = recvfrom(sockfd, c_loc(buf), bufsize, 0_c_int, c_null_ptr, c_null_ptr)
  end function

  function udp_open_socket() result(sockfd)
    integer(c_int) :: sockfd
    sockfd = socket(AF_INET, SOCK_DGRAM, 0_c_int)
  end function

  subroutine udp_bind_socket(sockfd, port)
    integer(c_int), value :: sockfd
    integer,       value :: port
    type(sockaddr_in), target :: addr
    integer(c_int) :: ret
    integer :: i

    addr%sin_family       = AF_INET
    addr%sin_port         = htons(int(port, c_short))
    addr%sin_addr%s_addr  = 0_c_int32_t        ! INADDR_ANY
    addr%sin_zero         = [(c_null_char, i=1,8)]

    ret = bind(sockfd, c_loc(addr), int(c_sizeof(addr), c_int))
    if (ret /= 0) stop "bind() failed"
  end subroutine

  subroutine udp_close_socket(sockfd)
    integer(c_int), value :: sockfd
    call close(sockfd)
  end subroutine

  subroutine udp_set_nonblocking(sockfd)
    integer(c_int), value :: sockfd
    integer(c_int) :: flags, ret
    flags = fcntl(sockfd, F_GETFL, 0_c_int)
    ret   = fcntl(sockfd, F_SETFL, ior(flags, O_NONBLOCK))
  end subroutine

  subroutine udp_set_recv_timeout(sockfd, timeout_sec)
    integer(c_int), value :: sockfd
    integer, value :: timeout_sec
    type(timeval), target :: tv
    integer(c_int) :: ret

    tv%tv_sec = timeout_sec
    tv%tv_usec = 0
    ret = setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, c_loc(tv), int(c_sizeof(tv), c_int))
  end subroutine

  ! ------------------ Sending ------------------
  subroutine udp_send_real8(sockfd, host, port, ar)
    integer(c_int), value        :: sockfd
    character(len=*), intent(in) :: host
    integer,       value         :: port
    real, dimension(:)           :: ar

    real, dimension(size(ar)), target :: arr
    type(sockaddr_in), target :: addr
    integer(c_int) :: ret
    integer :: i
    character(kind=c_char,len=:), allocatable :: host_c

    arr = ar
    addr%sin_family      = AF_INET
    addr%sin_port        = htons(int(port, c_short))
    host_c               = trim(host)//c_null_char
    addr%sin_addr%s_addr = inet_addr(host_c)
    addr%sin_zero        = [(c_null_char,i=1,8)]

    ret = sendto(sockfd, c_loc(arr), c_sizeof(arr), 0_c_int, c_loc(addr), int(c_sizeof(addr), c_int))
  end subroutine

  ! ------------------ Blocking receive ------------------
  subroutine udp_recv_real8(sockfd, ar)
    integer(c_int), value :: sockfd
    real, dimension(:), intent(out) :: ar
    real, dimension(size(ar)), target :: arr
    integer(c_int) :: ret

    ret = recvfrom(sockfd, c_loc(arr), c_sizeof(arr), 0_c_int, c_null_ptr, c_null_ptr)
    if (ret < 0) stop "udp_recv_real8: recvfrom() failed"
    ar = arr
  end subroutine

  ! ------------------ Non-blocking receive ------------------
  function udp_recv_real8_nb(sockfd, ar) result(status)
    integer(c_int), value :: sockfd
    real, dimension(:)    :: ar
    integer               :: status
    real, dimension(size(ar)), target :: arr
    integer(c_int) :: ret

    ret = recvfrom(sockfd, c_loc(arr), c_sizeof(arr), 0_c_int, c_null_ptr, c_null_ptr)
    if (ret < 0) then
      status = 0
    else
      ar     = arr
      status = 1
    end if
  end function

  ! ------------------ Blocking receive, drain to latest ------------------
  ! Blocks until a packet arrives or the socket timeout expires, then drains
  ! any additional queued packets and returns the most recent.
  ! Set a receive timeout first with udp_set_recv_timeout.
  subroutine udp_recv_real8_latest(sockfd, ar, got_data)
    integer(c_int), value :: sockfd
    real, dimension(:), intent(inout) :: ar
    logical, intent(out) :: got_data

    real, dimension(size(ar)), target :: arr
    integer(c_int) :: ret

    got_data = .false.

    ! blocking receive (with timeout if set via SO_RCVTIMEO)
    ret = recvfrom(sockfd, c_loc(arr), c_sizeof(arr), 0_c_int, c_null_ptr, c_null_ptr)
    if (ret < 0) return
    ar = arr
    got_data = .true.

    ! drain any additional queued packets using MSG_DONTWAIT
    do while (.true.)
      ret = recvfrom(sockfd, c_loc(arr), c_sizeof(arr), MSG_DONTWAIT, c_null_ptr, c_null_ptr)
      if (ret < 0) exit
      ar = arr
    end do
  end subroutine udp_recv_real8_latest

  ! ------------------ Entity-ID-prefixed send (real8) ------------------
  ! Packet layout: [int32 entity_id (4 bytes)] [real8 values (8*n bytes)]
  subroutine udp_send_real8_with_id(sockfd, host, port, entity_id, ar)
    integer(c_int), value        :: sockfd
    character(len=*), intent(in) :: host
    integer, value               :: port, entity_id
    real, dimension(:)           :: ar

    integer :: n, nbytes, i
    integer(c_int32_t)               :: id32
    character(c_char), allocatable, target :: raw(:)
    type(sockaddr_in), target        :: addr
    integer(c_int)                   :: ret
    character(kind=c_char, len=:), allocatable :: host_c

    n      = size(ar)
    nbytes = 4 + 8*n
    allocate(raw(nbytes))

    id32       = int(entity_id, c_int32_t)
    raw(1:4)   = transfer(id32, [(c_null_char, i=1, 4)])
    raw(5:nbytes) = transfer(ar, [(c_null_char, i=1, 8*n)])

    addr%sin_family      = AF_INET
    addr%sin_port        = htons(int(port, c_short))
    host_c               = trim(host) // c_null_char
    addr%sin_addr%s_addr = inet_addr(host_c)
    addr%sin_zero        = [(c_null_char, i=1, 8)]

    ret = sendto(sockfd, c_loc(raw), int(nbytes, c_size_t), 0_c_int, c_loc(addr), int(c_sizeof(addr), c_int))
    deallocate(raw)
  end subroutine udp_send_real8_with_id

  ! ------------------ Entity-ID-prefixed blocking receive, drain to latest (real8) ------------------
  subroutine udp_recv_real8_latest_with_id(sockfd, ar, entity_id, got_data)
    integer(c_int), value         :: sockfd
    real, dimension(:), intent(inout) :: ar
    integer, intent(out)          :: entity_id
    logical, intent(out)          :: got_data

    integer :: n, nbytes
    integer(c_int32_t)               :: id32
    character(c_char), allocatable, target :: raw(:)
    integer(c_int) :: ret

    n      = size(ar)
    nbytes = 4 + 8*n
    allocate(raw(nbytes))

    entity_id = 1
    got_data  = .false.

    ! blocking receive (with timeout if set via SO_RCVTIMEO)
    ret = recvfrom(sockfd, c_loc(raw), int(nbytes, c_size_t), 0_c_int, c_null_ptr, c_null_ptr)
    if (ret < 0) then
      deallocate(raw)
      return
    end if
    id32      = transfer(raw(1:4), id32)
    entity_id = int(id32)
    ar        = transfer(raw(5:nbytes), ar)
    got_data  = .true.

    ! drain any additional queued packets using MSG_DONTWAIT
    do while (.true.)
      ret = recvfrom(sockfd, c_loc(raw), int(nbytes, c_size_t), MSG_DONTWAIT, c_null_ptr, c_null_ptr)
      if (ret < 0) exit
      id32      = transfer(raw(1:4), id32)
      entity_id = int(id32)
      ar        = transfer(raw(5:nbytes), ar)
    end do
    deallocate(raw)
  end subroutine udp_recv_real8_latest_with_id

  ! ------------------ Single-precision (real4) plain send ------------------
  ! For sims that exchange float32 packets (e.g. the quadrotor example).
  ! Caller supplies a real(c_float) array; no entity-id prefix.
  subroutine udp_send_real4(sockfd, host, port, ar)
    integer(c_int), value        :: sockfd
    character(len=*), intent(in) :: host
    integer,       value         :: port
    real(c_float), dimension(:)  :: ar

    real(c_float), dimension(size(ar)), target :: arr
    type(sockaddr_in), target :: addr
    integer(c_int) :: ret
    integer :: i
    character(kind=c_char,len=:), allocatable :: host_c

    arr = ar
    addr%sin_family      = AF_INET
    addr%sin_port        = htons(int(port, c_short))
    host_c               = trim(host)//c_null_char
    addr%sin_addr%s_addr = inet_addr(host_c)
    addr%sin_zero        = [(c_null_char,i=1,8)]

    ret = sendto(sockfd, c_loc(arr), c_sizeof(arr), 0_c_int, c_loc(addr), int(c_sizeof(addr), c_int))
  end subroutine udp_send_real4

  ! ------------------ Single-precision (real4) blocking receive, drain to latest ------------------
  ! Blocks until a packet arrives (with timeout if set), then drains queued
  ! packets and returns the most recent. Caller supplies a real(c_float) array.
  subroutine udp_recv_real4_latest(sockfd, ar, got_data)
    integer(c_int), value :: sockfd
    real(c_float), dimension(:), intent(inout) :: ar
    logical, intent(out) :: got_data

    real(c_float), dimension(size(ar)), target :: arr
    integer(c_int) :: ret

    got_data = .false.
    ret = recvfrom(sockfd, c_loc(arr), c_sizeof(arr), 0_c_int, c_null_ptr, c_null_ptr)
    if (ret < 0) return
    ar = arr
    got_data = .true.

    do while (.true.)
      ret = recvfrom(sockfd, c_loc(arr), c_sizeof(arr), MSG_DONTWAIT, c_null_ptr, c_null_ptr)
      if (ret < 0) exit
      ar = arr
    end do
  end subroutine udp_recv_real4_latest

  ! dummy functions
  subroutine udp_initialize()
  end subroutine udp_initialize
  subroutine udp_finalize()
  end subroutine udp_finalize

end module udp_m
