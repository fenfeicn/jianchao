import Foundation

public enum HistoryDateFilter: Equatable, Sendable {
    case all, today, yesterday, last7Days, last30Days
    case custom(start: Date, end: Date)

    public var title: String {
        switch self {
        case .all: return "全部日期"
        case .today: return "今天"
        case .yesterday: return "昨天"
        case .last7Days: return "近 7 天"
        case .last30Days: return "近 30 天"
        case .custom: return "指定日期"
        }
    }
    /// End is exclusive, so midnight of the following day never leaks in.
    public func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval? {
        let today = calendar.startOfDay(for: now)
        let start: Date
        let endDay: Date
        switch self {
        case .all: return nil
        case .today: start = today; endDay = today
        case .yesterday:
            start = calendar.date(byAdding: .day, value: -1, to: today) ?? today; endDay = start
        case .last7Days:
            start = calendar.date(byAdding: .day, value: -6, to: today) ?? today; endDay = today
        case .last30Days:
            start = calendar.date(byAdding: .day, value: -29, to: today) ?? today; endDay = today
        case .custom(let from, let to):
            start = calendar.startOfDay(for: min(from, to))
            endDay = calendar.startOfDay(for: max(from, to))
        }
        let end = calendar.date(byAdding: .day, value: 1, to: endDay) ?? endDay
        return DateInterval(start: start, end: end)
    }
}
