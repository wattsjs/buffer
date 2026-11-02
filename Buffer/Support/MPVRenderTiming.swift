/// Paired render timing experiment. A launch flag cannot alter normal playback
/// or Release builds, and no value is written to persistent user settings.
@MainActor
enum MPVRenderTiming {
    static var validationNoBlock: Bool {
#if DEBUG
        guard PlaybackValidation.isEnabled || SavedPlaybackScenario.isCapturing else { return false }
        return CommandLine.arguments.contains("--validate-render-no-block")
#else
        false
#endif
    }

    // The render API recommends offset=0 when disabling its presentation wait.
    // Changing only the wait leaves the existing early-video offset in place.
    static var videoTimingOffset: String { validationNoBlock ? "0" : "0.016" }
    static var blockForTargetTime: Int32 { validationNoBlock ? 0 : 1 }
}
