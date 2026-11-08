import SwiftUI
import UIKit

@main
struct AuraFrameApp: App {
    init() {
        // Prevent screen from turning off while framing shots
        UIApplication.shared.isIdleTimerDisabled = true
    }

    var body: some Scene {
        WindowGroup {
            CameraMainView()
                .preferredColorScheme(.dark)
        }
    }
}
