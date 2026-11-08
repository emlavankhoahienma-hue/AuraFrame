import Foundation
import CoreGraphics
import Vision
import Accelerate

public final class NeuralTargetTracker: @unchecked Sendable {
    public static let shared = NeuralTargetTracker()

    private var targetFeaturePrint: VNFeaturePrintObservation?
    private var targetColorHistogram: [Float] = []
    private var lastValidBox: CGRect = .zero
    private let trackerLock = NSLock()

    private init() {}

    public func reset() {
        trackerLock.lock()
        defer { trackerLock.unlock() }
        targetFeaturePrint = nil
        targetColorHistogram.removeAll()
        lastValidBox = .zero
    }

    public func registerTarget(
        featurePrint: VNFeaturePrintObservation?,
        histogram: [Float],
        boundingBox: CGRect
    ) {
        trackerLock.lock()
        defer { trackerLock.unlock() }
        self.targetFeaturePrint = featurePrint
        self.targetColorHistogram = histogram
        self.lastValidBox = boundingBox
    }

    public func computeFeatureDistance(candidate: VNFeaturePrintObservation) -> Float? {
        trackerLock.lock()
        guard let target = targetFeaturePrint else {
            trackerLock.unlock()
            return nil
        }
        trackerLock.unlock()

        var distance: Float = 0.0
        do {
            try candidate.computeDistance(&distance, to: target)
            return distance
        } catch {
            return nil
        }
    }

    public func computeHistogramSimilarity(candidateHistogram: [Float]) -> Float {
        trackerLock.lock()
        guard !targetColorHistogram.isEmpty, candidateHistogram.count == targetColorHistogram.count else {
            trackerLock.unlock()
            return 0.5
        }
        let targetHist = targetColorHistogram
        trackerLock.unlock()

        // Bhattacharyya distance / coefficient
        var bhattacharyya: Float = 0.0
        for i in 0..<min(targetHist.count, candidateHistogram.count) {
            bhattacharyya += sqrt(targetHist[i] * candidateHistogram[i])
        }

        return max(0.0, min(1.0, bhattacharyya))
    }

    public var lastKnownBox: CGRect {
        trackerLock.lock()
        defer { trackerLock.unlock() }
        return lastValidBox
    }

    public func updateLastKnownBox(_ box: CGRect) {
        trackerLock.lock()
        defer { trackerLock.unlock() }
        self.lastValidBox = box
    }
}
