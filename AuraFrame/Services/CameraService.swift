import Foundation
import AVFoundation
import UIKit
import Combine

public protocol CameraServiceDelegate: AnyObject {
    func cameraService(_ service: CameraService, didOutput sampleBuffer: CMSampleBuffer, intrinsics: CameraIntrinsicsCalibration?)
    func cameraService(_ service: CameraService, didCapturePhoto image: UIImage)
    func cameraService(_ service: CameraService, didFinishRecordingVideoAt url: URL)
}

public final class CameraService: NSObject, ObservableObject, @unchecked Sendable {
    public static let shared = CameraService()

    public weak var delegate: CameraServiceDelegate?

    public let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.auraframe.sessionQueue", qos: .userInitiated)
    private let videoDataQueue = DispatchQueue(label: "com.auraframe.videoDataQueue", qos: .userInteractive)

    private var activeDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()

    @Published public private(set) var isSessionRunning = false
    @Published public private(set) var currentZoomFactor: CGFloat = 1.0
    @Published public private(set) var minZoomFactor: CGFloat = 0.5
    @Published public private(set) var maxZoomFactor: CGFloat = 15.0
    @Published public private(set) var exposureBias: Float = 0.0
    @Published public private(set) var isRecordingVideo = false
    @Published public private(set) var activeLens: String = "1x Wide"

    private var availableDevices: [AVCaptureDevice] = []

    private override init() {
        super.init()
        discoverHardwareDevices()
    }

    // MARK: - Hardware Discovery

    private func discoverHardwareDevices() {
        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera
        ]

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .back
        )
        self.availableDevices = discovery.devices
    }

    // MARK: - Session Configuration

    public func configureSession(completion: @escaping (Bool) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .high

            // 1. Setup Video Input
            let preferredDevice = self.availableDevices.first ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)

            guard let device = preferredDevice else {
                CameraLogger.shared.camera.error("❌ No suitable rear video capture device found.")
                self.captureSession.commitConfiguration()
                DispatchQueue.main.async { completion(false) }
                return
            }

            self.activeDevice = device

            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.captureSession.canAddInput(input) {
                    self.captureSession.addInput(input)
                    self.videoInput = input
                }

                // 2. Setup Audio Input
                if let audioDevice = AVCaptureDevice.default(for: .audio),
                   let aInput = try? AVCaptureDeviceInput(device: audioDevice),
                   self.captureSession.canAddInput(aInput) {
                    self.captureSession.addInput(aInput)
                    self.audioInput = aInput
                }

                // 3. Setup Video Data Output (60 FPS Stream)
                self.videoOutput.alwaysDiscardsLateVideoFrames = true
                self.videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
                ]
                self.videoOutput.setSampleBufferDelegate(self, queue: self.videoDataQueue)

                if self.captureSession.canAddOutput(self.videoOutput) {
                    self.captureSession.addOutput(self.videoOutput)
                }

                // Enable Camera Intrinsics Delivery
                if let connection = self.videoOutput.connection(with: .video) {
                    if connection.isVideoOrientationSupported {
                        connection.videoOrientation = .portrait
                    }
                    if connection.isCameraIntrinsicMatrixDeliverySupported {
                        connection.isCameraIntrinsicMatrixDeliveryEnabled = true
                        CameraLogger.shared.logCamera("Camera intrinsic matrix delivery enabled.")
                    }
                }

                // 4. Setup Photo Output
                if self.captureSession.canAddOutput(self.photoOutput) {
                    self.captureSession.addOutput(self.photoOutput)
                    self.photoOutput.isHighResolutionCaptureEnabled = true
                    self.photoOutput.maxPhotoQualityPrioritization = .quality
                }

                // 5. Setup Movie File Output
                if self.captureSession.canAddOutput(self.movieOutput) {
                    self.captureSession.addOutput(self.movieOutput)
                }

                // Configure 60 FPS if supported
                try self.configure60FPS(for: device)

                self.captureSession.commitConfiguration()

                DispatchQueue.main.async {
                    self.currentZoomFactor = device.videoZoomFactor
                    self.minZoomFactor = device.minAvailableVideoZoomFactor
                    self.maxZoomFactor = min(device.maxAvailableVideoZoomFactor, 15.0)
                    self.updateLensLabel(for: device.videoZoomFactor)
                    completion(true)
                }
            } catch {
                CameraLogger.shared.logError("CameraSetup", error: error)
                self.captureSession.commitConfiguration()
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    private func configure60FPS(for device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        var bestFormat: AVCaptureDevice.Format?
        var bestFrameRateRange: AVFrameRateRange?

        for format in device.formats {
            for range in format.videoSupportedFrameRateRanges {
                if range.maxFrameRate >= 59.9 {
                    if bestFrameRateRange == nil || range.maxFrameRate > bestFrameRateRange!.maxFrameRate {
                        bestFormat = format
                        bestFrameRateRange = range
                    }
                }
            }
        }

        if let format = bestFormat, let range = bestFrameRateRange {
            device.activeFormat = format
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(range.maxFrameRate.rounded()))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(range.maxFrameRate.rounded()))
            CameraLogger.shared.logCamera("Device configured at \(range.maxFrameRate) FPS.")
        }
        device.unlockForConfiguration()
    }

    // MARK: - Lifecycle Controls

    public func startSession() {
        sessionQueue.async { [weak self] in
            guard let self = self, !self.captureSession.isRunning else { return }
            self.captureSession.startRunning()
            DispatchQueue.main.async {
                self.isSessionRunning = self.captureSession.isRunning
            }
        }
    }

    public func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self = self, self.captureSession.isRunning else { return }
            self.captureSession.stopRunning()
            DispatchQueue.main.async {
                self.isSessionRunning = false
            }
        }
    }

    // MARK: - Zoom Controls & Optical Ramping

    public func rampZoom(to displayZoom: CGFloat, rate: Float = 4.0) {
        guard let device = activeDevice else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                let targetZoom = max(device.minAvailableVideoZoomFactor, min(displayZoom, device.maxAvailableVideoZoomFactor))
                device.ramp(toVideoZoomFactor: targetZoom, withRate: rate)
                device.unlockForConfiguration()

                DispatchQueue.main.async {
                    self.currentZoomFactor = targetZoom
                    self.updateLensLabel(for: targetZoom)
                }
            } catch {
                CameraLogger.shared.logError("Zoom", error: error)
            }
        }
    }

    public func setLinearZoomFactor(_ zoom: CGFloat) {
        guard let device = activeDevice else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                let clamped = max(device.minAvailableVideoZoomFactor, min(zoom, device.maxAvailableVideoZoomFactor))
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()

                DispatchQueue.main.async {
                    self.currentZoomFactor = clamped
                    self.updateLensLabel(for: clamped)
                }
            } catch {
                CameraLogger.shared.logError("ZoomImmediate", error: error)
            }
        }
    }

    private func updateLensLabel(for zoom: CGFloat) {
        if zoom < 0.9 {
            self.activeLens = "0.5x Ultra Wide"
        } else if zoom < 1.9 {
            self.activeLens = "1x Wide"
        } else if zoom < 4.9 {
            self.activeLens = "2x Tele"
        } else {
            self.activeLens = "5x Tele"
        }
    }

    // MARK: - Exposure & Focus Controls

    public func setExposureTargetBias(_ bias: Float) {
        guard let device = activeDevice else { return }
        let clampedBias = max(device.minExposureTargetBias, min(bias, device.maxExposureTargetBias))
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(clampedBias, completionHandler: nil)
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.exposureBias = clampedBias
                }
            } catch {
                CameraLogger.shared.logError("ExposureBias", error: error)
            }
        }
    }

    public func focusAndExpose(at normalizedPoint: CGPoint) {
        guard let device = activeDevice else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = normalizedPoint
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposurePointOfInterest = normalizedPoint
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch {
                CameraLogger.shared.logError("FocusExpose", error: error)
            }
        }
    }

    // MARK: - Photo & Video Capture

    public func capturePhoto() {
        guard isSessionRunning else { return }
        let settings = AVCapturePhotoSettings()
        settings.flashMode = .auto
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    public func startVideoRecording() {
        guard isSessionRunning, !movieOutput.isRecording else { return }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuraFrame_\(UUID().uuidString).mov")
        movieOutput.startRecording(to: tempURL, recordingDelegate: self)
        DispatchQueue.main.async {
            self.isRecordingVideo = true
        }
    }

    public func stopVideoRecording() {
        guard movieOutput.isRecording else { return }
        movieOutput.stopRecording()
        DispatchQueue.main.async {
            self.isRecordingVideo = false
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        var intrinsics: CameraIntrinsicsCalibration?

        // Extract camera intrinsic matrix if delivered
        if let attachment = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil) as? Data {
            if attachment.count == 36 || attachment.count == 48 { // 3x3 matrix of Float32 or Float64
                attachment.withUnsafeBytes { rawBuffer in
                    if let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: Float.self) {
                        let fx: Double
                        let fy: Double
                        let cx: Double
                        let cy: Double
                        if attachment.count >= 48 {
                            fx = Double(ptr[0])
                            fy = Double(ptr[5])
                            cx = Double(ptr[8])
                            cy = Double(ptr[9])
                        } else {
                            fx = Double(ptr[0])
                            fy = Double(ptr[4])
                            cx = Double(ptr[6])
                            cy = Double(ptr[7])
                        }
                        intrinsics = CameraIntrinsicsCalibration(
                            fx: fx,
                            fy: fy,
                            cx: cx,
                            cy: cy,
                            imageSize: CGSize(width: 1920, height: 1080)
                        )
                    }
                }
            }
        }

        delegate?.cameraService(self, didOutput: sampleBuffer, intrinsics: intrinsics)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraService: AVCapturePhotoCaptureDelegate {
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            CameraLogger.shared.logError("PhotoCapture", error: error)
            return
        }

        guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
            return
        }

        DispatchQueue.main.async {
            self.delegate?.cameraService(self, didCapturePhoto: image)
        }
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension CameraService: AVCaptureFileOutputRecordingDelegate {
    public func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async {
            self.isRecordingVideo = false
            if let error = error {
                CameraLogger.shared.logError("VideoRecording", error: error)
            } else {
                self.delegate?.cameraService(self, didFinishRecordingVideoAt: outputFileURL)
            }
        }
    }
}
