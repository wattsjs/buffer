import Foundation

/// The guide's horizontal extent on iOS and tvOS: from the replay lookback
/// (capped) to a day ahead, snapped to half hours so the time strip and the
/// rows share one origin.
struct GuideTimelineWindow: Equatable {
    var start: Date
    var hours: Int
    var pixelsPerMinute: Double

    static let slot: TimeInterval = 30 * 60

    init(now: Date = Date(), hoursBack: Int = 3, hoursAhead: Int = 24, pixelsPerMinute: Double) {
        let origin = now.addingTimeInterval(-Double(hoursBack) * 3600).timeIntervalSinceReferenceDate
        start = Date(timeIntervalSinceReferenceDate: (origin / Self.slot).rounded(.down) * Self.slot)
        hours = hoursBack + hoursAhead + 1
        self.pixelsPerMinute = pixelsPerMinute
    }

    var end: Date { start.addingTimeInterval(Double(hours) * 3600) }
    var width: Double { Double(hours) * 60 * pixelsPerMinute }

    func x(for date: Date) -> Double { date.timeIntervalSince(start) / 60 * pixelsPerMinute }

    func timeStrip(now: Date = Date()) -> EPGTimeStripSpec {
        EPGTimeStripSpec(start: start, hours: hours, pixelsPerMinute: CGFloat(pixelsPerMinute), relativeTo: now)
    }
}
