enum MPVEndReason: Equatable, Sendable {
    /// Playback was stopped by a `stop` command or a new `loadfile`.
    case stopped
    /// mpv reached EOF. For live streams this is usually a false EOF and the
    /// owner should reconnect; for finite files it's the end of playback.
    case eof
    /// An mpv error code (see `mpv_error_string`).
    case error(code: Int32, message: String)
    /// HTTP 509 Bandwidth Limit Exceeded — provider is throttling.
    /// Treated separately from generic errors because the recovery strategy
    /// is fundamentally different: back off much longer, stop other streams
    /// if account-level, and never retry at the segment-fetch level.
    case http509(message: String)

    var isRecoverable: Bool {
        switch self {
        case .stopped: return false
        case .eof, .error, .http509: return true
        }
    }
}

enum MPVStreamIssue: Equatable, Sendable {
    case httpError(String)
    case hlsReloadFailed(String)
    case reconnecting(String)

    var recoveryMessage: String {
        switch self {
        case .httpError(let message), .hlsReloadFailed(let message), .reconnecting(let message):
            message
        }
    }
}

