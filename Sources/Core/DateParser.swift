import Foundation

public enum DateParser {
    /// Accepts ISO ("2026-08-27 14:00", "2026-08-27"), naturals ("today",
    /// "tomorrow 9am", "friday"), time-only ("2pm", "14:30" = today), and
    /// offsets ("+7d", "+2h", "+30m"). Returns nil on anything else.
    public static func parse(_ input: String, now: Date, calendar: Calendar) -> Date? {
        let s = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }

        if s.hasPrefix("+") { return offset(s, from: now, calendar: calendar) }
        if let d = formatter("yyyy-MM-dd HH:mm", calendar).date(from: s) { return d }
        if let d = formatter("yyyy-MM-dd", calendar).date(from: s) { return d }

        var words = s.split(separator: " ").map(String.init)
        var time: (hour: Int, minute: Int)?
        if let last = words.last, let t = parseTime(last) {
            time = t
            words.removeLast()
        }
        let dayWord = words.joined(separator: " ")

        var day: Date?
        switch dayWord {
        case "", "today":
            day = calendar.startOfDay(for: now)
        case "tomorrow":
            day = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        default:
            day = weekdayNumber(dayWord).flatMap { next(weekday: $0, after: now, calendar: calendar) }
        }
        guard let base = day, !(dayWord.isEmpty && time == nil) else { return nil }
        guard let t = time else { return base }
        return calendar.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: base)
    }

    static func formatter(_ format: String, _ calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = format
        return f
    }

    static func offset(_ s: String, from now: Date, calendar: Calendar) -> Date? {
        guard s.count >= 3, let value = Double(s.dropFirst().dropLast()) else { return nil }
        switch s.last {
        case "d":
            // Calendar-day arithmetic keeps "+7d" at the same wall-clock time across
            // DST transitions; fall back to elapsed time for fractional or huge values.
            if value == value.rounded(), let days = Int(exactly: value) {
                return calendar.date(byAdding: .day, value: days, to: now)
            }
            return now.addingTimeInterval(value * 86_400)
        case "h": return now.addingTimeInterval(value * 3_600)
        case "m": return now.addingTimeInterval(value * 60)
        default: return nil
        }
    }

    static func parseTime(_ s: String) -> (hour: Int, minute: Int)? {
        var body = s
        var meridiem: String?
        if body.hasSuffix("am") || body.hasSuffix("pm") {
            meridiem = String(body.suffix(2))
            body = String(body.dropLast(2))
        }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2, let hour = Int(parts[0]) else { return nil }
        let minute = parts.count == 2 ? Int(parts[1]) ?? -1 : 0
        guard (0...59).contains(minute) else { return nil }
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            return (hour % 12 + (meridiem == "pm" ? 12 : 0), minute)
        }
        // Without am/pm, require an explicit HH:mm — a bare number is ambiguous.
        guard parts.count == 2, (0...23).contains(hour) else { return nil }
        return (hour, minute)
    }

    static func weekdayNumber(_ s: String) -> Int? {
        ["sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
         "thursday": 5, "friday": 6, "saturday": 7][s]
    }

    static func next(weekday: Int, after now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        for i in 1...7 {
            if let d = calendar.date(byAdding: .day, value: i, to: today),
               calendar.component(.weekday, from: d) == weekday {
                return d
            }
        }
        return nil
    }
}

public enum DurationParser {
    /// "1h", "30m", "1h30m", "2d" -> seconds. Requires an explicit unit.
    public static func parse(_ input: String) -> TimeInterval? {
        let s = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }
        var total: TimeInterval = 0
        var digits = ""
        var sawComponent = false
        for ch in s {
            if ch.isNumber {
                digits.append(ch)
                continue
            }
            guard let value = Double(digits) else { return nil }
            switch ch {
            case "d": total += value * 86_400
            case "h": total += value * 3_600
            case "m": total += value * 60
            default: return nil
            }
            digits = ""
            sawComponent = true
        }
        guard digits.isEmpty, sawComponent else { return nil }
        return total
    }
}
