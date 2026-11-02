import Foundation

/// Header titles are constant throughout a local calendar day. Keep the
/// 14-day catchup header out of the live-line ticker's formatting hot path.
final class EPGTimeStripCache {
    private struct Inputs: Equatable {
        let start: Date
        let hours: Int
        let pixelsPerMinute: CGFloat
        let relativeDay: Date
        let calendar: Calendar
        let localeID: String
    }

    private var inputs: Inputs?
    private var cachedSlots: [TimeStripSlot] = []

    func slots(start: Date, hours: Int, pixelsPerMinute: CGFloat, relativeTo now: Date) -> [TimeStripSlot] {
        let calendar = Calendar.current
        let next = Inputs(start: start, hours: hours, pixelsPerMinute: pixelsPerMinute,
                          relativeDay: calendar.startOfDay(for: now), calendar: calendar,
                          localeID: Locale.current.identifier)
        guard next != inputs else { return cachedSlots }
        inputs = next
        cachedSlots = (0..<(max(0, hours) * 2)).map { index in
            let date = start.addingTimeInterval(Double(index) * 30 * 60)
            let title = calendar.isDate(date, inSameDayAs: now)
                ? date.formatted(date: .omitted, time: .shortened)
                : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            return TimeStripSlot(x: CGFloat(index) * 30 * pixelsPerMinute, title: title)
        }
        return cachedSlots
    }
}
