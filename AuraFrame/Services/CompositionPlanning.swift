import Foundation
import CoreGraphics

public struct FramingTrajectoryHint: Sendable {
    public let directionVector: CGVector
    public let distance: CGFloat
    public let isWithinAlignmentGate: Bool
    public let instruction: String
}

public final class CompositionPlanning: Sendable {
    public static let shared = CompositionPlanning()

    public let alignmentTolerance: CGFloat = 0.04 // 4% screen radius gate

    private init() {}

    /// Checks crop safety: verifies that subject bounding box maintains at least 5% margin from edges
    public func verifyCropSafety(
        subjectBox: CGRect,
        predictedAimPoint: CGPoint
    ) -> (isSafe: Bool, adjustedAimPoint: CGPoint) {
        let minMargin: CGFloat = 0.05
        var adjusted = predictedAimPoint

        let expectedSubjectMinX = subjectBox.minX + (0.5 - predictedAimPoint.x)
        let expectedSubjectMaxX = subjectBox.maxX + (0.5 - predictedAimPoint.x)
        let expectedSubjectMinY = subjectBox.minY + (0.5 - predictedAimPoint.y)
        let expectedSubjectMaxY = subjectBox.maxY + (0.5 - predictedAimPoint.y)

        // Adjust X if too close to frame boundaries
        if expectedSubjectMinX < minMargin {
            adjusted.x -= (minMargin - expectedSubjectMinX)
        } else if expectedSubjectMaxX > 1.0 - minMargin {
            adjusted.x += (expectedSubjectMaxX - (1.0 - minMargin))
        }

        // Adjust Y if too close to top or bottom
        if expectedSubjectMinY < minMargin {
            adjusted.y -= (minMargin - expectedSubjectMinY)
        } else if expectedSubjectMaxY > 1.0 - minMargin {
            adjusted.y += (expectedSubjectMaxY - (1.0 - minMargin))
        }

        let isSafe = (expectedSubjectMinX >= minMargin) && (expectedSubjectMaxX <= 1.0 - minMargin) &&
                     (expectedSubjectMinY >= minMargin) && (expectedSubjectMaxY <= 1.0 - minMargin)

        return (isSafe, adjusted)
    }

    /// Computes navigation guidance hints to guide the user's hands towards the aim reticle
    public func planTrajectory(currentAimPoint: CGPoint) -> FramingTrajectoryHint {
        // Screen center is (0.5, 0.5)
        let dx = currentAimPoint.x - 0.5
        let dy = currentAimPoint.y - 0.5
        let dist = hypot(dx, dy)

        let isAligned = dist <= alignmentTolerance

        var instruction = "Align target with center"
        if isAligned {
            instruction = "Perfect composition! Hold still"
        } else {
            let hGuide = abs(dx) > 0.03 ? (dx > 0 ? "Pan Right" : "Pan Left") : ""
            let vGuide = abs(dy) > 0.03 ? (dy > 0 ? "Tilt Down" : "Tilt Up") : ""
            if !hGuide.isEmpty && !vGuide.isEmpty {
                instruction = "\(hGuide) & \(vGuide)"
            } else if !hGuide.isEmpty {
                instruction = hGuide
            } else if !vGuide.isEmpty {
                instruction = vGuide
            }
        }

        return FramingTrajectoryHint(
            directionVector: CGVector(dx: dx, dy: dy),
            distance: dist,
            isWithinAlignmentGate: isAligned,
            instruction: instruction
        )
    }
}
