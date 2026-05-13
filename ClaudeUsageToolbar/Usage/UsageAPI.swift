import Foundation

final class UsageAPI {
    private let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let betaHeader = "oauth-2025-04-20"

    private static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }

    private var session = makeSession()

    func fetch(reason: String, completion: @escaping (UsageFetchResult) -> Void) {
        let token: String
        do {
            token = try KeychainTokenStore.readAccessToken()
        } catch KeychainTokenStore.Error.notFound {
            UsageAPIDebugLog.record([
                "Time: \(Self.debugTimestamp())",
                "Reason: \(reason)",
                "Request: not sent",
                "Result: unauthenticated",
                "Detail: access token not found in keychain",
                "Debug Info:",
                "  Keychain lookup failed before any HTTP request was created.",
                "  Token value: not logged"
            ])
            completion(.unauthenticated(attempts: 0)); return
        } catch {
            UsageAPIDebugLog.record([
                "Time: \(Self.debugTimestamp())",
                "Reason: \(reason)",
                "Request: not sent",
                "Result: failure",
                "Detail: keychain: \(error)",
                "Debug Info:",
                "  Keychain error type: \(type(of: error))",
                "  Token value: not logged"
            ])
            completion(.failure("keychain: \(error)", attempts: 0)); return
        }

        performFetch(token: token, reason: reason, attempt: 1, completion: completion)
    }

    private func performFetch(token: String, reason: String, attempt: Int, completion: @escaping (UsageFetchResult) -> Void) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("claude-usage-toolbar/1.0", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: req) { data, response, error in
            if let error {
                Self.recordHTTPRequest(reason: reason, request: req, attempt: attempt, response: response, data: data, error: error, result: "failure")
                completion(.failure(error.localizedDescription, attempts: attempt)); return
            }
            guard let http = response as? HTTPURLResponse, let data else {
                Self.recordHTTPRequest(reason: reason, request: req, attempt: attempt, response: response, data: data, result: "failure", detail: "no response")
                completion(.failure("no response", attempts: attempt)); return
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                KeychainTokenStore.invalidateCachedAccessToken()
                Self.recordHTTPRequest(reason: reason, request: req, attempt: attempt, response: http, data: data, result: "unauthenticated")
                completion(.unauthenticated(attempts: attempt)); return
            }
            if http.statusCode == 429 {
                Self.recordHTTPRequest(reason: reason, request: req, attempt: attempt, response: http, data: data, result: "rate limited")
                completion(.rateLimited(attempts: attempt)); return
            }
            if !(200...299).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? ""
                Self.recordHTTPRequest(reason: reason, request: req, attempt: attempt, response: http, data: data, result: "failure", detail: body)
                completion(.failure("http \(http.statusCode): \(body.prefix(200))", attempts: attempt))
                return
            }
            do {
                let parsed = try Self.parse(data)
                Self.recordHTTPRequest(
                    reason: reason,
                    attempt: attempt,
                    statusCode: http.statusCode,
                    result: "success",
                    detail: "fiveHour=\(Self.debugBucket(parsed.fiveHour)), sevenDay=\(Self.debugBucket(parsed.sevenDay))"
                )
                completion(.success(parsed, attempts: attempt))
            } catch {
                let body = String(data: data, encoding: .utf8) ?? ""
                Self.recordHTTPRequest(reason: reason, request: req, attempt: attempt, response: http, data: data, error: error, result: "parse failure", detail: body)
                completion(.failure("parse: \(error)", attempts: attempt))
            }
        }.resume()
    }

    private static func recordHTTPRequest(reason: String, attempt: Int, statusCode: Int? = nil, result: String, detail: String? = nil) {
        var lines = [
            "Time: \(debugTimestamp())",
            "Reason: \(reason)",
            "Request: GET https://api.anthropic.com/api/oauth/usage",
            "Attempt: \(attempt)"
        ]
        if let statusCode {
            lines.append("Status: \(statusCode)")
        }
        lines.append("Result: \(result)")
        if let detail, !detail.isEmpty {
            lines.append("Detail: \(detail)")
        }
        UsageAPIDebugLog.record(lines)
    }

    private static func recordHTTPRequest(
        reason: String,
        request: URLRequest,
        attempt: Int,
        response: URLResponse?,
        data: Data?,
        error: Error? = nil,
        result: String,
        detail: String? = nil
    ) {
        let http = response as? HTTPURLResponse
        var lines = [
            "Time: \(debugTimestamp())",
            "Reason: \(reason)",
            "Request: \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "unknown")",
            "Attempt: \(attempt)"
        ]
        if let statusCode = http?.statusCode {
            lines.append("Status: \(statusCode)")
        }
        lines.append("Result: \(result)")
        if result == "success" {
            if let detail, !detail.isEmpty {
                lines.append("Detail: \(detail)")
            }
        } else {
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
            if let detail, !detail.isEmpty {
                lines.append("  Detail: \(detail)")
            }
        }
        UsageAPIDebugLog.record(lines)
    }

    private static func sanitizedHeaders(from request: URLRequest) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            if key.caseInsensitiveCompare("Authorization") == .orderedSame {
                headers[key] = "<redacted>"
            } else {
                headers[key] = value
            }
        }
        return headers
    }

    private static func debugTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mma, MMM d"
        return formatter.string(from: Date())
    }

    private static func debugBucket(_ bucket: UsageResponse.Bucket?) -> String {
        guard let bucket else { return "nil" }
        let reset = bucket.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "nil"
        return "{ utilization: \(bucket.utilization), resetsAt: \(reset) }"
    }

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
                let reset = parseDate(dict["resets_at"]) ?? parseDate(dict["reset_at"]) ?? parseDate(dict["resetsAt"])
                return UsageResponse.Bucket(utilization: u, resetsAt: reset)
            }
            if let percent = root[k] as? Double {
                return UsageResponse.Bucket(utilization: percent > 1 ? percent / 100 : percent, resetsAt: nil)
            }
        }
        return nil
    }

    private static let iso = ISO8601DateFormatter()
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseDate(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        return iso.date(from: s) ?? isoFractional.date(from: s)
    }
}
