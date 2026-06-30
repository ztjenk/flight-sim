! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

module udp_m
  use iso_c_binding
  implicit none

  private
  public :: udp_open_socket, udp_bind_socket, udp_close_socket
  public :: udp_send_real4, udp_send_real8
  public :: udp_recv_real4, udp_recv_real8
  public :: udp_recv_real4_nb, udp_recv_real8_nb
  public :: udp_send_real4_with_id, udp_send_real8_with_id
  public :: udp_recv_real4_nb_with_id, udp_recv_real8_nb_with_id
  public :: udp_set_nonblocking, udp_set_blocking
  public :: udp_recvfrom_raw  ! Cross-platform raw receive wrapper
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

  integer(c_int), parameter :: F_GETFL    = 3
  integer(c_int), parameter :: F_SETFL    = 4
  integer(c_int), parameter :: O_NONBLOCK = 2048   ! Linux value (macOS/BSD is 4)

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

  subroutine udp_set_blocking(sockfd)
    integer(c_int), value :: sockfd
    integer(c_int) :: flags, ret
    flags = fcntl(sockfd, F_GETFL, 0_c_int)
    ret   = fcntl(sockfd, F_SETFL, iand(flags, not(O_NONBLOCK)))
  end subroutine

  ! ------------------ Sending ------------------
  subroutine udp_send_real4(sockfd, host, port, ar)
    integer(c_int), value        :: sockfd
    character(len=*), intent(in) :: host
    integer,       value         :: port
    real, dimension(:)           :: ar

    real(c_float), dimension(size(ar)), target :: arr
    type(sockaddr_in), target :: addr
    integer(c_int) :: ret
    integer :: i
    character(kind=c_char,len=:), allocatable :: host_c

    arr = real(ar, kind=c_float)
    addr%sin_family      = AF_INET
    addr%sin_port        = htons(int(port, c_short))
    host_c               = trim(host)//c_null_char
    addr%sin_addr%s_addr = inet_addr(host_c)
    addr%sin_zero        = [(c_null_char,i=1,8)]

    ret = sendto(sockfd, c_loc(arr), c_sizeof(arr), 0_c_int, c_loc(addr), int(c_sizeof(addr), c_int))
  end subroutine

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
  subroutine udp_recv_real4(sockfd, ar)
    integer(c_int), value :: sockfd
    real, dimension(:)    :: ar
    real(c_float), dimension(size(ar)), target :: arr
    integer(c_int) :: ret

    ret = recvfrom(sockfd, c_loc(arr), c_sizeof(arr), 0_c_int, c_null_ptr, c_null_ptr)
    ar  = real(arr, kind=c_double)
  end subroutine

  subroutine udp_recv_real8(sockfd, ar)
    integer(c_int), value :: sockfd
    real, dimension(:)    :: ar
    real, dimension(size(ar)), target :: arr
    integer(c_int) :: ret

    ret = recvfrom(sockfd, c_loc(arr), c_sizeof(arr), 0_c_int, c_null_ptr, c_null_ptr)
    ar  = arr
  end subroutine

  ! ------------------ Non-blocking receive ------------------
  function udp_recv_real4_nb(sockfd, ar) result(status)
    integer(c_int), value :: sockfd
    real, dimension(:)    :: ar
    integer               :: status
    real(c_float), dimension(size(ar)), target :: arr
    integer(c_int) :: ret

    ret = recvfrom(sockfd, c_loc(arr), c_sizeof(arr), 0_c_int, c_null_ptr, c_null_ptr)
    if (ret < 0) then
      status = 0
    else
      ar     = real(arr, kind=c_double)
      status = 1
    end if
  end function

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

  ! ------------------ Entity-ID-prefixed send (real8) ------------------
  ! Packet layout: [int32 entity_id (4 bytes)] [real8 values (8*n bytes)]
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
    character(kind=c_char, len=:), allocatable :: host_c

    n      = size(ar)
    nbytes = 4 + 4*n
    arr4   = real(ar, kind=c_float)
    allocate(raw(nbytes))

    id32       = int(entity_id, c_int32_t)
    raw(1:4)   = transfer(id32, [(c_null_char, i=1, 4)])
    raw(5:nbytes) = transfer(arr4, [(c_null_char, i=1, 4*n)])

    addr%sin_family      = AF_INET
    addr%sin_port        = htons(int(port, c_short))
    host_c               = trim(host) // c_null_char
    addr%sin_addr%s_addr = inet_addr(host_c)
    addr%sin_zero        = [(c_null_char, i=1, 8)]

    ret = sendto(sockfd, c_loc(raw), int(nbytes, c_size_t), 0_c_int, c_loc(addr), int(c_sizeof(addr), c_int))
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

    ret = recvfrom(sockfd, c_loc(raw), int(nbytes, c_size_t), 0_c_int, c_null_ptr, c_null_ptr)
    if (ret < 0) then
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

    ret = recvfrom(sockfd, c_loc(raw), int(nbytes, c_size_t), 0_c_int, c_null_ptr, c_null_ptr)
    if (ret < 0) then
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

  ! dummy functions
  subroutine udp_initialize()
  end subroutine udp_initialize
  subroutine udp_finalize()
  end subroutine udp_finalize

end module udp_m