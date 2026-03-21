import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var statusMessage: String?

    private let service = SMAppService.mainApp

    init() {
        refreshStatus()
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            statusMessage = installHint ?? "Launch at Login failed: \(error.localizedDescription)"
        }

        refreshStatus()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func refreshStatus() {
        requiresApproval = false

        switch service.status {
        case .enabled:
            isEnabled = true
            statusMessage = installHint
        case .requiresApproval:
            isEnabled = true
            requiresApproval = true
            statusMessage = "Approve Third Of The Screen in System Settings > General > Login Items."
        case .notRegistered:
            isEnabled = false
            statusMessage = installHint
        case .notFound:
            isEnabled = false
            statusMessage = "Launch at Login is unavailable for this build."
        @unknown default:
            isEnabled = false
            statusMessage = "Launch at Login returned an unknown status."
        }
    }

    private var installHint: String? {
        guard !isInstalledInApplications else { return nil }
        return "Move the app to /Applications before enabling Launch at Login."
    }

    private var isInstalledInApplications: Bool {
        let bundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let applicationDirectories = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask)
            + FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask)

        return applicationDirectories.contains { applicationDirectory in
            let normalizedDirectory = applicationDirectory.resolvingSymlinksInPath()
            return bundleURL.path.hasPrefix(normalizedDirectory.path + "/")
        }
    }
}
