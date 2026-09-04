import Foundation

/// `HH:mm` in a fixed locale, once. A `DateFormatter` with an explicit `dateFormat` still
/// honours the user's locale, so under a 12-hour region the pattern is rewritten and one
/// adapter's rows would render differently from another's; `en_US_POSIX` pins it. Built
/// once — DateFormatter is expensive.
enum ClockFormat {
    nonisolated(unsafe) static let hhmm: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "HH:mm"
        return f
    }()

    /// "14:05" for `date`, local time.
    static func hhmm(_ date: Date) -> String { hhmm.string(from: date) }
}
