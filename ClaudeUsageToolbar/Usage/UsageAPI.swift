import Foundation

final class UsageAPI {
    private static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }

    private let session = makeSession()

    func fetch(reason: String) async -> UsageFetchResult {
        if let cookies = try? ClaudeCookieStore.readCookies(),
           let cookieURL = URL(string: Strings.API.webUsageURL(orgId: cookies.orgId)) {
            NSLog("[ClaudeUsageToolbar] UsageAPI: using cookie-based fetch (org: %@)", cookies.orgId)
            return await performCookieFetch(cookies: cookies, url: cookieURL, reason: reason, attempt: 1, fallbackToOAuth: true)
        }
        NSLog("[ClaudeUsageToolbar] UsageAPI: cookies unavailable, falling back to OAuth fetch")
        return await fetchWithOAuth(reason: reason)
    }

    // MARK: - OAuth path

    private func fetchWithOAuth(reason: String) async -> UsageFetchResult {
        let token: String
        do {
            token = try await KeychainTokenStore.readAccessToken()
        } catch KeychainTokenStore.Error.notFound {
            NSLog("[ClaudeUsageToolbar] UsageAPI: token not found in keychain, returning unauthenticated")
            UsageAPIDebugLog.record([
                "Time: \(DateUtils.formatReset(Date()))",
                "Reason: \(reason)",
                "Request: not sent",
                "Result: unauthenticated",
                "Detail: access token not found in keychain"
            ])
            return .unauthenticated(attempts: 0)
        } catch {
            NSLog("[ClaudeUsageToolbar] UsageAPI: keychain error: %@", "\(error)")
            UsageAPIDebugLog.record([
                "Time: \(DateUtils.formatReset(Date()))",
                "Reason: \(reason)",
                "Request: not sent",
                "Result: failure",
                "Detail: keychain: \(error)"
            ])
            return .failure("keychain: \(error)", attempts: 0)
        }
        return await performOAuthFetch(token: token, reason: reason, attempt: 1)
    }

    private func performOAuthFetch(token: String, reason: String, attempt: Int) async -> UsageFetchResult {
        guard let url = URL(string: Strings.API.oauthURL) else {
            return .failure("invalid URL", attempts: attempt)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(Strings.API.betaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("claude-usage-toolbar/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            Self.recordRequest(reason: reason, request: req, attempt: attempt, response: nil, data: nil, error: error, result: "failure")
            return .failure(error.localizedDescription, attempts: attempt)
        }

        switch Self.classify(data: data, response: response) {
        case .unauthenticated:
            KeychainTokenStore.invalidateCachedAccessToken()
            Self.recordRequest(reason: reason, request: req, attempt: attempt, response: response, data: data, result: "unauthenticated")
            return .unauthenticated(attempts: attempt)
        case .rateLimited(let retryAfter):
            let retrySeconds = retryAfter.flatMap { $0 > 0 ? $0 : nil } ?? UsageFetchResult.rateLimitFallbackSeconds
            let retrySource: UsageAPIDebugLog.RetrySource = retryAfter.map { $0 > 0 } == true ? .response : .fallback
            Self.recordRequest(reason: reason, request: req, attempt: attempt, response: response, data: data,
                               result: "rate limited", rateLimitRetryAfter: retrySeconds, rateLimitRetrySource: retrySource)
            return .rateLimited(retryAfter: retryAfter, attempts: attempt)
        case .failure(let msg):
            Self.recordRequest(reason: reason, request: req, attempt: attempt, response: response, data: data, result: "failure", detail: msg)
            return .failure(msg, attempts: attempt)
        case .parsed(let resp):
            Self.recordSuccess(reason: reason, attempt: attempt, url: Strings.API.oauthURL, result: "success", resp: resp)
            return .success(resp, attempts: attempt)
        }
    }

    // MARK: - Cookie path

    private func performCookieFetch(cookies: ClaudeCookieStore.Cookies, url: URL, reason: String, attempt: Int, fallbackToOAuth: Bool) async -> UsageFetchResult {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(cookies.cookieString, forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // Browser-like User-Agent is required — Cloudflare validates it alongside cf_clearance
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            Self.recordRequest(reason: reason, request: req, attempt: attempt, response: nil, data: nil, error: error, result: "failure")
            return .failure(error.localizedDescription, attempts: attempt)
        }

        switch Self.classify(data: data, response: response) {
        case .unauthenticated:
            NSLog("[ClaudeUsageToolbar] UsageAPI: cookie fetch got 401/403, %@", fallbackToOAuth ? "falling back to OAuth" : "returning unauthenticated")
            Self.recordRequest(reason: reason, request: req, attempt: attempt, response: response, data: data, result: "unauthenticated (cookie)")
            if fallbackToOAuth { return await fetchWithOAuth(reason: reason) }
            return .unauthenticated(attempts: attempt)
        case .rateLimited(let retryAfter):
            let retrySeconds = retryAfter.flatMap { $0 > 0 ? $0 : nil } ?? UsageFetchResult.rateLimitFallbackSeconds
            let retrySource: UsageAPIDebugLog.RetrySource = retryAfter.map { $0 > 0 } == true ? .response : .fallback
            Self.recordRequest(reason: reason, request: req, attempt: attempt, response: response, data: data,
                               result: "rate limited", rateLimitRetryAfter: retrySeconds, rateLimitRetrySource: retrySource)
            return .rateLimited(retryAfter: retryAfter, attempts: attempt)
        case .failure(let msg):
            Self.recordRequest(reason: reason, request: req, attempt: attempt, response: response, data: data, result: "failure", detail: msg)
            return .failure(msg, attempts: attempt)
        case .parsed(let resp):
            Self.recordSuccess(reason: reason, attempt: attempt, url: url.absoluteString, result: "success (cookie)", resp: resp)
            return .success(resp, attempts: attempt)
        }
    }

    // MARK: - Shared HTTP classification

    private enum HTTPClassification {
        case unauthenticated
        case rateLimited(TimeInterval?)
        case failure(String)
        case parsed(UsageResponse)
    }

    private static func classify(data: Data, response: URLResponse) -> HTTPClassification {
        guard let http = response as? HTTPURLResponse else {
            return .failure("no HTTP response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            return .unauthenticated
        }
        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap { TimeInterval($0) }
            return .rateLimited(retryAfter)
        }
        if !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            return .failure("http \(http.statusCode): \(body.prefix(200))")
        }
        do {
            return .parsed(try parse(data))
        } catch {
            return .failure("parse: \(error)")
        }
    }

    // MARK: - Parsing

    private static func parse(_ data: Data) throws -> UsageResponse {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let root = obj as? [String: Any] else {
            throw NSError(domain: "UsageAPI", code: 1, userInfo: [NSLocalizedDescriptionKey: "not an object"])
        }
        return UsageResponse(
            fiveHour: extractBucket(from: root, keys: ["five_hour", "fiveHour", "session", "rolling_5h"]),
            sevenDay: extractBucket(from: root, keys: ["seven_day", "sevenDay", "weekly", "rolling_7d"]),
            sevenDayOpus: extractBucket(from: root, keys: ["seven_day_opus", "sevenDayOpus", "weekly_opus", "rolling_7d_opus"])
        )
    }

    private static func extractBucket(from root: [String: Any], keys: [String]) -> UsageResponse.Bucket? {
        for k in keys {
            if let dict = root[k] as? [String: Any] {
                let util = (dict["utilization"] as? Double)
                    ?? (dict["percent_used"] as? Double).map { $0 / 100.0 }
                    ?? (dict["used"] as? Double)
                guard let u = util else { continue }
                let reset = DateUtils.parseISO(dict["resets_at"]) ?? DateUtils.parseISO(dict["reset_at"]) ?? DateUtils.parseISO(dict["resetsAt"])
                return UsageResponse.Bucket(utilization: u, resetsAt: reset)
            }
            if let percent = root[k] as? Double {
                return UsageResponse.Bucket(utilization: percent > 1 ? percent / 100 : percent, resetsAt: nil)
            }
        }
        return nil
    }

    // MARK: - Debug logging

    private static func recordSuccess(reason: String, attempt: Int, url: String, result: String, resp: UsageResponse) {
        UsageAPIDebugLog.record([
            "Time: \(DateUtils.formatReset(Date()))",
            "Reason: \(reason)",
            "Request: GET \(url)",
            "Attempt: \(attempt)",
            "Result: \(result)",
            "Detail: fiveHour=\(debugBucket(resp.fiveHour)), sevenDay=\(debugBucket(resp.sevenDay))"
        ])
    }

    private static func recordRequest(
        reason: String,
        request: URLRequest,
        attempt: Int,
        response: URLResponse?,
        data: Data?,
        error: Error? = nil,
        result: String,
        detail: String? = nil,
        rateLimitRetryAfter: TimeInterval? = nil,
        rateLimitRetrySource: UsageAPIDebugLog.RetrySource? = nil
    ) {
        let http = response as? HTTPURLResponse
        var lines = [
            "Time: \(DateUtils.formatReset(Date()))",
            "Reason: \(reason)",
            "Request: \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "unknown")",
            "Attempt: \(attempt)"
        ]
        if let statusCode = http?.statusCode { lines.append("Status: \(statusCode)") }
        lines.append("Result: \(result)")
        lines.append("Debug Info:")
        lines.append("  Request Headers:")
        for (key, value) in sanitizedHeaders(from: request).sorted(by: { $0.key < $1.key }) {
            lines.append("    \(key): \(value)")
        }
        if let response {
            lines.append("  Response Type: \(type(of: response))")
            lines.append("  Response URL: \(response.url?.absoluteString ?? "nil")")
        } else {
            lines.append("  Response: nil")
        }
        if let http {
            lines.append("  Response Headers:")
            for (key, value) in http.allHeaderFields.sorted(by: { "\($0.key)" < "\($1.key)" }) {
                lines.append("    \(key): \(value)")
            }
        }
        if let error {
            let nsError = error as NSError
            lines.append("  Error Domain: \(nsError.domain)")
            lines.append("  Error Code: \(nsError.code)")
            lines.append("  Error Description: \(nsError.localizedDescription)")
            if !nsError.userInfo.isEmpty {
                lines.append("  Error User Info:")
                for (key, value) in nsError.userInfo.sorted(by: { $0.key < $1.key }) {
                    lines.append("    \(key): \(value)")
                }
            }
        }
        if let data {
            lines.append("  Response Body Bytes: \(data.count)")
            lines.append("  Response Body:")
            lines.append(String(data: data, encoding: .utf8) ?? data.map { String(format: "%02x", $0) }.joined())
        } else {
            lines.append("  Response Body: nil")
        }
        if let detail, !detail.isEmpty { lines.append("  Detail: \(detail)") }
        UsageAPIDebugLog.record(lines, rateLimitRetryAfter: rateLimitRetryAfter, rateLimitRetrySource: rateLimitRetrySource)
    }

    private static func sanitizedHeaders(from request: URLRequest) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            if key.caseInsensitiveCompare("Authorization") == .orderedSame ||
               key.caseInsensitiveCompare("Cookie") == .orderedSame {
                headers[key] = "<redacted>"
            } else {
                headers[key] = value
            }
        }
        return headers
    }

    private static func debugBucket(_ bucket: UsageResponse.Bucket?) -> String {
        guard let bucket else { return "nil" }
        let reset = bucket.resetsAt.map { DateUtils.iso.string(from: $0) } ?? "nil"
        return "{ utilization: \(bucket.utilization), resetsAt: \(reset) }"
    }
}
