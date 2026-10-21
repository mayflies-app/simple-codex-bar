import Observation

public enum LoginItemStatus: Sendable {
    case notRegistered, enabled, requiresApproval, notFound
}

@MainActor public protocol LoginItemService {
    var status: LoginItemStatus { get }
    var isAvailable: Bool { get }
    func register() throws
    func unregister() throws
}

/// The OS is the source of truth, including changes made in System Settings.
@MainActor @Observable public final class LoginItemController {
    public private(set) var status: LoginItemStatus
    public private(set) var available: Bool
    public private(set) var errorMessage: LocalizedText?
    public var error: String? { errorMessage?.resolve(in: .simplifiedChinese) }
    public var enabled: Bool { status == .enabled || status == .requiresApproval }
    public var requiresApproval: Bool { status == .requiresApproval }
    @ObservationIgnored private let service: any LoginItemService

    public init(service: any LoginItemService) {
        self.service = service; status = service.status; available = service.isAvailable
    }

    public func reload() { status = service.status; available = service.isAvailable }

    public func setEnabled(_ enabled: Bool) {
        guard available else { return }
        do {
            if enabled { try service.register() }
            else { try service.unregister() }
            errorMessage = nil
        } catch {
            errorMessage = LocalizedText("loginItem.error")
        }
        reload()
    }
}
