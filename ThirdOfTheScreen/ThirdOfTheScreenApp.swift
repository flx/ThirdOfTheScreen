import SwiftUI

@main
struct ThirdOfTheScreenApp: App {
    @StateObject private var overlayManager = OverlayManager.shared
    @StateObject private var launchAtLoginManager = LaunchAtLoginManager()

    init() {
        OverlayManager.shared.restoreState()
    }

    var body: some Scene {
        MenuBarExtra {
            Toggle("Show Overlay", isOn: gridOverlayBinding)
            Toggle("Emphasize Active Window", isOn: activeWindowEmphasisBinding)
            Picker("Overlay Strength", selection: emphasisStrengthBinding) {
                ForEach(OverlayManager.EmphasisStrength.allCases) { emphasisStrength in
                    Text(emphasisStrength.label)
                        .tag(emphasisStrength)
                }
            }

            if let emphasisStatusMessage = overlayManager.emphasisStatusMessage {
                Text(emphasisStatusMessage)
                    .font(.caption)
            }

            Divider()

            Toggle("Launch at Login", isOn: launchAtLoginBinding)

            if let statusMessage = launchAtLoginManager.statusMessage {
                Divider()

                Text(statusMessage)
                    .font(.caption)
            }

            if launchAtLoginManager.requiresApproval {
                Button("Open Login Items Settings") {
                    launchAtLoginManager.openLoginItemsSettings()
                }
            }

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

    private var gridOverlayBinding: Binding<Bool> {
        Binding(
            get: { overlayManager.isGridOverlayEnabled },
            set: { isVisible in
                overlayManager.setGridOverlayEnabled(isVisible)
            }
        )
    }

    private var activeWindowEmphasisBinding: Binding<Bool> {
        Binding(
            get: { overlayManager.isActiveWindowEmphasisEnabled },
            set: { isEnabled in
                overlayManager.setActiveWindowEmphasisEnabled(isEnabled)
            }
        )
    }

    private var emphasisStrengthBinding: Binding<OverlayManager.EmphasisStrength> {
        Binding(
            get: { overlayManager.emphasisStrength },
            set: { emphasisStrength in
                overlayManager.setEmphasisStrength(emphasisStrength)
            }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginManager.isEnabled },
            set: { isEnabled in
                launchAtLoginManager.setEnabled(isEnabled)
            }
        )
    }
}
