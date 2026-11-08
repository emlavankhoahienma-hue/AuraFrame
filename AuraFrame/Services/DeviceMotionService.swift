import Foundation
import CoreMotion
import Combine

public final class DeviceMotionService: ObservableObject, @unchecked Sendable {
    public static let shared = DeviceMotionService()

    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()

    @Published public private(set) var currentRoll: Double = 0.0      // Degrees [-180, 180]
    @Published public private(set) var currentPitch: Double = 0.0     // Degrees [-90, 90]
    @Published public private(set) var currentYaw: Double = 0.0       // Degrees [-180, 180]
    @Published public private(set) var angularVelocity: Double = 0.0  // rad/s
    @Published public private(set) var isLevel: Bool = false          // Within ±0.5 degrees roll
    @Published public private(set) var isRunning: Bool = false

    private init() {
        motionQueue.name = "com.auraframe.motionQueue"
        motionQueue.maxConcurrentOperationCount = 1
        motionQueue.qualityOfService = .userInteractive
    }

    public func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else {
            CameraLogger.shared.camera.error("⚠️ CoreMotion is not available on this device.")
            return
        }

        guard !isRunning else { return }

        // Set sampling frequency to 200 Hz (0.005s period)
        motionManager.deviceMotionUpdateInterval = 1.0 / 200.0

        let referenceFrame: CMAttitudeReferenceFrame
        let availableFrames = CMMotionManager.availableAttitudeReferenceFrames()
        if availableFrames.contains(.xArbitraryCorrectedZVertical) {
            referenceFrame = .xArbitraryCorrectedZVertical
        } else if availableFrames.contains(.xArbitraryZVertical) {
            referenceFrame = .xArbitraryZVertical
        } else {
            referenceFrame = .xArbitraryZVertical
        }

        motionManager.startDeviceMotionUpdates(using: referenceFrame, to: motionQueue) { [weak self] motion, error in
            guard let self = self, let motion = motion, error == nil else {
                if let error = error {
                    CameraLogger.shared.logError("Motion", error: error)
                }
                return
            }

            let timestamp = ProcessInfo.processInfo.systemUptime
            let q = motion.attitude.quaternion

            // 1. Push directly into C++ 200Hz native ring buffer
            ntc_imu_push_sample(timestamp, q.x, q.y, q.z, q.w)

            // 2. Compute roll and pitch in degrees for UI Horizon Leveler
            let rollDeg = motion.attitude.roll * (180.0 / .pi)
            let pitchDeg = motion.attitude.pitch * (180.0 / .pi)
            let yawDeg = motion.attitude.yaw * (180.0 / .pi)

            let rotRate = motion.rotationRate
            let speed = sqrt(rotRate.x * rotRate.x + rotRate.y * rotRate.y + rotRate.z * rotRate.z)

            let levelStatus = abs(rollDeg) <= 0.50

            DispatchQueue.main.async {
                self.currentRoll = rollDeg
                self.currentPitch = pitchDeg
                self.currentYaw = yawDeg
                self.angularVelocity = speed
                self.isLevel = levelStatus
            }
        }

        isRunning = true
        CameraLogger.shared.logMotion("High-frequency 200Hz IMU updates started with frame \(referenceFrame).")
    }

    public func stopMotionUpdates() {
        guard isRunning else { return }
        motionManager.stopDeviceMotionUpdates()
        isRunning = false
        CameraLogger.shared.logMotion("Device motion updates stopped.")
    }
}
