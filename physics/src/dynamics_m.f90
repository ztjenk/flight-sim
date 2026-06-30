! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! equations of motion and numerical integration
module dynamics_m
    use constants_m
    use math_m
    use atmosphere_m
    use vehicle_types_m
    use force_source_m
    use aero_state_m
    implicit none
    private

    public :: dynamics_engine_t

    integer, parameter, public :: RIGID_DIM = 13  ! rigid body state dimension

    type :: dynamics_engine_t
        type(vehicle_config_t), pointer :: config => null()
        type(control_inputs_t), pointer :: ctrl => null()
        type(control_inputs_t), pointer :: ctrl_commanded => null()
        type(passive_inputs_t), pointer :: passive => null()
        type(actuator_map_t) :: act_map
        integer :: state_dim = 13
        logical :: clamp_actuators = .true.  ! false during trim to allow unconstrained Newton iteration
        real :: wind(3) = [0.0, 0.0, 0.0]   ! constant wind [N, E, D] in earth frame (ft/s)
        real :: gust(6) = 0.0  ! turbulence gusts [u,v,w,p,q,r]
        real :: T_sl_R = 0.0      ! sea-level temperature [Rankine] (0 = standard day)
        real :: P_sl_psf = 0.0   ! sea-level pressure [psf] (0 = standard day)
        ! cached force/moment from last derivatives evaluation (for sensor module)
        real :: F_total_cache(3) = 0.0  ! total non-gravitational force [lbf], body frame
        real :: M_total_cache(3) = 0.0  ! total moment [ft-lbf], body frame
        ! alpha-hat (dimensionless alpha-dot, Eq 3.4.20), held constant across one RK4 step
        real :: alpha_hat = 0.0          ! = alpha_dot * c_bar / (2 V), set once per timestep
        real :: alpha_prev = 0.0         ! previous accepted alpha [rad] for the backward difference
        logical :: alpha_init = .false.  ! .false. until the first alpha_prev has been recorded
        ! beta-hat (dimensionless beta-dot, Eq 3.4.21 = beta_dot * b / (2 V)); shares the alpha_init gate
        real :: beta_hat = 0.0           ! set once per timestep alongside alpha_hat
        real :: beta_prev = 0.0          ! previous accepted beta [rad] for the backward difference
    contains
        procedure :: initialize => dynamics_init
        procedure :: compute_derivatives => dynamics_derivatives
        procedure :: step_rk4 => dynamics_step_rk4
    end type dynamics_engine_t

contains

    subroutine dynamics_init(self, config, ctrl, ctrl_commanded, passive, act_map, wind, &
                             T_sl_R, P_sl_psf)
        class(dynamics_engine_t), intent(inout) :: self
        type(vehicle_config_t), target, intent(in) :: config
        type(control_inputs_t), target, intent(in) :: ctrl
        type(control_inputs_t), target, intent(in) :: ctrl_commanded
        type(passive_inputs_t), target, intent(in) :: passive
        type(actuator_map_t), intent(in) :: act_map
        real, intent(in), optional :: wind(3)
        real, intent(in), optional :: T_sl_R, P_sl_psf

        self%config => config
        self%ctrl => ctrl
        self%ctrl_commanded => ctrl_commanded
        self%passive => passive
        self%act_map = act_map
        self%state_dim = act_map%state_dim
        if (present(wind)) self%wind = wind
        if (present(T_sl_R)) self%T_sl_R = T_sl_R
        if (present(P_sl_psf)) self%P_sl_psf = P_sl_psf
    end subroutine dynamics_init

    ! compute state derivatives
    function dynamics_derivatives(self, t, y, verbose_unit, call_num) result(dy_dt)
        class(dynamics_engine_t), intent(inout) :: self
        real, intent(in) :: t
        real, intent(in) :: y(:)
        integer, intent(in), optional :: verbose_unit
        integer, intent(in), optional :: call_num
        real :: dy_dt(size(y))

        real :: u, v, w, p, q, r, e0, ex, ey, ez
        real :: alt, g, ac
        real :: F(3), M(3), M_eff(3), F_j(3), M_j(3)
        real :: hx, hy, hz
        real :: I(3,3), I_inv(3,3)
        real :: mass
        real :: Z_atm, T_atm, P_atm, rho, a_snd, mu_atm
        real :: ctrl_vals(self%ctrl%n)
        real :: all_vals(self%ctrl%n + 2 * self%act_map%n_passive)
        integer :: j, n_ctrl, n_passive, n_all
        type(vehicle_state_t) :: state
        ! actuator dynamics variables
        integer :: k, eff_idx
        real :: delta_actual, delta_cmd, delta_dot
        real :: delta_rate, omega_n, zeta, delta_ddot
        ! passive effector dynamics variables
        real :: pe_theta, pe_rate, V_mag_pe, q_dyn, C_drive, torque, theta_dot, theta_ddot
        type(aero_state_t) :: pe_state
        ! component frame variables
        real :: v_comp(3), omega_comp(3)
        ! propeller gyroscopic angular momentum
        real :: h_local(3)

        ! publish this vehicle's alpha-hat / beta-hat (set once per timestep) so the aero evaluators read them
        call set_alpha_hat(self%alpha_hat)
        call set_beta_hat(self%beta_hat)

        ! extract state components
        u = y(1); v = y(2); w = y(3)
        p = y(4); q = y(5); r = y(6)
        e0 = y(10); ex = y(11); ey = y(12); ez = y(13)
        alt = -y(9)

        call state%from_array(y(1:RIGID_DIM))

        n_passive = self%act_map%n_passive

        ! treat vehicle as a simple kinematics problem (no forces)
        if (self%config%is_kinematic) then
            dy_dt = 0.0
            dy_dt(7:9) = quat_rotate_body_to_inertial(y(1:3), y(10:13)) + self%wind
            ! quaternion changes based on angular velocity (will be zero if p=q=r=0)
            dy_dt(10) = 0.5 * (-ex*p - ey*q - ez*r)
            dy_dt(11) = 0.5 * ( e0*p - ez*q + ey*r)
            dy_dt(12) = 0.5 * ( e0*q + ez*p - ex*r)
            dy_dt(13) = 0.5 * ( e0*r - ey*p + ex*q)

            ! verbose output if requested
            if (present(verbose_unit) .and. present(call_num)) then
                F = 0.0; M = 0.0; g = 0.0; ac = 0.0; mass = 1.0
                call write_derivatives_verbose(verbose_unit, call_num, t, y, F, M, dy_dt, &
                                               g, ac, mass)
            end if
            return
        end if

        ! atmosphere at current altitude
        if (self%T_sl_R > 0.0 .or. self%P_sl_psf > 0.0) then
            call std_atm_english(alt, Z_atm, T_atm, P_atm, rho, a_snd, mu_atm, &
                                 self%T_sl_R, self%P_sl_psf)
        else
            call std_atm_english(alt, Z_atm, T_atm, P_atm, rho, a_snd, mu_atm)
        end if

        ! build control values array
        n_ctrl = self%ctrl%n
        do j = 1, n_ctrl
            ctrl_vals(j) = self%ctrl%effectors(j)%value
        end do

        ! override with actuator states from extended state vector
        do k = 1, self%act_map%n_actuators
            eff_idx = self%act_map%effector_idx(k)
            if (self%clamp_actuators) then
                ctrl_vals(eff_idx) = max(self%ctrl%effectors(eff_idx)%min_val, &
                                     min(self%ctrl%effectors(eff_idx)%max_val, &
                                         y(self%ctrl%effectors(eff_idx)%state_index)))
            else
                ctrl_vals(eff_idx) = y(self%ctrl%effectors(eff_idx)%state_index)
            end if
        end do

        ! build extended values array: ctrl + PE positions + PE nondim rates
        n_all = n_ctrl + 2 * n_passive
        all_vals(1:n_ctrl) = ctrl_vals(1:n_ctrl)

        ! PE positions from state vector
        do j = 1, n_passive
            pe_theta = y(self%passive%effectors(j)%state_index)
            if (self%clamp_actuators .and. self%passive%effectors(j)%has_limits) then
                pe_theta = max(self%passive%effectors(j)%min_val, &
                           min(self%passive%effectors(j)%max_val, pe_theta))
            end if
            all_vals(n_ctrl + j) = pe_theta
        end do

        ! PE nondim rates from state vector
        V_mag_pe = norm3(state%velocity)
        do j = 1, n_passive
            pe_rate = y(self%passive%effectors(j)%rate_state_index)
            if (self%passive%effectors(j)%nondim_rate .and. V_mag_pe > TOLERANCE) then
                all_vals(n_ctrl + n_passive + j) = pe_rate * self%passive%effectors(j)%ref_length / (2.0 * V_mag_pe)
            else if (.not. self%passive%effectors(j)%nondim_rate) then
                all_vals(n_ctrl + n_passive + j) = pe_rate
            else
                all_vals(n_ctrl + n_passive + j) = 0.0
            end if
        end do

        ! sum forces and moments from all components/sources (Section 3.6)
        ! per Section 9.8: gusts modify velocities seen by aero model only
        F = 0.0; M = 0.0
        do j = 1, self%config%n_sources
            associate(src => self%config%sources(j)%src)

            if (src%has_orientation) then
                ! component velocity: V_c = [R]^-1 * [V + (omega_b x P)]  (Eq 3.6.2)
                ! P = component location relative to CG (Section 3.6, p.99)
                ! [R] = rotation matrix from component Euler angles (Eq 2.6.2)
                v_comp = state%velocity + self%gust(1:3) &
                       + cross3(state%omega + self%gust(4:6), src%location)
                v_comp = quat_rotate_inertial_to_body(v_comp, src%orientation)
                ! component angular rate in component frame
                omega_comp = quat_rotate_inertial_to_body(state%omega + self%gust(4:6), src%orientation)

                call src%compute(v_comp, omega_comp, rho, mu_atm, all_vals, n_all, F_j, M_j)

                ! F_b = [R] * F_c  (Eq 3.6.4)
                F_j = quat_rotate_body_to_inertial(F_j, src%orientation)
                ! M_b = [R] * M_c + P x F_b  (Eq 3.6.5)
                M_j = quat_rotate_body_to_inertial(M_j, src%orientation)
            else
                call src%compute( &
                    state%velocity + self%gust(1:3), state%omega + self%gust(4:6), &
                    rho, mu_atm, all_vals, n_all, F_j, M_j)
            end if

            ! F_b_total = sum(F_b_i)  (Eq 3.6.6)
            F = F + F_j
            ! M_b_total = sum(M_b_i)  (Eq 3.6.7), with P x F_b from Eq 3.6.5
            M = M + M_j + cross3(src%location, F_j)

            end associate
        end do

        ! cache total force/moment for sensor module
        self%F_total_cache = F
        self%M_total_cache = M

        ! mass properties
        mass = self%config%mass%mass
        I = self%config%mass%I
        I_inv = self%config%mass%I_inv

        ! angular momentum: static h from assembled mass + dynamic h from spinning propellers
        ! gyroscopic coupling enters the rotational EOM (flightsim Eq. 5.4.6)
        hx = self%config%mass%h(1)
        hy = self%config%mass%h(2)
        hz = self%config%mass%h(3)
        do j = 1, self%config%n_sources
            select type (src => self%config%sources(j)%src)
            type is (propeller_source_t)
                if (src%comp_mass%I(1,1) > 0.0) then
                    ! h = I * omega_total in component frame
                    ! omega_total = [omega_spin + p_c, q_c, r_c] (spin + body rates)
                    if (src%has_orientation) then
                        omega_comp = quat_rotate_inertial_to_body(state%omega, src%orientation)
                    else
                        omega_comp = state%omega
                    end if
                    omega_comp(1) = omega_comp(1) + src%delta * src%omega_current * 2.0 * PI
                    h_local = matmul(src%comp_mass%I, omega_comp)
                    if (src%has_orientation) then
                        h_local = quat_rotate_body_to_inertial(h_local, src%orientation)
                    end if
                    hx = hx + h_local(1)
                    hy = hy + h_local(2)
                    hz = hz + h_local(3)
                end if
            end select
        end do

        ! rotational dynamics - eq 5.4.6
        M_eff(1) = -hz*q + hy*r + M(1) &
                 + (I(2,2) - I(3,3))*q*r + I(2,3)*(q*q - r*r) + I(1,3)*p*q - I(1,2)*p*r
        M_eff(2) = hz*p - hx*r + M(2) &
                 + (I(3,3) - I(1,1))*p*r + I(1,3)*(r*r - p*p) + I(1,2)*q*r - I(2,3)*p*q
        M_eff(3) = -hy*p + hx*q + M(3) &
                 + (I(1,1) - I(2,2))*p*q + I(1,2)*(p*p - q*q) + I(2,3)*p*r - I(1,3)*q*r

        ! pdot, qdot, rdot   -   eq 5.4.6
        dy_dt(4) = I_inv(1,1)*M_eff(1) + I_inv(1,2)*M_eff(2) + I_inv(1,3)*M_eff(3)
        dy_dt(5) = I_inv(2,1)*M_eff(1) + I_inv(2,2)*M_eff(2) + I_inv(2,3)*M_eff(3)
        dy_dt(6) = I_inv(3,1)*M_eff(1) + I_inv(3,2)*M_eff(2) + I_inv(3,3)*M_eff(3)

        ! xdot, ydot, zdot - eq 5.4.7 (ground velocity = airspeed in earth frame + wind)
        dy_dt(7:9) = quat_rotate_body_to_inertial(y(1:3), y(10:13)) + self%wind

        ! gravity at current altitude with gravity relief - eq 5.5.3
        g = gravity_english(alt)
        ac = (dy_dt(7)**2 + dy_dt(8)**2) / (R_MEAN_EARTH_ENGLISH + alt)

        ! udot, vdot, wdot - eq 5.4.5
        dy_dt(1) = F(1)/mass + 2.0*(g-ac)*(ex*ez - e0*ey) + r*v - q*w
        dy_dt(2) = F(2)/mass + 2.0*(g-ac)*(e0*ex + ey*ez) + p*w - r*u
        dy_dt(3) = F(3)/mass + (g-ac)*(e0*e0 + ez*ez - ex*ex - ey*ey) + q*u - p*v

        ! e0dot, exdot, eydot, dzdot - eq 5.4.8
        dy_dt(10) = 0.5 * (-ex*p - ey*q - ez*r)
        dy_dt(11) = 0.5 * ( e0*p - ez*q + ey*r)
        dy_dt(12) = 0.5 * ( e0*q + ez*p - ex*r)
        dy_dt(13) = 0.5 * ( e0*r - ey*p + ex*q)

        ! actuator dynamics
        do k = 1, self%act_map%n_actuators
            eff_idx = self%act_map%effector_idx(k)
            associate(eff => self%ctrl%effectors(eff_idx))
            delta_cmd = self%ctrl_commanded%effectors(eff_idx)%value
            delta_actual = y(eff%state_index)

            if (eff%dynamics_order == 1) then
                ! first-order dynamics - algorithm 10.2.10
                if (self%clamp_actuators) delta_actual = max(eff%min_val, min(eff%max_val, delta_actual))
                delta_dot = (delta_cmd - delta_actual) / eff%time_constant
                if (self%clamp_actuators) then
                    delta_dot = max(eff%rate_min, min(eff%rate_max, delta_dot))
                    call clamp_and_freeze(delta_actual, eff%min_val, eff%max_val, delta_dot)
                end if
                dy_dt(eff%state_index) = delta_dot

            else  ! dynamics_order == 2, algorithm 10.3.11
                delta_rate = y(eff%rate_state_index)
                omega_n = eff%natural_frequency; zeta = eff%damping_ratio
                if (self%clamp_actuators) then
                    delta_actual = max(eff%min_val, min(eff%max_val, delta_actual))              ! line 9
                    delta_rate = max(eff%rate_min, min(eff%rate_max, delta_rate))                ! line 10
                    call clamp_and_freeze(delta_actual, eff%min_val, eff%max_val, delta_rate)    ! lines 11-12
                end if
                delta_ddot = omega_n**2 * (delta_cmd - delta_actual) - 2.0*zeta*omega_n*delta_rate  ! line 13
                if (self%clamp_actuators) then
                    delta_ddot = max(eff%accel_min, min(eff%accel_max, delta_ddot))              ! line 14
                    call clamp_and_freeze(delta_rate, eff%rate_min, eff%rate_max, delta_ddot)    ! lines 15-16
                    if (delta_actual <= eff%min_val .and. delta_cmd < eff%min_val) delta_ddot = 0.0  ! line 17
                    if (delta_actual >= eff%max_val .and. delta_cmd > eff%max_val) delta_ddot = 0.0  ! line 18
                end if
                dy_dt(eff%state_index) = delta_rate
                dy_dt(eff%rate_state_index) = delta_ddot
            end if
            end associate
        end do

        ! passive effector dynamics: I * theta_ddot = C_drive * Q * S * L - c * theta_dot
        if (n_passive > 0) then
            ! build aero state from gusted velocity/omega (per Section 9.8)
            call populate_aero_state(pe_state, &
                                     state%velocity + self%gust(1:3), &
                                     state%omega + self%gust(4:6), &
                                     self%config%ref_b, self%config%ref_c, &
                                     all_vals, n_all)
            V_mag_pe = norm3(state%velocity + self%gust(1:3))
            q_dyn = calc_dynamic_pressure(rho, V_mag_pe)

            do j = 1, n_passive
                associate(pe => self%passive%effectors(j))

                C_drive = pe%driving%evaluate(pe_state)

                torque = C_drive * q_dyn * pe%ref_area * pe%ref_length
                theta_dot = y(pe%rate_state_index)
                if (pe%has_damping) then
                    theta_ddot = (torque - pe%damping * theta_dot) / pe%inertia
                else
                    theta_ddot = torque / pe%inertia
                end if
                dy_dt(pe%state_index) = theta_dot
                dy_dt(pe%rate_state_index) = theta_ddot
                end associate
            end do
        end if

        ! verbose output if requested
        if (present(verbose_unit) .and. present(call_num)) then
            call write_derivatives_verbose(verbose_unit, call_num, t, y, F, M, dy_dt, &
                                           g, ac, mass)
        end if

    end function dynamics_derivatives

    ! RK4 integration step
    function dynamics_step_rk4(self, t, y, dt, verbose_unit) result(y_new)
        class(dynamics_engine_t), intent(inout) :: self
        real, intent(in) :: t
        real, intent(in) :: y(:)
        real, intent(in) :: dt
        integer, intent(in), optional :: verbose_unit
        real :: y_new(size(y))

        real :: k1(self%state_dim), k2(self%state_dim), k3(self%state_dim), &
                k4(self%state_dim), y_temp(self%state_dim)
        integer :: n, k, eff_idx

        n = self%state_dim

        if (present(verbose_unit)) then
            call write_state_header(verbose_unit, t, y, .true.)
            write(verbose_unit, '(A)') ''
            write(verbose_unit, '(A)') '  rk4 function called...'
            write(verbose_unit, '(A)') ''
        end if

        ! k1 at t   -   eq 5.7.6
        k1 = self%compute_derivatives(t, y, verbose_unit, 1)

        ! k2 at t + dt/2    -   eq 5.7.7
        y_temp = y + 0.5*dt*k1
        k2 = self%compute_derivatives(t + 0.5*dt, y_temp, verbose_unit, 2)

        ! k3 at t + dt/2    -   eq 5.7.8
        y_temp = y + 0.5*dt*k2
        k3 = self%compute_derivatives(t + 0.5*dt, y_temp, verbose_unit, 3)

        ! k4 at t + dt  -   eq 5.7.9
        y_temp = y + dt*k3
        k4 = self%compute_derivatives(t + dt, y_temp, verbose_unit, 4)

        ! weighted average  -   eq 5.7.5
        y_new = y + (dt/6.0) * (k1 + 2.0*k2 + 2.0*k3 + k4)

        ! normalize quaternion
        call quat_normalize(y_new(10:13))

        ! apply limiters to actuator states at end of full time step (eqs 10.3.32-10.3.33)
        do k = 1, self%act_map%n_actuators
            eff_idx = self%act_map%effector_idx(k)
            associate(eff => self%ctrl%effectors(eff_idx))
            y_new(eff%state_index) = max(eff%min_val, min(eff%max_val, y_new(eff%state_index)))
            if (eff%dynamics_order == 2) then
                y_new(eff%rate_state_index) = max(eff%rate_min, min(eff%rate_max, y_new(eff%rate_state_index)))
            end if
            end associate
        end do

        ! apply limiters to passive effector positions (zero rate at limits)
        do k = 1, self%act_map%n_passive
            associate(pe => self%passive%effectors(k))
            if (pe%has_limits) then
                call clamp_and_freeze(y_new(pe%state_index), pe%min_val, pe%max_val, &
                                      y_new(pe%rate_state_index))
            end if
            end associate
        end do

        if (present(verbose_unit)) then
            call write_state_header(verbose_unit, t + dt, y_new, .false.)
            write(verbose_unit, '(A)') ''
            write(verbose_unit, '(A)') ' --------------------------- End of single RK4 integration step. ---------------------------'
            write(verbose_unit, '(A)') ''
            flush(verbose_unit)
        end if

    end function dynamics_step_rk4

    ! write verbose output for a single derivatives evaluation
    subroutine write_derivatives_verbose(unit_out, call_num, t, y, F, M, dy_dt, g, ac, mass)
        integer, intent(in) :: unit_out, call_num
        real, intent(in) :: t, y(:), F(3), M(3), dy_dt(:)
        real, intent(in) :: g, ac, mass

        write(unit_out, '(A)') '    diff_eq function called...'
        write(unit_out, '(A,I12)') '    |           RK4 call number = ', call_num
        write(unit_out, '(A,ES20.12)') '    |                  time [s] = ', t
        write(unit_out, '(A,13ES20.12)') '    |    state vector coming in = ', y(1:RIGID_DIM)
        write(unit_out, '(A,6ES20.12)') '    | pseudo aerodynamics (F,M) = ', F, M
        write(unit_out, '(A,ES20.12)')   '    |        gravity [ft/s^2] = ', g
        write(unit_out, '(A,ES20.12)')   '    | centripetal ac [ft/s^2] = ', ac
        write(unit_out, '(A,ES20.12)')   '    |           mass [slug] = ', mass
        write(unit_out, '(A,13ES20.12)') '    |           diff_eq results = ', dy_dt(1:RIGID_DIM)
        if (size(y) > RIGID_DIM) then
            write(unit_out, '(A,*(ES20.12))') '    |        actuator states in = ', y(RIGID_DIM+1:)
            write(unit_out, '(A,*(ES20.12))') '    |         actuator rates    = ', dy_dt(RIGID_DIM+1:)
        end if
        write(unit_out, '(A)') ''
    end subroutine write_derivatives_verbose

    ! write RK4 state header
    subroutine write_state_header(unit_out, t, y, is_beginning)
        integer, intent(in) :: unit_out
        real, intent(in) :: t, y(:)
        logical, intent(in) :: is_beginning

        character(len=300) :: header

        if (is_beginning) then
            write(unit_out, '(A)') '  state of the vehicle at the beginning of this RK4 integration step:'
        else
            write(unit_out, '(A)') '  state of the vehicle after running RK4:'
        end if
        header = '  t[s]                u[ft/s]             v[ft/s]             w[ft/s]   ' // &
                 '          p[rad/s]            q[rad/s]            r[rad/s]            ' // &
                 'x[ft]               y[ft]               z[ft]               e0        ' // &
                 '          ex                  ey                  ez'
        write(unit_out, '(A)') trim(header)
        write(unit_out, '(14ES20.12)') t, y(1:RIGID_DIM)
        if (size(y) > RIGID_DIM) then
            write(unit_out, '(A,*(ES20.12))') '  actuator states: ', y(RIGID_DIM+1:)
        end if
    end subroutine write_state_header

    ! clamp value to [lo, hi] and freeze derivative at boundaries
    ! if val is at lo and deriv < 0, deriv is zeroed (and vice versa at hi)
    pure subroutine clamp_and_freeze(val, lo, hi, deriv)
        real, intent(inout) :: val, deriv
        real, intent(in) :: lo, hi
        val = max(lo, min(hi, val))
        if (val <= lo .and. deriv < 0.0) deriv = 0.0
        if (val >= hi .and. deriv > 0.0) deriv = 0.0
    end subroutine clamp_and_freeze

end module dynamics_m
