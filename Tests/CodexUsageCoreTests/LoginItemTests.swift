import Testing
@testable import CodexUsageCore

@MainActor private final class FakeLoginItemService: LoginItemService {
    var status: LoginItemStatus = .notRegistered
    var isAvailable = true
    var failure = false
    var needsApproval = false
    var registrations = 0
    var removals = 0
    func register() throws {
        registrations += 1
        if failure { throw UsageError.storage }
        status = needsApproval ? .requiresApproval : .enabled
    }
    func unregister() throws {
        removals += 1
        if failure { throw UsageError.storage }
        status = .notRegistered
    }
}

@Test @MainActor func loginItemReflectsSystemStatusAndFailedOperations() {
    let service = FakeLoginItemService()
    let controller = LoginItemController(service: service)
    #expect(!controller.enabled)
    controller.setEnabled(true)
    #expect(controller.enabled && service.registrations == 1)
    service.failure = true
    controller.setEnabled(false)
    #expect(controller.enabled && controller.error != nil)
    #expect(controller.errorMessage?.resolve(in: .english) == "Unable to change the login setting. Check Login Items in System Settings.")
    service.failure = false
    controller.setEnabled(false)
    #expect(!controller.enabled && controller.error == nil)
    #expect(controller.errorMessage == nil)
    service.needsApproval = true
    controller.setEnabled(true)
    #expect(controller.enabled && controller.requiresApproval)
    service.status = .enabled // User approves in System Settings.
    controller.reload()
    #expect(controller.enabled && !controller.requiresApproval)
    service.status = .notRegistered // User removes the login item externally.
    controller.reload()
    #expect(!controller.enabled)
    service.isAvailable = false
    controller.reload()
    let previous = service.registrations
    controller.setEnabled(true)
    #expect(!controller.enabled && service.registrations == previous)
}
