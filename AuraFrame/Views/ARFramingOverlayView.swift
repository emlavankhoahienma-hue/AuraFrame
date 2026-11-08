import SwiftUI

public struct ARFramingOverlayView: View {
    @ObservedObject var viewModel: CameraViewModel
    @State private var radarPhase: CGFloat = 0.0
    @State private var pulseScale: CGFloat = 1.0
    @State private var sunDragOffset: CGFloat = 0.0

    private let goldenColor = Color(red: 1.0, green: 0.843, blue: 0.0) // #FFD700
    private let emeraldColor = Color(red: 0.18, green: 0.85, blue: 0.45) // Perfect alignment green

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                // 1. Composition Grid
                compositionGridView(size: geo.size)

                // 2. Radar Scan Wave Animation
                if viewModel.sessionState == .analyzing {
                    radarScanWave(size: geo.size)
                }

                // 3. Multi-Entity Bounding Boxes
                ForEach(viewModel.detectedEntities) { entity in
                    entityBoundingBoxView(entity: entity, size: geo.size)
                }

                // 4. Virtual Horizon Leveler
                virtualHorizonLeveler(size: geo.size)

                // 5. 3D Spatial Target Reticle & Edge Docking
                if viewModel.spatialEngine.isTrackingActive {
                    targetReticleView(size: geo.size)
                }

                // 6. Direct Sun Exposure Gesture Slider (Right edge)
                sunExposureControl(size: geo.size)

                // 7. Top Status & Guidance Banner
                topGuidanceBanner(size: geo.size)
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in
                        let point = value.location
                        let normPoint = CGPoint(
                            x: point.x / geo.size.width,
                            y: point.y / geo.size.height
                        )
                        viewModel.handleTapToTrack(at: normPoint)
                    }
            )
        }
    }

    // MARK: - 1. Composition Grid

    @ViewBuilder
    private func compositionGridView(size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let gridColor = Color.white.opacity(0.18)

            switch viewModel.activeRule {
            case .ruleOfThirds:
                // Vertical lines at 1/3 and 2/3
                let x1 = w / 3.0
                let x2 = 2.0 * w / 3.0
                let y1 = h / 3.0
                let y2 = 2.0 * h / 3.0

                context.stroke(Path { p in
                    p.move(to: CGPoint(x: x1, y: 0))
                    p.addLine(to: CGPoint(x: x1, y: h))
                    p.move(to: CGPoint(x: x2, y: 0))
                    p.addLine(to: CGPoint(x: x2, y: h))
                    p.move(to: CGPoint(x: 0, y: y1))
                    p.addLine(to: CGPoint(x: w, y: y1))
                    p.move(to: CGPoint(x: 0, y: y2))
                    p.addLine(to: CGPoint(x: w, y: y2))
                }, with: .color(gridColor), lineWidth: 1.0)

            case .goldenRatio:
                let x1 = w * 0.381966
                let x2 = w * 0.618034
                let y1 = h * 0.381966
                let y2 = h * 0.618034

                context.stroke(Path { p in
                    p.move(to: CGPoint(x: x1, y: 0))
                    p.addLine(to: CGPoint(x: x1, y: h))
                    p.move(to: CGPoint(x: x2, y: 0))
                    p.addLine(to: CGPoint(x: x2, y: h))
                    p.move(to: CGPoint(x: 0, y: y1))
                    p.addLine(to: CGPoint(x: w, y: y1))
                    p.move(to: CGPoint(x: 0, y: y2))
                    p.addLine(to: CGPoint(x: w, y: y2))
                }, with: .color(gridColor), lineWidth: 1.0)

            case .centerSymmetry:
                let cx = w * 0.5
                let cy = h * 0.5
                context.stroke(Path { p in
                    p.move(to: CGPoint(x: cx, y: 0))
                    p.addLine(to: CGPoint(x: cx, y: h))
                    p.move(to: CGPoint(x: 0, y: cy))
                    p.addLine(to: CGPoint(x: w, y: cy))
                }, with: .color(gridColor), lineWidth: 1.0)

            case .diagonalLeadingLines:
                context.stroke(Path { p in
                    p.move(to: CGPoint(x: 0, y: h))
                    p.addLine(to: CGPoint(x: w * 0.5, y: h * 0.45))
                    p.move(to: CGPoint(x: w, y: h))
                    p.addLine(to: CGPoint(x: w * 0.5, y: h * 0.45))
                    p.move(to: CGPoint(x: 0, y: 0))
                    p.addLine(to: CGPoint(x: w * 0.5, y: h * 0.45))
                    p.move(to: CGPoint(x: w, y: 0))
                    p.addLine(to: CGPoint(x: w * 0.5, y: h * 0.45))
                }, with: .color(gridColor), lineWidth: 1.0)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - 2. Radar Scan Wave

    @ViewBuilder
    private func radarScanWave(size: CGSize) -> some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.clear, goldenColor.opacity(0.35), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(height: 120)
            .offset(y: radarPhase * size.height - 60)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                    radarPhase = 1.0
                }
            }
            .allowsHitTesting(false)
    }

    // MARK: - 3. Multi-Entity Bounding Boxes

    @ViewBuilder
    private func entityBoundingBoxView(entity: TrackedEntity, size: CGSize) -> some View {
        let uiBox = TrackingGeometry.shared.visionToUIRect(entity.boundingBox)
        let rect = CGRect(
            x: uiBox.minX * size.width,
            y: uiBox.minY * size.height,
            width: uiBox.width * size.width,
            height: uiBox.height * size.height
        )

        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(entity.isPinned ? goldenColor : Color.white.opacity(0.45), lineWidth: 1.5)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .overlay(alignment: .topLeading) {
                Text(entity.entityType.rawValue)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(3)
                    .position(x: rect.minX + 24, y: rect.minY - 10)
            }
    }

    // MARK: - 4. Virtual Horizon Leveler

    @ViewBuilder
    private func virtualHorizonLeveler(size: CGSize) -> some View {
        let roll = viewModel.horizonRoll
        let isLvl = viewModel.isHorizonLevel
        let levelColor = isLvl ? emeraldColor : Color.white.opacity(0.65)

        HStack(spacing: 8) {
            Rectangle()
                .fill(levelColor)
                .frame(width: 44, height: 1.5)

            Circle()
                .strokeBorder(levelColor, lineWidth: 1.5)
                .frame(width: 8, height: 8)

            Rectangle()
                .fill(levelColor)
                .frame(width: 44, height: 1.5)
        }
        .rotationEffect(.degrees(-roll))
        .position(x: size.width * 0.5, y: size.height * 0.5)
        .overlay(alignment: .center) {
            if isLvl {
                Text("LEVEL 0°")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(emeraldColor)
                    .offset(y: 20)
            } else if abs(roll) > 1.0 {
                Text(String(format: "%.1f°", roll))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .offset(y: 20)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - 5. 3D Spatial Target Reticle & Edge Docking

    @ViewBuilder
    private func targetReticleView(size: CGSize) -> some View {
        let isInside = viewModel.spatialEngine.isTargetInsideFrame
        let targetPt = viewModel.spatialEngine.projectedTargetPoint
        let screenX = targetPt.x * size.width
        let screenY = targetPt.y * size.height

        let isAligned = viewModel.sessionState == .alignmentPerfect
        let reticleColor = isAligned ? emeraldColor : goldenColor

        Group {
            if isInside {
                // Golden / Emerald 36pt Reticle with 4 micro-crosshairs
                ZStack {
                    // Outer Ring
                    Circle()
                        .strokeBorder(reticleColor.opacity(0.85), lineWidth: 2.0)
                        .frame(width: 36, height: 36)
                        .scaleEffect(isAligned ? 1.15 : pulseScale)

                    // Center Dot
                    Circle()
                        .fill(reticleColor)
                        .frame(width: 5, height: 5)

                    // 4 Micro Crosshairs
                    ForEach(0..<4) { i in
                        Rectangle()
                            .fill(reticleColor)
                            .frame(width: 1.5, height: 6)
                            .offset(y: -22)
                            .rotationEffect(.degrees(Double(i) * 90.0))
                    }
                }
                .position(x: screenX, y: screenY)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                        pulseScale = 1.08
                    }
                }

            } else {
                // Offscreen Edge Docking Indicator with Direction Arrow
                let angle = viewModel.spatialEngine.edgeDockedAngle

                HStack(spacing: 4) {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(goldenColor)
                        .rotationEffect(.radians(angle - .pi / 2.0))

                    Text("TARGET")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(goldenColor)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.75))
                .cornerRadius(12)
                .position(x: screenX, y: screenY)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - 6. Sun Exposure Gesture Slider

    @ViewBuilder
    private func sunExposureControl(size: CGSize) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 16))
                .foregroundColor(.yellow)

            Text(String(format: "%+.1f EV", viewModel.exposureBias))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
        }
        .padding(8)
        .background(Color.black.opacity(0.5))
        .cornerRadius(8)
        .position(x: size.width - 45, y: size.height * 0.45 + sunDragOffset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    sunDragOffset = value.translation.height * 0.5
                    // Drag up increases EV, drag down decreases EV
                    let deltaEV = Float(-value.translation.height / 100.0)
                    let newBias = max(-2.0, min(2.0, deltaEV))
                    viewModel.setExposureBias(newBias)
                }
                .onEnded { _ in
                    withAnimation(.spring()) {
                        sunDragOffset = 0.0
                    }
                }
        )
    }

    // MARK: - 7. Top Status Banner

    @ViewBuilder
    private func topGuidanceBanner(size: CGSize) -> some View {
        VStack(spacing: 4) {
            Text(viewModel.guidanceInstruction)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(viewModel.sessionState == .alignmentPerfect ? emeraldColor.opacity(0.85) : Color.black.opacity(0.65))
                )

            if let result = viewModel.framingResult {
                Text("\(result.bestRule.shortName) • \(result.sceneType.rawValue) • \(String(format: "%.0f%%", result.confidence * 100))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.75))
            }
        }
        .position(x: size.width * 0.5, y: 55)
        .allowsHitTesting(false)
    }
}
