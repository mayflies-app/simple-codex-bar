import Foundation
import ServiceManagement
import CodexUsageCore

@MainActor final class SystemLoginItemService: LoginItemService {
    var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }
    var status: LoginItemStatus {
        guard isAvailable else { return .notFound }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// Demo mode exercises the UI without touching the user's real login items.
@MainActor final class SimulationLoginItemService: LoginItemService {
    var status: LoginItemStatus = .notRegistered
    let isAvailable = true
    func register() { status = .enabled }
    func unregister() { status = .notRegistered }
}
