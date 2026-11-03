@MainActor
enum MPVNativeCacheOnly {
    static func enabled(forLiveLoad live: Bool) -> Bool {
#if DEBUG
        enabled(forLiveLoad: live,
                validationActive: PlaybackValidation.isEnabled || SavedPlaybackScenario.isCapturing,
                flagRequested: CommandLine.arguments.contains("--validate-native-cache-only"))
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
