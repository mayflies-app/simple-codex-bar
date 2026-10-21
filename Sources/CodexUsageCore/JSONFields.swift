import Foundation
import CoreFoundation

/// Convert each alias before falling back. JSON null is a value, not Optional.none.
enum JSONFields {
    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    static func text(_ values: Any?...) -> String? {
        values.lazy.compactMap { value -> String? in
            guard let string = value as? String else { return nil }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.first
    }

    static func object(_ values: Any?...) -> [String: Any]? {
        values.lazy.compactMap { $0 as? [String: Any] }.first
    }

    static func number(_ values: Any?..., flexible: Bool = false) -> Double? {
        for value in values {
            if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite {
                return n.doubleValue
            }
            if flexible, let string = value as? String,
               let n = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)), n.isFinite { return n }
        }
        return nil
    }

    static func accountID(_ object: [String: Any]) throws -> String? {
        let a = text(object["account_id"])
        let b = text(object["accountId"])
        if let a, let b, a != b { throw UsageError.identityChanged }
        return a ?? b
    }

    static func validateAccount(_ object: [String: Any], expected: String) throws {
        if let id = try accountID(object), id != expected { throw UsageError.identityChanged }
    }

    static func safeHeader(_ value: String) -> Bool {
        !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
