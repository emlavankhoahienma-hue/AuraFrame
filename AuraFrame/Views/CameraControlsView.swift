import SwiftUI

public struct CameraControlsView: View {
    @ObservedObject var viewModel: CameraViewModel

    private let goldenColor = Color(red: 1.0, green: 0.843, blue: 0.0)

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 16) {
            // Lens Zoom Switcher (0.5x, 1x, 2x, 5x)
            lensZoomSelector

            // Composition Rule Selector
            compositionRulePicker

            // Mode Selector (PHOTO / VIDEO)
            modeSelector

            // Main Shutter Row (Thumbnail, Shutter, AI Scan)
            shutterControlRow
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .background(
            LinearGradient(
                colors: [.clear, Color.black.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - Lens Zoom Selector

    @ViewBuilder
    private var lensZoomSelector: some View {
        HStack(spacing: 12) {
            zoomButton(label: ".5", factor: 0.5)
            zoomButton(label: "1x", factor: 1.0)
            zoomButton(label: "2x", factor: 2.0)
            zoomButton(label: "5x", factor: 5.0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.black.opacity(0.4))
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func zoomButton(label: String, factor: CGFloat) -> some View {
        let isSelected = abs(viewModel.currentZoom - factor) < 0.25

        Button {
            viewModel.selectLensZoom(factor)
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(isSelected ? goldenColor : .white)
                .frame(width: 34, height: 34)
                .background(isSelected ? Color.white.opacity(0.18) : Color.clear)
                .clipShape(Circle())
        }
    }

    // MARK: - Composition Rule Picker

    @ViewBuilder
    private var compositionRulePicker: some View {
        HStack(spacing: 8) {
            ForEach(CompositionRule.allCases) { rule in
                let isSelected = viewModel.activeRule == rule
                Button {
                    viewModel.selectRule(rule)
                } label: {
                    Text(rule.shortName)
                        .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .rounded))
                        .foregroundColor(isSelected ? .black : .white.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(isSelected ? goldenColor : Color.white.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: - Mode Selector

    @ViewBuilder
    private var modeSelector: some View {
        HStack(spacing: 28) {
            ForEach(CameraCaptureMode.allCases) { mode in
                let isSelected = viewModel.captureMode == mode
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.captureMode = mode
                        HapticFeedbackService.shared.modeSwitched()
                    }
                } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 13, weight: isSelected ? .bold : .semibold, design: .rounded))
                        .foregroundColor(isSelected ? goldenColor : .white.opacity(0.6))
                }
            }
        }
    }

    // MARK: - Shutter Control Row

    @ViewBuilder
    private var shutterControlRow: some View {
        HStack(alignment: .center) {
            // Left: Captured Photo Thumbnail / Gallery
            thumbnailButton
                .frame(width: 56, height: 56)

            Spacer()

            // Center: Shutter Button
            shutterButton

            Spacer()

            // Right: Futuristic AI Auto-Framing Scan Button
            aiScanButton
                .frame(width: 56, height: 56)
        }
    }

    @ViewBuilder
    private var thumbnailButton: some View {
        if let thumb = viewModel.capturedThumbnail {
            Image(uiImage: thumb)
                .resizable()
                .scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
                )
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.15))
                .frame(width: 48, height: 48)
                .overlay(
                    Image(systemName: "photo.on.rectangle")
                        .foregroundColor(.white.opacity(0.7))
                )
        }
    }

    @ViewBuilder
    private var shutterButton: some View {
        Button {
            viewModel.triggerShutter()
        } label: {
            ZStack {
                // Outer Ring
                Circle()
                    .strokeBorder(Color.white, lineWidth: 4)
                    .frame(width: 74, height: 74)

                if viewModel.captureMode == .photo {
                    // Photo Inner White Circle
                    Circle()
                        .fill(viewModel.sessionState == .alignmentPerfect ? goldenColor : Color.white)
                        .frame(width: 60, height: 60)
                } else {
                    // Video Record Button
                    if viewModel.isRecordingVideo {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.red)
                            .frame(width: 28, height: 28)
                    } else {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 60, height: 60)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var aiScanButton: some View {
        Button {
            viewModel.triggerAIScan()
        } label: {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 48, height: 48)

                Circle()
                    .stroke(goldenColor.opacity(0.8), lineWidth: 1.5)
                    .frame(width: 48, height: 48)

                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(goldenColor)
            }
        }
    }
}
