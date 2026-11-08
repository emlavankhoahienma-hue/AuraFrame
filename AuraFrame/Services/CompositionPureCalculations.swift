import Foundation
import CoreGraphics

public enum CompositionPureCalculations {
    // MARK: - Canonical Mathematical Constants
    public static let phi: Double = 1.618033988749895
    public static let phiInv: Double = 0.618033988749895
    public static let phiComp: Double = 0.381966011250105
    public static let oneThird: Double = 1.0 / 3.0
    public static let twoThirds: Double = 2.0 / 3.0

    // MARK: - Distance & Vector Math

    @inlinable
    public static func distance(_ p1: CGPoint, _ p2: CGPoint) -> Double {
        let dx = Double(p1.x - p2.x)
        let dy = Double(p1.y - p2.y)
        return sqrt(dx * dx + dy * dy)
    }

    @inlinable
    public static func dotProduct(_ v1: CGVector, _ v2: CGVector) -> Double {
        return Double(v1.dx * v2.dx + v1.dy * v2.dy)
    }

    @inlinable
    public static func vectorLength(_ v: CGVector) -> Double {
        return sqrt(Double(v.dx * v.dx + v.dy * v.dy))
    }

    @inlinable
    public static func normalizeVector(_ v: CGVector) -> CGVector {
        let len = vectorLength(v)
        guard len > 1e-6 else { return CGVector(dx: 0, dy: 0) }
        return CGVector(dx: CGFloat(Double(v.dx) / len), dy: CGFloat(Double(v.dy) / len))
    }

    // MARK: - Aim Point Formula
    /// Computes the viewfinder Aim Point (P_target) given current subject anchor (S_anchor) and desired grid point (P_grid):
    /// P_target = (0.5 + (S_anchor.x - P_grid.x), 0.5 + (S_anchor.y - P_grid.y))
    @inlinable
    public static func computeAimPoint(subjectAnchor: CGPoint, desiredGridPoint: CGPoint) -> CGPoint {
        let aimX = 0.5 + (subjectAnchor.x - desiredGridPoint.x)
        let aimY = 0.5 + (subjectAnchor.y - desiredGridPoint.y)
        return CGPoint(x: aimX, y: aimY)
    }

    // MARK: - Headroom Evaluation

    /// Evaluates whether the headroom (top margin) satisfies professional photographic composition
    public static func evaluateHeadroom(subjectBox: CGRect, targetRange: ClosedRange<Double>) -> Double {
        // UI coordinates: subjectBox.minY is the top of the subject
        let currentHeadroom = Double(subjectBox.minY)
        if targetRange.contains(currentHeadroom) {
            return 1.0
        }
        let distanceToRange = currentHeadroom < targetRange.lowerBound
            ? (targetRange.lowerBound - currentHeadroom)
            : (currentHeadroom - targetRange.upperBound)
        return max(0.0, 1.0 - (distanceToRange / 0.15))
    }

    // MARK: - Looking Room (Lead Room) Evaluation

    /// Evaluates if there is ample open space in the direction the subject is facing/looking
    public static func evaluateLookingRoom(
        subjectAnchor: CGPoint,
        gazeVector: CGVector?,
        gridPoint: CGPoint
    ) -> Double {
        guard let gaze = gazeVector else { return 0.5 }
        let normGaze = normalizeVector(gaze)

        // Vector from subject anchor to candidate grid point
        let toGrid = CGVector(dx: gridPoint.x - subjectAnchor.x, dy: gridPoint.y - subjectAnchor.y)
        let normToGrid = normalizeVector(toGrid)

        // If subject is looking right (gaze.dx > 0), gridPoint should ideally be placed on the left,
        // leaving the right 2/3 of frame open for looking room.
        // Therefore, vector to center/open frame aligns with gaze.
        let alignment = dotProduct(normGaze, normToGrid)

        // Return score bonus between 0.0 and 1.0
        return max(0.0, min(1.0, (alignment + 1.0) * 0.5))
    }

    // MARK: - Visual Balance Score

    /// Computes balance score based on distance from canvas center and symmetry
    public static func evaluateVisualBalance(anchor: CGPoint, gridPoint: CGPoint) -> Double {
        let dist = distance(anchor, gridPoint)
        // Closer anchor to chosen grid point yields higher balance score
        return max(0.0, 1.0 - (dist / 0.707))
    }
}
