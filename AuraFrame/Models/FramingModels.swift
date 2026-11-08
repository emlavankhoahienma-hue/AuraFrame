import Foundation
import CoreGraphics
import ImageIO
import simd

// MARK: - Composition Rules

public enum CompositionRule: String, CaseIterable, Identifiable, Sendable {
    case ruleOfThirds = "Rule of Thirds"
    case goldenRatio = "Golden Ratio (Phi Grid)"
    case centerSymmetry = "Center Symmetry"
    case diagonalLeadingLines = "Leading Lines"

    public var id: String { rawValue }

    public var shortName: String {
        switch self {
        case .ruleOfThirds: return "1/3"
        case .goldenRatio: return "Phi"
        case .centerSymmetry: return "Center"
        case .diagonalLeadingLines: return "Lines"
        }
    }

    public var description: String {
        switch self {
        case .ruleOfThirds:
            return "Places key elements along vertical and horizontal 1/3 grid lines for classic aesthetic balance."
        case .goldenRatio:
            return "Aligns focal anchors with the 0.382 / 0.618 divine proportion for organic harmony."
        case .centerSymmetry:
            return "Emphasizes powerful, stable central focal points with bilateral visual symmetry."
        case .diagonalLeadingLines:
            return "Guides the viewer's eye along diagonal perspective vectors directly into the subject."
        }
    }

    public var canonicalGridPoints: [CGPoint] {
        switch self {
        case .ruleOfThirds:
            return [
                CGPoint(x: 1.0 / 3.0, y: 1.0 / 3.0),
                CGPoint(x: 2.0 / 3.0, y: 1.0 / 3.0),
                CGPoint(x: 1.0 / 3.0, y: 2.0 / 3.0),
                CGPoint(x: 2.0 / 3.0, y: 2.0 / 3.0)
            ]
        case .goldenRatio:
            let phiInv = 0.6180339887
            let phiComp = 0.3819660113
            return [
                CGPoint(x: phiComp, y: phiComp),
                CGPoint(x: phiInv, y: phiComp),
                CGPoint(x: phiComp, y: phiInv),
                CGPoint(x: phiInv, y: phiInv)
            ]
        case .centerSymmetry:
            return [CGPoint(x: 0.5, y: 0.5)]
        case .diagonalLeadingLines:
            return [
                CGPoint(x: 0.35, y: 0.40),
                CGPoint(x: 0.65, y: 0.40),
                CGPoint(x: 0.50, y: 0.45)
            ]
        }
    }
}

// MARK: - Scene Classification

public enum DetectedSceneType: String, CaseIterable, Sendable {
    case portrait = "Portrait"
    case landscape = "Landscape"
    case street = "Street"
    case architecture = "Architecture"
    case food = "Food"
    case night = "Night"
    case general = "General"

    public var optimalHeadroomMargin: ClosedRange<Double> {
        switch self {
        case .portrait: return 0.10...0.18
        case .street: return 0.12...0.22
        case .architecture: return 0.05...0.15
        default: return 0.08...0.25
        }
    }

    public var primaryRule: CompositionRule {
        switch self {
        case .portrait: return .goldenRatio
        case .landscape: return .ruleOfThirds
        case .architecture: return .centerSymmetry
        case .street: return .diagonalLeadingLines
        case .food: return .ruleOfThirds
        case .night: return .centerSymmetry
        case .general: return .ruleOfThirds
        }
    }
}

// MARK: - Composition Hypothesis

public struct CompositionHypothesis: Identifiable, Sendable {
    public let id: UUID
    public let rule: CompositionRule
    public let gridPoint: CGPoint        // P_grid
    public let anchorPoint: CGPoint      // S_anchor (subject anchor in current frame)
    public let targetPoint: CGPoint      // P_target (aim reticle point to guide user)
    public let score: Double             // Overall composite score [0.0 ... 1.0]
    public let lookingRoomBonus: Double  // Bonus applied for gaze direction clearance
    public let headroomFit: Double       // Evaluation of top headroom fit
    public let visualBalanceScore: Double // Horizon and peripheral visual balance
    public let rationale: String         // Explanation of why this hypothesis was scored

    public init(
        id: UUID = UUID(),
        rule: CompositionRule,
        gridPoint: CGPoint,
        anchorPoint: CGPoint,
        targetPoint: CGPoint,
        score: Double,
        lookingRoomBonus: Double = 0.0,
        headroomFit: Double = 0.0,
        visualBalanceScore: Double = 0.0,
        rationale: String = ""
    ) {
        self.id = id
        self.rule = rule
        self.gridPoint = gridPoint
        self.anchorPoint = anchorPoint
        self.targetPoint = targetPoint
        self.score = score
        self.lookingRoomBonus = lookingRoomBonus
        self.headroomFit = headroomFit
        self.visualBalanceScore = visualBalanceScore
        self.rationale = rationale
    }
}

// MARK: - Framing Target Result

public struct FramingTargetResult: Sendable {
    public let targetPoint: CGPoint          // Normalized [0, 1] target aim reticle point
    public let anchorPoint: CGPoint          // Normalized [0, 1] tracked subject anchor point
    public let bestRule: CompositionRule
    public let confidence: Double
    public let suggestedZoomFactor: CGFloat
    public let sceneType: DetectedSceneType
    public let hypotheses: [CompositionHypothesis]
    public let timestamp: TimeInterval

    public init(
        targetPoint: CGPoint,
        anchorPoint: CGPoint,
        bestRule: CompositionRule,
        confidence: Double,
        suggestedZoomFactor: CGFloat = 1.0,
        sceneType: DetectedSceneType = .general,
        hypotheses: [CompositionHypothesis] = [],
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        self.targetPoint = targetPoint
        self.anchorPoint = anchorPoint
        self.bestRule = bestRule
        self.confidence = confidence
        self.suggestedZoomFactor = suggestedZoomFactor
        self.sceneType = sceneType
        self.hypotheses = hypotheses
        self.timestamp = timestamp
    }
}

// MARK: - Camera Calibration & Tracking Context

public struct CameraIntrinsicsCalibration: Sendable {
    public let fx: Double
    public let fy: Double
    public let cx: Double
    public let cy: Double
    public let imageSize: CGSize

    public init(fx: Double, fy: Double, cx: Double, cy: Double, imageSize: CGSize) {
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.imageSize = imageSize
    }

    public static var standardIPhoneWide: CameraIntrinsicsCalibration {
        CameraIntrinsicsCalibration(
            fx: 1450.0,
            fy: 1450.0,
            cx: 960.0,
            cy: 540.0,
            imageSize: CGSize(width: 1920, height: 1080)
        )
    }
}

public struct TrackingFrameContext: Sendable {
    public let timestamp: TimeInterval
    public let displayZoom: CGFloat
    public let calibration: CameraIntrinsicsCalibration
    public let orientation: CGImagePropertyOrientation

    public init(
        timestamp: TimeInterval,
        displayZoom: CGFloat,
        calibration: CameraIntrinsicsCalibration,
        orientation: CGImagePropertyOrientation = .up
    ) {
        self.timestamp = timestamp
        self.displayZoom = displayZoom
        self.calibration = calibration
        self.orientation = orientation
    }
}

// MARK: - 3D Tracking Projection & State

public struct TrackingProjection: Sendable {
    public let point: CGPoint
    public let isInFront: Bool
    public let isInsideImage: Bool
    public let distanceFromCenter: CGFloat

    public init(point: CGPoint, isInFront: Bool, isInsideImage: Bool, distanceFromCenter: CGFloat) {
        self.point = point
        self.isInFront = isInFront
        self.isInsideImage = isInsideImage
        self.distanceFromCenter = distanceFromCenter
    }
}

public enum TrackingQuality: String, Sendable {
    case locked = "Locked"
    case predicting = "Predicting"
    case reacquiring = "Reacquiring"
    case lost = "Lost"

    public var isStable: Bool {
        self == .locked || self == .predicting
    }
}

public enum TrackingOpticalEvidence: Sendable {
    case geometryContinuation
    case verifiedContinuation
    case confirmedContinuation
    case reidentified

    public var gateThresholdSquared: Double {
        switch self {
        case .geometryContinuation: return 25.0
        case .verifiedContinuation: return 64.0
        case .confirmedContinuation: return 144.0
        case .reidentified: return 196.0
        }
    }
}

// MARK: - Tracked Entity Representation

public struct TrackedEntity: Identifiable, Sendable {
    public enum EntityType: String, Sendable {
        case face = "Face"
        case humanBody = "Person"
        case genericObject = "Object"
    }

    public let id: UUID
    public var boundingBox: CGRect       // Normalized [0, 1] in Vision coordinates (bottom-left origin)
    public var confidence: Float
    public var entityType: EntityType
    public var gazeVector: CGVector?     // Estimated 2D gaze/yaw vector if detected
    public var anchorPoint: CGPoint      // Key feature anchor (e.g. eye center or torso center)
    public var isPinned: Bool

    public init(
        id: UUID = UUID(),
        boundingBox: CGRect,
        confidence: Float,
        entityType: EntityType = .genericObject,
        gazeVector: CGVector? = nil,
        anchorPoint: CGPoint? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.entityType = entityType
        self.gazeVector = gazeVector
        self.anchorPoint = anchorPoint ?? CGPoint(x: boundingBox.midX, y: boundingBox.midY)
        self.isPinned = isPinned
    }
}

// MARK: - Exposure Region

public struct SmartExposureRegion: Sendable {
    public let rect: CGRect
    public let targetBias: Float
    public let confidence: Float

    public init(rect: CGRect, targetBias: Float, confidence: Float) {
        self.rect = rect
        self.targetBias = targetBias
        self.confidence = confidence
    }
}
