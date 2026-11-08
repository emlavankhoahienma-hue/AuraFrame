import Foundation
import CoreGraphics

public final class CompositionCalculator: Sendable {
    public static let shared = CompositionCalculator()

    private init() {}

    /// Evaluates the primary entity and determines the winning composition hypothesis and recommended zoom factor
    public func calculateOptimalFraming(
        primaryEntity: TrackedEntity,
        detectedScene: DetectedSceneType = .portrait,
        activeRuleOverride: CompositionRule? = nil
    ) -> FramingTargetResult {
        // Convert Vision bounding box to UI coordinates for framing logic
        let uiBox = TrackingGeometry.shared.visionToUIRect(primaryEntity.boundingBox)
        let uiAnchor = TrackingGeometry.shared.visionToUICoordinate(primaryEntity.anchorPoint)

        // 1. Search hypotheses across aesthetic rules
        let hypotheses = CompositionAestheticSearch.shared.searchHypotheses(
            subjectBox: uiBox,
            subjectAnchor: uiAnchor,
            gazeVector: primaryEntity.gazeVector,
            sceneType: detectedScene,
            activeRuleOverride: activeRuleOverride
        )

        guard let topHypothesis = hypotheses.first else {
            // Fallback to center
            let fallbackAim = CGPoint(x: 0.5, y: 0.5)
            return FramingTargetResult(
                targetPoint: fallbackAim,
                anchorPoint: uiAnchor,
                bestRule: .centerSymmetry,
                confidence: 0.5,
                suggestedZoomFactor: 1.0,
                sceneType: detectedScene
            )
        }

        // 2. Crop Protection check
        let (_, safeAimPoint) = CompositionPlanning.shared.verifyCropSafety(
            subjectBox: uiBox,
            predictedAimPoint: topHypothesis.targetPoint
        )

        // 3. Virtual Crop Simulation (AI Smart Windowed Zoom)
        // rho = Area(S_box) / Area(Frame)
        let frameArea: CGFloat = 1.0 * 1.0
        let subjectArea = max(1e-4, uiBox.width * uiBox.height)
        let rho = subjectArea / frameArea

        let suggestedZoom = calculateVirtualCropZoom(
            rho: rho,
            sceneType: detectedScene,
            entityType: primaryEntity.entityType
        )

        return FramingTargetResult(
            targetPoint: safeAimPoint,
            anchorPoint: uiAnchor,
            bestRule: topHypothesis.rule,
            confidence: topHypothesis.score,
            suggestedZoomFactor: suggestedZoom,
            sceneType: detectedScene,
            hypotheses: hypotheses
        )
    }

    /// Evaluates subject coverage rho to select the optimal hardware optical zoom level
    public func calculateVirtualCropZoom(
        rho: CGFloat,
        sceneType: DetectedSceneType,
        entityType: TrackedEntity.EntityType
    ) -> CGFloat {
        switch entityType {
        case .face, .humanBody:
            if rho < 0.035 {
                // Distant subject: Step up to 2x or 3x for clear portraiture
                return 2.0
            } else if rho < 0.015 {
                return 3.0
            } else if rho > 0.65 {
                // Subject overflowing frame: recommend 0.5x Ultra Wide
                return 0.5
            } else {
                return 1.0
            }
        case .genericObject:
            if sceneType == .landscape || sceneType == .architecture {
                if rho > 0.75 {
                    return 0.5
                }
                return 1.0
            } else if rho < 0.03 {
                return 2.0
            } else {
                return 1.0
            }
        }
    }
}
