import Foundation

public enum MacActivityState: String, Sendable {
    case active, locked, sleeping, lidClosed, displaySleeping, sessionInactive, idle

    public var isActive: Bool { self == .active }
    public var title: String { title(in: .simplifiedChinese) }
    public func title(in language: AppLanguage) -> String {
        LocalizedText("activity.\(rawValue)").resolve(in: language)
    }
}

/// Inputs from the OS, independent of network scheduling or account state.
public struct MacActivitySignals: Sendable {
    public static let idleThreshold: TimeInterval = 300
    public var sleeping: Bool
    public var locked: Bool
    public var lidClosed: Bool
    public var hasAwakeExternalDisplay: Bool
    public var displaySleeping: Bool
    public var sessionActive: Bool
    public var idleSeconds: TimeInterval

    public init(sleeping: Bool = false, locked: Bool = false, lidClosed: Bool = false,
                hasAwakeExternalDisplay: Bool = false,
                displaySleeping: Bool = false, sessionActive: Bool = true, idleSeconds: TimeInterval = 0) {
        self.sleeping = sleeping; self.locked = locked; self.lidClosed = lidClosed
        self.hasAwakeExternalDisplay = hasAwakeExternalDisplay
        self.displaySleeping = displaySleeping; self.sessionActive = sessionActive; self.idleSeconds = idleSeconds
    }

    public var state: MacActivityState {
        if sleeping { return .sleeping }
        if locked { return .locked }
        // An awake external display allows normal use with the laptop lid closed.
        if lidClosed && !hasAwakeExternalDisplay { return .lidClosed }
        if !sessionActive { return .sessionInactive }
        if displaySleeping { return .displaySleeping }
        if !idleSeconds.isFinite || idleSeconds >= Self.idleThreshold { return .idle }
        return .active
    }
}
