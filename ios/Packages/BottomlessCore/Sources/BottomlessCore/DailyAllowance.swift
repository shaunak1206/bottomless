import Foundation

/// How many new photos a day's backups may start. Under 100 waiting all go at once; with 100 or more,
/// a day takes half and the next day takes the rest, so a big batch is spread over two days.
/// Kept in the catalog, so the Shortcuts action, the nightly task and upload wake-ups share one count.
public final class DailyAllowance: @unchecked Sendable {
    public static let splitAt = 100
    private let catalog: Catalog
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    public init(catalog: Catalog, calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { Date() }) {
        self.catalog = catalog; self.calendar = calendar; self.now = now
    }

    private func day(_ d: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func int(_ key: String) -> Int? { catalog.value(key).flatMap { Int($0) } }
    private func set(_ key: String, _ value: String?) { try? catalog.setValue(value, for: key) }

    /// New items that may start now, with `waiting` not started yet; Int.max when today has no limit.
    /// The first day a backlog of 100 or more is seen gets half of it; the day after a split has no limit.
    public func remaining(waiting: Int) -> Int {
        let today = day(now())
        let yesterday = day(calendar.date(byAdding: .day, value: -1, to: now()) ?? now())
        if catalog.value("allowance.day") != today {
            set("allowance.day", today)
            set("allowance.used", "0")
            set("allowance.cap", nil)
        }
        let used = int("allowance.used") ?? 0
        let splitDay = catalog.value("allowance.splitDay")
        if int("allowance.cap") == nil, waiting >= Self.splitAt, splitDay != yesterday, splitDay != today {
            set("allowance.cap", String(used + (waiting + 1) / 2))
            set("allowance.splitDay", today)
        }
        guard let cap = int("allowance.cap") else { return .max }
        return max(0, cap - used)
    }

    /// Count `n` items started today.
    public func use(_ n: Int = 1) {
        set("allowance.used", String((int("allowance.used") ?? 0) + n))
    }

    /// Of `waiting` items, how many today's allowance leaves for tomorrow.
    public func leftForTomorrow(waiting: Int) -> Int {
        max(0, waiting - min(waiting, remaining(waiting: waiting)))
    }
}
