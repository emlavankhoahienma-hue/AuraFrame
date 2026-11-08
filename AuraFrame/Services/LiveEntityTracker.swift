import Foundation
import CoreGraphics
import CoreVideo
import Vision

public final class LiveEntityTracker: @unchecked Sendable {
    public static let shared = LiveEntityTracker()

    private let sequenceHandler = VNSequenceRequestHandler()
    private let detectionQueue = DispatchQueue(label: "com.auraframe.entityDetection", qos: .userInitiated)

    private init() {}

    /// Detects human faces, eye landmarks, gaze vectors, and bodies in the pixel buffer
    public func detectEntities(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .up,
        completion: @escaping ([TrackedEntity]) -> Void
    ) {
        detectionQueue.async { [weak self] in
            guard let self = self else { return }

            var detectedEntities: [TrackedEntity] = []

            let faceRequest = VNDetectFaceLandmarksRequest()
            let bodyRequest = VNDetectHumanBodyPoseRequest()

            let requests: [VNRequest] = [faceRequest, bodyRequest]

            do {
                try self.sequenceHandler.perform(requests, on: pixelBuffer, orientation: orientation)

                // 1. Process Face Observations & Landmarks
                if let faceResults = faceRequest.results {
                    for face in faceResults {
                        let box = face.boundingBox
                        var gazeVector: CGVector?
                        var eyeAnchor: CGPoint?

                        if let landmarks = face.landmarks {
                            let leftEye = landmarks.leftEye?.normalizedPoints ?? []
                            let rightEye = landmarks.rightEye?.normalizedPoints ?? []
                            let nose = landmarks.nose?.normalizedPoints ?? []

                            if !leftEye.isEmpty && !rightEye.isEmpty {
                                // Compute midpoint of eyes in Vision coordinates
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

                                eyeAnchor = CGPoint(
                                    x: (leftEyeCenter.x + rightEyeCenter.x) * 0.5,
                                    y: (leftEyeCenter.y + rightEyeCenter.y) * 0.5
                                )

                                // Estimate 2D gaze/yaw from face roll and nose offset
                                if let nosePoint = nose.first {
                                    let nosePos = CGPoint(
                                        x: box.minX + nosePoint.x * box.width,
                                        y: box.minY + nosePoint.y * box.height
                                    )
                                    let eyeMid = eyeAnchor!
                                    let dx = nosePos.x - eyeMid.x
                                    let dy = nosePos.y - eyeMid.y
                                    let len = hypot(dx, dy)
                                    if len > 1e-4 {
                                        // Gaze points in direction of nose protrusion
                                        gazeVector = CGVector(dx: dx / len, dy: dy / len)
                                    }
                                }
                            }
                        }

                        let anchor = eyeAnchor ?? CGPoint(x: box.midX, y: box.midY)
                        let entity = TrackedEntity(
                            boundingBox: box,
                            confidence: face.confidence,
                            entityType: .face,
                            gazeVector: gazeVector,
                            anchorPoint: anchor,
                            isPinned: false
                        )
                        detectedEntities.append(entity)
                    }
                }

                // 2. Process Human Body Poses
                if let bodyResults = bodyRequest.results {
                    for body in bodyResults {
                        if let recognizedPoints = try? body.recognizedPoints(.all) {
                            var minX: CGFloat = 1.0, maxX: CGFloat = 0.0
                            var minY: CGFloat = 1.0, maxY: CGFloat = 0.0
                            var validPointsCount = 0

                            for (_, pt) in recognizedPoints where pt.confidence > 0.3 {
                                minX = min(minX, pt.location.x)
                                maxX = max(maxX, pt.location.x)
                                minY = min(minY, pt.location.y)
                                maxY = max(maxY, pt.location.y)
                                validPointsCount += 1
                            }

                            if validPointsCount >= 4 && maxX > minX && maxY > minY {
                                let bodyBox = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                                // Avoid duplicate if face already covers this body
                                let isOverlappingFace = detectedEntities.contains {
                                    $0.entityType == .face && $0.boundingBox.intersects(bodyBox)
                                }

                                if !isOverlappingFace {
                                    let entity = TrackedEntity(
                                        boundingBox: bodyBox,
                                        confidence: body.confidence,
                                        entityType: .humanBody,
                                        gazeVector: nil,
                                        anchorPoint: CGPoint(x: bodyBox.midX, y: bodyBox.maxY - bodyBox.height * 0.2), // Upper chest/head
                                        isPinned: false
                                    )
                                    detectedEntities.append(entity)
                                }
                            }
                        }
                    }
                }

                completion(detectedEntities)
            } catch {
                CameraLogger.shared.logError("EntityDetection", error: error)
                completion([])
            }
        }
    }
}
