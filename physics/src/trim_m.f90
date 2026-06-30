! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! trim solver using Newton's method
! algorithm 6.2.3 - Newton's method for solving a system of equations
! algorithm 6.2.4 - residual function calc_R
module trim_m
    use constants_m
    use math_m
    use atmosphere_m
    use vehicle_types_m
    use dynamics_m
    implicit none
    private

    public :: solve_trim

    ! trim variable layout: x = [alpha, beta, ctrl(1), ..., ctrl(n), phi]
    integer, parameter :: IDX_ALPHA = TRIM_IDX_ALPHA       ! = 1, always
    integer, parameter :: IDX_BETA  = TRIM_IDX_BETA        ! = 2, always
    integer, parameter :: IDX_CTRL_BASE = TRIM_IDX_CTRL_BASE  ! = 2, effector i at 2+i
    ! phi index is dynamic: idx_phi = settings%n_trim_vars (the last element)

    ! encapsulated context for calc_R
    type :: trim_context_t
        type(vehicle_config_t), pointer :: config => null()
        type(vehicle_state_t), pointer :: state_in => null()
        type(trim_settings_t), pointer :: settings => null()
        type(control_inputs_t) :: ctrl
        type(control_inputs_t) :: ctrl_commanded
        type(passive_inputs_t) :: passive
        type(dynamics_engine_t) :: dynamics
        type(actuator_map_t) :: act_map
        type(vehicle_state_t) :: state_computed  ! computed state from calc_R
        ! cached invariant values (computed in solve_trim, used in calc_R)
        real :: V_mag = 0.0
        real :: alt = 0.0
        real :: grav = 0.0
        real :: psi = 0.0
        real :: euler_in(3) = 0.0
    end type trim_context_t

contains

    ! Newton solver (algorithm 6.2.3)
    subroutine newton_solve(calc_R_func, x, free_idx, n_free, n_eqn, settings, context, info)
        interface
            subroutine calc_R_func(x, residual, context)
                import :: trim_context_t
                real, intent(in) :: x(:)
                real, intent(out) :: residual(:)
                type(trim_context_t), intent(inout) :: context
            end subroutine calc_R_func
        end interface
        real, intent(inout) :: x(:) ! initial guess for the vector of independent variables
        integer, intent(in) :: free_idx(:)
        integer, intent(in) :: n_free
        integer, intent(in) :: n_eqn
        type(trim_settings_t), intent(in) :: settings
        type(trim_context_t), intent(inout) :: context
        integer, intent(out) :: info

        real, allocatable :: residual(:), Jac(:,:), dx(:)
        real, allocatable :: x_pert(:), R_plus(:), R_minus(:)
        real :: eps_max, delta, Gamma_relax
        integer :: iter, jj, kk

        delta = settings%fd_step            ! real step size used for finite differencing
        Gamma_relax = settings%relaxation   ! relaxation factor

        allocate(residual(n_eqn), Jac(n_eqn, n_free), dx(n_free))
        allocate(x_pert(size(x)), R_plus(n_eqn), R_minus(n_eqn))

        if (settings%verbose) then
            write(*,'(A)') '  Iteration      Error'
        end if

        ! initial residual
        call calc_R_func(x, residual, context)       ! (line 6 of algorithm 6.2.3)
        eps_max = maxval(abs(residual))     ! current max error (line 7 of algorithm 6.2.3)

        if (settings%verbose) then
            write(*,'(I11,ES18.10)') 0, eps_max
        end if

        ! Newton iteration
        iter = 0
        do while (eps_max > settings%tolerance .and. iter < settings%max_iterations)    ! (line 8 of algorithm 6.2.3)
            iter = iter + 1

            do jj = 1, n_free       ! build Jacobian via central differencing
                kk = free_idx(jj)

                x_pert = x
                x_pert(kk) = x(kk) + delta          ! (line 10 of algorithm 6.2.3)
                call calc_R_func(x_pert, R_plus, context)    ! (line 11 of algorithm 6.2.3)

                x_pert = x
                x_pert(kk) = x(kk) - delta          ! (line 12 of algorithm 6.2.3)
                call calc_R_func(x_pert, R_minus, context)   ! (line 13 of algorithm 6.2.3)

                Jac(:, jj) = (R_plus - R_minus) / (2.0 * delta)     ! (line 15 and 17 of algorithm 6.2.3)
            end do

            ! solve J * dx = -R     ! (line 19 of algorithm 6.2.3)
            call lu_solve(n_free, n_eqn, Jac, -residual, dx, info)
            if (info /= 0) then
                info = 2
                deallocate(residual, Jac, dx, x_pert, R_plus, R_minus)
                return
            end if

            do jj = 1, n_free       ! update with relaxation
                kk = free_idx(jj)
                x(kk) = x(kk) + Gamma_relax * dx(jj)    ! (line 20 of algorithm 6.2.3)
            end do

            call calc_R_func(x, residual, context)       ! (line 21 of algorithm 6.2.3)
            eps_max = maxval(abs(residual))     ! (line 22 of algorithm 6.2.3)

            if (settings%verbose) then
                write(*,'(I11,ES18.10)') iter, eps_max
            end if
        end do

        if (eps_max <= settings%tolerance) then     ! tolerance is below limit, trim solution found
            info = 0
        else
            info = 1
            write(*,'(A)') '  WARNING: Trim did not converge. Final residuals (accelerations):'
            write(*,'(A,ES12.4,A)') '    u_dot: ', residual(1), '  ft/s^2  (longitudinal)'
            write(*,'(A,ES12.4,A)') '    v_dot: ', residual(2), '  ft/s^2  (lateral)'
            write(*,'(A,ES12.4,A)') '    w_dot: ', residual(3), '  ft/s^2  (vertical)'
            write(*,'(A,ES12.4,A)') '    p_dot: ', residual(4), '  rad/s^2 (roll)'
            write(*,'(A,ES12.4,A)') '    q_dot: ', residual(5), '  rad/s^2 (pitch)'
            write(*,'(A,ES12.4,A)') '    r_dot: ', residual(6), '  rad/s^2 (yaw)'
        end if

        deallocate(residual, Jac, dx, x_pert, R_plus, R_minus)

    end subroutine newton_solve

    ! LU solver with partial pivoting (provided by AI)
    recursive subroutine lu_solve(n, m, A, b, x, info)
        integer, intent(in) :: n, m
        real, intent(in) :: A(m, n)
        real, intent(in) :: b(m)
        real, intent(out) :: x(n)
        integer, intent(out) :: info

        real, allocatable :: A_work(:,:), b_work(:), AtA(:,:), Atb(:)
        integer :: ii, jj, kk, pivot_row
        real :: max_val, temp, factor

        info = 0

        if (m == n) then
            allocate(A_work(m, n), b_work(m))
            A_work = A
            b_work = b

            do kk = 1, n-1
                max_val = abs(A_work(kk, kk))
                pivot_row = kk
                do ii = kk+1, m
                    if (abs(A_work(ii, kk)) > max_val) then
                        max_val = abs(A_work(ii, kk))
                        pivot_row = ii
                    end if
                end do

                if (max_val < TOLERANCE) then
                    info = 1
                    deallocate(A_work, b_work)
                    return
                end if

                if (pivot_row /= kk) then
                    do jj = kk, n
                        temp = A_work(kk, jj)
                        A_work(kk, jj) = A_work(pivot_row, jj)
                        A_work(pivot_row, jj) = temp
                    end do
                    temp = b_work(kk)
                    b_work(kk) = b_work(pivot_row)
                    b_work(pivot_row) = temp
                end if

                do ii = kk+1, m
                    factor = A_work(ii, kk) / A_work(kk, kk)
                    do jj = kk+1, n
                        A_work(ii, jj) = A_work(ii, jj) - factor * A_work(kk, jj)
                    end do
                    b_work(ii) = b_work(ii) - factor * b_work(kk)
                end do
            end do

            if (abs(A_work(n, n)) < TOLERANCE) then
                info = 1
                deallocate(A_work, b_work)
                return
            end if

            x(n) = b_work(n) / A_work(n, n)
            do ii = n-1, 1, -1
                x(ii) = b_work(ii)
                do jj = ii+1, n
                    x(ii) = x(ii) - A_work(ii, jj) * x(jj)
                end do
                x(ii) = x(ii) / A_work(ii, ii)
            end do

            deallocate(A_work, b_work)

        else if (m > n) then
            ! overdetermined: least-squares via normal equations (A^T A) x = A^T b
            allocate(AtA(n, n), Atb(n))
            do ii = 1, n
                do jj = 1, n
                    AtA(ii, jj) = sum(A(:, ii) * A(:, jj))
                end do
                Atb(ii) = sum(A(:, ii) * b)
            end do
            call lu_solve(n, n, AtA, Atb, x, info)
            deallocate(AtA, Atb)
        else
            ! underdetermined (n > m): minimum-norm solution x = A^T (A A^T)^-1 b
            ! distributes effort evenly across all free variables
            allocate(AtA(m, m), Atb(m))
            AtA = matmul(A, transpose(A))   ! A A^T is m x m (square, solvable by LU)
            call lu_solve(m, m, AtA, b, Atb, info)  ! solve (A A^T) lambda = b
            if (info == 0) x = matmul(transpose(A), Atb)  ! x = A^T lambda
            deallocate(AtA, Atb)
        end if

    end subroutine lu_solve

    subroutine solve_trim(config, state_in, ctrl_in, passive_in, settings, &
                          state_out, ctrl_out, info, T_sl_R, P_sl_psf)
        type(vehicle_config_t), target, intent(in) :: config
        type(vehicle_state_t), target, intent(in) :: state_in
        type(control_inputs_t), intent(in) :: ctrl_in
        type(passive_inputs_t), intent(in) :: passive_in
        type(trim_settings_t), target, intent(in) :: settings
        type(vehicle_state_t), intent(out) :: state_out
        type(control_inputs_t), intent(out) :: ctrl_out
        integer, intent(out) :: info
        ! optional sea-level atmosphere overrides (Rankine / psf); absent or 0 = standard day
        real, intent(in), optional :: T_sl_R, P_sl_psf

        real, allocatable :: x(:)
        integer, allocatable :: free_idx(:)
        integer :: n_free, n_eqn, ii, jj, n_ctrl, idx_phi, i
        type(trim_context_t) :: ctx

        ! set context pointers for calc_R
        ctx%config => config
        ctx%state_in => state_in
        ctx%settings => settings

        ! cache invariant values for use in calc_R
        ctx%V_mag = norm3(state_in%velocity)
        ctx%alt = -state_in%position(3)
        ctx%euler_in = quat_to_euler(state_in%quaternion)
        ctx%psi = ctx%euler_in(3)
        ctx%grav = gravity_english(ctx%alt)

        call ctx%ctrl%copy_from(ctrl_in)  ! deep copy effectors from input controls
        call ctx%ctrl_commanded%copy_from(ctrl_in)  ! at trim, commanded = actual
        ctx%passive = passive_in  ! copy passive effector configuration
        call build_actuator_map(ctx%ctrl, ctx%passive, ctx%act_map)
        call ctx%dynamics%initialize(config, ctx%ctrl, ctx%ctrl_commanded, ctx%passive, ctx%act_map, &
                                     T_sl_R=T_sl_R, P_sl_psf=P_sl_psf)

        n_ctrl = ctx%ctrl%n
        idx_phi = settings%n_trim_vars

        ! allocate and initialize trim vector
        allocate(x(settings%n_trim_vars))
        x = 0.0

        ! initialize control effector slots from current effector values
        do i = 1, n_ctrl
            x(IDX_CTRL_BASE + i) = ctx%ctrl%effectors(i)%value
        end do

        ! build free_idx
        n_free = count(settings%free_vars)
        allocate(free_idx(n_free))
        jj = 0
        do ii = 1, settings%n_trim_vars
            if (settings%free_vars(ii)) then
                jj = jj + 1
                free_idx(jj) = ii
            end if
        end do

        n_eqn = 6

        ! disable actuator constraints during trim so the unconstrained Newton
        ! iteration can compute accurate finite-difference Jacobians
        ctx%dynamics%clamp_actuators = .false.

        ! call newton solver
        call newton_solve(calc_R, x, free_idx, n_free, n_eqn, settings, ctx, info)

        ! restore actuator constraints for simulation
        ctx%dynamics%clamp_actuators = .true.

        ! check if trim solution is within control effector limits
        if (info == 0) then
            call check_control_limits(x, ctrl_in, settings, info)
            if (info == 3) then
                ! trim found but outside limits - zero everything and return
                state_out = state_in
                state_out%velocity = [0.0, 0.0, 0.0]
                state_out%omega = [0.0, 0.0, 0.0]
                call ctrl_out%copy_from(ctrl_in)
                call ctrl_out%zero_all()
                deallocate(free_idx)
                deallocate(x)
                return
            end if
        end if

        ! output state was already computed in final calc_R call
        state_out = ctx%state_computed
        state_out%latitude = state_in%latitude
        state_out%longitude = state_in%longitude

        ! build output controls from trim solution
        call ctrl_out%copy_from(ctrl_in)
        do i = 1, n_ctrl
            ctrl_out%effectors(i)%value = x(IDX_CTRL_BASE + i)
        end do

        deallocate(free_idx)
        deallocate(x)

    end subroutine solve_trim

    ! residual function for trim (algorithm 6.2.4)
    subroutine calc_R(x, residual, ctx)
        real, intent(in) :: x(:)
        real, intent(out) :: residual(:)
        type(trim_context_t), intent(inout) :: ctx

        real :: theta, phi, beta
        real :: velocity(3), omega(3), quat(4)
        real, allocatable :: y(:), dy_dt(:)
        real :: ac, vel_ned(3), n_L     ! load factor variables
        integer :: k, eff_idx, idx_phi, n_ctrl, i
        ! eq 7.3.5 iteration variables
        real :: phi_new, ub, vb, wb, p, q, r
        real :: C_theta, S_theta, C_alpha, S_alpha, C_phi
        real :: A_lf, numer, denom, arg
        integer :: iter_phi
        integer, parameter :: MAX_PHI_ITER = 1000

        n_ctrl = ctx%ctrl%n
        idx_phi = ctx%settings%n_trim_vars

        ! phi: use x vector if free (shss with specified beta), otherwise from euler angles
        if (ctx%settings%free_vars(idx_phi)) then
            phi = x(idx_phi)
        else
            phi = ctx%euler_in(1)
        end if

        ! beta: use x vector if free, otherwise use specified sideslip angle
        if (ctx%settings%free_vars(IDX_BETA)) then
            beta = x(IDX_BETA)
        else
            beta = ctx%settings%sideslip_angle
        end if

        ! update all controls from trim vector  -  line 14 of algorithm 6.2.4
        do i = 1, n_ctrl
            ctx%ctrl%effectors(i)%value = x(IDX_CTRL_BASE + i)
        end do

        velocity = compute_body_velocity(ctx%V_mag, x(IDX_ALPHA), beta)      ! lines 8-10 of algorithm 6.2.4
        ub = velocity(1)
        vb = velocity(2)
        wb = velocity(3)

        if (trim(ctx%settings%trim_type) == 'vbr') then
            ! vbr: compute quaternion that maps v_body to purely vertical V_NED
            ! this ensures V_x = V_y = 0 (no lateral drift)
            if (ctx%settings%vbr_ascending) then
                quat = quat_from_two_vectors(velocity, [0.0, 0.0, -ctx%V_mag])
            else
                quat = quat_from_two_vectors(velocity, [0.0, 0.0, ctx%V_mag])
            end if
            block
                real :: euler_vbr(3)
                euler_vbr = quat_to_euler(quat)
                phi = euler_vbr(1)
                theta = euler_vbr(2)
            end block

        else if (ctx%settings%loadfactor_is_set) then
            ! load factor specified: iterate to find phi using eq 7.3.5
            n_L = ctx%settings%loadfactor_specified
            C_alpha = cos(x(IDX_ALPHA))
            S_alpha = sin(x(IDX_ALPHA))

            ! initial guess: phi = acos(1/n_L) for level turn
            if (abs(n_L) > TOLERANCE) then
                phi = acos(min(1.0, max(-1.0, 1.0 / n_L)))
            else
                phi = 0.0
            end if

            ! iterate to solve eq 7.3.5
            do iter_phi = 1, MAX_PHI_ITER
                ! compute theta from gamma constraint
                if (ctx%settings%gamma_is_set) then
                    theta = solve_theta_from_gamma(velocity, phi, ctx%V_mag, ctx%settings%gamma_specified)
                else
                    theta = solve_theta_from_gamma(velocity, phi, ctx%V_mag, 0.0)  ! level turn
                end if

                ! compute body rates for sct
                quat = euler_to_quat([phi, theta, ctx%psi])
                vel_ned = quat_rotate_body_to_inertial(velocity, quat)
                ac = (vel_ned(1)**2 + vel_ned(2)**2) / (R_MEAN_EARTH_ENGLISH + ctx%alt)
                call compute_sct_body_rates_core(velocity, theta, phi, ctx%grav, ac, omega)
                p = omega(1); q = omega(2); r = omega(3)

                ! trig values
                C_theta = cos(theta)
                S_theta = sin(theta)
                C_phi = cos(phi)

                A_lf = (S_theta + (q*wb - r*vb) / (ctx%grav - ac)) * S_alpha    ! eq 7.3.6

                ! eq 7.3.5
                if (abs(ub) > TOLERANCE .and. abs(C_theta) > TOLERANCE .and. abs(C_alpha) > TOLERANCE) then
                    numer = C_theta + C_phi * S_theta * wb / ub
                    denom = (n_L - A_lf) / C_alpha + p * vb / (ctx%grav - ac)

                    if (abs(denom) > TOLERANCE) then
                        arg = numer / denom - wb * S_theta / (ub * C_theta)
                        arg = min(1.0, max(-1.0, arg))  ! clamp for acos
                        phi_new = acos(arg)
                    else
                        phi_new = phi
                    end if
                else
                    phi_new = phi
                end if

                ! check convergence
                if (abs(phi_new - phi) < TOLERANCE) exit
                phi = phi_new
            end do

        else if (ctx%settings%gamma_is_set) then
            ! gamma specified: compute theta from gamma
            theta = solve_theta_from_gamma(velocity, phi, ctx%V_mag, ctx%settings%gamma_specified)
            quat = euler_to_quat([phi, theta, ctx%psi])
        else if (trim(ctx%settings%trim_type) == 'hover') then
            ! hover: level attitude (phi=0, theta=0 enforced), only controls are free
            theta = 0.0
            quat = euler_to_quat([phi, theta, ctx%psi])
        else
            ! gamma not specified: use theta from input euler angles
            theta = ctx%euler_in(2)
            quat = euler_to_quat([phi, theta, ctx%psi])
        end if

        ! compute body rates (skip if already done in load factor iteration)
        if (.not. ctx%settings%loadfactor_is_set) then
            call compute_body_rates(ctx%settings%trim_type, velocity, theta, phi, &
                                    ctx%psi, ctx%alt, ctx%grav, ctx%V_mag, ctx%settings%vbr_pw, omega)
        end if

        ! build state array for dynamics engine: [u, v, w, p, q, r, x, y, z, e0, ex, ey, ez, actuators..., PE...]
        allocate(y(ctx%act_map%state_dim))
        y(1:3) = velocity
        y(4:6) = omega
        y(7:9) = ctx%state_in%position
        y(10:13) = quat

        ! set actuator states = current ctrl values (at trim, cmd = actual -> derivatives = 0)
        do k = 1, ctx%act_map%n_actuators
            eff_idx = ctx%act_map%effector_idx(k)
            y(ctx%ctrl%effectors(eff_idx)%state_index) = ctx%ctrl%effectors(eff_idx)%value
            ctx%ctrl_commanded%effectors(eff_idx)%value = ctx%ctrl%effectors(eff_idx)%value
            if (ctx%ctrl%effectors(eff_idx)%dynamics_order == 2) &
                y(ctx%ctrl%effectors(eff_idx)%rate_state_index) = 0.0
        end do

        ! set passive effector states (position = initial value, rate = 0 for trim)
        do k = 1, ctx%passive%n
            y(ctx%passive%effectors(k)%state_index) = ctx%passive%effectors(k)%value
            y(ctx%passive%effectors(k)%rate_state_index) = 0.0
        end do

        call ctx%state_computed%from_array(y(1:RIGID_DIM))   ! store computed state for output

        dy_dt = ctx%dynamics%compute_derivatives(0.0, y)       ! line 15 of algorithm 6.2.4
        residual(1:6) = dy_dt(1:6)                             ! line 16 of algorithm 6.2.4

        deallocate(y)

    end subroutine calc_R

    ! calculates body rotation rates p,q,r
    subroutine compute_body_rates(trim_type, velocity, theta, phi, psi, alt, grav, V_mag, vbr_pw, omega)
        character(len=*), intent(in) :: trim_type
        real, intent(in) :: velocity(3)
        real, intent(in) :: theta, phi
        real, intent(in) :: psi, alt, grav, V_mag, vbr_pw
        real, intent(out) :: omega(3)

        real :: quat(4), vel_ned(3), ac

        select case (trim(trim_type))
        case ('sct')
            ! compute centripetal acceleration
            quat = euler_to_quat([phi, theta, psi])
            vel_ned = quat_rotate_body_to_inertial(velocity, quat)
            ac = (vel_ned(1)**2 + vel_ned(2)**2) / (R_MEAN_EARTH_ENGLISH + alt)
            call compute_sct_body_rates_core(velocity, theta, phi, grav, ac, omega)
        case ('shss')
            omega = [0.0, 0.0, 0.0] ! rotation rates in shss are all zero
        case ('vbr')
            call compute_vbr_body_rates(velocity, V_mag, vbr_pw, omega)
        case default
            omega = [0.0, 0.0, 0.0]
        end select

    end subroutine compute_body_rates

    ! sct body rates computation with precomputed gravity and ac - eq 6.4.3
    subroutine compute_sct_body_rates_core(velocity, theta, phi, grav, ac, omega)
        real, intent(in) :: velocity(3)
        real, intent(in) :: theta, phi, grav, ac
        real, intent(out) :: omega(3)

        real :: ub, wb, K, denom
        real :: sin_phi, cos_phi, sin_theta, cos_theta

        ub = velocity(1)
        wb = velocity(3)

        sin_phi = sin(phi)
        cos_phi = cos(phi)
        sin_theta = sin(theta)
        cos_theta = cos(theta)

        ! for wings-level flight (phi = 0), body rates are zero
        if (abs(sin_phi) < TOLERANCE) then
            omega = [0.0, 0.0, 0.0]
            return
        end if

        denom = ub * cos_theta * cos_phi + wb * sin_theta
        if (abs(denom) < TOLERANCE) then
            omega = [0.0, 0.0, 0.0]
            return
        end if
        K = (grav - ac) * sin_phi * cos_theta / denom   ! equation 6.4.3
        omega(1) = -K * sin_theta               ! p
        omega(2) = K * sin_phi * cos_theta      ! q
        omega(3) = K * cos_phi * cos_theta      ! r

    end subroutine compute_sct_body_rates_core

    ! compute body rates for vertical barrel roll - eq 6.6.4
    subroutine compute_vbr_body_rates(velocity, V_mag, vbr_pw, omega)
        real, intent(in) :: velocity(3)
        real, intent(in) :: V_mag, vbr_pw
        real, intent(out) :: omega(3)

        if (V_mag < TOLERANCE) then
            omega = [0.0, 0.0, 0.0]
            return
        end if

        omega = (vbr_pw / V_mag) * velocity    ! eq 6.6.4

    end subroutine compute_vbr_body_rates

    ! solve for theta given gamma (flight path angle) - combining eqs 7.2.12 and 7.2.9
    function solve_theta_from_gamma(velocity, phi, V_mag, gamma) result(theta)
        real, intent(in) :: velocity(3)
        real, intent(in) :: phi
        real, intent(in) :: V_mag
        real, intent(in) :: gamma
        real :: theta

        real :: A, B, C, R, delta, arg, s, theta1, theta2
        real :: theta_approx

        theta_approx = gamma

        ! A*sin(theta) + B*cos(theta) = C
        A = velocity(1)
        B = -(velocity(2) * sin(phi) + velocity(3) * cos(phi))
        C = V_mag * sin(gamma)

        R = sqrt(max(TOLERANCE, A*A + B*B))
        delta = atan2(B, A)
        arg = C / R

        ! clamp for numerical safety
        if (arg > 1.0) arg = 1.0
        if (arg < -1.0) arg = -1.0

        s = asin(arg)
        theta1 = s - delta
        theta2 = (PI - s) - delta

        ! wrap angles to [-pi, pi]
        theta1 = wrap_angle(theta1)
        theta2 = wrap_angle(theta2)

        ! choose solution closest to approximate value
        if (abs(wrap_angle(theta1 - theta_approx)) <= abs(wrap_angle(theta2 - theta_approx))) then
            theta = theta1
        else
            theta = theta2
        end if

    end function solve_theta_from_gamma

    ! check if trim solution is within control effector limits
    subroutine check_control_limits(x, ctrl, settings, info)
        real, intent(in) :: x(:)
        type(control_inputs_t), intent(in) :: ctrl
        type(trim_settings_t), intent(in) :: settings
        integer, intent(inout) :: info

        logical :: outside_limits
        real :: beta_val, lo, hi, val
        integer :: i, idx_phi

        outside_limits = .false.
        idx_phi = settings%n_trim_vars

        ! check all control effectors against their limits
        do i = 1, ctrl%n
            lo = ctrl%effectors(i)%min_val
            hi = ctrl%effectors(i)%max_val
            val = x(IDX_CTRL_BASE + i)
            if (val < lo .or. val > hi) outside_limits = .true.
        end do

        if (outside_limits) then
            ! get correct beta value
            if (settings%free_vars(IDX_BETA)) then
                beta_val = x(IDX_BETA)
            else
                beta_val = settings%sideslip_angle
            end if

            write(*,'(A)') ''
            write(*,'(A)') '  WARNING: Trim solution found but outside control effector limits!'
            write(*,'(A)') '  Trim solution (aircraft state):'
            write(*,'(A,F10.4,A)') '    Alpha:    ', x(IDX_ALPHA) * RAD2DEG, ' deg'
            write(*,'(A,F10.4,A)') '    Beta:     ', beta_val * RAD2DEG, ' deg'
            if (settings%free_vars(idx_phi)) then
                write(*,'(A,F10.4,A)') '    Phi:      ', x(idx_phi) * RAD2DEG, ' deg'
            end if
            do i = 1, ctrl%n
                val = x(IDX_CTRL_BASE + i)
                if (ctrl%effectors(i)%is_angle) then
                    write(*,'(A,A,A,F10.4,A)') '    ', trim(ctrl%effectors(i)%name), &
                        ':  ', val * RAD2DEG, ' deg'
                else
                    write(*,'(A,A,A,F10.4)') '    ', trim(ctrl%effectors(i)%name), &
                        ':  ', val
                end if
            end do
            write(*,'(A)') '  Initializing all controls to 0 and running simulation.'
            write(*,'(A)') ''
            info = 3
        end if

    end subroutine check_control_limits

end module trim_m