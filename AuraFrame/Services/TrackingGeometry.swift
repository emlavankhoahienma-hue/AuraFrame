import Foundation
import CoreGraphics
import simd

public final class TrackingGeometry: Sendable {
    public static let shared = TrackingGeometry()

    private init() {}

    // MARK: - 2D <-> 3D Ray Conversions

    /// Unprojects a normalized 2D screen coordinate (top-left origin [0, 1]) to a 3D unit ray in camera coordinates
    public func unprojectScreenPointToCameraRay(
        point: CGPoint,
        calibration: CameraIntrinsicsCalibration,
        zoomFactor: CGFloat = 1.0
    ) -> simd_double3 {
        let pixelX = Double(point.x) * Double(calibration.imageSize.width)
        let pixelY = Double(point.y) * Double(calibration.imageSize.height)

        let effectiveFx = calibration.fx * Double(zoomFactor)
        let effectiveFy = calibration.fy * Double(zoomFactor)

        let xCam = (pixelX - calibration.cx) / effectiveFx
        let yCam = (pixelY - calibration.cy) / effectiveFy
        let zCam = 1.0

        let ray = simd_double3(xCam, yCam, zCam)
        return simd_normalize(ray)
    }

    /// Projects a 3D camera ray onto a normalized 2D screen coordinate (top-left origin [0, 1])
    public func projectCameraRayToScreenPoint(
        ray: simd_double3,
        calibration: CameraIntrinsicsCalibration,
        zoomFactor: CGFloat = 1.0
    ) -> TrackingProjection {
        guard ray.z > 1e-4 else {
            // Point is behind camera
            let xNorm = (ray.x >= 0) ? 1.5 : -0.5
            let yNorm = (ray.y >= 0) ? 1.5 : -0.5
            return TrackingProjection(
                point: CGPoint(x: xNorm, y: yNorm),
                isInFront: false,
                isInsideImage: false,
                distanceFromCenter: 2.0
            )
        }

        let effectiveFx = calibration.fx * Double(zoomFactor)
        let effectiveFy = calibration.fy * Double(zoomFactor)

        let pixelX = (ray.x / ray.z) * effectiveFx + calibration.cx
        let pixelY = (ray.y / ray.z) * effectiveFy + calibration.cy

        let normX = CGFloat(pixelX / Double(calibration.imageSize.width))
        let normY = CGFloat(pixelY / Double(calibration.imageSize.height))

        let isInside = normX >= 0.0 && normX <= 1.0 && normY >= 0.0 && normY <= 1.0
        let distCenter = hypot(normX - 0.5, normY - 0.5)

        return TrackingProjection(
            point: CGPoint(x: normX, y: normY),
            isInFront: true,
            isInsideImage: isInside,
            distanceFromCenter: distCenter
        )
    }

    // MARK: - Quaternion Rotations

    /// Rotates a 3D vector by a quaternion: v' = q * v * q^-1 using Apple's simd_act
    public func rotateVector(by q: simd_quatd, vector: simd_double3) -> simd_double3 {
        return simd_act(q, vector)
    }

    /// Rotates a world ray into camera frame using the attitude quaternion
    public func worldRayToCameraRay(worldRay: simd_double3, attitude: simd_quatd) -> simd_double3 {
        let inverseAttitude = simd_inverse(attitude)
        return simd_act(inverseAttitude, worldRay)
    }

    /// Rotates a camera ray into world frame using the attitude quaternion
    public func cameraRayToWorldRay(cameraRay: simd_double3, attitude: simd_quatd) -> simd_double3 {
        return simd_act(attitude, cameraRay)
    }

    // MARK: - Tangent Space (Error-State Manifold S^2)

    /// Creates an orthonormal basis (e1, e2) on the tangent plane orthogonal to the unit ray r
    public func tangentBasis(for ray: simd_double3) -> (e1: simd_double3, e2: simd_double3) {
        let r = simd_normalize(ray)
        let up = abs(r.z) < 0.9 ? simd_double3(0, 0, 1) : simd_double3(0, 1, 0)
        let e1 = simd_normalize(simd_cross(up, r))
        let e2 = simd_normalize(simd_cross(r, e1))
        return (e1, e2)
    }

    /// Retraction map from tangent vector (d1, d2) back onto sphere S^2: Exp_r(d1*e1 + d2*e2)
    public func retract(ray: simd_double3, delta: simd_double2) -> simd_double3 {
        let (e1, e2) = tangentBasis(for: ray)
        let tangentVec = delta.x * e1 + delta.y * e2
        let angle = simd_length(tangentVec)

        if angle < 1e-8 {
            return ray
        }

        let newRay = cos(angle) * ray + (sin(angle) / angle) * tangentVec
        return simd_normalize(newRay)
    }

    /// Geodesic angular distance on unit sphere S^2
    public func angularDistance(ray1: simd_double3, ray2: simd_double3) -> Double {
        let dotVal = simd_clamp(simd_dot(simd_normalize(ray1), simd_normalize(ray2)), -1.0, 1.0)
        return acos(dotVal)
    }

    // MARK: - Coordinate Conversion Helpers

    /// Converts Vision coordinate (origin bottom-left, y-up) to UI coordinate (origin top-left, y-down)
    public func visionToUICoordinate(_ visionPoint: CGPoint) -> CGPoint {
        return CGPoint(x: visionPoint.x, y: 1.0 - visionPoint.y)
    }

    /// Converts UI coordinate (origin top-left, y-down) to Vision coordinate (origin bottom-left, y-up)
    public func uiToVisionCoordinate(_ uiPoint: CGPoint) -> CGPoint {
        return CGPoint(x: uiPoint.x, y: 1.0 - uiPoint.y)
    }

    /// Converts Vision CGRect to UI CGRect
    public func visionToUIRect(_ visionRect: CGRect) -> CGRect {
        return CGRect(
            x: visionRect.minX,
            y: 1.0 - visionRect.maxY,
            width: visionRect.width,
            height: visionRect.height
        )
    }
}
