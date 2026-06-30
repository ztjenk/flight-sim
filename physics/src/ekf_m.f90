! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! 15-state error-state Extended Kalman Filter for navigation
! Based on PX4 EKF2 architecture (simplified)
! States: quaternion(4), velocity_NED(3), position_NED(3), gyro_bias(3), accel_bias(3)
! Error state: attitude_error(3), vel_error(3), pos_error(3), gbias_error(3), abias_error(3)
! Covariance P is 15x15 (quaternion attitude uses 3-DOF rotation vector error)
!
! LIMITATION: No wind states. GPS and position fusion work correctly in wind because
! both GPS and the EKF track ground velocity. However, airspeed fusion (ekf_fuse_airspeed)
! assumes TAS = |ground_velocity|, which is only true in zero wind. In wind, the ADS
! measures true airspeed (air-relative) while the EKF predicts groundspeed, creating a
! persistent innovation bias equal to the wind magnitude. This will corrupt the velocity
! estimate if airspeed fusion is weighted heavily relative to GPS.
!
! FIX: Add 2-3 wind states (wind_N, wind_E, optionally wind_D) so the EKF can estimate
! wind and compute TAS = |ground_velocity - wind|. This expands the state to 17-18 with
! corresponding F matrix, Q process noise, and observability changes.
! Refer to PX4 EKF2 wind estimation code for reference implementation.
!
! The same air-relative caveat applies to alpha/beta vane fusion (ekf_fuse_aero_angles):
! the vanes measure air-relative incidence/sideslip, while the EKF reconstructs them from
! the body-frame ground velocity (R^T * v_NED). In zero wind these are identical; in wind
! they differ and the wind states above would be the proper fix. With zero/low wind the
! aero-angle update is a strong observability aid for attitude and the velocity direction.
module ekf_m
    use constants_m
    use math_m
    implicit none
    private

    integer, parameter, public :: EKF_N = 15  ! error-state dimension

    ! error-state index ranges
    integer, parameter :: ATT = 1    ! attitude error start
    integer, parameter :: VEL = 4    ! velocity error start
    integer, parameter :: POS = 7    ! position error start
    integer, parameter :: GB  = 10   ! gyro bias error start
    integer, parameter :: AB  = 13   ! accel bias error start

    public :: ekf_t, ekf_params_t
    public :: ekf_init, ekf_predict
    public :: ekf_fuse_gps, ekf_fuse_mag_heading, ekf_fuse_airspeed, ekf_fuse_gravity
    public :: ekf_fuse_aero_angles
    public :: ekf_get_body_state

    type :: ekf_params_t
        ! IMU noise (standard deviations)
        real :: gyro_noise = 0.005        ! gyro white noise [rad/s]
        real :: accel_noise = 0.05        ! accel white noise [ft/s^2]
        real :: gyro_bias_walk = 0.0001   ! gyro bias random walk [rad/s/sqrt(s)]
        real :: accel_bias_walk = 0.001   ! accel bias random walk [ft/s^2/sqrt(s)]
        real :: omega_dot_tau = 0.015     ! smoothing time constant [s] for the rate/accel tracker
                                          ! (dt-robust knob: larger = smoother/more lag, smaller = noisier/less lag;
                                          !  ~0.01-0.02 s is a good start. NOTE: this is in seconds, independent of sim rate)
        ! measurement noise (standard deviations)
        real :: gps_pos_noise = 5.0       ! GPS position noise [ft]
        real :: gps_vel_noise = 0.3       ! GPS velocity noise [ft/s]
        real :: mag_heading_noise = 0.1   ! magnetometer heading noise [rad]
        real :: airspeed_noise = 3.0      ! ADS true airspeed noise [ft/s]
        real :: aero_alpha_noise = 0.01   ! alpha vane noise [rad]
        real :: aero_beta_noise = 0.01    ! beta vane noise [rad]
        real :: gravity_noise = 0.1       ! gravity reference noise [normalized]
        ! magnetic declination (true heading = magnetic heading - declination)
        real :: mag_declination = 0.0  ! [rad] (positive = mag north east of true north)
        ! innovation gate thresholds [sigma]
        real :: gps_gate = 5.0
        real :: mag_gate = 3.0
        real :: airspeed_gate = 5.0
        real :: aero_angle_gate = 5.0
        real :: gravity_gate = 3.0
        ! gravity reference threshold: fuse when |a| within 1 +/- this fraction
        real :: gravity_accel_range = 0.15
    end type ekf_params_t

    type :: ekf_t
        ! nominal state
        real :: quaternion(4) = [1.0, 0.0, 0.0, 0.0]  ! body-to-Earth
        real :: velocity(3) = 0.0     ! Earth-frame (NED) velocity [ft/s]
        real :: position(3) = 0.0     ! Earth-frame (NED) position [ft]
        real :: gyro_bias(3) = 0.0    ! gyroscope bias [rad/s]
        real :: accel_bias(3) = 0.0   ! accelerometer bias [ft/s^2]
        ! angular rate + acceleration tracker (per-axis fading-memory g-h filter)
        real :: omega_filt(3) = 0.0      ! smoothed body angular rate [rad/s]
        real :: omega_dot_filt(3) = 0.0  ! estimated body angular acceleration [rad/s^2]
        ! covariance
        real :: P(EKF_N, EKF_N) = 0.0
        ! params
        type(ekf_params_t) :: params
        logical :: initialized = .false.
    end type ekf_t

contains

    ! --- initialization ---

    subroutine ekf_init(ekf, quaternion, velocity_body, position, g, mag_field)
        type(ekf_t), intent(inout) :: ekf
        real, intent(in) :: quaternion(4)   ! initial attitude
        real, intent(in) :: velocity_body(3) ! initial body-frame velocity [ft/s]
        real, intent(in) :: position(3)     ! initial Earth-frame position [ft]
        real, intent(in) :: g               ! gravity magnitude [ft/s^2]
        real, intent(in), optional :: mag_field(3) ! Earth-frame magnetic field [nT] for declination
        integer :: i

        ekf%quaternion = quaternion

        ! compute magnetic declination from field vector if provided
        if (present(mag_field)) then
            ekf%params%mag_declination = atan2(mag_field(2), mag_field(1))
        end if
        call quat_normalize(ekf%quaternion)

        ! convert body velocity to Earth frame for EKF state
        ekf%velocity = quat_rotate_body_to_inertial(velocity_body, quaternion)
        ekf%position = position
        ekf%gyro_bias = 0.0
        ekf%accel_bias = 0.0

        ! initial covariance — small since we start from trim
        ekf%P = 0.0
        do i = ATT, ATT+2
            ekf%P(i,i) = (1.0 * DEG2RAD)**2     ! 1 deg attitude uncertainty
        end do
        do i = VEL, VEL+2
            ekf%P(i,i) = 1.0**2                  ! 1 ft/s velocity uncertainty
        end do
        do i = POS, POS+2
            ekf%P(i,i) = 5.0**2                  ! 5 ft position uncertainty
        end do
        do i = GB, GB+2
            ekf%P(i,i) = (0.01 * DEG2RAD)**2     ! 0.01 deg/s gyro bias uncertainty
        end do
        do i = AB, AB+2
            ekf%P(i,i) = 0.1**2                  ! 0.1 ft/s^2 accel bias uncertainty
        end do

        ! angular rate/accel tracker: start at rest
        ekf%omega_filt = 0.0
        ekf%omega_dot_filt = 0.0

        ekf%initialized = .true.
    end subroutine ekf_init

    ! --- prediction step (IMU mechanization) ---

    subroutine ekf_predict(ekf, gyro, accel, dt, g)
        type(ekf_t), intent(inout) :: ekf
        real, intent(in) :: gyro(3)     ! measured angular velocity [rad/s] (body frame)
        real, intent(in) :: accel(3)    ! measured specific force [ft/s^2] (body frame)
        real, intent(in) :: dt          ! time step [s]
        real, intent(in) :: g           ! gravity magnitude [ft/s^2]

        real :: omega(3), acc(3)
        real :: delta_angle(3), dq(4), half(3)
        real :: R(3,3), accel_earth(3)
        real :: F(EKF_N, EKF_N), Q(EKF_N, EKF_N)
        real :: FP(EKF_N, EKF_N)
        real :: skew_omega(3,3), skew_ra(3,3), ra(3)
        integer :: i, j

        if (.not. ekf%initialized) return

        ! 1. bias-correct IMU
        omega = gyro - ekf%gyro_bias
        acc = accel - ekf%accel_bias

        ! 1b. track angular rate + acceleration from the bias-corrected gyro
        call ekf_track_rates(ekf, omega, dt)

        ! 2. attitude prediction: q_new = q * delta_q(omega * dt)
        delta_angle = omega * dt
        half = 0.5 * delta_angle
        dq(1) = 1.0     ! small angle: cos(|da|/2) ~ 1
        dq(2) = half(1)  ! sin(|da|/2) * axis ~ da/2
        dq(3) = half(2)
        dq(4) = half(3)
        ekf%quaternion = quat_multiply(ekf%quaternion, dq)
        call quat_normalize(ekf%quaternion)

        ! 3. velocity prediction: rotate accel to Earth, add gravity
        R = quat_to_dcm(ekf%quaternion)
        accel_earth = matmul(R, acc)
        accel_earth(3) = accel_earth(3) + g   ! NED: gravity is +z (down)
        ekf%velocity = ekf%velocity + accel_earth * dt

        ! 4. position prediction
        ekf%position = ekf%position + ekf%velocity * dt

        ! 5. covariance prediction: P = F*P*F^T + Q
        ! build F = I + Fc*dt
        F = 0.0
        do i = 1, EKF_N
            F(i,i) = 1.0
        end do

        ! attitude error ← -(omega×)*att_error - gbias_error
        skew_omega = skew3(omega)
        F(ATT:ATT+2, ATT:ATT+2) = F(ATT:ATT+2, ATT:ATT+2) - skew_omega * dt
        do i = 0, 2
            F(ATT+i, GB+i) = F(ATT+i, GB+i) - dt   ! -I * dt
        end do

        ! velocity error ← -(R*a×)*att_error - R*abias_error
        ra = matmul(R, acc)
        skew_ra = skew3(ra)
        F(VEL:VEL+2, ATT:ATT+2) = F(VEL:VEL+2, ATT:ATT+2) - skew_ra * dt
        F(VEL:VEL+2, AB:AB+2) = F(VEL:VEL+2, AB:AB+2) - R * dt

        ! position error ← velocity error
        do i = 0, 2
            F(POS+i, VEL+i) = F(POS+i, VEL+i) + dt  ! I * dt
        end do

        ! process noise Q (diagonal)
        Q = 0.0
        do i = ATT, ATT+2
            Q(i,i) = (ekf%params%gyro_noise * dt)**2
        end do
        do i = VEL, VEL+2
            Q(i,i) = (ekf%params%accel_noise * dt)**2
        end do
        ! position gets no direct process noise (driven by velocity)
        do i = GB, GB+2
            Q(i,i) = ekf%params%gyro_bias_walk**2 * dt
        end do
        do i = AB, AB+2
            Q(i,i) = ekf%params%accel_bias_walk**2 * dt
        end do

        ! P = F*P*F^T + Q
        FP = matmul(F, ekf%P)
        ekf%P = matmul(FP, transpose(F)) + Q

        ! enforce symmetry
        do i = 1, EKF_N
            do j = i+1, EKF_N
                ekf%P(i,j) = 0.5 * (ekf%P(i,j) + ekf%P(j,i))
                ekf%P(j,i) = ekf%P(i,j)
            end do
        end do
    end subroutine ekf_predict

    ! --- angular rate + acceleration tracker (per-axis fading-memory g-h filter) ---
    ! Smooths the bias-corrected gyro into [omega; omega_dot] so the controller gets a clean,
    ! time-synchronized angular acceleration for INDI instead of differentiating noisy gyro.
    ! Critically-damped g-h filter keyed on a time constant (omega_dot_tau, seconds) so the
    ! smoothing/lag is the SAME regardless of sim rate:
    !   theta = exp(-dt/tau),  alpha = 1 - theta^2,  beta = (1 - theta)^2
    subroutine ekf_track_rates(ekf, omega_meas, dt)
        type(ekf_t), intent(inout) :: ekf
        real, intent(in) :: omega_meas(3)   ! bias-corrected body rates [rad/s]
        real, intent(in) :: dt

        real :: theta, alpha, beta, wp, innov
        integer :: ax

        theta = exp(-dt / max(ekf%params%omega_dot_tau, 1.0e-9))
        alpha = 1.0 - theta*theta
        beta  = (1.0 - theta)**2

        do ax = 1, 3
            wp = ekf%omega_filt(ax) + ekf%omega_dot_filt(ax) * dt   ! predict rate
            innov = omega_meas(ax) - wp
            ekf%omega_filt(ax)     = wp + alpha * innov
            ekf%omega_dot_filt(ax) = ekf%omega_dot_filt(ax) + (beta / dt) * innov
        end do
    end subroutine ekf_track_rates

    ! --- GPS fusion: position + velocity (6 sequential scalar updates) ---

    subroutine ekf_fuse_gps(ekf, gps_pos, gps_vel)
        type(ekf_t), intent(inout) :: ekf
        real, intent(in) :: gps_pos(3)   ! Earth-frame position [ft]
        real, intent(in) :: gps_vel(3)   ! Earth-frame velocity [ft/s]

        real :: H(EKF_N), innov, R_noise
        integer :: i

        if (.not. ekf%initialized) return

        ! fuse velocity (3 axes)
        do i = 1, 3
            H = 0.0
            H(VEL + i - 1) = 1.0
            innov = gps_vel(i) - ekf%velocity(i)
            R_noise = ekf%params%gps_vel_noise**2
            call fuse_scalar(ekf, H, innov, R_noise, ekf%params%gps_gate)
        end do

        ! fuse position (3 axes)
        do i = 1, 3
            H = 0.0
            H(POS + i - 1) = 1.0
            innov = gps_pos(i) - ekf%position(i)
            R_noise = ekf%params%gps_pos_noise**2
            call fuse_scalar(ekf, H, innov, R_noise, ekf%params%gps_gate)
        end do
    end subroutine ekf_fuse_gps

    ! --- magnetometer heading fusion (1 scalar update) ---

    subroutine ekf_fuse_mag_heading(ekf, mag_body)
        type(ekf_t), intent(inout) :: ekf
        real, intent(in) :: mag_body(3)  ! magnetic field in body frame [nT]

        real :: H(EKF_N), innov, R_noise
        real :: euler(3), psi_meas, psi_est
        real :: mag_earth(3)
        real :: q_pert(4), dq(4), euler_pert(3)
        real :: eps
        integer :: i

        if (.not. ekf%initialized) return

        ! compute measured heading from magnetometer
        ! tilt-compensate using estimated roll/pitch, then extract heading
        euler = quat_to_euler(ekf%quaternion)
        ! tilt compensation: rotate mag from body to horizontal plane using roll/pitch only
        ! this gives the magnetic field projected onto the local horizontal plane
        mag_earth(1) = mag_body(1)*cos(euler(2)) + mag_body(2)*sin(euler(1))*sin(euler(2)) &
                      + mag_body(3)*cos(euler(1))*sin(euler(2))
        mag_earth(2) = mag_body(2)*cos(euler(1)) - mag_body(3)*sin(euler(1))
        ! true heading = magnetic heading - declination
        psi_meas = atan2(mag_earth(2), mag_earth(1)) - ekf%params%mag_declination

        ! expected heading from current quaternion
        euler = quat_to_euler(ekf%quaternion)
        psi_est = euler(3)

        ! innovation (wrapped to [-pi, pi])
        innov = wrap_angle(psi_meas - psi_est)

        ! compute H numerically: d(psi)/d(delta_theta)
        H = 0.0
        eps = 1.0e-6
        do i = 1, 3
            ! perturb attitude by small rotation around body axis i
            dq = [1.0, 0.0, 0.0, 0.0]
            dq(1+i) = 0.5 * eps
            q_pert = quat_multiply(ekf%quaternion, dq)
            call quat_normalize(q_pert)
            euler_pert = quat_to_euler(q_pert)
            H(ATT + i - 1) = wrap_angle(euler_pert(3) - psi_est) / eps
        end do

        R_noise = ekf%params%mag_heading_noise**2
        call fuse_scalar(ekf, H, innov, R_noise, ekf%params%mag_gate)
    end subroutine ekf_fuse_mag_heading

    ! --- airspeed fusion (1 scalar update) ---

    subroutine ekf_fuse_airspeed(ekf, TAS_measured)
        type(ekf_t), intent(inout) :: ekf
        real, intent(in) :: TAS_measured  ! true airspeed [ft/s]

        real :: H(EKF_N), innov, R_noise
        real :: TAS_est, vel_mag

        if (.not. ekf%initialized) return

        ! expected TAS = |velocity| (no wind states, so TAS = groundspeed)
        vel_mag = norm3(ekf%velocity)
        if (vel_mag < 1.0) return  ! avoid singularity at zero speed
        TAS_est = vel_mag

        innov = TAS_measured - TAS_est

        ! H: d(|vel|)/d(error_state) — only velocity block is nonzero
        H = 0.0
        H(VEL:VEL+2) = ekf%velocity / vel_mag

        R_noise = ekf%params%airspeed_noise**2
        call fuse_scalar(ekf, H, innov, R_noise, ekf%params%airspeed_gate)
    end subroutine ekf_fuse_airspeed

    ! --- aerodynamic angle (alpha/beta vane) fusion (2 scalar updates) ---
    ! Fuses angle of attack and sideslip from an aero_angles sensor (alpha/beta vanes or
    ! FADS). The measurement model reconstructs the angles from the body-frame velocity
    ! v_body = R(q)^T * v_NED:  alpha = atan2(w, u),  beta = asin(v / |v_body|).
    ! Both angles depend on attitude (through R^T) and on the NED velocity, so the Jacobian
    ! is populated over the attitude and velocity error blocks (computed numerically, like
    ! ekf_fuse_mag_heading). Air-relative vs. ground caveat: see the wind note at top of file.
    subroutine ekf_fuse_aero_angles(ekf, alpha_meas, beta_meas)
        type(ekf_t), intent(inout) :: ekf
        real, intent(in) :: alpha_meas   ! measured angle of attack [rad]
        real, intent(in) :: beta_meas    ! measured sideslip angle [rad]

        real :: H_alpha(EKF_N), H_beta(EKF_N)
        real :: alpha_est, beta_est, innov
        logical :: ok

        if (.not. ekf%initialized) return

        ! --- alpha (angle of attack) ---
        call aero_angle_predict(ekf, alpha_est, beta_est, H_alpha, H_beta, ok)
        if (.not. ok) return  ! velocity too low — angles ill-conditioned
        innov = wrap_angle(alpha_meas - alpha_est)
        call fuse_scalar(ekf, H_alpha, innov, ekf%params%aero_alpha_noise**2, &
                         ekf%params%aero_angle_gate)

        ! --- beta (sideslip) --- recompute after the alpha update changed the state
        call aero_angle_predict(ekf, alpha_est, beta_est, H_alpha, H_beta, ok)
        if (.not. ok) return
        innov = wrap_angle(beta_meas - beta_est)
        call fuse_scalar(ekf, H_beta, innov, ekf%params%aero_beta_noise**2, &
                         ekf%params%aero_angle_gate)
    end subroutine ekf_fuse_aero_angles

    ! internal: predict alpha/beta and their measurement Jacobian rows from current state.
    ! ok = .false. when body speed is too low for the angles to be well defined.
    subroutine aero_angle_predict(ekf, alpha_est, beta_est, H_alpha, H_beta, ok)
        type(ekf_t), intent(in) :: ekf
        real, intent(out) :: alpha_est, beta_est
        real, intent(out) :: H_alpha(EKF_N), H_beta(EKF_N)
        logical, intent(out) :: ok

        real :: v_ned(3), v_body(3)
        real :: a0, b0, a, b
        real :: q_pert(4), dq(4), v_pert(3)
        real :: eps
        integer :: i

        H_alpha = 0.0
        H_beta  = 0.0
        alpha_est = 0.0
        beta_est  = 0.0

        v_ned = ekf%velocity
        v_body = quat_rotate_inertial_to_body(v_ned, ekf%quaternion)
        ok = (norm3(v_body) >= 1.0)   ! avoid singularity at near-zero speed
        if (.not. ok) return

        a0 = calc_alpha(v_body)
        b0 = calc_beta(v_body)
        alpha_est = a0
        beta_est  = b0

        eps = 1.0e-6

        ! attitude-error columns: perturb the body-frame rotation (q = q * dq),
        ! holding the NED velocity fixed
        do i = 1, 3
            dq = [1.0, 0.0, 0.0, 0.0]
            dq(1+i) = 0.5 * eps
            q_pert = quat_multiply(ekf%quaternion, dq)
            call quat_normalize(q_pert)
            v_body = quat_rotate_inertial_to_body(v_ned, q_pert)
            a = calc_alpha(v_body)
            b = calc_beta(v_body)
            H_alpha(ATT+i-1) = wrap_angle(a - a0) / eps
            H_beta(ATT+i-1)  = wrap_angle(b - b0) / eps
        end do

        ! velocity-error columns: perturb the NED velocity, holding attitude fixed
        do i = 1, 3
            v_pert = v_ned
            v_pert(i) = v_pert(i) + eps
            v_body = quat_rotate_inertial_to_body(v_pert, ekf%quaternion)
            a = calc_alpha(v_body)
            b = calc_beta(v_body)
            H_alpha(VEL+i-1) = wrap_angle(a - a0) / eps
            H_beta(VEL+i-1)  = wrap_angle(b - b0) / eps
        end do
    end subroutine aero_angle_predict

    ! --- gravity reference fusion (2 scalar updates for roll/pitch) ---

    subroutine ekf_fuse_gravity(ekf, accel_body, g)
        type(ekf_t), intent(inout) :: ekf
        real, intent(in) :: accel_body(3)  ! measured specific force [ft/s^2]
        real, intent(in) :: g              ! gravity magnitude [ft/s^2]

        real :: H(EKF_N), innov, R_noise
        real :: a_mag, a_norm(3)
        real :: R_mat(3,3), g_body(3), skew_g(3,3)
        integer :: i

        if (.not. ekf%initialized) return

        ! only fuse when acceleration is near 1g (not maneuvering)
        a_mag = norm3(accel_body)
        if (abs(a_mag / g - 1.0) > ekf%params%gravity_accel_range) return

        ! normalized measured gravity direction in body frame
        a_norm = accel_body / a_mag

        ! expected gravity direction in body frame from current attitude
        ! accelerometer measures specific force ≈ -gravity in level flight
        ! so expected normalized accel = R^T * [0, 0, -1] (opposing gravity in NED)
        R_mat = quat_to_dcm(ekf%quaternion)
        g_body(1) = -R_mat(3,1)
        g_body(2) = -R_mat(3,2)
        g_body(3) = -R_mat(3,3)

        ! H: d(g_body)/d(delta_theta) = skew(g_body)
        skew_g = skew3(g_body)

        R_noise = ekf%params%gravity_noise**2

        ! fuse x and y components (z is redundant with unit constraint)
        do i = 1, 2
            H = 0.0
            H(ATT:ATT+2) = skew_g(i, :)
            innov = a_norm(i) - g_body(i)
            call fuse_scalar(ekf, H, innov, R_noise, ekf%params%gravity_gate)
        end do
    end subroutine ekf_fuse_gravity

    ! --- extract estimated body-frame state for controller ---

    subroutine ekf_get_body_state(ekf, velocity_body, omega_body, position, quaternion, gyro_meas, omega_dot_body)
        type(ekf_t), intent(in) :: ekf
        real, intent(out) :: velocity_body(3)  ! estimated u, v, w [ft/s]
        real, intent(out) :: omega_body(3)     ! bias-corrected p, q, r [rad/s]
        real, intent(out) :: position(3)       ! estimated Earth-frame position [ft]
        real, intent(out) :: quaternion(4)     ! estimated attitude quaternion
        real, intent(in)  :: gyro_meas(3)      ! latest gyro measurement [rad/s]
        real, intent(out) :: omega_dot_body(3) ! estimated angular acceleration [rad/s^2] (for INDI)

        ! attitude
        quaternion = ekf%quaternion

        ! body velocity = R^T * earth_velocity
        velocity_body = quat_rotate_inertial_to_body(ekf%velocity, ekf%quaternion)

        ! position (Earth frame)
        position = ekf%position

        ! bias-corrected angular rates (raw, so the rate loops behave as before)
        omega_body = gyro_meas - ekf%gyro_bias

        ! smoothed angular acceleration from the tracker (no controller-side differencing)
        omega_dot_body = ekf%omega_dot_filt
    end subroutine ekf_get_body_state

    ! --- internal: sequential scalar Kalman update with Joseph form ---

    subroutine fuse_scalar(ekf, H, innov, R_noise, gate)
        type(ekf_t), intent(inout) :: ekf
        real, intent(in) :: H(EKF_N)    ! 1xN measurement Jacobian row
        real, intent(in) :: innov       ! scalar innovation (z - h)
        real, intent(in) :: R_noise     ! scalar measurement noise variance
        real, intent(in) :: gate        ! innovation gate threshold [sigma]

        real :: PH(EKF_N)    ! P * H^T (Nx1)
        real :: S             ! innovation variance (scalar)
        real :: K(EKF_N)     ! Kalman gain (Nx1)
        real :: dx(EKF_N)    ! error-state correction
        real :: IKH(EKF_N, EKF_N)  ! I - K*H
        real :: dq(4)
        integer :: i, j

        ! PH = P * H^T
        do i = 1, EKF_N
            PH(i) = 0.0
            do j = 1, EKF_N
                PH(i) = PH(i) + ekf%P(i,j) * H(j)
            end do
        end do

        ! innovation variance: S = H * P * H^T + R
        S = R_noise
        do i = 1, EKF_N
            S = S + H(i) * PH(i)
        end do

        ! innovation gating (chi-squared test)
        if (innov * innov / S > gate * gate) return

        ! Kalman gain: K = PH / S
        K = PH / S

        ! error-state correction
        dx = K * innov

        ! apply correction to nominal state
        ! attitude: q = q * delta_q(dx(1:3))
        dq(1) = 1.0
        dq(2) = 0.5 * dx(ATT)
        dq(3) = 0.5 * dx(ATT+1)
        dq(4) = 0.5 * dx(ATT+2)
        ekf%quaternion = quat_multiply(ekf%quaternion, dq)
        call quat_normalize(ekf%quaternion)

        ! velocity, position, biases: direct addition
        ekf%velocity  = ekf%velocity  + dx(VEL:VEL+2)
        ekf%position  = ekf%position  + dx(POS:POS+2)
        ekf%gyro_bias = ekf%gyro_bias + dx(GB:GB+2)
        ekf%accel_bias = ekf%accel_bias + dx(AB:AB+2)

        ! Joseph-form covariance update: P = (I-KH)*P*(I-KH)^T + K*R*K^T
        ! IKH = I - K*H^T  (outer product)
        do i = 1, EKF_N
            do j = 1, EKF_N
                if (i == j) then
                    IKH(i,j) = 1.0 - K(i) * H(j)
                else
                    IKH(i,j) = -K(i) * H(j)
                end if
            end do
        end do

        ekf%P = matmul(IKH, matmul(ekf%P, transpose(IKH)))
        ! add K*R*K^T
        do i = 1, EKF_N
            do j = 1, EKF_N
                ekf%P(i,j) = ekf%P(i,j) + K(i) * R_noise * K(j)
            end do
        end do

        ! enforce symmetry
        do i = 1, EKF_N
            do j = i+1, EKF_N
                ekf%P(i,j) = 0.5 * (ekf%P(i,j) + ekf%P(j,i))
                ekf%P(j,i) = ekf%P(i,j)
            end do
        end do
    end subroutine fuse_scalar

    ! quat_to_dcm now provided by math_m

    ! --- utility: 3x3 skew-symmetric matrix ---

    pure function skew3(v) result(S)
        real, intent(in) :: v(3)
        real :: S(3,3)
        S(1,1) =  0.0;   S(1,2) = -v(3);  S(1,3) =  v(2)
        S(2,1) =  v(3);  S(2,2) =  0.0;   S(2,3) = -v(1)
        S(3,1) = -v(2);  S(3,2) =  v(1);  S(3,3) =  0.0
    end function skew3

end module ekf_m
