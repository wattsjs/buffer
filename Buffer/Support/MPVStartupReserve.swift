/// A bounded startup trial. It holds the initial live load for mpv's existing
/// cache-pause-wait reserve instead of playing a short burst before pausing.
/// No preference changes; completed diagnostics cannot alter ordinary loads.
@MainActor
enum MPVStartupReserve {
    static func enabled(forLiveLoad live: Bool) -> Bool {
#if DEBUG
        enabled(forLiveLoad: live,
                validationActive: PlaybackValidation.isEnabled || SavedPlaybackScenario.isCapturing,
                flagRequested: CommandLine.arguments.contains("--validate-startup-reserve"))
#else
        false
#endif
    }

    nonisolated static func enabled(forLiveLoad live: Bool, validationActive: Bool, flagRequested: Bool) -> Bool {
#if DEBUG
        live && validationActive && flagRequested
#else
        false
#endif
    }
}
