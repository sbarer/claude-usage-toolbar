import Foundation

enum Strings {
    enum API {
        static let oauthURL = "https://api.anthropic.com/api/oauth/usage"
        static let betaHeader = "oauth-2025-04-20"
        static func webUsageURL(orgId: String) -> String {
            "https://claude.ai/api/organizations/\(orgId)/usage"
        }
    }

    enum Keychain {
        static let claudeCodeService = "Claude Code-credentials"
        static let safeStorageService = "Claude Safe Storage"
    }

    enum Cookies {
        static let dbPath = NSHomeDirectory() + "/Library/Application Support/Claude/Cookies"
        static let pbkdfSalt = "saltysalt"
    }

    enum Defaults {
        static let rateLimitedUntil = "rateLimitedUntil"
        static let cachedSessionPercent = "cachedSessionPercent"
        static let cachedWeeklyPercent = "cachedWeeklyPercent"
        static let cachedSessionResetsAt = "cachedSessionResetsAt"
        static let cachedWeeklyResetsAt = "cachedWeeklyResetsAt"
        static let cachedFetchedAt = "cachedFetchedAt"
        static let lastAlertedWeeklyResetWindow = "lastAlertedWeeklyResetWindow"
    }

    enum Menu {
        static let forceFetch = "Force Fetch Now"
        static let restart = "Restart"
        static let ok = "OK"
        static let openClaude = "Open Claude"
        static let lastFetchNever = "Last fetch: never"
    }

    enum Status {
        static let loading = "Loading"
        static let ok = "Okay"
        static let unauth = "Unauth"
        static let error = "Error"
        static let rateLimited = "Rate limited"
        static let rateLimitedDisplay = "Error (RL)"
    }

    enum Tooltip {
        static let loading = "Loading Claude usage…"
        static let unauthenticated = "Not authenticated — run `claude` to sign in"
    }
}
