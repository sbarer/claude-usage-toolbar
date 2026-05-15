import Foundation

enum UsageFetchResult {
    static let rateLimitFallbackSeconds: TimeInterval = 150

    case success(UsageResponse, attempts: Int)
    case unauthenticated(attempts: Int)
    case rateLimited(retryAfter: TimeInterval?, attempts: Int)
    case failure(String, attempts: Int)
}
