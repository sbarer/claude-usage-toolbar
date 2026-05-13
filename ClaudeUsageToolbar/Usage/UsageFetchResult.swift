import Foundation

enum UsageFetchResult {
    case success(UsageResponse, attempts: Int)
    case unauthenticated(attempts: Int)
    case rateLimited(attempts: Int)
    case failure(String, attempts: Int)
}
