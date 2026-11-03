/// Experimental archive-only workaround for MPEG-TS clock resets which
/// libavformat interprets as a 33-bit wrap. Linearization makes low-level
/// seeks unsafe, so callers must reload archive URLs for wall-clock moves.
@MainActor
enum ArchiveTimestampRecovery {
    static var validationRequested: Bool {
#if DEBUG
        CommandLine.arguments.contains("--validate-archive-timestamps")
            && (PlaybackValidation.isEnabled || SavedPlaybackScenario.isCapturing)
#else
        false
#endif
    }

    struct Options: Equatable {
        let enabled: Bool
        let lavf: String
        let linearize: String
    }

    static func options(forArchiveLoad archive: Bool,
                        validationRequested: Bool? = nil) -> Options {
        let enabled = archive && (validationRequested ?? Self.validationRequested)
        let baseline = "fflags=+discardcorrupt+genpts+igndts,http_persistent=1,http_multiple=1,seg_max_retry=2,extension_picky=0"
        return Options(enabled: enabled,
                       lavf: baseline + ",correct_ts_overflow=" + (enabled ? "0" : "1"),
                       linearize: enabled ? "yes" : "auto")
    }
}
