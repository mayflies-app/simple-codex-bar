import Foundation

public enum PlanPresentation {
    public static func title(usage: String?, auth: String?) -> String {
        guard let usage else { return auth.map(label) ?? "Codex" }
        if usage.lowercased() == "pro" {
            if let auth, ["prolite", "pro", "promax"].contains(auth.lowercased()) {
                return label(auth)
            }
            return "Pro"
        }
        return label(usage)
    }

    private static func label(_ raw: String) -> String {
        switch raw.lowercased() {
        case "plus": "Plus"
        case "pro": "Pro More"
        case "prolite": "Pro Lite"
        case "promax": "Pro Max"
        case "free": "Free"
        case "go": "Go"
        case "team": "Team"
        case "business": "Business"
        case "enterprise", "hc", "ent26": "Enterprise"
        case "education", "edu": "Edu"
        case "edu_plus": "Edu Plus"
        case "edu_pro": "Edu Pro"
        default: raw
        }
    }
}
