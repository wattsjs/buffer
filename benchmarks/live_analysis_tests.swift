import Foundation

@main enum LiveAnalysisTests {
    static func main() {
        var checks = 0
        func check(_ condition: Bool, _ message: String) { checks += 1; precondition(condition, message) }
        func options(_ path: String = "https://example.test/live/channel.m3u8", live: Bool = true,
                     archive: Bool = false, fast: Bool = false, active: Bool = true,
                     arguments: [String] = ["--validate-live-analysis=2"]) -> MPVLoadProbeOptions {
            MPVLoadProbeOptions.configuration(url: URL(string: path)!, live: live, archive: archive,
                fastProbe: fast, validationActive: active, arguments: arguments)
        }
        let baseline = MPVLoadProbeOptions.baseline
        check(baseline.analyzeDurationSeconds == 5 && baseline.probeSize == 2_097_152 && baseline.probeInfo == "auto",
            "ordinary playback must preserve analysis, probe budget and stream discovery")
        let fast = options("file:///recording.ts", live: false, fast: true)
        check(fast.analyzeDurationSeconds == 0.1 && fast.probeSize == 65_536 && fast.liveAnalysisRequestedSeconds == nil,
            "the existing local-recording path must retain its own explicit settings")

        for seconds in ["1", "2"] {
            for ext in ["m3u8", "M3U8", "m3u", "ts"] {
                let trial = options("https://example.test/live/channel.\(ext)", arguments: ["--validate-live-analysis=\(seconds)"])
#if DEBUG
                check(trial.analyzeDurationSeconds == Double(seconds)! && trial.liveAnalysisRequestedSeconds == Double(seconds)!,
                    "recognized live format in active DEBUG capture must apply the selected ceiling")
                check(trial.probeSize == baseline.probeSize && trial.probeInfo == "auto",
                    "a shorter ceiling must retain detection budget and complete stream-info policy")
#else
                check(trial == baseline, "Release must ignore diagnostic analysis requests")
#endif
            }
        }
        for item in [
            options(active: false), options(live: false), options(archive: true),
            options("file:///channel.ts"), options("ftp://example.test/channel.ts"),
            options("https://example.test/live/channel"), options("https://example.test/live/channel.mp4"),
            options("https://example.test/live/channel?token=pretend.m3u8"),
            options(arguments: []), options(arguments: ["--validate-live-analysis", "2"]),
            options(arguments: ["--validate-live-analysis=2", "--validate-live-analysis=1"])
        ] {
            check(item == baseline, "ineligible, unknown or ambiguous input must retain baseline probe options")
        }
        for value in ["", "0", "3", "-1", "NaN", "inf", "2.0", "2junk", "other=2"] {
            check(options(arguments: ["--validate-live-analysis=\(value)"]) == baseline,
                "unsupported or malformed analysis request must not alter playback")
        }
        let sequence = [options(), options(live: false), fast, options(archive: true), options(active: false)]
        check(sequence[1].perFileOptions.contains("analyzeduration=5.0") && sequence[3] == baseline && sequence[4] == baseline,
            "trial to finite, archive and completed capture must bind baseline values on the next entry")
        check(fast.perFileOptions.contains("probesize=65536") && fast.perFileOptions.contains("analyzeduration=0.1"),
            "local fast settings must bind to that entry rather than inherit a preceding live trial")
        check(!sequence.map(\.perFileOptions).joined().contains("example.test"),
            "per-entry probe options may contain settings only, never input URLs")

        var phases = MPVStartupPhases()
        phases.reset(generation: 4, enabled: true)
        phases.note(.redirectStarted, generation: 4, elapsedMilliseconds: 5)
        phases.note(.redirectCompleted, generation: 3, elapsedMilliseconds: 10)
        check(phases.timingsMilliseconds["redirectCompleted"] == nil, "old load cannot append startup timing")
        for value in [-1, Double.nan, Double.infinity, 120_001] {
            phases.note(.redirectCompleted, generation: 4, elapsedMilliseconds: value)
            check(phases.timingsMilliseconds["redirectCompleted"] == nil, "invalid timing cannot enter numeric telemetry")
        }
        phases.note(.redirectCompleted, generation: 4, elapsedMilliseconds: 20)
        phases.note(.redirectCompleted, generation: 4, elapsedMilliseconds: 25)
        check(phases.timingsMilliseconds["redirectCompleted"] == 20, "duplicate callbacks must preserve first milestone")
        check(phases.timingsMilliseconds.count == 3, "collector retains only fixed first milestones")
        phases.reset(generation: 5, enabled: true)
        check(phases.timingsMilliseconds == ["loadStarted": 0], "replacement must clear preceding startup phases")
        phases.reset(generation: 6, enabled: false)
        phases.note(.firstRender, generation: 6, elapsedMilliseconds: 10)
        check(phases.timingsMilliseconds.isEmpty, "ordinary playback and reuse must disable phase collection")
        check((try? JSONSerialization.data(withJSONObject: phases.timingsMilliseconds)) != nil,
            "phase output must always be JSON-safe")
        var raw = PlaybackClockSample()
        check(raw.current(generation: 1, at: 10) == nil, "unobserved clocks must remain unavailable")
        raw.observe(1.26, generation: 1, at: 10.26)
        check(raw.current(generation: 1, at: 10.26)?.seconds == 1.26,
            "clock telemetry must retain fractional progress hidden by the UI threshold")
        check(raw.current(generation: 1, at: 10.51).map { abs($0.ageMilliseconds - 250) < 0.000001 } == true,
            "receipt age must identify the time represented by the raw clock")
        raw.observe(1.52, generation: 1, at: 10.52)
        check(raw.current(generation: 1, at: 10.52)?.seconds == 1.52,
            "adjacent samples must expose smooth fractional motion, not a UI jump and zero pair")
        check(raw.current(generation: 2, at: 10.52) == nil, "a prior generation cannot prove source continuity")
        check(raw.current(generation: 1, at: 10.51) == nil, "a backward receipt clock must not prove freshness")
        check(raw.current(generation: 1, at: 13.02) != nil, "bounded receipt age remains available through its deadline")
        check(raw.current(generation: 1, at: 13.0201) == nil, "stale raw position and age must both become unavailable")
        for value in [Double?.none, .some(.nan), .some(.infinity), .some(-.infinity)] {
            raw.observe(2, generation: 2, at: 20)
            raw.observe(value, generation: 2, at: 20.1)
            check(raw.current(generation: 2, at: 20.2) == nil,
                "an unavailable/invalid clock must retire the last position immediately")
        }
        raw.observe(-0.02, generation: 3, at: 30)
        check(raw.current(generation: 3, at: 30)?.seconds == -0.02,
            "finite preroll/source positions must remain truthful evidence")
        raw.observe(4, generation: 3, at: .nan)
        check(raw.current(generation: 3, at: 30.1) == nil, "invalid receipt time cannot refresh an older clock")
        raw.observe(4, generation: 4, at: 40)
        check(raw.current(generation: 4, at: .infinity) == nil, "invalid sample-read clock cannot emit a numeric age")
        raw.reset()
        check(raw.current(generation: 4, at: 40) == nil, "load, stop and handle reuse must clear raw clocks")
        print("PASS \(checks) live analysis and phase scoping checks")
    }
}
