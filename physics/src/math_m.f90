! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

module math_m
    use constants_m
    implicit none
    private ! default visibility is private
    public :: cross3, dot3, norm3                                    ! vector operations
    public :: quat_multiply, quat_normalize, quat_conjugate          ! quaternion algebra
    public :: quat_rotate_body_to_inertial, quat_rotate_inertial_to_body  ! frame rotations
    public :: euler_to_quat, quat_to_euler, quat_to_dcm              ! angle conversions
    public :: quat_from_two_vectors                                  ! compute rotation between vectors
    public :: clamp, wrap_angle                                      ! utility functions
    public :: calc_alpha, calc_beta, calc_beta_flank                 ! aero angles from velocity
    public :: calc_nondim_rates, calc_dynamic_pressure               ! aero helpers
    public :: get_wall_time                                          ! timing utility
    
contains
    ! computes the cross product of two 3D vectors
    pure function cross3(a, b) result(c)
        real, intent(in) :: a(3), b(3)  ! input vectors
        real :: c(3)                    ! resulting perpendicular vector
        c(1) = a(2)*b(3) - a(3)*b(2)    ! x-component: ay*bz - az*by
        c(2) = a(3)*b(1) - a(1)*b(3)    ! y-component: az*bx - ax*bz
        c(3) = a(1)*b(2) - a(2)*b(1)    ! z-component: ax*by - ay*bx
    end function cross3
    
    ! computes the dot product of two 3D vectors
    pure function dot3(a, b) result(d)
        real, intent(in) :: a(3), b(3)  ! input vectors
        real :: d                        ! scalar result
        d = a(1)*b(1) + a(2)*b(2) + a(3)*b(3)  ! sum of component products
    end function dot3
    
    ! computes the magnitude of a 3D vector
    pure function norm3(a) result(n)
        real, intent(in) :: a(3)  ! input vector
        real :: n                  ! scalar magnitude
        n = sqrt(a(1)*a(1) + a(2)*a(2) + a(3)*a(3))  ! Euclidean distance from origin
    end function norm3
    
    ! quat_multiply: computes the product of two quaternions (eq 1.4.4)
    pure function quat_multiply(q1, q2) result(q)
        real, intent(in) :: q1(4), q2(4)  ! input quaternions [scalar, vector]
        real :: q(4)                       ! product quaternion
        ! e0
        q(1) = q1(1)*q2(1) - q1(2)*q2(2) - q1(3)*q2(3) - q1(4)*q2(4)
        ! vector components
        q(2) = q1(1)*q2(2) + q1(2)*q2(1) + q1(3)*q2(4) - q1(4)*q2(3)
        q(3) = q1(1)*q2(3) - q1(2)*q2(4) + q1(3)*q2(1) + q1(4)*q2(2)
        q(4) = q1(1)*q2(4) + q1(2)*q2(3) - q1(3)*q2(2) + q1(4)*q2(1)
    end function quat_multiply
    
    ! quat_normalize: normalizes quaternion (eq 1.4.6))
    pure subroutine quat_normalize(q)
        real, intent(inout) :: q(4)  ! quaternion to normalize
        real :: mag                   ! quaternion magnitude
        mag = sqrt(q(1)**2 + q(2)**2 + q(3)**2 + q(4)**2)  ! compute norm
        if (mag > TOLERANCE) q = q / mag  ! avoid division by zero; scale to unit length
    end subroutine quat_normalize
    
    ! quat_conjugate: returns the conjugate of a quaternion (eq 1.4.7)
    pure function quat_conjugate(q) result(qc)
        real, intent(in) :: q(4)   ! input quaternion
        real :: qc(4)               ! conjugate quaternion
        qc(1) = q(1)               ! scalar part unchanged
        qc(2:4) = -q(2:4)          ! vector part negated
    end function quat_conjugate
    
    ! quat_rotate_body_to_inertial: transforms a vector from body frame to inertial frame
    ! this is dependent to base. inverse of base to dependent
    pure function quat_rotate_body_to_inertial(v, e) result(v_out)
        real, intent(in) :: v(3)   ! vector in body-fixed frame
        real, intent(in) :: e(4)   ! attitude quaternion (body relative to inertial)
        real :: v_out(3)           ! vector in inertial frame
        real :: T(4)               ! intermediate quaternion product
        ! first half: T = v_quat * q_conjugate
        T(1) =  v(1)*e(2) + v(2)*e(3) + v(3)*e(4)
        T(2) =  v(1)*e(1) - v(2)*e(4) + v(3)*e(3)
        T(3) =  v(1)*e(4) + v(2)*e(1) - v(3)*e(2)
        T(4) = -v(1)*e(3) + v(2)*e(2) + v(3)*e(1)
        ! second half: extract vector part of q * T
        v_out(1) = e(1)*T(2) + e(2)*T(1) + e(3)*T(4) - e(4)*T(3)
        v_out(2) = e(1)*T(3) - e(2)*T(4) + e(3)*T(1) + e(4)*T(2)
        v_out(3) = e(1)*T(4) + e(2)*T(3) - e(3)*T(2) + e(4)*T(1)
    end function quat_rotate_body_to_inertial
    
    ! quat_rotate_inertial_to_body: transforms a vector from inertial frame to body frame
    ! this is base to dependent
    pure function quat_rotate_inertial_to_body(v, e) result(v_out)
        real, intent(in) :: v(3)   ! vector in inertial frame
        real, intent(in) :: e(4)   ! attitude quaternion (body relative to inertial)
        real :: v_out(3)           ! vector in body-fixed frame
        real :: T(4)               ! intermediate quaternion product
        ! first half with conjugate: T = v_quat * q - eq 1.5.6
        T(1) = -v(1)*e(2) - v(2)*e(3) - v(3)*e(4)
        T(2) =  v(1)*e(1) + v(2)*e(4) - v(3)*e(3)
        T(3) = -v(1)*e(4) + v(2)*e(1) + v(3)*e(2)
        T(4) =  v(1)*e(3) - v(2)*e(2) + v(3)*e(1)
        ! second half: extract vector part of q_conjugate * T - eq 1.5.7
        v_out(1) = e(1)*T(2) - e(2)*T(1) - e(3)*T(4) + e(4)*T(3)
        v_out(2) = e(1)*T(3) + e(2)*T(4) - e(3)*T(1) - e(4)*T(2)
        v_out(3) = e(1)*T(4) - e(2)*T(3) + e(3)*T(2) - e(4)*T(1)
    end function quat_rotate_inertial_to_body

    ! quat_to_dcm: converts quaternion to 3x3 direction cosine matrix (Eq 1.5.4)
    ! R rotates from body frame to inertial frame: v_inertial = R * v_body
    pure function quat_to_dcm(q) result(R)
        real, intent(in) :: q(4)   ! unit quaternion [e0, ex, ey, ez]
        real :: R(3,3)
        real :: e0, ex, ey, ez

        e0 = q(1); ex = q(2); ey = q(3); ez = q(4)

        R(1,1) = e0*e0 + ex*ex - ey*ey - ez*ez
        R(1,2) = 2.0*(ex*ey - e0*ez)
        R(1,3) = 2.0*(ex*ez + e0*ey)
        R(2,1) = 2.0*(ex*ey + e0*ez)
        R(2,2) = e0*e0 - ex*ex + ey*ey - ez*ez
        R(2,3) = 2.0*(ey*ez - e0*ex)
        R(3,1) = 2.0*(ex*ez - e0*ey)
        R(3,2) = 2.0*(ey*ez + e0*ex)
        R(3,3) = e0*e0 - ex*ex - ey*ey + ez*ez
    end function quat_to_dcm

    ! euler_to_quat: converts euler angles to quaternions
    pure function euler_to_quat(eul) result(q)
        real, intent(in) :: eul(3)  ! [phi, theta, psi] in radians
        real :: q(4)                 ! equivalent unit quaternion
        real :: cp, sp              ! cos and sin of phi
        real :: ct, st              ! cos and sin of theta
        real :: cpsi, spsi          ! cos and sin of psi
        
        cp = cos(0.5*eul(1)); sp = sin(0.5*eul(1))    
        ct = cos(0.5*eul(2)); st = sin(0.5*eul(2))    
        cpsi = cos(0.5*eul(3)); spsi = sin(0.5*eul(3))

        q(1) = cp*ct*cpsi + sp*st*spsi  ! e0    ! eq 1.6.2
        q(2) = sp*ct*cpsi - cp*st*spsi  ! ex
        q(3) = cp*st*cpsi + sp*ct*spsi  ! ey
        q(4) = cp*ct*spsi - sp*st*cpsi  ! ez
    end function euler_to_quat
    
    ! quat_to_euler: converts quaternion to euler angles using eq 1.6.3
    pure function quat_to_euler(q) result(eul)
        real, intent(in) :: q(4)    ! input unit quaternion
        real :: eul(3)              ! [phi, theta, psi] in radians
        real :: test                 ! singularity test value
        
        ! test for gimbal lock: when pitch = +/- 90 deg, test = +/- 0.5
        test = q(1)*q(3) - q(2)*q(4)
        
        if (abs(test - 0.5) <= TOLERANCE) then
            ! gimbal lock at +90 degrees pitch (nose straight up)
            eul(3) = 0.0                        ! psi arbitrarily set to 0
            eul(1) = 2.0*atan2(q(2), q(1))
            eul(2) = PI * 0.5
        else if (abs(test + 0.5) <= TOLERANCE) then
            ! gimbal lock at -90 degrees pitch (nose straight down)
            eul(3) = 0.0                        ! psi arbitrarily set to 0
            eul(1) = -2.0*atan2(q(2), q(1))
            eul(2) = -PI * 0.5  
        else
            ! normal case: no gimbal lock
            ! phi
            eul(1) = atan2(2.0*(q(1)*q(2) + q(3)*q(4)), &
                          q(1)**2 + q(4)**2 - q(2)**2 - q(3)**2)
            ! theta
            eul(2) = asin(max(-1.0, min(1.0, 2.0*test)))
            ! psi
            eul(3) = atan2(2.0*(q(1)*q(4) + q(2)*q(3)), &
                          q(1)**2 + q(2)**2 - q(3)**2 - q(4)**2)
        end if
    end function quat_to_euler

    ! quat_from_two_vectors: computes quaternion that rotates vector a to vector b
    ! uses half-vector method: q = [a·h, a×h] where h = normalize(a + b)
    pure function quat_from_two_vectors(a, b) result(q)
        real, intent(in) :: a(3), b(3)  ! input vectors (will be normalized internally)
        real :: q(4)                     ! rotation quaternion
        real :: a_unit(3), b_unit(3)     ! normalized input vectors
        real :: h(3)                     ! half-vector
        real :: a_dot_b                  ! dot product of unit vectors
        real :: h_mag                    ! magnitude of half-vector
        real :: a_mag, b_mag

        ! normalize input vectors
        a_mag = norm3(a)
        b_mag = norm3(b)
        if (a_mag < TOLERANCE .or. b_mag < TOLERANCE) then
            q = [1.0, 0.0, 0.0, 0.0]  ! identity if either vector is zero
            return
        end if
        a_unit = a / a_mag
        b_unit = b / b_mag

        a_dot_b = dot3(a_unit, b_unit)

        ! handle special case: vectors are opposite (180 degree rotation)
        if (a_dot_b < -1.0 + TOLERANCE) then
            ! find an orthogonal axis to rotate around
            ! try cross with [1,0,0], if parallel use [0,1,0]
            if (abs(a_unit(1)) < 0.9) then
                h = cross3(a_unit, [1.0, 0.0, 0.0])
            else
                h = cross3(a_unit, [0.0, 1.0, 0.0])
            end if
            h = h / norm3(h)
            ! 180 degree rotation: q = [0, axis]
            q = [0.0, h(1), h(2), h(3)]
            return
        end if

        ! normal case: compute half-vector
        h = a_unit + b_unit
        h_mag = norm3(h)
        h = h / h_mag

        ! q = [a·h, a×h] - this is automatically normalized
        q(1) = dot3(a_unit, h)
        q(2:4) = cross3(a_unit, h)
    end function quat_from_two_vectors

    ! clamp: constrains a value to within specified bounds
    pure function clamp(x, xmin, xmax) result(y)
        real, intent(in) :: x         ! value to constrain
        real, intent(in) :: xmin      ! lower bound
        real, intent(in) :: xmax      ! upper bound
        real :: y                     ! clamped result
        y = min(max(x, xmin), xmax) 
    end function clamp
    
    ! wrap_angle: wraps angle to the range [-pi, +pi]
    pure function wrap_angle(x) result(y)
        real, intent(in) :: x  ! input angle [rad], possibly outside [-pi, pi]
        real :: y               ! output angle [rad], guaranteed in [-pi, pi]
        ! formula: y = x - 2*pi * floor((x + pi) / (2*pi))
        ! shifts to [0, 2*pi), takes floor, then subtracts appropriate multiple
        y = x - floor((x + PI) / (2.0*PI)) * 2.0*PI
    end function wrap_angle

    ! angle of attack from body velocity (eq 3.4.4)
    pure function calc_alpha(velocity) result(alpha)
        real, intent(in) :: velocity(3)
        real :: alpha
        alpha = atan2(velocity(3), velocity(1))
    end function calc_alpha

    ! sideslip angle from body velocity (eq 3.4.5)
    pure function calc_beta(velocity) result(beta)
        real, intent(in) :: velocity(3)
        real :: beta, V_mag
        V_mag = norm3(velocity)
        if (V_mag > TOLERANCE) then
            beta = asin(velocity(2) / V_mag)
        else
            beta = 0.0
        end if
    end function calc_beta

    ! flank sideslip angle from body velocity
    pure function calc_beta_flank(velocity) result(beta_flank)
        real, intent(in) :: velocity(3)
        real :: beta_flank
        if (velocity(1) > TOLERANCE) then
            beta_flank = atan2(velocity(2), velocity(1))
        else
            beta_flank = 0.0
        end if
    end function calc_beta_flank

    ! nondimensional angular rates (eq 3.4.23)
    pure subroutine calc_nondim_rates(omega, V_mag, b_ref, c_bar, p_bar, q_bar, r_bar)
        real, intent(in)  :: omega(3), V_mag, b_ref, c_bar
        real, intent(out) :: p_bar, q_bar, r_bar
        if (V_mag > TOLERANCE) then
            p_bar = (b_ref / (2.0 * V_mag)) * omega(1)
            q_bar = (c_bar / (2.0 * V_mag)) * omega(2)
            r_bar = (b_ref / (2.0 * V_mag)) * omega(3)
        else
            p_bar = 0.0; q_bar = 0.0; r_bar = 0.0
        end if
    end subroutine calc_nondim_rates

    ! dynamic pressure
    pure function calc_dynamic_pressure(rho, V_mag) result(q_dyn)
        real, intent(in) :: rho, V_mag
        real :: q_dyn
        q_dyn = 0.5 * rho * V_mag**2
    end function calc_dynamic_pressure

    ! get wall clock time in seconds (nanosecond precision via int64)
    function get_wall_time() result(t)
        use iso_fortran_env, only: int64
        real :: t
        integer(int64) :: count, rate
        call system_clock(count, rate)
        t = real(count) / real(rate)
    end function get_wall_time

end module math_m