! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! Shared gamepad input: reads the 28-byte UDP packet the graphics layer sends
! (<6f I> little-endian = 6 float axes + 32-bit button mask) and exposes
! rising-edge button detection. Button bit positions follow the graphics
! (gilrs) mapping, which is the SDL standard layout, so the Xbox face/shoulder
! buttons land on fixed bits regardless of pad brand.
module gamepad_m
  use iso_c_binding, only: c_int, c_float, c_char, c_size_t
  use udp_m, only: udp_recvfrom_raw
  implicit none
  private

  public :: gamepad_t, gp_recv, gp_rising, gp_pressed

  ! Button bit positions (gilrs/SDL standard). Xbox labels in comments.
  integer, parameter, public :: BTN_A      = 0   ! South  (toggle velocity hold)
  integer, parameter, public :: BTN_B      = 1   ! East   (toggle angles mode)
  integer, parameter, public :: BTN_X      = 2   ! West   (toggle rates mode)
  integer, parameter, public :: BTN_Y      = 3   ! North  (toggle altitude mode)
  integer, parameter, public :: BTN_BACK   = 4
  integer, parameter, public :: BTN_GUIDE  = 5
  integer, parameter, public :: BTN_START  = 6
  integer, parameter, public :: BTN_LSTICK = 7
  integer, parameter, public :: BTN_RSTICK = 8
  integer, parameter, public :: BTN_LB     = 9   ! LeftShoulder
  integer, parameter, public :: BTN_RB     = 10  ! RightShoulder (toggle sideslip/beta)
  integer, parameter, public :: BTN_DUP    = 11
  integer, parameter, public :: BTN_DDOWN  = 12
  integer, parameter, public :: BTN_DLEFT  = 13  ! decrease V_cmd
  integer, parameter, public :: BTN_DRIGHT = 14  ! increase V_cmd

  ! Decoded gamepad state. Axis sign conventions match the legacy controllers:
  ! the graphics packet's yaw/pitch/roll are negated here so positive stick maps
  ! the way the control mapping expects.
  type :: gamepad_t
    real :: throttle = 0.5    ! left stick Y, remapped to 0.0 (down) .. 1.0 (up), 0.5 center (default = centered)
    real :: yaw      = 0.0    ! left stick X,  -1.0 .. 1.0
    real :: pitch    = 0.0    ! right stick Y, -1.0 .. 1.0
    real :: roll     = 0.0    ! right stick X, -1.0 .. 1.0
    real :: L2       = 0.0    ! left analog trigger,  0.0 .. 1.0
    real :: R2       = 0.0    ! right analog trigger, 0.0 .. 1.0
    integer :: buttons      = 0
    integer :: buttons_prev = 0
  end type gamepad_t

contains

  ! Receive and parse all queued gamepad packets, keeping the latest.
  subroutine gp_recv(sockfd, gp)
    integer(c_int), intent(in) :: sockfd
    type(gamepad_t), intent(inout) :: gp

    character(c_char), target :: buf(28)
    real(c_float) :: floats(6)
    integer(c_int) :: ret, btn_temp

    do while (.true.)
      ret = udp_recvfrom_raw(sockfd, buf, 28_c_size_t)
      if (ret <= 0) exit
      floats = transfer(buf(1:24), floats)
      gp%throttle = real(floats(1))
      gp%yaw      = -real(floats(2))
      gp%pitch    = -real(floats(3))
      gp%roll     = -real(floats(4))
      gp%L2       = real(floats(5))
      gp%R2       = real(floats(6))
      btn_temp    = transfer(buf(25:28), btn_temp)
      gp%buttons  = btn_temp
    end do
  end subroutine gp_recv

  ! Rising-edge mask since the last gp_mark (buttons newly pressed this frame).
  ! Call gp_rising once per frame, then update buttons_prev via the returned
  ! handling; callers should set gp%buttons_prev = gp%buttons after processing.
  pure function gp_rising(gp) result(rising)
    type(gamepad_t), intent(in) :: gp
    integer :: rising
    rising = iand(gp%buttons, not(gp%buttons_prev))
  end function gp_rising

  ! Test whether a given bit is set in a mask (convenience wrapper around btest).
  pure function gp_pressed(mask, bit) result(is_set)
    integer, intent(in) :: mask, bit
    logical :: is_set
    is_set = btest(mask, bit)
  end function gp_pressed

end module gamepad_m
