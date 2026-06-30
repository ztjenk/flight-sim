! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! Current: Dryden-Beal atmospheric turbulence model (flightsim ch9)
    ! translational velocity turbulence, rotational p,q,r turbulence
    ! gusts modify aerodynamic velocities only, not rigid-body state (Section 9.8)
module turbulence_m
    use constants_m
    use random_m
    implicit none
    private

    public :: dryden_beal_state
    public :: dryden_beal_init
    public :: dryden_beal_reset
    public :: dryden_beal_step
    public :: dryden_beal_update_dx
    public :: dryden_beal_update_params
    public :: sigma_from_intensity

    type :: dryden_beal_state
        ! turbulence parameters
        real :: Lu = 0.0             ! u length scale
        real :: Lv = 0.0             ! v length scale
        real :: Lw = 0.0             ! w length scale
        real :: sigma_u = 0.0        ! u turbulence intensity [ft/s]
        real :: sigma_v = 0.0        ! v turbulence intensity [ft/s]
        real :: sigma_w = 0.0        ! w turbulence intensity [ft/s]
        real :: dx_ff = 0.0          ! frozen-field step size [ft]

        real :: Au = 0.0
        real :: Av = 0.0
        real :: Aw = 0.0
        real :: sigma_eta_u = 0.0
        real :: sigma_eta_v = 0.0
        real :: sigma_eta_w = 0.0
        real :: u_prev = 0.0        
        real :: v_prev = 0.0        
        real :: w_prev = 0.0        
        real :: f_prev = 0.0         
        real :: g_prev = 0.0         

        real :: Lb = 0.0             
        real :: sigma_w_input = 0.0  
        real :: Ap = 0.0             
        real :: sigma_eta_p = 0.0    
        real :: p_prev = 0.0         

        real :: Lh_sep = 0.0             ! cg to horizontal tail distance [ft]
        real :: Lv_sep = 0.0             ! cg to vertical tail distance [ft]

        integer :: buf_size = 0          ! buffer length (0 = no q/r gusts)
        integer :: buf_idx = 0           ! current write index
        real, allocatable :: buf_xff(:)  ! frozen-field distance at each stored point
        real, allocatable :: buf_v(:)    ! v gust history 
        real, allocatable :: buf_w(:)    ! w gust history 
        real :: xff_cumulative = 0.0     ! total frozen-field distance traveled
    end type dryden_beal_state


    ! light turbulence (Table 9.2.1)
    integer, parameter :: N_LIGHT = 3
    real, parameter :: ALT_LIGHT(N_LIGHT) = [2000.0, 8000.0, 17000.0]
    real, parameter :: SIG_LIGHT(N_LIGHT) = [5.0, 5.0, 3.0]

    ! moderate turbulence (Table 9.2.2)
    integer, parameter :: N_MODERATE = 3
    real, parameter :: ALT_MODERATE(N_MODERATE) = [2000.0, 11000.0, 45000.0]
    real, parameter :: SIG_MODERATE(N_MODERATE) = [10.0, 10.0, 3.0]

    ! severe turbulence (Table 9.2.3)
    integer, parameter :: N_SEVERE = 4
    real, parameter :: ALT_SEVERE(N_SEVERE) = [2000.0, 4000.0, 20000.0, 80000.0]
    real, parameter :: SIG_SEVERE(N_SEVERE) = [15.0, 21.0, 21.0, 3.0]

contains

    ! initialize the Beal filter: set parameters, compute coefficients, zero state
    subroutine dryden_beal_init(state, Lu, Lv, Lw, sigma_u, sigma_v, sigma_w, dx_ff, &
                                wingspan, Lh_sep, Lv_sep, buf_size)
        type(dryden_beal_state), intent(out) :: state
        real, intent(in) :: Lu, Lv, Lw
        real, intent(in) :: sigma_u, sigma_v, sigma_w
        real, intent(in) :: dx_ff
        real, intent(in), optional :: wingspan     ! aircraft wingspan [ft]
        real, intent(in), optional :: Lh_sep       
        real, intent(in), optional :: Lv_sep       
        integer, intent(in), optional :: buf_size  ! circular buffer length

        state%Lu = Lu;  state%Lv = Lv;  state%Lw = Lw
        state%sigma_u = sigma_u
        state%sigma_v = sigma_v
        state%sigma_w = sigma_w
        state%dx_ff = dx_ff

        ! store sigma_w for p gust noise scaling (Eq. 9.5.9)
        state%sigma_w_input = sigma_w

        ! Eq. 9.5.5: Lb = 4*b / pi
        if (present(wingspan) .and. wingspan > 0.0) then
            state%Lb = wingspan * 4.0 / PI
        else
            state%Lb = 0.0
        end if

        ! q/r gust parameters (Eqs. 9.5.16-9.5.17)
        if (present(Lh_sep)) state%Lh_sep = Lh_sep
        if (present(Lv_sep)) state%Lv_sep = Lv_sep

        if (present(buf_size) .and. buf_size >= 2) then
            state%buf_size = buf_size
            allocate(state%buf_xff(buf_size), state%buf_v(buf_size), state%buf_w(buf_size))
        end if

        call compute_coefficients(state)
        call dryden_beal_reset(state)
    end subroutine dryden_beal_init

    ! update frozen-field step size (for variable-speed flight: dx_ff = V * dt)
    ! recomputes filter and noise coefficients; preserves filter state
    subroutine dryden_beal_update_dx(state, dx_ff)
        type(dryden_beal_state), intent(inout) :: state
        real, intent(in) :: dx_ff
        state%dx_ff = dx_ff
        call compute_coefficients(state)
    end subroutine dryden_beal_update_dx

    ! update sigma and dx_ff for altitude-dependent intensity mode
    ! isotropic: sigma_u = sigma_v = sigma_w = sigma
    subroutine dryden_beal_update_params(state, dx_ff, sigma)
        type(dryden_beal_state), intent(inout) :: state
        real, intent(in) :: dx_ff, sigma
        state%dx_ff = dx_ff
        state%sigma_u = sigma
        state%sigma_v = sigma
        state%sigma_w = sigma
        state%sigma_w_input = sigma
        call compute_coefficients(state)
    end subroutine dryden_beal_update_params

    ! reset filter state to zero without changing parameters
    subroutine dryden_beal_reset(state)
        type(dryden_beal_state), intent(inout) :: state
        state%u_prev = 0.0;  state%v_prev = 0.0;  state%w_prev = 0.0
        state%f_prev = 0.0;  state%g_prev = 0.0
        state%p_prev = 0.0
        if (allocated(state%buf_xff)) then
            state%buf_xff = 0.0
            state%buf_v = 0.0
            state%buf_w = 0.0
        end if
        state%buf_idx = 0
        state%xff_cumulative = 0.0
    end subroutine dryden_beal_reset

    ! advance the Beal filter one frozen-field step
    ! implements Eqs. 9.3.26-9.3.31 (translational), Eq. 9.5.11 (roll rate),
    ! and Eqs. 9.5.16-9.5.17 (pitch/yaw rate via finite difference)
    subroutine dryden_beal_step(state, u_gust, v_gust, w_gust, p_gust, q_gust, r_gust)
        type(dryden_beal_state), intent(inout) :: state
        real, intent(out) :: u_gust, v_gust, w_gust
        real, intent(out), optional :: p_gust, q_gust, r_gust
        real :: eta_u, eta_v, eta_w, eta_p
        real :: Au, Av, Aw, Ap
        real :: f_new, g_new
        real :: sqrt3
        integer :: i_back

        sqrt3 = sqrt(3.0)
        Au = state%Au;  Av = state%Av;  Aw = state%Aw

        ! scaled white noise samples (Eq. 9.3.24)
        eta_u = state%sigma_eta_u * rand_normal()
        eta_v = state%sigma_eta_v * rand_normal()
        eta_w = state%sigma_eta_w * rand_normal()

        ! u omponent: first-order Beal filter (Eq. 9.3.26)
        u_gust = ((1.0 - Au) * state%u_prev + 2.0 * Au * eta_u) / (1.0 + Au)

        ! v component: second-order Beal filter
        f_new = ((1.0 - Av) * state%f_prev + 2.0 * Av * eta_v) / (1.0 + Av) ! (Eq. 9.3.30)
        ! v-gust (Eq. 9.3.27)
        v_gust = ((1.0 - Av) * state%v_prev &
                 + Av * (f_new + state%f_prev) &
                 + sqrt3 * (f_new - state%f_prev)) / (1.0 + Av)

        ! w-component: second-order Beal filter
        g_new = ((1.0 - Aw) * state%g_prev + 2.0 * Aw * eta_w) / (1.0 + Aw) ! (Eq. 9.3.31)
        ! w-gust (Eq. 9.3.28)
        w_gust = ((1.0 - Aw) * state%w_prev &
                 + Aw * (g_new + state%g_prev) &
                 + sqrt3 * (g_new - state%g_prev)) / (1.0 + Aw)

        ! store state for next step
        state%u_prev = u_gust;  state%v_prev = v_gust;  state%w_prev = w_gust
        state%f_prev = f_new;   state%g_prev = g_new

        ! p component: (Eq. 9.5.11)
        if (present(p_gust)) then
            if (state%Lb > 0.0) then
                Ap = state%Ap
                eta_p = state%sigma_eta_p * rand_normal()
                p_gust = ((1.0 - Ap) * state%p_prev + 2.0 * Ap * eta_p) / (1.0 + Ap)
                state%p_prev = p_gust
            else
                p_gust = 0.0
            end if
        end if

        ! q/r rate gusts from circular buffer (Eqs. 9.5.16-9.5.17)
        if (state%buf_size >= 2) then
            state%xff_cumulative = state%xff_cumulative + state%dx_ff

            ! Eq. 9.5.16: q = (w_i - w_{i-m}) / dx_h
            if (present(q_gust)) then
                if (state%Lh_sep > 0.0) then
                    i_back = find_closest(state%buf_xff, state%buf_size, &
                                          state%xff_cumulative - state%Lh_sep)
                    q_gust = (w_gust - state%buf_w(i_back)) / state%Lh_sep
                else
                    q_gust = 0.0
                end if
            end if

            ! Eq. 9.5.17: r = -(v_i - v_{i-n}) / dx_v
            if (present(r_gust)) then
                if (state%Lv_sep > 0.0) then
                    i_back = find_closest(state%buf_xff, state%buf_size, &
                                          state%xff_cumulative - state%Lv_sep)
                    r_gust = -(v_gust - state%buf_v(i_back)) / state%Lv_sep
                else
                    r_gust = 0.0
                end if
            end if

            ! advance buffer index (circular) and store current values
            state%buf_idx = mod(state%buf_idx, state%buf_size) + 1
            state%buf_xff(state%buf_idx) = state%xff_cumulative
            state%buf_v(state%buf_idx) = v_gust
            state%buf_w(state%buf_idx) = w_gust
        else
            if (present(q_gust)) q_gust = 0.0
            if (present(r_gust)) r_gust = 0.0
        end if
    end subroutine dryden_beal_step

    !  altitude dependent sigma lookup (Section 9.2, Tables 9.2.1-9.2.3)
    pure function sigma_from_intensity(intensity, altitude_ft) result(sigma)
        character(len=*), intent(in) :: intensity
        real, intent(in) :: altitude_ft
        real :: sigma

        select case (trim(intensity))
        case ('light')
            sigma = interp_table(ALT_LIGHT, SIG_LIGHT, N_LIGHT, altitude_ft)
        case ('moderate')
            sigma = interp_table(ALT_MODERATE, SIG_MODERATE, N_MODERATE, altitude_ft)
        case ('severe')
            sigma = interp_table(ALT_SEVERE, SIG_SEVERE, N_SEVERE, altitude_ft)
        case default
            sigma = interp_table(ALT_LIGHT, SIG_LIGHT, N_LIGHT, altitude_ft)
        end select
    end function sigma_from_intensity

    ! compute filter and noise coefficients from current parameters
    subroutine compute_coefficients(state)
        type(dryden_beal_state), intent(inout) :: state
        ! filter coefficients (Eq. 9.3.29)
        state%Au = state%dx_ff / (2.0 * state%Lu)
        state%Av = state%dx_ff / (4.0 * state%Lv)
        state%Aw = state%dx_ff / (4.0 * state%Lw)
        ! white noise standard deviations (Eq. 9.3.24)
        state%sigma_eta_u = state%sigma_u * sqrt(2.0 * state%Lu / state%dx_ff)
        state%sigma_eta_v = state%sigma_v * sqrt(2.0 * state%Lv / state%dx_ff)
        state%sigma_eta_w = state%sigma_w * sqrt(2.0 * state%Lw / state%dx_ff)
        ! p gust coefficients (Eqs. 9.5.9, 9.5.12)
        if (state%Lb > 0.0) then
            state%Ap = state%dx_ff / (2.0 * state%Lb)
            state%sigma_eta_p = state%sigma_w_input * &
                sqrt(0.8 * PI * (state%Lw / state%Lb)**(1.0/3.0) / (state%Lw * state%dx_ff))
        else
            state%Ap = 0.0
            state%sigma_eta_p = 0.0
        end if
    end subroutine compute_coefficients

    ! find index in circular buffer closest to target xff distance
    pure function find_closest(xff_arr, n, target) result(idx)
        real, intent(in) :: xff_arr(:)
        integer, intent(in) :: n
        real, intent(in) :: target
        integer :: idx
        idx = minloc(abs(xff_arr(1:n) - target), dim=1)
    end function find_closest

    ! piecewise linear interpolation on a table
    pure function interp_table(alt_tbl, sig_tbl, n, alt) result(sigma)
        real, intent(in) :: alt_tbl(:), sig_tbl(:)
        integer, intent(in) :: n
        real, intent(in) :: alt
        real :: sigma
        integer :: i
        real :: frac

        ! below first breakpoint: clamp
        if (alt <= alt_tbl(1)) then
            sigma = sig_tbl(1)
            return
        end if

        ! above last breakpoint: clamp
        if (alt >= alt_tbl(n)) then
            sigma = sig_tbl(n)
            return
        end if

        ! find interval and interpolate
        do i = 1, n - 1
            if (alt <= alt_tbl(i+1)) then
                frac = (alt - alt_tbl(i)) / (alt_tbl(i+1) - alt_tbl(i))
                sigma = sig_tbl(i) + frac * (sig_tbl(i+1) - sig_tbl(i))
                return
            end if
        end do

        ! fallback (should not reach here)
        sigma = sig_tbl(n)
    end function interp_table

end module turbulence_m
