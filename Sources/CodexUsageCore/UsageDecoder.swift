import Foundation

struct UsagePayload: Sendable {
    let plan: String?
    let windows: [UsageWindow]
    let shouldFetchMonthly: Bool
    let credits: CreditBalance?
}

enum MonthlyQuotaResult {
    case window(UsageWindow), inactive, unavailable
}

extension UsageSnapshot {
    public static func decode(_ data: Data, expectedAccountID: String, at now: Date = Date()) throws -> Self {
        let payload = try parse(data, expectedAccountID: expectedAccountID, at: now)
        guard !payload.windows.isEmpty || payload.credits != nil else { throw UsageError.invalidResponse }
        return Self(plan: payload.plan, windows: payload.windows, fetchedAt: now, credits: payload.credits)
    }

    static func parse(_ data: Data, expectedAccountID: String, at now: Date) throws -> UsagePayload {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.invalidResponse
        }
        try JSONFields.validateAccount(object, expected: expectedAccountID)
        let rate = JSONFields.object(object["rate_limit"])
        var windows = try rate.map { try decodeWindows($0, prefix: "codex", name: nil, now: now, strict: true) } ?? []
        var extraIDs: Set<String> = []
        // Lossy per element, not per array. Unknown/bad entries must not discard their valid siblings.
        for raw in object["additional_rate_limits"] as? [Any] ?? [] {
            guard let extra = raw as? [String: Any], let limits = JSONFields.object(extra["rate_limit"]),
                  let source = JSONFields.text(extra["metered_feature"], extra["limit_name"]) else { continue }
            let name = JSONFields.text(extra["limit_name"], extra["metered_feature"]) ?? source
            let spark = [source, name].contains { $0.lowercased().contains("spark") }
            let prefix = spark ? "codex-spark" : "extra-" + stableSlug(source)
            let mapped = (try? decodeWindows(limits, prefix: prefix, name: spark ? "Spark" : name, now: now, strict: false)) ?? []
            windows += mapped.filter { extraIDs.insert($0.id).inserted }
        }
        let spend = JSONFields.object(object["spend_control"], object["spendControl"])
        // Preserve source priority even if a valid higher-priority object lacks usage. Missing is not zero.
        let individual = JSONFields.object(object["individual_limit"], object["individualLimit"],
                                          rate?["individual_limit"], rate?["individualLimit"],
                                          spend?["individual_limit"], spend?["individualLimit"])
        let directMonthly = individual.flatMap(monthlyWindow)
        if let directMonthly { windows.append(directMonthly) }
        let plan = JSONFields.text(object["plan_type"])
        let isPersonal = ["guest", "free", "go", "plus", "pro", "prolite", "promax"].contains(plan?.lowercased() ?? "")
        let shouldFetchMonthly = directMonthly == nil && !isPersonal
            && (object.keys.contains("spend_control") || object.keys.contains("spendControl"))
        let credits = JSONFields.object(object["credits"]).flatMap { raw -> CreditBalance? in
            let amount = JSONFields.number(raw["balance"], flexible: true).flatMap { $0 >= 0 ? $0 : nil }
            let hasCredits = JSONFields.boolean(raw["has_credits"])
            let unlimited = JSONFields.boolean(raw["unlimited"])
            guard amount != nil || hasCredits != nil || unlimited != nil else { return nil }
            return CreditBalance(balance: amount, hasCredits: hasCredits, unlimited: unlimited)
        }
        return UsagePayload(plan: plan, windows: windows, shouldFetchMonthly: shouldFetchMonthly, credits: credits)
    }

    static func decodeMonthly(_ data: Data, expectedAccountID: String) throws -> MonthlyQuotaResult {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unavailable }
        try JSONFields.validateAccount(object, expected: expectedAccountID)
        guard let effective = JSONFields.object(object["effective_monthly_limit"]),
              let limit = JSONFields.number(effective["limit"], flexible: true) else { return .unavailable }
        if let raw = effective["enforcement_mode"], !(raw is NSNull), !(raw is String) { return .unavailable }
        let mode = JSONFields.text(effective["enforcement_mode"])?.lowercased()
        if limit <= 0 || ["none", "off", "disabled", "no_limit"].contains(mode ?? "") { return .inactive }
        guard let used = JSONFields.number(object["current_month_usage"], flexible: true), used >= 0 else { return .unavailable }
        return .window(UsageWindow(id: "monthly", title: "每月额度", usedPercent: utilization(used: used, limit: limit),
                                   resetsAt: nil, usedAmount: used, limitAmount: limit,
                                   titleMessage: LocalizedText("window.monthly")))
    }

    private struct WindowValue {
        let key: String
        let used: Double
        let duration: Double?
        let reset: Date?
        var role: String {
            switch duration {
            case 18000: "session"
            case 604800: "weekly"
            default: key
            }
        }
        func titleMessage(name: String?) -> LocalizedText {
            let kind: String
            var arguments: [String] = []
            switch duration {
            case 18000: kind = "session"
            case 604800: kind = "weekly"
            case let seconds? where seconds >= 3600 && seconds < 31536000:
                let count = Int(seconds / (seconds >= 86400 ? 86400 : 3600))
                kind = seconds >= 86400 ? (count == 1 ? "day" : "days") : (count == 1 ? "hour" : "hours")
                arguments = [String(count)]
            case let seconds? where seconds > 0 && seconds < 3600:
                let count = max(1, Int(ceil(seconds / 60)))
                kind = count == 1 ? "minute" : "minutes"
                arguments = [String(count)]
            default: kind = key == "primary_window" ? "primary" : "secondary"
            }
            if let name {
                return LocalizedText("window.named.\(kind)", arguments: [name] + arguments)
            }
            return LocalizedText("window.\(kind)", arguments: arguments)
        }
    }

    private static func decodeWindows(_ limits: [String: Any], prefix: String, name: String?,
                                      now: Date, strict: Bool) throws -> [UsageWindow] {
        var values: [WindowValue] = []
        for key in ["primary_window", "secondary_window"] {
            guard let raw = limits[key], !(raw is NSNull) else { continue }
            guard let window = raw as? [String: Any], let used = JSONFields.number(window["used_percent"]) else {
                if strict { throw UsageError.invalidResponse }
                continue
            }
            var reset: Date?
            if let epoch = JSONFields.number(window["reset_at"]), epoch > 0, epoch < 253402300800 {
                reset = Date(timeIntervalSince1970: epoch)
            } else if let seconds = JSONFields.number(window["reset_after_seconds"]), seconds >= 0, seconds < 31536000 {
                reset = now.addingTimeInterval(seconds)
            }
            values.append(WindowValue(key: key, used: used, duration: JSONFields.number(window["limit_window_seconds"]), reset: reset))
        }
        // The API's primary slot can be weekly. Normalize by duration, not by JSON position.
        if values.count == 2 && values[0].role == "weekly" && values[1].role != "weekly" { values.swapAt(0, 1) }
        var ids: Set<String> = []
        return values.map { value in
            var id = "\(prefix)-\(value.role)"
            if !ids.insert(id).inserted { id += "-\(value.key)" }
            let message = value.titleMessage(name: name)
            return UsageWindow(id: id, title: message.resolve(in: .simplifiedChinese),
                               usedPercent: value.used, resetsAt: value.reset, titleMessage: message)
        }
    }

    private static func monthlyWindow(_ raw: [String: Any]) -> UsageWindow? {
        guard let cap = JSONFields.number(raw["limit"], flexible: true), cap > 0 else { return nil }
        let used: Double
        if let remaining = JSONFields.number(raw["remaining_percent"], raw["remainingPercent"], flexible: true) { used = 100 - remaining }
        else if let amount = JSONFields.number(raw["used"], flexible: true), amount >= 0 { used = utilization(used: amount, limit: cap) }
        else { return nil }
        let epoch = JSONFields.number(raw["reset_at"], raw["resets_at"], raw["resetsAt"], flexible: true)
        let reset = epoch.flatMap { $0 > 0 && $0 < 253402300800 ? Date(timeIntervalSince1970: $0) : nil }
        let amount = JSONFields.number(raw["used"], flexible: true).flatMap { $0 >= 0 ? $0 : nil }
        return UsageWindow(id: "monthly", title: "每月额度", usedPercent: used, resetsAt: reset,
                           usedAmount: amount, limitAmount: cap, titleMessage: LocalizedText("window.monthly"))
    }

    private static func utilization(used: Double, limit: Double) -> Double {
        used >= limit ? 100 : used / limit * 100 // Avoid overflowing when a finite counter exceeds a tiny cap.
    }

    private static func stableSlug(_ source: String) -> String {
        // Stable even if the array is reordered; retain a hash to distinguish punctuation-only slug collisions.
        let slug = source.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined()
        let hash = source.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return slug + "-" + String(hash, radix: 16)
    }
}
