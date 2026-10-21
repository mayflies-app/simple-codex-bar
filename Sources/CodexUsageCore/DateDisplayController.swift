import Foundation
import Observation

@MainActor @Observable public final class DateDisplayController {
    public private(set) var absolute: Bool
    @ObservationIgnored private let defaults: UserDefaults?
    public static let preferenceKey = "AbsoluteDateDisplay"
    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        absolute = defaults?.bool(forKey: Self.preferenceKey) ?? false
    }
    public func toggle() {
        absolute.toggle()
        defaults?.set(absolute, forKey: Self.preferenceKey)
    }
}
