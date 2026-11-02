// Drives continuous vertical scrolling over the running Debug Buffer window
// so guide rendering can be observed (telemetry or screen capture).
// Usage: swift scripts/scroll-epg.swift [seconds] [pixelsPerEvent]
import AppKit
import CoreGraphics

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "6") ?? 6
let step = Int32(CommandLine.arguments.dropFirst(2).first ?? "40") ?? 40

let apps = NSWorkspace.shared.runningApplications.filter {
    $0.executableURL?.path.contains("DerivedData/Build/Products/Debug/Buffer.app") == true
}
guard let app = apps.first else { fputs("Debug Buffer is not running\n", stderr); exit(1) }
app.activate()
Thread.sleep(forTimeInterval: 0.5)

let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
    .filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }
guard let bounds = windows.compactMap({ $0[kCGWindowBounds as String] as? [String: CGFloat] })
    .max(by: { ($0["Width"] ?? 0) * ($0["Height"] ?? 0) < ($1["Width"] ?? 0) * ($1["Height"] ?? 0) }) else {
    fputs("No Buffer window on screen\n", stderr); exit(1)
}
let x = bounds["X"]!, y = bounds["Y"]!, w = bounds["Width"]!, h = bounds["Height"]!
print("window \(Int(x)),\(Int(y)),\(Int(w)),\(Int(h))")
// Over the programme grid: right of the channel column, below the header.
let point = CGPoint(x: x + w * 0.6, y: y + h * 0.55)
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)

let interval = 1.0 / 120.0
let deadline = Date().addingTimeInterval(seconds)
var direction: Int32 = -1
var flipAt = Date().addingTimeInterval(seconds / 4)
while Date() < deadline {
    if Date() >= flipAt { direction = -direction; flipAt = Date().addingTimeInterval(seconds / 4) }
    let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: direction * step, wheel2: 0, wheel3: 0)
    event?.location = point
    event?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: interval)
}
print("scrolled \(seconds)s")
