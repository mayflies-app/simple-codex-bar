import AppKit
import CoreGraphics
import IOKit
import CodexUsageCore

/// Reads system activity without monitoring or storing individual keyboard/mouse events.
@MainActor final class MacActivityMonitor: NSObject {
    private var sleeping = false
    private var locked = false
    private var screensSleeping = false
    private var sessionActive = true
    private var timer: Timer?
    private let onChange: @MainActor (MacActivityState) -> Void

    init(onChange: @escaping @MainActor (MacActivityState) -> Void) {
        self.onChange = onChange
        super.init()
    }

    func start() {
        guard timer == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.sessionDidResignActiveNotification] {
            center.addObserver(self, selector: #selector(workspaceChanged(_:)), name: name, object: nil)
        }
        // macOS broadcasts these on screen lock/unlock. The session dictionary and display
        // state are also sampled, so startup and missed notifications do not depend on them alone.
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            distributed.addObserver(self, selector: #selector(lockChanged(_:)), name: .init(name), object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(workspaceChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        publish()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    func currentState() -> MacActivityState {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let console = session?[kCGSessionOnConsoleKey as String] as? Bool ?? false
        let sessionLocked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        // Online displays include hardware mirrors and sleeping displays, which NSScreen can omit.
        let displays = onlineDisplayIDs().map { id in
            (isBuiltIn: CGDisplayIsBuiltin(id) != 0, isAsleep: CGDisplayIsAsleep(id) != 0)
        }
        let allDisplaysAsleep = !displays.isEmpty && displays.allSatisfy { $0.isAsleep }
        let hasAwakeExternalDisplay = displays.contains { !$0.isBuiltIn && !$0.isAsleep }
        return MacActivitySignals(sleeping: sleeping, locked: locked || sessionLocked,
                                  lidClosed: lidIsClosed(), hasAwakeExternalDisplay: hasAwakeExternalDisplay,
                                  displaySleeping: screensSleeping || allDisplaysAsleep,
                                  sessionActive: sessionActive && console,
                                  idleSeconds: CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                      // CoreGraphics' kCGAnyInputEventType selector (-1).
                                      eventType: CGEventType(rawValue: UInt32.max)!)).state
    }

    private func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return [] }
        return Array(displays.prefix(Int(count)))
    }

    private func lidIsClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false } // Desktop Macs have no lid.
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool ?? false
    }

    private func publish() { onChange(currentState()) }

    @objc private func workspaceChanged(_ notification: Notification) {
        switch notification.name {
        case NSWorkspace.willSleepNotification: sleeping = true
        case NSWorkspace.didWakeNotification: sleeping = false
        case NSWorkspace.screensDidSleepNotification: screensSleeping = true
        case NSWorkspace.screensDidWakeNotification: screensSleeping = false
        case NSWorkspace.sessionDidBecomeActiveNotification: sessionActive = true
        case NSWorkspace.sessionDidResignActiveNotification: sessionActive = false
        default: break
        }
        publish()
    }

    @objc private func lockChanged(_ notification: Notification) {
        locked = notification.name.rawValue == "com.apple.screenIsLocked"
        publish()
    }
}
