import Foundation
import CoreVideo
import CoreGraphics
import Accelerate

public final class SmartSceneExposureEngine: Sendable {
    public static let shared = SmartSceneExposureEngine()

    private init() {}

    /// Analyzes the subject region against the surrounding background to calculate optimal EV exposure bias
    public func computeSmartExposureBias(
        pixelBuffer: CVPixelBuffer,
        subjectRect: CGRect,
        currentBias: Float
    ) -> SmartExposureRegion {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return SmartExposureRegion(rect: subjectRect, targetBias: currentBias, confidence: 0.0)
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        // Map normalized subject rect to pixel coordinates
        let minX = max(0, min(width - 1, Int(subjectRect.minX * CGFloat(width))))
        let maxX = max(minX + 1, min(width, Int(subjectRect.maxX * CGFloat(width))))
        let minY = max(0, min(height - 1, Int((1.0 - subjectRect.maxY) * CGFloat(height))))
        let maxY = max(minY + 1, min(height, Int((1.0 - subjectRect.minY) * CGFloat(height))))

        let step = 8 // Subsample for fast real-time analysis
        var subjectLumaSum: Double = 0.0
        var subjectCount: Int = 0

        var bgLumaSum: Double = 0.0
        var bgCount: Int = 0

        let bufferPtr = baseAddress.assumingMemoryBound(to: UInt8.self)

        // 1. Compute average luminance of subject and background
        for y in stride(from: 0, to: height, by: step) {
            let rowOffset = y * bytesPerRow
            for x in stride(from: 0, to: width, by: step) {
                let pixelOffset = rowOffset + x * 4
                // BGRA format: byte 0 = B, 1 = G, 2 = R
                let b = Double(bufferPtr[pixelOffset])
                let g = Double(bufferPtr[pixelOffset + 1])
                let r = Double(bufferPtr[pixelOffset + 2])
                // Rec. 709 luma standard
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b

                if x >= minX && x < maxX && y >= minY && y < maxY {
                    subjectLumaSum += luma
                    subjectCount += 1
                } else {
                    bgLumaSum += luma
                    bgCount += 1
                }
            }
        }

        guard subjectCount > 0, bgCount > 0 else {
            return SmartExposureRegion(rect: subjectRect, targetBias: currentBias, confidence: 0.5)
        }

        let avgSubjectLuma = subjectLumaSum / Double(subjectCount) // [0 ... 255]
        let avgBgLuma = bgLumaSum / Double(bgCount)                // [0 ... 255]

        // Target mid-tone subject luminance is ~118.0 (18% gray in sRGB)
        let targetLuma = 118.0
        let lumaRatio = max(1e-3, avgSubjectLuma / targetLuma)
        var recommendedEVBias = Float(-log2(lumaRatio))

        // Backlight compensation: If background is significantly brighter than subject
        let contrastRatio = avgBgLuma / max(1.0, avgSubjectLuma)
        if contrastRatio > 2.2 {
            // Strong backlight (e.g. subject in front of bright sky or sunset)
            recommendedEVBias += Float(min(1.2, (contrastRatio - 2.2) * 0.35))
        } else if contrastRatio < 0.45 {
            // Dark background (e.g. spotlight or stage photography)
            recommendedEVBias -= Float(min(0.8, (0.45 - contrastRatio) * 0.4))
        }

        // Clamp to safe EV range [-2.0 ... +2.0]
        let clampedEV = max(-2.0, min(recommendedEVBias, 2.0))
        let confidence = Float(min(1.0, Double(subjectCount) / 100.0))

        return SmartExposureRegion(
            rect: subjectRect,
            targetBias: clampedEV,
            confidence: confidence
        )
    }
}
