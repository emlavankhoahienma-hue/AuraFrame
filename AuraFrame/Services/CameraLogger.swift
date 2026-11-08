import Foundation
import os

public final class CameraLogger: Sendable {
    public static let shared = CameraLogger()

    private let subsystem = "com.auraframe.camera"

    public let camera: Logger
    public let tracking: Logger
    public let composition: Logger
    public let motion: Logger

    private init() {
        self.camera = Logger(subsystem: subsystem, category: "Camera")
        self.tracking = Logger(subsystem: subsystem, category: "Tracking")
        self.composition = Logger(subsystem: subsystem, category: "Composition")
        self.motion = Logger(subsystem: subsystem, category: "Motion")
    }

    public func logCamera(_ message: String) {
        camera.info("🎥 \(message, privacy: .public)")
    }

    public func logTracking(_ message: String) {
        tracking.info("🎯 \(message, privacy: .public)")
    }

    public func logComposition(_ message: String) {
        composition.info("📐 \(message, privacy: .public)")
    }

    public func logMotion(_ message: String) {
        motion.info("🧭 \(message, privacy: .public)")
    }

    public func logError(_ category: String, error: Error) {
        camera.error("❌ [\(category, privacy: .public)] Error: \(error.localizedDescription, privacy: .public)")
    }
}
