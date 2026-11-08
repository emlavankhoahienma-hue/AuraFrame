import UIKit

@MainActor
public final class HapticFeedbackService {
    public static let shared = HapticFeedbackService()

    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private let heavyImpact = UIImpactFeedbackGenerator(style: .heavy)
    private let rigidImpact = UIImpactFeedbackGenerator(style: .rigid)
    private let notificationGenerator = UINotificationFeedbackGenerator()
    private let selectionGenerator = UISelectionFeedbackGenerator()

    private init() {
        prepare()
    }

    public func prepare() {
        lightImpact.prepare()
        mediumImpact.prepare()
        heavyImpact.prepare()
        rigidImpact.prepare()
        notificationGenerator.prepare()
        selectionGenerator.prepare()
    }

    public func targetLocked() {
        rigidImpact.prepare()
        rigidImpact.impactOccurred(intensity: 0.85)
    }

    public func alignmentPerfect() {
        notificationGenerator.prepare()
        notificationGenerator.notificationOccurred(.success)
    }

    public func shutterFired() {
        heavyImpact.prepare()
        heavyImpact.impactOccurred(intensity: 1.0)
    }

    public func modeSwitched() {
        selectionGenerator.prepare()
        selectionGenerator.selectionChanged()
    }

    public func ruleChanged() {
        lightImpact.prepare()
        lightImpact.impactOccurred(intensity: 0.6)
    }

    public func edgeDocked() {
        mediumImpact.prepare()
        mediumImpact.impactOccurred(intensity: 0.45)
    }

    public func warningLimitReached() {
        notificationGenerator.prepare()
        notificationGenerator.notificationOccurred(.warning)
    }
}
