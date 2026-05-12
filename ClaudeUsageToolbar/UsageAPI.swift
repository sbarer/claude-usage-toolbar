import Foundation

struct UsageResponse {
    struct Bucket {
        let utilization: Double
        let resetsAt: Date?
    }
    let fiveHour: Bucket?
    let sevenDay: Bucket?
    let sevenDayOpus: Bucket?
}

enum UsageFetchResult {
    case success(UsageResponse)
    case unauthenticated
    case rateLimited
    case failure(String)
}

final class UsageAPI {
    private let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let betaHeader = "oauth-2025-04-20"
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    func fetch(completion: @escaping (UsageFetchResult) -> Void) {
        let token: String
        do {
            token = try KeychainTokenStore.readAccessToken()
        } catch KeychainTokenStore.Error.notFound {
            completion(.unauthenticated); return
        } catch {
            completion(.failure("keychain: \(error)")); return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("claude-usage-toolbar/1.0", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: req) { data, response, error in
            if let error {
                completion(.failure(error.localizedDescription)); return
            }
            guard let http = response as? HTTPURLResponse, let data else {
                completion(.failure("no response")); return
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                completion(.unauthenticated); return
            }
            if http.statusCode == 429 {
                completion(.rateLimited); return
            }
            if !(200...299).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? ""
                completion(.failure("http \(http.statusCode): \(body.prefix(200))"))
                return
            }
            do {
                let parsed = try Self.parse(data)
                completion(.success(parsed))
            } catch {
                completion(.failure("parse: \(error)"))
            }
        }.resume()
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
