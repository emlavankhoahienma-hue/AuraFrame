import Foundation
import SwiftUI
import UIKit
import AVFoundation
import CoreMotion
import Combine

public enum AISessionState: Equatable, Sendable {
    case idle
    case analyzing
    case targetPlaced(locked: Bool)
    case alignmentPerfect
    case capturing
    case done
}

public enum CameraCaptureMode: String, CaseIterable, Identifiable, Sendable {
    case photo = "PHOTO"
    case video = "VIDEO"

    public var id: String { rawValue }
}

@MainActor
public final class CameraViewModel: NSObject, ObservableObject {
    // MARK: - Published State
    @Published public var sessionState: AISessionState = .idle
    @Published public var captureMode: CameraCaptureMode = .photo
    @Published public var detectedEntities: [TrackedEntity] = []
    @Published public var activeRule: CompositionRule = .goldenRatio
    @Published public var framingResult: FramingTargetResult?
    @Published public var guidanceInstruction: String = "Tap Subject or AI Scan"

    // Alignment and Leveler
    @Published public var isAligned: Bool = false
    @Published public var alignmentDistance: CGFloat = 1.0
    @Published public var horizonRoll: Double = 0.0
    @Published public var isHorizonLevel: Bool = false

    // Hardware Controls
    @Published public var currentZoom: CGFloat = 1.0
    @Published public var exposureBias: Float = 0.0
    @Published public var isRecordingVideo: Bool = false
    @Published public var recordingDuration: TimeInterval = 0.0
    @Published public var capturedThumbnail: UIImage?

    // Settings
    @Published public var autoCaptureEnabled: Bool = false
    @Published public var isCameraHibernating: Bool = false

    // Services
    public let cameraService = CameraService.shared
    public let motionService = DeviceMotionService.shared
    public let spatialEngine = SpatialTrackingEngine.shared
    public let visionEngine = VisionFramingEngine.shared
    public let entityTracker = LiveEntityTracker.shared

    // Subscriptions & Timers
    private var cancellables = Set<AnyCancellable>()
    private var alignmentTimer: Date?
    private var recordingTimer: Timer?
    private var lastAnalysisTimestamp: TimeInterval = 0.0

    // Cached Calibration & Buffer
    private var latestCalibration: CameraIntrinsicsCalibration = .standardIPhoneWide
    private var latestPixelBuffer: CVPixelBuffer?

    public override init() {
        super.init()
        setupBindings()
    }

    // MARK: - Bindings & Subscriptions

    private func setupBindings() {
        cameraService.delegate = self

        // Motion subscriptions
        motionService.$currentRoll
            .receive(on: DispatchQueue.main)
            .sink { [weak self] roll in
                self?.horizonRoll = roll
            }
            .store(in: &cancellables)

        motionService.$isLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLvl in
                self?.isHorizonLevel = isLvl
            }
            .store(in: &cancellables)

        // Camera Service properties
        cameraService.$currentZoomFactor
            .receive(on: DispatchQueue.main)
            .sink { [weak self] zoom in
                self?.currentZoom = zoom
            }
            .store(in: &cancellables)

        cameraService.$exposureBias
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bias in
                self?.exposureBias = bias
            }
            .store(in: &cancellables)

        cameraService.$isRecordingVideo
            .receive(on: DispatchQueue.main)
            .sink { [weak self] recording in
                self?.isRecordingVideo = recording
            }
            .store(in: &cancellables)

        // Spatial Engine tracking state
        spatialEngine.$projectedTargetPoint
            .receive(on: DispatchQueue.main)
            .sink { [weak self] targetPoint in
                self?.evaluateAlignment(targetPoint: targetPoint)
            }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    public func startCamera() {
        isCameraHibernating = false
        motionService.startMotionUpdates()
        cameraService.configureSession { [weak self] success in
            if success {
                self?.cameraService.startSession()
            }
        }
    }

    public func stopCamera() {
        isCameraHibernating = true
        motionService.stopMotionUpdates()
        cameraService.stopSession()
        spatialEngine.stopTracking()
        visionEngine.stopTracking()
    }

    // MARK: - AI Scan & Composition Analysis

    public func triggerAIScan() {
        guard sessionState != .capturing, !isCameraHibernating else { return }

        sessionState = .analyzing
        guidanceInstruction = "Scanning scene & subjects..."
        HapticFeedbackService.shared.prepare()

        guard let buffer = latestPixelBuffer else {
            // If no frame yet, cancel scan
            sessionState = .idle
            guidanceInstruction = "Point camera at subject"
            return
        }

        // Detect entities in scene
        entityTracker.detectEntities(in: buffer) { [weak self] entities in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.detectedEntities = entities

                if let primary = entities.first {
                    self.finishLocalAnalysis(with: primary)
                } else {
                    // Fallback to center frame
                    let centerBox = CGRect(x: 0.35, y: 0.35, width: 0.30, height: 0.30)
                    let fallbackEntity = TrackedEntity(
                        boundingBox: centerBox,
                        confidence: 0.7,
                        entityType: .genericObject,
                        anchorPoint: CGPoint(x: 0.5, y: 0.5)
                    )
                    self.finishLocalAnalysis(with: fallbackEntity)
                }
            }
        }
    }

    public func finishLocalAnalysis(with primaryEntity: TrackedEntity) {
        let result = CompositionCalculator.shared.calculateOptimalFraming(
            primaryEntity: primaryEntity,
            detectedScene: .portrait,
            activeRuleOverride: activeRule
        )

        self.framingResult = result
        self.activeRule = result.bestRule

        // Tap-to-Track / Pin Target Anchor
        pinTargetAndStartMotion(
            trackedPoint: result.anchorPoint,
            aimPoint: result.targetPoint,
            boundingBox: primaryEntity.boundingBox,
            suggestedZoom: result.suggestedZoomFactor
        )
    }

    // MARK: - Pin Target & Start Handheld Spatial Tracking

    public func pinTargetAndStartMotion(
        trackedPoint: CGPoint,
        aimPoint: CGPoint,
        boundingBox: CGRect,
        suggestedZoom: CGFloat
    ) {
        guard sessionState != .capturing, !isCameraHibernating else { return }

        let timestamp = ProcessInfo.processInfo.systemUptime

        // 1. Start 3D Spatial Tracking Engine
        spatialEngine.startTracking(
            subjectPoint: trackedPoint,
            targetPoint: aimPoint,
            calibration: latestCalibration,
            zoomFactor: currentZoom,
            timestamp: timestamp
        )

        // 2. Start Optical Vision Tracker
        if let buffer = latestPixelBuffer {
            visionEngine.startTracking(
                initialBoundingBox: boundingBox,
                pixelBuffer: buffer,
                orientation: .up
            )
        }

        // 3. Trigger optical zoom ramping if recommended
        if abs(suggestedZoom - currentZoom) > 0.4 {
            cameraService.rampZoom(to: suggestedZoom, rate: 3.5)
        }

        // 4. Update UI State & Haptic
        sessionState = .targetPlaced(locked: true)
        HapticFeedbackService.shared.targetLocked()
        guidanceInstruction = "Align reticle to center"
    }

    // MARK: - Tap to Track

    public func handleTapToTrack(at normalizedTapPoint: CGPoint) {
        guard sessionState != .capturing, !isCameraHibernating else { return }

        // Find entity containing point or create one
        let visionTap = TrackingGeometry.shared.uiToVisionCoordinate(normalizedTapPoint)
        let tappedEntity = detectedEntities.first { $0.boundingBox.contains(visionTap) }

        let box = tappedEntity?.boundingBox ?? CGRect(
            x: max(0.05, visionTap.x - 0.15),
            y: max(0.05, visionTap.y - 0.15),
            width: 0.30,
            height: 0.30
        )

        let entity = TrackedEntity(
            boundingBox: box,
            confidence: 0.9,
            entityType: tappedEntity?.entityType ?? .genericObject,
            anchorPoint: visionTap
        )

        finishLocalAnalysis(with: entity)
    }

    // MARK: - Alignment Gate & Smart Auto-Capture

    private func evaluateAlignment(targetPoint: CGPoint) {
        guard case .targetPlaced = sessionState, spatialEngine.isTrackingActive else {
            return
        }

        let trajectory = CompositionPlanning.shared.planTrajectory(currentAimPoint: targetPoint)
        self.alignmentDistance = trajectory.distance
        self.guidanceInstruction = trajectory.instruction

        if trajectory.isWithinAlignmentGate {
            if alignmentTimer == nil {
                alignmentTimer = Date()
            } else if let start = alignmentTimer, Date().timeIntervalSince(start) >= 0.120 { // 120ms stable hold
                // Gate passed! Perfect alignment achieved
                sessionState = .alignmentPerfect
                isAligned = true
                HapticFeedbackService.shared.alignmentPerfect()

                if autoCaptureEnabled && captureMode == .photo {
                    triggerShutter()
                }
            }
        } else {
            alignmentTimer = nil
            isAligned = false
            if sessionState == .alignmentPerfect {
                sessionState = .targetPlaced(locked: true)
            }
        }
    }

    // MARK: - Shutter & Exposure Actions

    public func triggerShutter() {
        guard sessionState != .capturing else { return }

        if captureMode == .photo {
            sessionState = .capturing
            HapticFeedbackService.shared.shutterFired()
            cameraService.capturePhoto()
        } else {
            // Video mode toggle
            if isRecordingVideo {
                cameraService.stopVideoRecording()
                stopRecordingTimer()
                HapticFeedbackService.shared.shutterFired()
            } else {
                cameraService.startVideoRecording()
                startRecordingTimer()
                HapticFeedbackService.shared.shutterFired()
            }
        }
    }

    public func setExposureBias(_ bias: Float) {
        cameraService.setExposureTargetBias(bias)
    }

    public func selectRule(_ rule: CompositionRule) {
        self.activeRule = rule
        HapticFeedbackService.shared.ruleChanged()

        // Recompute framing if target is active
        if let primary = detectedEntities.first {
            finishLocalAnalysis(with: primary)
        }
    }

    public func selectLensZoom(_ zoom: CGFloat) {
        cameraService.rampZoom(to: zoom, rate: 5.0)
        HapticFeedbackService.shared.modeSwitched()
    }

    // MARK: - Video Timer

    private func startRecordingTimer() {
        recordingDuration = 0.0
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recordingDuration += 1.0
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingDuration = 0.0
    }
}

// MARK: - CameraServiceDelegate

extension CameraViewModel: CameraServiceDelegate {
    public nonisolated func cameraService(
        _ service: CameraService,
        didOutput sampleBuffer: CMSampleBuffer,
        intrinsics: CameraIntrinsicsCalibration?
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds

        Task { @MainActor [weak self] in
            guard let self = self, !self.isCameraHibernating else { return }

            self.latestPixelBuffer = pixelBuffer
            if let calib = intrinsics {
                self.latestCalibration = calib
            }

            // 1. Update 3D Spatial Tracking Pose at 60 FPS
            self.spatialEngine.updateDevicePose(
                timestamp: timestamp,
                zoomFactor: self.currentZoom,
                calibration: intrinsics
            )

            // 2. Feed Optical Tracker at 24 FPS (both photo and video modes)
            if self.spatialEngine.isTrackingActive {
                self.visionEngine.processFrame(
                    pixelBuffer: pixelBuffer,
                    timestamp: timestamp,
                    orientation: .up
                )
            }
        }
    }

    public nonisolated func cameraService(_ service: CameraService, didCapturePhoto image: UIImage) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.capturedThumbnail = image
            self.sessionState = .done

            // Save to Photo Library
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)

            // Reset back to idle after 1.5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.sessionState = .idle
                self.guidanceInstruction = "Ready for next shot"
            }
        }
    }

    public nonisolated func cameraService(_ service: CameraService, didFinishRecordingVideoAt url: URL) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.guidanceInstruction = "Video saved to Photos"

            // Save video to library
            UISaveVideoAtPathToSavedPhotosAlbum(url.path, nil, nil, nil)
        }
    }
}
