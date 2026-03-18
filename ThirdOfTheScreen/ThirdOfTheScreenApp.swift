import SwiftUI

@main
struct ThirdOfTheScreenApp: App {
    @StateObject private var overlayManager = OverlayManager.shared

    init() {
        OverlayManager.shared.showOverlay()
    }

    var body: some Scene {
        MenuBarExtra {
            Toggle("Show Overlay", isOn: overlayBinding)

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Text("1/3")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
        }
        .menuBarExtraStyle(.menu)
    }

    private var overlayBinding: Binding<Bool> {
        Binding(
            get: { overlayManager.isOverlayVisible },
            set: { isVisible in
                if isVisible {
                    overlayManager.showOverlay()
                } else {
                    overlayManager.hideOverlay()
                }
            }
        )
    }
}
