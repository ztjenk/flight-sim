! SPDX-License-Identifier: GPL-3.0-or-later
! Copyright (C) 2026 Zachary Jenkins

! packet construction and parsing for UDP telemetry
module packet_builder_m
    use vehicle_types_m
    use sensor_m, only: SENSOR_IMU, SENSOR_MAGNETOMETER
    use ekf_m, only: ekf_get_body_state
    implicit none
    private

    ! packet layout constants
    integer, parameter, public :: STATE_PACKET_SIZE = 14  ! t(1) + velocity(3) + omega(3) + position(3) + quaternion(4)

    ! data type constants for packet formats
    integer, parameter, public :: DATA_CONTROLS = 1  ! N values: one per effector
    integer, parameter, public :: DATA_STATE = 2     ! t + velocity(3) + omega(3) + position(3) + quaternion(4)
    integer, parameter, public :: DATA_BOTH = 3      ! STATE_PACKET_SIZE + 2*N values: state + cmd + actual controls
    integer, parameter, public :: DATA_SENSORS = 4   ! sensor outputs (sensor list specified per connection)
    integer, parameter, public :: DATA_EKF_STATE = 5 ! EKF state (= DATA_STATE layout) + 3 angular-accel fields appended at the tail
    integer, parameter, public :: DATA_EKF_BOTH = 6  ! EKF state + control effectors (= DATA_BOTH layout) + 3 angular-accel fields appended at the tail

    public :: build_packet, parse_controls_packet
    public :: find_imu_gyro, find_sensor, find_mag_field

contains

    ! find first sensor matching any of the given type IDs
    ! returns sensor index (1-based), or 0 if not found
    function find_sensor(config, type_ids) result(idx)
        type(vehicle_config_t), intent(in) :: config
        integer, intent(in) :: type_ids(:)
        integer :: idx
        integer :: j, k

        do j = 1, config%n_sensors
            do k = 1, size(type_ids)
                if (config%sensors(j)%sensor%type_id == type_ids(k)) then
                    idx = j
                    return
                end if
            end do
        end do
        idx = 0
    end function find_sensor

    ! find latest IMU gyro output from a vehicle's sensor list
    ! used by EKF routines that need bias-corrected body rates
    subroutine find_imu_gyro(config, imu_gyro)
        type(vehicle_config_t), intent(in) :: config
        real, intent(out) :: imu_gyro(3)
        integer :: idx

        idx = find_sensor(config, [SENSOR_IMU])
        if (idx > 0) then
            imu_gyro = config%sensors(idx)%sensor%output(4:6)
        else
            imu_gyro = 0.0
        end if
    end subroutine find_imu_gyro

    ! find magnetic field vector from first IMU or magnetometer sensor
    subroutine find_mag_field(config, mag_field, found)
        type(vehicle_config_t), intent(in) :: config
        real, intent(out) :: mag_field(3)
        logical, intent(out) :: found
        integer :: idx

        idx = find_sensor(config, [SENSOR_IMU, SENSOR_MAGNETOMETER])
        if (idx > 0) then
            mag_field = config%sensors(idx)%sensor%mag_field
            found = .true.
        else
            found = .false.
        end if
    end subroutine find_mag_field

    ! unified packet builder for all data types
    subroutine build_packet(data_type, t, state, config, ctrl_cmd, ctrl_act, passive, packet)
        integer, intent(in) :: data_type
        real, intent(in) :: t
        type(vehicle_state_t), intent(in) :: state
        type(vehicle_config_t), intent(in) :: config
        type(control_inputs_t), intent(in) :: ctrl_cmd, ctrl_act
        type(passive_inputs_t), intent(in) :: passive
        real, intent(out) :: packet(:)
        integer :: offset
        real :: omega_dot(3)   ! EKF-estimated angular accel, appended after the EKF payload

        select case (data_type)
        case (DATA_CONTROLS)
            call pack_controls(ctrl_act, packet)

        case (DATA_STATE)
            call pack_state(t, state, packet)

        case (DATA_BOTH)
            call pack_state(t, state, packet)
            offset = STATE_PACKET_SIZE
            call pack_controls_and_passives(ctrl_cmd, ctrl_act, passive, packet, offset)

        case (DATA_EKF_STATE)
            call pack_ekf_state(t, config, packet, omega_dot)
            packet(STATE_PACKET_SIZE+1:STATE_PACKET_SIZE+3) = omega_dot

        case (DATA_EKF_BOTH)
            call pack_ekf_state(t, config, packet, omega_dot)
            offset = STATE_PACKET_SIZE
            call pack_controls_and_passives(ctrl_cmd, ctrl_act, passive, packet, offset)
            packet(offset+1:offset+3) = omega_dot   ! 3 angular-accel fields at the tail
        end select
    end subroutine build_packet

    ! parse controls packet
    subroutine parse_controls_packet(values, ctrl)
        real, intent(in) :: values(:)
        type(control_inputs_t), intent(inout) :: ctrl
        integer :: j

        if (size(values) >= ctrl%n) then
            do j = 1, ctrl%n
                ctrl%effectors(j)%value = values(j)
            end do
        end if
    end subroutine parse_controls_packet

    ! --- private helpers ---

    subroutine pack_controls(ctrl, packet)
        type(control_inputs_t), intent(in) :: ctrl
        real, intent(out) :: packet(:)
        integer :: j

        do j = 1, ctrl%n
            packet(j) = ctrl%effectors(j)%value
        end do
    end subroutine pack_controls

    subroutine pack_state(t, state, packet)
        real, intent(in) :: t
        type(vehicle_state_t), intent(in) :: state
        real, intent(out) :: packet(:)

        packet(1) = t
        packet(2:4) = state%velocity
        packet(5:7) = state%omega
        packet(8:10) = state%position
        packet(11:14) = state%quaternion
    end subroutine pack_state

    subroutine pack_ekf_state(t, config, packet, omega_dot)
        real, intent(in) :: t
        type(vehicle_config_t), intent(in) :: config
        real, intent(out) :: packet(:)
        real, intent(out) :: omega_dot(3)   ! EKF-estimated angular accel, appended at packet tail
        real :: vel_body(3), omega_body(3), pos(3), quat(4)
        real :: imu_gyro(3)

        call find_imu_gyro(config, imu_gyro)
        call ekf_get_body_state(config%ekf, vel_body, omega_body, pos, quat, imu_gyro, omega_dot)

        packet(1) = t
        packet(2:4) = vel_body
        packet(5:7) = omega_body
        packet(8:10) = pos
        packet(11:14) = quat
    end subroutine pack_ekf_state

    subroutine pack_controls_and_passives(ctrl_cmd, ctrl_act, passive, packet, offset)
        type(control_inputs_t), intent(in) :: ctrl_cmd
        type(control_inputs_t), intent(in) :: ctrl_act
        type(passive_inputs_t), intent(in) :: passive
        real, intent(out) :: packet(:)
        integer, intent(inout) :: offset
        integer :: j

        ! control effectors: interleaved cmd/act (matches datalog)
        do j = 1, ctrl_cmd%n
            if (ctrl_cmd%effectors(j)%dynamics_order >= 1) then
                offset = offset + 1
                packet(offset) = ctrl_cmd%effectors(j)%value
                offset = offset + 1
                packet(offset) = ctrl_act%effectors(j)%value
            else
                offset = offset + 1
                packet(offset) = ctrl_act%effectors(j)%value
            end if
        end do

        ! passive effectors: pos then rate
        do j = 1, passive%n
            offset = offset + 1
            packet(offset) = passive%effectors(j)%value
            offset = offset + 1
            packet(offset) = passive%effectors(j)%rate_value
        end do
    end subroutine pack_controls_and_passives

end module packet_builder_m
