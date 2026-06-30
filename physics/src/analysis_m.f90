! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! state-space linearization via central-difference Jacobian computation
! computes A = df/dx and B = df/du at the trim equilibrium point
! algorithm follows textbook ch8 (Algorithm 8.3.9: numerical linear model)
module analysis_m
    use constants_m
    use math_m
    use vehicle_types_m
    use dynamics_m
    implicit none
    private

    public :: run_analysis

    integer, parameter :: EULER_DIM = 12  ! Euler-angle rigid body state dimension

contains

    ! main entry point: called from main.f90 after trim is solved
    subroutine run_analysis(config, state_trim, ctrl_trim, passive_trim, settings, &
                            T_sl_R, P_sl_psf)
        type(vehicle_config_t), target, intent(in) :: config
        type(vehicle_state_t), intent(in) :: state_trim
        type(control_inputs_t), intent(in) :: ctrl_trim
        type(passive_inputs_t), intent(in) :: passive_trim
        type(analysis_settings_t), intent(in) :: settings
        ! optional sea-level atmosphere overrides (Rankine / psf); absent or 0 = standard day
        real, intent(in), optional :: T_sl_R, P_sl_psf

        type(control_inputs_t) :: an_ctrl, an_ctrl_cmd
        type(passive_inputs_t) :: an_passive
        type(actuator_map_t) :: an_act_map
        type(dynamics_engine_t) :: engine

        integer :: n_states, n_inputs, n_act_states
        real, allocatable :: y0(:)
        real, allocatable :: A_mat(:,:), B_mat(:,:)
        character(len=64), allocatable :: state_labels(:), input_labels(:)
        character(len=256) :: prefix
        logical :: use_euler

        if (.not. settings%export_state_space) return

        use_euler = (trim(settings%state_form) == 'euler')

        ! prefix for output files
        if (len_trim(settings%output_prefix) > 0) then
            prefix = trim(settings%output_prefix)
        else
            prefix = trim(config%name)
        end if

        write(*,*)
        write(*,'(A)') '  ========================================'
        write(*,'(A,A)') '  State-Space Linearization: ', trim(config%name)
        if (use_euler) then
            write(*,'(A)') '  State form: Euler angles'
        else
            write(*,'(A)') '  State form: Quaternion'
        end if
        write(*,'(A,ES10.3)') '  FD step size: ', settings%fd_step
        write(*,'(A)') '  ========================================'

        ! build engine with local copies (matches trim_m.f90 pattern)
        call an_ctrl%copy_from(ctrl_trim)
        call an_ctrl_cmd%copy_from(ctrl_trim)   ! at trim: commanded = actual
        an_passive = passive_trim
        call build_actuator_map(an_ctrl, an_passive, an_act_map)
        call engine%initialize(config, an_ctrl, an_ctrl_cmd, an_passive, an_act_map, &
                               T_sl_R=T_sl_R, P_sl_psf=P_sl_psf)
        engine%clamp_actuators = .false.   ! clean finite differences without saturation

        ! state dimension: extended state vector size
        n_act_states = an_act_map%state_dim - RIGID_DIM   ! actuator + passive states
        if (use_euler) then
            n_states = EULER_DIM + n_act_states
        else
            n_states = RIGID_DIM + n_act_states
        end if
        n_inputs = an_ctrl%n

        ! pack trim state into full quaternion extended state vector
        allocate(y0(an_act_map%state_dim))
        call pack_trim_state(state_trim, an_ctrl, an_passive, an_act_map, y0)

        ! allocate and compute matrices
        allocate(A_mat(n_states, n_states))
        allocate(B_mat(n_states, n_inputs))
        allocate(state_labels(n_states))
        allocate(input_labels(n_inputs))

        call build_state_labels(use_euler, an_ctrl, an_passive, an_act_map, state_labels)
        call build_input_labels(an_ctrl, input_labels)

        if (use_euler) then
            call compute_A_euler(engine, y0, settings%fd_step, n_states, n_act_states, A_mat)
            call compute_B_euler(engine, y0, an_ctrl, an_ctrl_cmd, settings%fd_step, &
                                 n_states, n_inputs, n_act_states, B_mat)
        else
            call compute_A_quat(engine, y0, settings%fd_step, n_states, A_mat)
            call compute_B_quat(engine, y0, an_ctrl, an_ctrl_cmd, settings%fd_step, &
                                n_states, n_inputs, B_mat)
        end if

        ! print trim point
        call print_trim_point(state_trim, an_ctrl)

        ! print matrices to terminal
        call print_matrix('A matrix', A_mat, n_states, n_states, state_labels, state_labels)
        call print_matrix('B matrix', B_mat, n_states, n_inputs, state_labels, input_labels)

        ! write CSV files
        call write_matrix_csv(trim(prefix)//'_A.csv', A_mat, n_states, n_states, state_labels, state_labels)
        call write_matrix_csv(trim(prefix)//'_B.csv', B_mat, n_states, n_inputs, state_labels, input_labels)

        write(*,'(A,A)') '  Wrote: ', trim(prefix)//'_A.csv'
        write(*,'(A,A)') '  Wrote: ', trim(prefix)//'_B.csv'
        write(*,*)

    end subroutine run_analysis

    ! pack trim state and controls into full extended state vector y (quaternion form)
    subroutine pack_trim_state(state_trim, ctrl, passive, act_map, y)
        type(vehicle_state_t), intent(in) :: state_trim
        type(control_inputs_t), intent(in) :: ctrl
        type(passive_inputs_t), intent(in) :: passive
        type(actuator_map_t), intent(in) :: act_map
        real, intent(out) :: y(:)

        integer :: k, eff_idx

        y = 0.0
        y(1:RIGID_DIM) = state_trim%to_array()

        do k = 1, act_map%n_actuators
            eff_idx = act_map%effector_idx(k)
            y(ctrl%effectors(eff_idx)%state_index) = ctrl%effectors(eff_idx)%value
            if (ctrl%effectors(eff_idx)%dynamics_order == 2) &
                y(ctrl%effectors(eff_idx)%rate_state_index) = ctrl%effectors(eff_idx)%rate_value
        end do

        do k = 1, passive%n
            y(passive%effectors(k)%state_index) = passive%effectors(k)%value
            y(passive%effectors(k)%rate_state_index) = passive%effectors(k)%rate_value
        end do

    end subroutine pack_trim_state

    ! evaluate derivatives in quaternion form (thin wrapper)
    function eval_deriv_quat(engine, y) result(dy)
        type(dynamics_engine_t), intent(inout) :: engine
        real, intent(in) :: y(:)
        real :: dy(size(y))
        dy = engine%compute_derivatives(0.0, y)
    end function eval_deriv_quat

    ! evaluate derivatives in Euler angle form
    ! y_euler = [u,v,w, p,q,r, x,y,z, phi,theta,psi, act_states...]
    ! converts to/from quaternion internally
    function eval_deriv_euler(engine, y_euler, n_euler, n_act) result(dy_euler)
        type(dynamics_engine_t), intent(inout) :: engine
        real, intent(in) :: y_euler(:)
        integer, intent(in) :: n_euler   ! total Euler state dim = 12 + n_act
        integer, intent(in) :: n_act     ! number of actuator/passive states
        real :: dy_euler(n_euler)

        real :: y_quat(RIGID_DIM + n_act)
        real :: dy_quat(RIGID_DIM + n_act)
        real :: eul(3), q(4), phi, theta, p, q_rate, r

        ! build quaternion state vector from Euler state vector
        y_quat(1:9) = y_euler(1:9)                          ! u,v,w, p,q,r, x,y,z
        eul = y_euler(10:12)                                 ! [phi, theta, psi]
        q = euler_to_quat(eul)
        y_quat(10:13) = q                                    ! e0,ex,ey,ez
        if (n_act > 0) y_quat(14:RIGID_DIM+n_act) = y_euler(13:EULER_DIM+n_act)  ! actuator states

        ! evaluate quaternion derivatives
        dy_quat = engine%compute_derivatives(0.0, y_quat)

        ! map back to Euler state derivatives
        dy_euler(1:9) = dy_quat(1:9)   ! udot,vdot,wdot, pdot,qdot,rdot, xdot,ydot,zdot

        ! Euler kinematic equations (ch8, Section 1.8):
        ! phi_dot   = p + (q*sin(phi) + r*cos(phi)) * tan(theta)
        ! theta_dot = q*cos(phi) - r*sin(phi)
        ! psi_dot   = (q*sin(phi) + r*cos(phi)) / cos(theta)
        phi   = eul(1)
        theta = eul(2)
        p     = y_euler(4)
        q_rate = y_euler(5)
        r     = y_euler(6)

        if (abs(cos(theta)) > TOLERANCE) then
            dy_euler(10) = p + (q_rate*sin(phi) + r*cos(phi)) * tan(theta)
            dy_euler(11) = q_rate*cos(phi) - r*sin(phi)
            dy_euler(12) = (q_rate*sin(phi) + r*cos(phi)) / cos(theta)
        else
            ! near gimbal lock (theta ~ +/- 90 deg): use quaternion derivatives directly
            ! approximation only — trim point should not be near vertical
            dy_euler(10) = 0.0
            dy_euler(11) = 0.0
            dy_euler(12) = 0.0
        end if

        if (n_act > 0) dy_euler(13:EULER_DIM+n_act) = dy_quat(14:RIGID_DIM+n_act)  ! actuator rates

    end function eval_deriv_euler

    ! convert quaternion extended state to Euler extended state
    subroutine quat_to_euler_state(y_quat, n_act, y_euler)
        real, intent(in) :: y_quat(:)
        integer, intent(in) :: n_act
        real, intent(out) :: y_euler(EULER_DIM + n_act)

        y_euler(1:9) = y_quat(1:9)
        y_euler(10:12) = quat_to_euler(y_quat(10:13))
        if (n_act > 0) y_euler(13:EULER_DIM+n_act) = y_quat(14:RIGID_DIM+n_act)

    end subroutine quat_to_euler_state

    ! A matrix (state Jacobian) in quaternion form — Algorithm 8.3.9
    subroutine compute_A_quat(engine, y0, delta, n_states, A)
        type(dynamics_engine_t), intent(inout) :: engine
        real, intent(in) :: y0(:)
        real, intent(in) :: delta
        integer, intent(in) :: n_states
        real, intent(out) :: A(n_states, n_states)

        real :: y_fwd(n_states), y_bwd(n_states)
        real :: dy_fwd(n_states), dy_bwd(n_states)
        integer :: j

        do j = 1, n_states
            y_fwd = y0(1:n_states)
            y_bwd = y0(1:n_states)
            y_fwd(j) = y_fwd(j) + delta
            y_bwd(j) = y_bwd(j) - delta
            dy_fwd = eval_deriv_quat(engine, y_fwd)
            dy_bwd = eval_deriv_quat(engine, y_bwd)
            A(:, j) = (dy_fwd - dy_bwd) / (2.0 * delta)
        end do

    end subroutine compute_A_quat

    ! A matrix (state Jacobian) in Euler angle form — Algorithm 8.3.9
    subroutine compute_A_euler(engine, y0_quat, delta, n_states, n_act, A)
        type(dynamics_engine_t), intent(inout) :: engine
        real, intent(in) :: y0_quat(:)
        real, intent(in) :: delta
        integer, intent(in) :: n_states   ! = 12 + n_act
        integer, intent(in) :: n_act
        real, intent(out) :: A(n_states, n_states)

        real :: y0_euler(n_states)
        real :: y_fwd(n_states), y_bwd(n_states)
        real :: dy_fwd(n_states), dy_bwd(n_states)
        integer :: j

        call quat_to_euler_state(y0_quat, n_act, y0_euler)

        do j = 1, n_states
            y_fwd = y0_euler
            y_bwd = y0_euler
            y_fwd(j) = y_fwd(j) + delta
            y_bwd(j) = y_bwd(j) - delta
            dy_fwd = eval_deriv_euler(engine, y_fwd, n_states, n_act)
            dy_bwd = eval_deriv_euler(engine, y_bwd, n_states, n_act)
            A(:, j) = (dy_fwd - dy_bwd) / (2.0 * delta)
        end do

    end subroutine compute_A_euler

    ! B matrix (input Jacobian) in quaternion form — Algorithm 8.3.9
    subroutine compute_B_quat(engine, y0, ctrl, ctrl_cmd, delta, n_states, n_inputs, B)
        type(dynamics_engine_t), intent(inout) :: engine
        real, intent(in) :: y0(:)
        type(control_inputs_t), intent(inout) :: ctrl
        type(control_inputs_t), intent(inout) :: ctrl_cmd
        real, intent(in) :: delta
        integer, intent(in) :: n_states, n_inputs
        real, intent(out) :: B(n_states, n_inputs)

        real :: dy_fwd(n_states), dy_bwd(n_states)
        real :: saved_val
        integer :: j

        do j = 1, n_inputs
            if (ctrl%effectors(j)%dynamics_order == 0) then
                ! order 0: direct effector — perturb ctrl%value (used directly in force model)
                saved_val = ctrl%effectors(j)%value
                ctrl%effectors(j)%value = saved_val + delta
                dy_fwd = eval_deriv_quat(engine, y0(1:n_states))
                ctrl%effectors(j)%value = saved_val - delta
                dy_bwd = eval_deriv_quat(engine, y0(1:n_states))
                ctrl%effectors(j)%value = saved_val
            else
                ! order 1/2: commanded value drives actuator ODE
                saved_val = ctrl_cmd%effectors(j)%value
                ctrl_cmd%effectors(j)%value = saved_val + delta
                dy_fwd = eval_deriv_quat(engine, y0(1:n_states))
                ctrl_cmd%effectors(j)%value = saved_val - delta
                dy_bwd = eval_deriv_quat(engine, y0(1:n_states))
                ctrl_cmd%effectors(j)%value = saved_val
            end if
            B(:, j) = (dy_fwd - dy_bwd) / (2.0 * delta)
        end do

    end subroutine compute_B_quat

    ! B matrix (input Jacobian) in Euler angle form — Algorithm 8.3.9
    subroutine compute_B_euler(engine, y0_quat, ctrl, ctrl_cmd, delta, n_states, n_inputs, n_act, B)
        type(dynamics_engine_t), intent(inout) :: engine
        real, intent(in) :: y0_quat(:)
        type(control_inputs_t), intent(inout) :: ctrl
        type(control_inputs_t), intent(inout) :: ctrl_cmd
        real, intent(in) :: delta
        integer, intent(in) :: n_states, n_inputs, n_act
        real, intent(out) :: B(n_states, n_inputs)

        real :: y0_euler(n_states)
        real :: dy_fwd(n_states), dy_bwd(n_states)
        real :: saved_val
        integer :: j

        call quat_to_euler_state(y0_quat, n_act, y0_euler)

        do j = 1, n_inputs
            if (ctrl%effectors(j)%dynamics_order == 0) then
                saved_val = ctrl%effectors(j)%value
                ctrl%effectors(j)%value = saved_val + delta
                dy_fwd = eval_deriv_euler(engine, y0_euler, n_states, n_act)
                ctrl%effectors(j)%value = saved_val - delta
                dy_bwd = eval_deriv_euler(engine, y0_euler, n_states, n_act)
                ctrl%effectors(j)%value = saved_val
            else
                saved_val = ctrl_cmd%effectors(j)%value
                ctrl_cmd%effectors(j)%value = saved_val + delta
                dy_fwd = eval_deriv_euler(engine, y0_euler, n_states, n_act)
                ctrl_cmd%effectors(j)%value = saved_val - delta
                dy_bwd = eval_deriv_euler(engine, y0_euler, n_states, n_act)
                ctrl_cmd%effectors(j)%value = saved_val
            end if
            B(:, j) = (dy_fwd - dy_bwd) / (2.0 * delta)
        end do

    end subroutine compute_B_euler

    ! build state labels for Euler form
    subroutine build_state_labels(use_euler, ctrl, passive, act_map, labels)
        logical, intent(in) :: use_euler
        type(control_inputs_t), intent(in) :: ctrl
        type(passive_inputs_t), intent(in) :: passive
        type(actuator_map_t), intent(in) :: act_map
        character(len=64), intent(out) :: labels(:)

        integer :: base, k, eff_idx

        if (use_euler) then
            labels(1)  = 'u[ft/s]'
            labels(2)  = 'v[ft/s]'
            labels(3)  = 'w[ft/s]'
            labels(4)  = 'p[rad/s]'
            labels(5)  = 'q[rad/s]'
            labels(6)  = 'r[rad/s]'
            labels(7)  = 'x[ft]'
            labels(8)  = 'y[ft]'
            labels(9)  = 'z[ft]'
            labels(10) = 'phi[rad]'
            labels(11) = 'theta[rad]'
            labels(12) = 'psi[rad]'
            base = EULER_DIM
        else
            labels(1)  = 'u[ft/s]'
            labels(2)  = 'v[ft/s]'
            labels(3)  = 'w[ft/s]'
            labels(4)  = 'p[rad/s]'
            labels(5)  = 'q[rad/s]'
            labels(6)  = 'r[rad/s]'
            labels(7)  = 'x[ft]'
            labels(8)  = 'y[ft]'
            labels(9)  = 'z[ft]'
            labels(10) = 'e0'
            labels(11) = 'ex'
            labels(12) = 'ey'
            labels(13) = 'ez'
            base = RIGID_DIM
        end if

        ! actuator state labels (order 1: position; order 2: position + rate)
        do k = 1, act_map%n_actuators
            eff_idx = act_map%effector_idx(k)
            associate(eff => ctrl%effectors(eff_idx))
                labels(eff%state_index - RIGID_DIM + base) = &
                    trim(eff%name)//'_pos'
                if (eff%dynamics_order == 2) then
                    labels(eff%rate_state_index - RIGID_DIM + base) = &
                        trim(eff%name)//'_rate'
                end if
            end associate
        end do

        ! passive effector state labels
        do k = 1, passive%n
            associate(pe => passive%effectors(k))
                labels(pe%state_index - RIGID_DIM + base) = &
                    trim(pe%name)//'_pos'
                labels(pe%rate_state_index - RIGID_DIM + base) = &
                    trim(pe%name)//'_rate'
            end associate
        end do

    end subroutine build_state_labels

    ! build input labels from control effector names
    subroutine build_input_labels(ctrl, labels)
        type(control_inputs_t), intent(in) :: ctrl
        character(len=64), intent(out) :: labels(:)
        integer :: j
        do j = 1, ctrl%n
            labels(j) = trim(ctrl%effectors(j)%name)
        end do
    end subroutine build_input_labels

    ! print trim point state and controls to terminal
    subroutine print_trim_point(state_trim, ctrl)
        type(vehicle_state_t), intent(in) :: state_trim
        type(control_inputs_t), intent(in) :: ctrl
        real :: eul(3)
        integer :: j

        eul = quat_to_euler(state_trim%quaternion)

        write(*,*)
        write(*,'(A)') '  Trim point (linearization point):'
        write(*,'(A,3F12.4,A)') '    Velocity [ft/s]:  ', state_trim%velocity, ''
        write(*,'(A,3F12.6,A)') '    Body rates [r/s]: ', state_trim%omega, ''
        write(*,'(A,3F12.4,A)') '    Position [ft]:    ', state_trim%position, ''
        write(*,'(A,3F10.6,A)') '    Euler [rad]:      ', eul, ''
        write(*,'(A,3F10.6,A)') '    Euler [deg]:      ', eul*180.0/PI, ''
        write(*,'(A)') '    Controls:'
        do j = 1, ctrl%n
            if (ctrl%effectors(j)%is_angle) then
                write(*,'(A,A,A,F10.6,A,F8.3,A)') '      ', &
                    trim(ctrl%effectors(j)%name), ' = ', &
                    ctrl%effectors(j)%value, ' rad  (', &
                    ctrl%effectors(j)%value * 180.0 / PI, ' deg)'
            else
                write(*,'(A,A,A,F12.6)') '      ', &
                    trim(ctrl%effectors(j)%name), ' = ', &
                    ctrl%effectors(j)%value
            end if
        end do
        write(*,*)

    end subroutine print_trim_point

    ! print a matrix to terminal with row/column labels
    subroutine print_matrix(label, mat, nrows, ncols, row_labels, col_labels)
        character(len=*), intent(in) :: label
        integer, intent(in) :: nrows, ncols
        real, intent(in) :: mat(nrows, ncols)
        character(len=64), intent(in) :: row_labels(nrows), col_labels(ncols)

        integer :: i, j

        write(*,'(A,A,A,I0,A,I0,A)') '  ', trim(label), ' (', nrows, ' x ', ncols, '):'

        ! column header
        write(*,'(A,16A)', advance='no') '    ', '               '
        do j = 1, ncols
            write(*,'(A14)', advance='no') trim(col_labels(j))
        end do
        write(*,*)

        ! rows
        do i = 1, nrows
            write(*,'(A,A14)', advance='no') '    ', trim(row_labels(i))
            do j = 1, ncols
                write(*,'(ES14.5)', advance='no') mat(i,j)
            end do
            write(*,*)
        end do
        write(*,*)

    end subroutine print_matrix

    ! write matrix to CSV file with row/column labels
    subroutine write_matrix_csv(filename, mat, nrows, ncols, row_labels, col_labels)
        character(len=*), intent(in) :: filename
        integer, intent(in) :: nrows, ncols
        real, intent(in) :: mat(nrows, ncols)
        character(len=64), intent(in) :: row_labels(nrows), col_labels(ncols)

        integer :: unit, i, j
        integer :: io_stat

        open(newunit=unit, file=filename, status='replace', action='write', iostat=io_stat)
        if (io_stat /= 0) then
            write(*,'(A,A)') '  ERROR: Cannot open file for writing: ', trim(filename)
            return
        end if

        ! header row: blank first cell, then column labels
        write(unit, '(A)', advance='no') ''
        do j = 1, ncols
            write(unit, '(A,A)', advance='no') ',', trim(col_labels(j))
        end do
        write(unit,*)

        ! data rows
        do i = 1, nrows
            write(unit, '(A)', advance='no') trim(row_labels(i))
            do j = 1, ncols
                write(unit, '(A,ES16.8)', advance='no') ',', mat(i,j)
            end do
            write(unit,*)
        end do

        close(unit)

    end subroutine write_matrix_csv

end module analysis_m