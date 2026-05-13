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
