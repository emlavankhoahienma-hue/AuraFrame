import Foundation
import CoreGraphics

public final class CompositionAestheticSearch: Sendable {
    public static let shared = CompositionAestheticSearch()

    private init() {}

    /// Searches across all composition rules to generate scored hypotheses
    public func searchHypotheses(
        subjectBox: CGRect,
        subjectAnchor: CGPoint,
        gazeVector: CGVector?,
        sceneType: DetectedSceneType,
        activeRuleOverride: CompositionRule? = nil
    ) -> [CompositionHypothesis] {
        var hypotheses: [CompositionHypothesis] = []

        let rulesToEvaluate: [CompositionRule] = (activeRuleOverride != nil)
            ? [activeRuleOverride!]
            : CompositionRule.allCases

        let headroomScore = CompositionPureCalculations.evaluateHeadroom(
            subjectBox: subjectBox,
            targetRange: sceneType.optimalHeadroomMargin
        )

        for rule in rulesToEvaluate {
            let candidatePoints = rule.canonicalGridPoints

            for pGrid in candidatePoints {
                // Aim point formula: P_target = (0.5 + (S_anchor.x - P_grid.x), 0.5 + (S_anchor.y - P_grid.y))
                let pTarget = CompositionPureCalculations.computeAimPoint(
                    subjectAnchor: subjectAnchor,
                    desiredGridPoint: pGrid
                )

                let lookingRoom = CompositionPureCalculations.evaluateLookingRoom(
                    subjectAnchor: subjectAnchor,
                    gazeVector: gazeVector,
                    gridPoint: pGrid
                )

                let balance = CompositionPureCalculations.evaluateVisualBalance(
                    anchor: subjectAnchor,
                    gridPoint: pGrid
                )

                // Scene-specific weighting factors
                var ruleSceneMultiplier = 1.0
                if rule == sceneType.primaryRule {
                    ruleSceneMultiplier = 1.25
                }

                // Composite score formula
                let rawScore = (balance * 0.40 + lookingRoom * 0.35 + headroomScore * 0.25) * ruleSceneMultiplier
                let finalScore = max(0.05, min(0.99, rawScore))

                let rationale = generateRationale(
                    rule: rule,
                    gridPoint: pGrid,
                    lookingRoom: lookingRoom,
                    sceneType: sceneType
                )

                let hypothesis = CompositionHypothesis(
                    rule: rule,
                    gridPoint: pGrid,
                    anchorPoint: subjectAnchor,
                    targetPoint: pTarget,
                    score: finalScore,
                    lookingRoomBonus: lookingRoom,
                    headroomFit: headroomScore,
                    visualBalanceScore: balance,
                    rationale: rationale
                )

                hypotheses.append(hypothesis)
            }
        }

        // Return sorted descending by score
        return hypotheses.sorted { $0.score > $1.score }
    }

    private func generateRationale(
        rule: CompositionRule,
        gridPoint: CGPoint,
        lookingRoom: Double,
        sceneType: DetectedSceneType
    ) -> String {
        let hPos = gridPoint.x < 0.45 ? "left" : (gridPoint.x > 0.55 ? "right" : "center")
        let vPos = gridPoint.y < 0.45 ? "top" : (gridPoint.y > 0.55 ? "bottom" : "middle")

        var notes: [String] = []
        notes.append("\(rule.shortName) at \(vPos)-\(hPos)")

        if lookingRoom > 0.70 {
            notes.append("optimal lead room for gaze")
        }
        if sceneType == .portrait {
            notes.append("flattering portrait balance")
        }

        return notes.joined(separator: ", ")
    }
}
