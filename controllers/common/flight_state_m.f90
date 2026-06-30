! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! Shared sim-state decoding for the fixed-wing controllers: the JSON-driven
! packet map (packet_order array) plus the decoded flight_state_t. Extended
! beyond the legacy map to capture actual surface positions and EKF angular
! accelerations (for INDI) and the BIRE empennage angle/rate.
module flight_state_m
  use json_m
  use jsonx_m
  implicit none
  private

  public :: packet_map_t, flight_state_t
  public :: load_packet_order, unpack_state

  type :: packet_map_t
    integer :: n = 0                 ! total packet length (field count)
    integer :: t = 0
    integer :: ub = 0, vb = 0, wb = 0
    integer :: pb = 0, qb = 0, rb = 0
    integer :: xf = 0, yf = 0, zf = 0
    integer :: e0 = 0, ex = 0, ey = 0, ez = 0
    integer :: da = 0, de = 0, dr = 0, thr = 0     ! actual surface positions (INDI baseline)
    integer :: pdot = 0, qdot = 0, rdot = 0         ! EKF angular accelerations (INDI)
    integer :: bire = 0, biredot = 0                ! BIRE empennage angle / rate
  end type packet_map_t

  type :: flight_state_t
    real :: t = 0.0
    real :: u = 0.0, v = 0.0, w = 0.0          ! body velocity [ft/s]
    real :: p = 0.0, q = 0.0, r = 0.0          ! body rates [rad/s]
    real :: x = 0.0, y = 0.0, z = 0.0          ! earth position [ft] (z down)
    real :: e0 = 1.0, ex = 0.0, ey = 0.0, ez = 0.0   ! attitude quaternion
    ! optional fields
    real :: da_act = 0.0, de_act = 0.0, dr_act = 0.0, thr_act = 0.0
    logical :: has_surf = .false.
    real :: pdot = 0.0, qdot = 0.0, rdot = 0.0       ! EKF angular accel [rad/s^2]
    logical :: has_wdot = .false.
    real :: bire = 0.0, biredot = 0.0
    logical :: has_bire = .false.
  end type flight_state_t

contains

  subroutine load_packet_order(j_udp, pmap)
    type(json_value), pointer, intent(in) :: j_udp
    type(packet_map_t), intent(out) :: pmap

    type(json_value), pointer :: j_array, j_elem
    character(len=:), allocatable :: name
    logical :: found
    integer :: i, n

    call json_get(j_udp, 'packet_order', j_array, found)
    if (.not. found) call json_clear_exceptions()
    if (.not. found) then
      print *, "Warning: packet_order not defined! Quitting..."
      stop
    end if

    n = json_value_count(j_array)
    pmap%n = n
    do i = 1, n
      call json_value_get(j_array, i, j_elem)
      call json_get(j_elem, value=name)
      call map_name_to_pmap(name, i, pmap)
    end do
    print '(A,I0,A)', " Packet order: loaded ", n, " fields from JSON"
    print '(A,I0)', "  Packet size: ", pmap%n
  end subroutine load_packet_order

  subroutine map_name_to_pmap(name, idx, pmap)
    character(len=*), intent(in) :: name
    integer, intent(in) :: idx
    type(packet_map_t), intent(inout) :: pmap

    select case (trim(name))
      case ('t', 'time');                             pmap%t = idx
      case ('ub', 'u');                               pmap%ub = idx
      case ('vb', 'v');                               pmap%vb = idx
      case ('wb', 'w');                               pmap%wb = idx
      case ('pb', 'p');                               pmap%pb = idx
      case ('qb', 'q');                               pmap%qb = idx
      case ('rb', 'r');                               pmap%rb = idx
      case ('xf', 'x');                               pmap%xf = idx
      case ('yf', 'y');                               pmap%yf = idx
      case ('zf', 'z');                               pmap%zf = idx
      case ('e0');                                    pmap%e0 = idx
      case ('ex');                                    pmap%ex = idx
      case ('ey');                                    pmap%ey = idx
      case ('ez');                                    pmap%ez = idx
      ! actual surface positions (used as INDI baseline) — NOT the *_cmd fields
      case ('da', 'da_act', 'aileron');               pmap%da = idx
      case ('de', 'de_act', 'elevator', 'elevsym');   pmap%de = idx
      case ('dr', 'dr_act', 'rudder', 'elevasym');    pmap%dr = idx
      case ('thr', 'thr_act', 'throttle');            pmap%thr = idx
      ! EKF angular accelerations (INDI)
      case ('pdot', 'p_dot', 'pbdot');                pmap%pdot = idx
      case ('qdot', 'q_dot', 'qbdot');                pmap%qdot = idx
      case ('rdot', 'r_dot', 'rbdot');                pmap%rdot = idx
      ! BIRE empennage state
      case ('bire', 'bire_angle');                    pmap%bire = idx
      case ('biredot', 'bire_dot');                   pmap%biredot = idx
      ! commanded surfaces — present in the packet but not consumed here
      case ('da_cmd', 'aileron_cmd', 'de_cmd', 'elevator_cmd', 'elevsym_cmd', &
            'dr_cmd', 'rudder_cmd', 'elevasym_cmd', 'thr_cmd', 'throttle_cmd')
      case ('skipthis')                               ! intentionally skip this position
      case default
        print '(A,I0,A,A,A)', " WARNING: packet_order[", idx, "]: unknown name '", trim(name), "', skipping"
    end select
  end subroutine map_name_to_pmap

  ! Decode a received packet (instate array) into a flight_state_t using the map.
  subroutine unpack_state(instate, pmap, st)
    real, intent(in) :: instate(:)
    type(packet_map_t), intent(in) :: pmap
    type(flight_state_t), intent(inout) :: st

    if (pmap%t  > 0) st%t  = instate(pmap%t)
    if (pmap%ub > 0) st%u  = instate(pmap%ub)
    if (pmap%vb > 0) st%v  = instate(pmap%vb)
    if (pmap%wb > 0) st%w  = instate(pmap%wb)
    if (pmap%pb > 0) st%p  = instate(pmap%pb)
    if (pmap%qb > 0) st%q  = instate(pmap%qb)
    if (pmap%rb > 0) st%r  = instate(pmap%rb)
    if (pmap%xf > 0) st%x  = instate(pmap%xf)
    if (pmap%yf > 0) st%y  = instate(pmap%yf)
    if (pmap%zf > 0) st%z  = instate(pmap%zf)
    if (pmap%e0 > 0) st%e0 = instate(pmap%e0)
    if (pmap%ex > 0) st%ex = instate(pmap%ex)
    if (pmap%ey > 0) st%ey = instate(pmap%ey)
    if (pmap%ez > 0) st%ez = instate(pmap%ez)

    st%has_surf = (pmap%da > 0 .or. pmap%de > 0 .or. pmap%dr > 0)
    if (pmap%da  > 0) st%da_act  = instate(pmap%da)
    if (pmap%de  > 0) st%de_act  = instate(pmap%de)
    if (pmap%dr  > 0) st%dr_act  = instate(pmap%dr)
    if (pmap%thr > 0) st%thr_act = instate(pmap%thr)

    st%has_wdot = (pmap%pdot > 0 .and. pmap%qdot > 0 .and. pmap%rdot > 0)
    if (pmap%pdot > 0) st%pdot = instate(pmap%pdot)
    if (pmap%qdot > 0) st%qdot = instate(pmap%qdot)
    if (pmap%rdot > 0) st%rdot = instate(pmap%rdot)

    st%has_bire = (pmap%bire > 0)
    if (pmap%bire    > 0) st%bire    = instate(pmap%bire)
    if (pmap%biredot > 0) st%biredot = instate(pmap%biredot)
  end subroutine unpack_state

end module flight_state_m
