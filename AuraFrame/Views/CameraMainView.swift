import SwiftUI
import UIKit
import AVFoundation

public struct CameraMainView: View {
    @StateObject private var viewModel = CameraViewModel()
    @State private var hasCameraPermission = false

    public init() {}

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if hasCameraPermission {
                // 1. Hardware 60 FPS Camera Preview
                CameraPreviewView(cameraService: viewModel.cameraService)
                    .ignoresSafeArea()

                // 2. Augmented Reality Composition & Spatial Reticle Overlay
                ARFramingOverlayView(viewModel: viewModel)
                    .ignoresSafeArea()

                // 3. Controls & Shutter UI
                VStack {
                    topBarView
                    Spacer()
                    CameraControlsView(viewModel: viewModel)
                }
                .ignoresSafeArea(edges: .bottom)
            } else {
                permissionRequiredView
            }
        }
        .statusBarHidden(true)
        .onAppear {
            checkPermissions()
        }
        .onDisappear {
            viewModel.stopCamera()
        }
    }

    // MARK: - Top Bar

    @ViewBuilder
    private var topBarView: some View {
        HStack {
            // Flash / Auto-Capture Indicator
            Button {
                viewModel.autoCaptureEnabled.toggle()
                HapticFeedbackService.shared.ruleChanged()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: viewModel.autoCaptureEnabled ? "bolt.badge.automatic.fill" : "bolt.slash.fill")
                        .font(.system(size: 14))
                    Text(viewModel.autoCaptureEnabled ? "AUTO-SNAP ON" : "MANUAL")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                }
                .foregroundColor(viewModel.autoCaptureEnabled ? Color(red: 1.0, green: 0.843, blue: 0.0) : .white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.5))
                .clipShape(Capsule())
            }

            Spacer()

            // Video Recording Duration Clock
            if viewModel.isRecordingVideo {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text(formatDuration(viewModel.recordingDuration))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.6))
                .clipShape(Capsule())
            }

            Spacer()

            // Active Lens Badge
            Text(viewModel.cameraService.activeLens)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.5))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Permissions Check

    private func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            hasCameraPermission = true
            viewModel.startCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.hasCameraPermission = granted
                    if granted {
                        self.viewModel.startCamera()
                    }
                }
            }
        default:
            hasCameraPermission = false
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    @ViewBuilder
    private var permissionRequiredView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 48))
                .foregroundColor(.yellow)

            Text("Camera Access Required")
                .font(.title2.bold())
                .foregroundColor(.white)

            Text("AuraFrame requires camera and motion access for intelligent real-time photographic framing and target tracking.")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("Grant Permission") {
                if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(settingsURL)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 1.0, green: 0.843, blue: 0.0))
        }
    }
}
