import Foundation
import CoreGraphics
import simd
import Combine

public final class SpatialTrackingEngine: ObservableObject, @unchecked Sendable {
    public static let shared = SpatialTrackingEngine()

    // MARK: - Published State for UI
    @Published public private(set) var projectedTargetPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @Published public private(set) var projectedSubjectPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @Published public private(set) var isTargetInsideFrame: Bool = true
    @Published public private(set) var edgeDockedAngle: Double = 0.0 // Angle in radians pointing towards target if offscreen
    @Published public private(set) var trackingQuality: TrackingQuality = .lost
    @Published public private(set) var isTrackingActive: Bool = false
    @Published public private(set) var presentationIsRecovering: Bool = false

    // MARK: - 3D Spherical Rays (Unit Vectors on S^2)
    private var subjectWorldRay: simd_double3 = simd_double3(0, 0, 1) // Physical subject anchor
    private var targetWorldRay: simd_double3 = simd_double3(0, 0, 1)  // Artistic composition aim point
    private var guideFromSubject: simd_quatd = simd_quatd(angle: 0, axis: simd_double3(0, 1, 0))

    // Smooth presentation ray for jitter-free UI rendering
    private var presentationRay: simd_double3 = simd_double3(0, 0, 1)
    private var lastPresentationTime: TimeInterval = 0.0

    // MARK: - Error-State Kalman Filter (ESKF) on S^2 Tangent Space
    private struct ESKFState {
        var deltaTheta: simd_double2 = simd_double2(0, 0) // Tangent error angle
        var omega: simd_double2 = simd_double2(0, 0)      // Angular velocity on tangent plane
        var covariance: simd_double4x4 = matrix_identity_double4x4 * 0.04
        var lastUpdateTime: TimeInterval = 0.0

        mutating func reset() {
            deltaTheta = simd_double2(0, 0)
            omega = simd_double2(0, 0)
            covariance = matrix_identity_double4x4 * 0.04
            lastUpdateTime = 0.0
        }

        mutating func reidentify(to observedRay: simd_double3, timestamp: TimeInterval) {
            deltaTheta = simd_double2(0, 0)
            omega = simd_double2(0, 0)
            covariance = matrix_identity_double4x4 * 0.02
            lastUpdateTime = timestamp
        }
    }

    private var filter = ESKFState()
    private let stateLock = NSLock()

    // Active calibration fallback
    private var currentCalibration: CameraIntrinsicsCalibration = .standardIPhoneWide
    private var currentZoom: CGFloat = 1.0

    private init() {}

    // MARK: - Initialization & Pinning

    /// Starts tracking a physical subject at `anchorPoint` (normalized [0, 1] UI space)
    /// and establishes the virtual composition aim point at `targetPoint`
    public func startTracking(
        subjectPoint: CGPoint,
        targetPoint: CGPoint,
        calibration: CameraIntrinsicsCalibration,
        zoomFactor: CGFloat,
        timestamp: TimeInterval
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }

        self.currentCalibration = calibration
        self.currentZoom = zoomFactor

        var qx: Double = 0, qy: Double = 0, qz: Double = 0, qw: Double = 1
        if !ntc_imu_interpolate_pose(timestamp, &qx, &qy, &qz, &qw) {
            qw = 1.0
        }
        let attitude = simd_quatd(vector: simd_double4(qx, qy, qz, qw))

        // 1. Unproject subject point to 3D world ray
        let subjectCamRay = TrackingGeometry.shared.unprojectScreenPointToCameraRay(
            point: subjectPoint,
            calibration: calibration,
            zoomFactor: zoomFactor
        )
        self.subjectWorldRay = TrackingGeometry.shared.cameraRayToWorldRay(cameraRay: subjectCamRay, attitude: attitude)

        // 2. Unproject target aim point to 3D world ray
        let targetCamRay = TrackingGeometry.shared.unprojectScreenPointToCameraRay(
            point: targetPoint,
            calibration: calibration,
            zoomFactor: zoomFactor
        )
        self.targetWorldRay = TrackingGeometry.shared.cameraRayToWorldRay(cameraRay: targetCamRay, attitude: attitude)

        // 3. Compute relative rotation from subject ray to target ray
        self.guideFromSubject = simd_quaternion(self.subjectWorldRay, self.targetWorldRay)

        // 4. Reset ESKF and presentation ray
        self.filter.reset()
        self.filter.lastUpdateTime = timestamp
        self.presentationRay = self.targetWorldRay
        self.lastPresentationTime = timestamp
        self.presentationIsRecovering = false

        DispatchQueue.main.async {
            self.isTrackingActive = true
            self.trackingQuality = .locked
            self.projectedSubjectPoint = subjectPoint
            self.projectedTargetPoint = targetPoint
            self.isTargetInsideFrame = true
        }

        CameraLogger.shared.logTracking("Spatial tracking initiated for subject at \(subjectPoint), target at \(targetPoint).")
    }

    public func stopTracking() {
        stateLock.lock()
        defer { stateLock.unlock() }

        isTrackingActive = false
        trackingQuality = .lost
        presentationIsRecovering = false

        DispatchQueue.main.async {
            self.isTrackingActive = false
            self.trackingQuality = .lost
        }
        CameraLogger.shared.logTracking("Spatial tracking stopped.")
    }

    // MARK: - High-Frequency Camera Pose Step (Called from 60 FPS Video Feed)

    public func updateDevicePose(timestamp: TimeInterval, zoomFactor: CGFloat, calibration: CameraIntrinsicsCalibration?) {
        stateLock.lock()
        guard isTrackingActive else {
            stateLock.unlock()
            return
        }

        if let calib = calibration {
            self.currentCalibration = calib
        }
        self.currentZoom = zoomFactor

        // Viewport latency compensation (~8ms rendering pipeline lead)
        let renderTime = timestamp - 0.008

        var qx: Double = 0, qy: Double = 0, qz: Double = 0, qw: Double = 1
        let validPose = ntc_imu_interpolate_pose(renderTime, &qx, &qy, &qz, &qw)
        stateLock.unlock()

        guard validPose else { return }

        let attitude = simd_quatd(vector: simd_double4(qx, qy, qz, qw))

        // Step 1: Predict via ESKF
        predictMotion(timestamp: renderTime)

        // Step 2: Smooth presentation ray using C++ 1-Euro Geodesic SLERP
        let dt = (lastPresentationTime > 0) ? (renderTime - lastPresentationTime) : 0.016
        self.lastPresentationTime = renderTime

        var outX: Double = 0, outY: Double = 0, outZ: Double = 0
        ntc_s2_1euro_slerp(
            presentationRay.x, presentationRay.y, presentationRay.z,
            targetWorldRay.x, targetWorldRay.y, targetWorldRay.z,
            Double(zoomFactor), dt,
            &outX, &outY, &outZ
        )
        self.presentationRay = simd_normalize(simd_double3(outX, outY, outZ))

        // Step 3: Project target and subject rays back to screen
        let camTargetRay = TrackingGeometry.shared.worldRayToCameraRay(worldRay: self.presentationRay, attitude: attitude)
        let camSubjectRay = TrackingGeometry.shared.worldRayToCameraRay(worldRay: self.subjectWorldRay, attitude: attitude)

        let targetProj = TrackingGeometry.shared.projectCameraRayToScreenPoint(
            ray: camTargetRay,
            calibration: self.currentCalibration,
            zoomFactor: zoomFactor
        )
        let subjectProj = TrackingGeometry.shared.projectCameraRayToScreenPoint(
            ray: camSubjectRay,
            calibration: self.currentCalibration,
            zoomFactor: zoomFactor
        )

        // Step 4: Calculate Edge Docking if target is outside screen
        var dockedPoint = targetProj.point
        var offscreenAngle: Double = 0.0
        let isInside = targetProj.isInsideImage && targetProj.isInFront

        if !isInside {
            let dx = targetProj.point.x - 0.5
            let dy = targetProj.point.y - 0.5
            offscreenAngle = atan2(Double(dy), Double(dx))

            // Clamp docked point to screen edge with 0.06 margin
            let margin: CGFloat = 0.06
            let halfW = 0.5 - margin
            let halfH = 0.5 - margin

            let absDx = abs(dx)
            let absDy = abs(dy)

            if absDx * halfH > absDy * halfW {
                let signX: CGFloat = dx > 0 ? 1 : -1
                dockedPoint.x = 0.5 + signX * halfH * (CGFloat(cos(offscreenAngle)) / max(1e-4, CGFloat(abs(cos(offscreenAngle)))))
                dockedPoint.y = 0.5 + (dockedPoint.x - 0.5) * CGFloat(tan(offscreenAngle))
            } else {
                let signY: CGFloat = dy > 0 ? 1 : -1
                dockedPoint.y = 0.5 + signY * halfH * (CGFloat(sin(offscreenAngle)) / max(1e-4, CGFloat(abs(sin(offscreenAngle)))))
                dockedPoint.x = 0.5 + (dockedPoint.y - 0.5) / max(1e-4, CGFloat(tan(offscreenAngle)))
            }

            dockedPoint.x = max(margin, min(1.0 - margin, dockedPoint.x))
            dockedPoint.y = max(margin, min(1.0 - margin, dockedPoint.y))
        }

        DispatchQueue.main.async {
            self.projectedTargetPoint = isInside ? targetProj.point : dockedPoint
            self.projectedSubjectPoint = subjectProj.point
            self.isTargetInsideFrame = isInside
            self.edgeDockedAngle = offscreenAngle
        }
    }

    // MARK: - Vision Update Step (24 Hz Optical Fusion & Parallax Correction)

    public func incorporateVisionObservation(
        observedSubjectPoint: CGPoint,
        evidence: TrackingOpticalEvidence,
        confidence: Double,
        timestamp: TimeInterval
    ) {
        stateLock.lock()
        guard isTrackingActive else {
            stateLock.unlock()
            return
        }

        var qx: Double = 0, qy: Double = 0, qz: Double = 0, qw: Double = 1
        if !ntc_imu_interpolate_pose(timestamp, &qx, &qy, &qz, &qw) {
            stateLock.unlock()
            return
        }
        let attitude = simd_quatd(vector: simd_double4(qx, qy, qz, qw))

        // 1. Unproject observed 2D point to 3D camera ray then to world ray
        let obsCamRay = TrackingGeometry.shared.unprojectScreenPointToCameraRay(
            point: observedSubjectPoint,
            calibration: self.currentCalibration,
            zoomFactor: self.currentZoom
        )
        let observedWorldRay = TrackingGeometry.shared.cameraRayToWorldRay(cameraRay: obsCamRay, attitude: attitude)

        // 2. Compute residual angular distance
        let residual = TrackingGeometry.shared.angularDistance(ray1: self.subjectWorldRay, ray2: observedWorldRay)

        // 3. Parallax Footstep Recovery Gate
        // When residual > 0.08 rad (~4.5 deg) and optical confidence >= 0.65
        if residual > 0.08 && confidence >= 0.65 {
            CameraLogger.shared.logTracking("Parallax shift detected (residual: \(residual) rad). Reidentifying filter.")
            self.subjectWorldRay = observedWorldRay
            self.targetWorldRay = simd_act(self.guideFromSubject, self.subjectWorldRay)
            self.filter.reidentify(to: observedWorldRay, timestamp: timestamp)
            self.presentationIsRecovering = true
            self.trackingQuality = .reacquiring
            stateLock.unlock()
            return
        }

        // 4. Tangent-space Mahalanobis Gating
        let (e1, e2) = TrackingGeometry.shared.tangentBasis(for: self.subjectWorldRay)
        let deltaRay = observedWorldRay - self.subjectWorldRay
        let yMeas = simd_double2(simd_dot(deltaRay, e1), simd_dot(deltaRay, e2))

        let rNoise = (confidence > 0.8) ? 0.005 : 0.02
        let mahalanobisSq = (yMeas.x * yMeas.x + yMeas.y * yMeas.y) / rNoise

        if mahalanobisSq <= evidence.gateThresholdSquared {
            // Kalman tangent update
            let kGain = 0.35 * confidence
            let correction = simd_double2(yMeas.x * kGain, yMeas.y * kGain)
            self.subjectWorldRay = TrackingGeometry.shared.retract(ray: self.subjectWorldRay, delta: correction)
            self.targetWorldRay = simd_act(self.guideFromSubject, self.subjectWorldRay)
            self.trackingQuality = .locked
            self.presentationIsRecovering = false
        } else {
            self.trackingQuality = .predicting
        }

        stateLock.unlock()
    }

    // MARK: - Internal ESKF Predictor

    private func predictMotion(timestamp: TimeInterval) {
        guard filter.lastUpdateTime > 0 else {
            filter.lastUpdateTime = timestamp
            return
        }

        let dt = max(1e-4, min(0.05, timestamp - filter.lastUpdateTime))
        filter.lastUpdateTime = timestamp

        // Damping human hand tremor: omega_{t+dt} = omega_t * exp(-2.85 * dt)
        let damping = exp(-2.85 * dt)
        filter.omega *= damping
        filter.deltaTheta += filter.omega * dt
    }
}
