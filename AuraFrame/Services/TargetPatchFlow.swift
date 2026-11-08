import Foundation
import CoreVideo
import CoreGraphics
import simd
import Accelerate

public final class TargetPatchFlow: @unchecked Sendable {
    public static let shared = TargetPatchFlow()

    private var previousBuffer: CVPixelBuffer?
    private var previousTimestamp: TimeInterval = 0.0
    private var previousKeypoints: [CGPoint] = []

    private let patchRadius = 8
    private let maxIterations = 5
    private let convergenceEpsilon: Float = 0.03

    private init() {}

    public func reset() {
        previousBuffer = nil
        previousTimestamp = 0.0
        previousKeypoints.removeAll()
    }

    /// Measures optical patch shift around anchorPoint, compensating for gyro rotation
    public func estimatePatchShift(
        currentBuffer: CVPixelBuffer,
        timestamp: TimeInterval,
        anchorPoint: CGPoint, // Normalized [0, 1] UI coordinates
        gyroDeltaAngleX: Double,
        gyroDeltaAngleY: Double,
        focalLengthPixels: Double
    ) -> NTCPatchFlowResult {
        guard let prevBuffer = previousBuffer, previousTimestamp > 0 else {
            self.previousBuffer = currentBuffer
            self.previousTimestamp = timestamp
            return NTCPatchFlowResult(dx: 0, dy: 0, confidence: 1.0, inliers: 1, isReliable: true)
        }

        // Expected pixel shift from gyro rotation
        let gyroExpectedDx = Float(gyroDeltaAngleY * focalLengthPixels)
        let gyroExpectedDy = Float(-gyroDeltaAngleX * focalLengthPixels)

        CVPixelBufferLockBaseAddress(prevBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(currentBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(prevBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(currentBuffer, .readOnly)
            self.previousBuffer = currentBuffer
            self.previousTimestamp = timestamp
        }

        guard let prevBase = CVPixelBufferGetBaseAddress(prevBuffer),
              let currBase = CVPixelBufferGetBaseAddress(currentBuffer) else {
            return NTCPatchFlowResult(dx: gyroExpectedDx, dy: gyroExpectedDy, confidence: 0.5, inliers: 0, isReliable: false)
        }

        let width = CVPixelBufferGetWidth(currentBuffer)
        let height = CVPixelBufferGetHeight(currentBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(currentBuffer)

        let centerX = Int(anchorPoint.x * CGFloat(width))
        let centerY = Int(anchorPoint.y * CGFloat(height))

        guard centerX - patchRadius >= 2 && centerX + patchRadius < width - 2 &&
              centerY - patchRadius >= 2 && centerY + patchRadius < height - 2 else {
            return NTCPatchFlowResult(dx: gyroExpectedDx, dy: gyroExpectedDy, confidence: 0.3, inliers: 0, isReliable: false)
        }

        let pPrev = prevBase.assumingMemoryBound(to: UInt8.self)
        let pCurr = currBase.assumingMemoryBound(to: UInt8.self)

        // Lucas-Kanade 3-scale gradient solver around anchor
        var u = gyroExpectedDx
        var v = gyroExpectedDy

        let scales: [Int] = [4, 2, 1] // 3-level pyramid scales

        for scale in scales {
            u /= Float(scale)
            v /= Float(scale)

            for _ in 0..<maxIterations {
                var gxx: Float = 0.0
                var gyy: Float = 0.0
                var gxy: Float = 0.0
                var bx: Float = 0.0
                var by: Float = 0.0

                for dy in -patchRadius...patchRadius {
                    let y = centerY + dy * scale
                    guard y > 1 && y < height - 2 else { continue }
                    let rowOffset = y * bytesPerRow

                    for dx in -patchRadius...patchRadius {
                        let x = centerX + dx * scale
                        guard x > 1 && x < width - 2 else { continue }

                        let pxOffset = rowOffset + x * 4
                        // Grayscale approximation
                        let prevI = Float(pPrev[pxOffset + 1])

                        // Spatial gradients Ix, Iy
                        let ix = (Float(pPrev[pxOffset + 4 + 1]) - Float(pPrev[pxOffset - 4 + 1])) * 0.5
                        let iy = (Float(pPrev[pxOffset + bytesPerRow + 1]) - Float(pPrev[pxOffset - bytesPerRow + 1])) * 0.5

                        // Warped target sample
                        let targetX = min(max(1, Int(Float(x) + u * Float(scale))), width - 2)
                        let targetY = min(max(1, Int(Float(y) + v * Float(scale))), height - 2)
                        let targetOffset = targetY * bytesPerRow + targetX * 4
                        let currI = Float(pCurr[targetOffset + 1])

                        // Temporal difference It
                        let it = currI - prevI

                        gxx += ix * ix
                        gyy += iy * iy
                        gxy += ix * iy
                        bx += ix * it
                        by += iy * it
                    }
                }

                let det = gxx * gyy - gxy * gxy
                if abs(det) < 1e-4 {
                    break
                }

                let du = -(gyy * bx - gxy * by) / det
                let dv = -(gxx * by - gxy * bx) / det

                u += du
                v += dv

                if hypot(du, dv) < convergenceEpsilon {
                    break
                }
            }

            u *= Float(scale)
            v *= Float(scale)
        }

        // Compute normalized residual and inliers
        let residualMag = hypot(u - gyroExpectedDx, v - gyroExpectedDy)
        let isReliable = residualMag < 35.0
        let confidence = max(0.0, min(1.0, 1.0 - (residualMag / 40.0)))
        let inliers = isReliable ? (patchRadius * 2 + 1) * (patchRadius * 2 + 1) : 0

        return NTCPatchFlowResult(
            dx: u,
            dy: v,
            confidence: Float(confidence),
            inliers: Int32(inliers),
            isReliable: isReliable
        )
    }
}
