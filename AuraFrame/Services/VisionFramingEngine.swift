import Foundation
import CoreGraphics
import CoreVideo
import Vision

public final class VisionFramingEngine: @unchecked Sendable {
    public static let shared = VisionFramingEngine()

    private let sequenceHandler = VNSequenceRequestHandler()
    private let visionQueue = DispatchQueue(label: "com.auraframe.visionTracking", qos: .userInitiated)

    private var activeTrackRequest: VNTrackObjectRequest?
    private var isTracking = false
    private var lastProcessTime: TimeInterval = 0.0
    private let targetFpsInterval: TimeInterval = 1.0 / 24.0 // 24 FPS optical rate

    // Re-ID state
    private var consecutiveLostFrames = 0
    private var lastSaliencyCheckTime: TimeInterval = 0.0

    private init() {}

    // MARK: - Tracking Initialization

    public func startTracking(
        initialBoundingBox: CGRect, // Vision coordinates [0, 1]
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .up
    ) {
        visionQueue.async { [weak self] in
            guard let self = self else { return }

            let observation = VNDetectedObjectObservation(boundingBox: initialBoundingBox)
            let trackRequest = VNTrackObjectRequest(detectedObjectObservation: observation)
            trackRequest.trackingLevel = .accurate

            self.activeTrackRequest = trackRequest
            self.isTracking = true
            self.consecutiveLostFrames = 0

            // Extract initial neural featureprint for Re-ID fallback
            self.extractFeaturePrint(from: pixelBuffer, boundingBox: initialBoundingBox, orientation: orientation)

            CameraLogger.shared.logTracking("Vision optical tracking started with box \(initialBoundingBox).")
        }
    }

    public func stopTracking() {
        visionQueue.async { [weak self] in
            guard let self = self else { return }
            self.isTracking = false
            self.activeTrackRequest = nil
            self.consecutiveLostFrames = 0
            NeuralTargetTracker.shared.reset()
            CameraLogger.shared.logTracking("Vision optical tracking stopped.")
        }
    }

    // MARK: - Frame Processing (24 FPS rate-limited)

    public func processFrame(
        pixelBuffer: CVPixelBuffer,
        timestamp: TimeInterval,
        orientation: CGImagePropertyOrientation = .up
    ) {
        visionQueue.async { [weak self] in
            guard let self = self, self.isTracking, let trackRequest = self.activeTrackRequest else {
                return
            }

            // Rate-limit optical analysis to ~24 FPS
            guard timestamp - self.lastProcessTime >= self.targetFpsInterval else {
                return
            }
            self.lastProcessTime = timestamp

            do {
                try self.sequenceHandler.perform([trackRequest], on: pixelBuffer, orientation: orientation)

                guard let results = trackRequest.results as? [VNDetectedObjectObservation],
                      let observation = results.first,
                      observation.confidence > 0.35 else {
                    self.handleLostTarget(pixelBuffer: pixelBuffer, timestamp: timestamp, orientation: orientation)
                    return
                }

                // Successful optical track
                self.consecutiveLostFrames = 0
                let currentBox = observation.boundingBox
                NeuralTargetTracker.shared.updateLastKnownBox(currentBox)

                // Refine anchor with eyes if face is present
                let anchor = self.refineAnchorPoint(in: pixelBuffer, box: currentBox, orientation: orientation)

                // Map Vision coordinate (origin bottom-left) to UI coordinate (origin top-left)
                let uiAnchor = TrackingGeometry.shared.visionToUICoordinate(anchor)

                let evidence: TrackingOpticalEvidence = observation.confidence > 0.75 ? .confirmedContinuation : .verifiedContinuation
                SpatialTrackingEngine.shared.incorporateVisionObservation(
                    observedSubjectPoint: uiAnchor,
                    evidence: evidence,
                    confidence: Double(observation.confidence),
                    timestamp: timestamp
                )

            } catch {
                CameraLogger.shared.logError("VisionTrack", error: error)
                self.handleLostTarget(pixelBuffer: pixelBuffer, timestamp: timestamp, orientation: orientation)
            }
        }
    }

    // MARK: - Two-Tier Re-ID Engine

    private func handleLostTarget(
        pixelBuffer: CVPixelBuffer,
        timestamp: TimeInterval,
        orientation: CGImagePropertyOrientation
    ) {
        consecutiveLostFrames += 1

        // Tier 1: Fast Saliency Scan (~7 Hz)
        if timestamp - lastSaliencyCheckTime > (1.0 / 7.0) {
            lastSaliencyCheckTime = timestamp
            performFastSaliencyScan(pixelBuffer: pixelBuffer, timestamp: timestamp, orientation: orientation)
        }

        // Tier 2: Neural FeaturePrint Grid Search if lost > 4 consecutive optical frames
        if consecutiveLostFrames > 4 {
            performNeuralGridSearch(pixelBuffer: pixelBuffer, timestamp: timestamp, orientation: orientation)
        }
    }

    private func performFastSaliencyScan(
        pixelBuffer: CVPixelBuffer,
        timestamp: TimeInterval,
        orientation: CGImagePropertyOrientation
    ) {
        let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])

        do {
            try handler.perform([saliencyRequest])
            guard let saliencyObservation = saliencyRequest.results?.first as? VNSaliencyImageObservation,
                  let salientObjects = saliencyObservation.salientObjects else {
                return
            }

            let lastBox = NeuralTargetTracker.shared.lastKnownBox
            let predictedSubjectPoint = SpatialTrackingEngine.shared.projectedSubjectPoint
            let visionPredicted = TrackingGeometry.shared.uiToVisionCoordinate(predictedSubjectPoint)

            for object in salientObjects {
                let box = object.boundingBox
                let distToBearing = hypot(box.midX - visionPredicted.x, box.midY - visionPredicted.y)
                let distToLastBox = hypot(box.midX - lastBox.midX, box.midY - lastBox.midY)

                if distToBearing <= 0.28 || distToLastBox <= 0.25 {
                    // Re-lock target via Saliency
                    reinitializeTracking(with: box, confidence: object.confidence, timestamp: timestamp)
                    return
                }
            }
        } catch {
            CameraLogger.shared.logError("SaliencyScan", error: error)
        }
    }

    private func performNeuralGridSearch(
        pixelBuffer: CVPixelBuffer,
        timestamp: TimeInterval,
        orientation: CGImagePropertyOrientation
    ) {
        let lastBox = NeuralTargetTracker.shared.lastKnownBox
        let predictedSubjectPoint = SpatialTrackingEngine.shared.projectedSubjectPoint
        let visionPredicted = TrackingGeometry.shared.uiToVisionCoordinate(predictedSubjectPoint)

        let gridSteps = 5
        let patchWidth: CGFloat = 0.25
        let patchHeight: CGFloat = 0.25

        var bestMatchBox: CGRect?
        var minDistance: Float = 0.45 // Cosine distance threshold for VNFeaturePrint

        for row in 0..<gridSteps {
            for col in 0..<gridSteps {
                let x = CGFloat(col) * (1.0 - patchWidth) / CGFloat(gridSteps - 1)
                let y = CGFloat(row) * (1.0 - patchHeight) / CGFloat(gridSteps - 1)
                let candidateBox = CGRect(x: x, y: y, width: patchWidth, height: patchHeight)

                let distToBearing = hypot(candidateBox.midX - visionPredicted.x, candidateBox.midY - visionPredicted.y)
                let distToLast = hypot(candidateBox.midX - lastBox.midX, candidateBox.midY - lastBox.midY)

                if distToBearing <= 0.35 || distToLast <= 0.35 {
                    let featureRequest = VNGenerateImageFeaturePrintRequest()
                    featureRequest.regionOfInterest = candidateBox
                    let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])

                    if (try? handler.perform([featureRequest])) != nil,
                       let featObs = featureRequest.results?.first as? VNFeaturePrintObservation,
                       let dist = NeuralTargetTracker.shared.computeFeatureDistance(candidate: featObs) {
                        if dist < minDistance {
                            minDistance = dist
                            bestMatchBox = candidateBox
                        }
                    }
                }
            }
        }

        if let recoveredBox = bestMatchBox {
            CameraLogger.shared.logTracking("Tier 2 Neural Re-ID succeeded with feature distance: \(minDistance).")
            reinitializeTracking(with: recoveredBox, confidence: Float(1.0 - minDistance), timestamp: timestamp)
        }
    }

    private func reinitializeTracking(with box: CGRect, confidence: Float, timestamp: TimeInterval) {
        let newObservation = VNDetectedObjectObservation(boundingBox: box)
        let newTrackRequest = VNTrackObjectRequest(detectedObjectObservation: newObservation)
        newTrackRequest.trackingLevel = .accurate

        self.activeTrackRequest = newTrackRequest
        self.consecutiveLostFrames = 0
        NeuralTargetTracker.shared.updateLastKnownBox(box)

        let center = CGPoint(x: box.midX, y: box.midY)
        let uiCenter = TrackingGeometry.shared.visionToUICoordinate(center)

        SpatialTrackingEngine.shared.incorporateVisionObservation(
            observedSubjectPoint: uiCenter,
            evidence: .reidentified,
            confidence: Double(confidence),
            timestamp: timestamp
        )
    }

    // MARK: - Anchor Refinement

    private func refineAnchorPoint(
        in pixelBuffer: CVPixelBuffer,
        box: CGRect,
        orientation: CGImagePropertyOrientation
    ) -> CGPoint {
        let faceRequest = VNDetectFaceLandmarksRequest()
        faceRequest.regionOfInterest = box
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])

        if (try? handler.perform([faceRequest])) != nil,
           let face = faceRequest.results?.first,
           let landmarks = face.landmarks,
           let leftEye = landmarks.leftEye?.normalizedPoints,
           let rightEye = landmarks.rightEye?.normalizedPoints,
           !leftEye.isEmpty && !rightEye.isEmpty {
            let leftAvg = leftEye.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            let rightAvg = rightEye.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }

            let leftEyeCenter = CGPoint(
                x: box.minX + (leftAvg.x / CGFloat(leftEye.count)) * box.width,
                y: box.minY + (leftAvg.y / CGFloat(leftEye.count)) * box.height
            )
            let rightEyeCenter = CGPoint(
                x: box.minX + (rightAvg.x / CGFloat(rightEye.count)) * box.width,
                y: box.minY + (rightAvg.y / CGFloat(rightEye.count)) * box.height
            )

            return CGPoint(
                x: (leftEyeCenter.x + rightEyeCenter.x) * 0.5,
                y: (leftEyeCenter.y + rightEyeCenter.y) * 0.5
            )
        }

        return CGPoint(x: box.midX, y: box.midY)
    }

    private func extractFeaturePrint(
        from pixelBuffer: CVPixelBuffer,
        boundingBox: CGRect,
        orientation: CGImagePropertyOrientation
    ) {
        let request = VNGenerateImageFeaturePrintRequest()
        request.regionOfInterest = boundingBox
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])

        do {
            try handler.perform([request])
            if let featObs = request.results?.first as? VNFeaturePrintObservation {
                NeuralTargetTracker.shared.registerTarget(
                    featurePrint: featObs,
                    histogram: [Float](repeating: 1.0 / 16.0, count: 16),
                    boundingBox: boundingBox
                )
            }
        } catch {
            CameraLogger.shared.logError("FeaturePrintInit", error: error)
        }
    }
}
