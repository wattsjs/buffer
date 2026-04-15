import AppKit
import Foundation

enum ExternalPlayerKind: String, CaseIterable, Identifiable {
    case none
    case iina
    case vlc
    case mpv
    case quickTime

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .iina: return "IINA"
        case .vlc: return "VLC"
        case .mpv: return "mpv"
        case .quickTime: return "QuickTime Player"
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .none: return nil
        case .iina: return "com.colliderli.iina"
        case .vlc: return "org.videolan.vlc"
        case .mpv: return "io.mpv"
        case .quickTime: return "com.apple.QuickTimePlayerX"
        }
    }
}

enum ExternalPlayer {
    static let selectedPlayerKey = "buffer_external_player"

    static var selected: ExternalPlayerKind {
        let raw = UserDefaults.standard.string(forKey: selectedPlayerKey) ?? ExternalPlayerKind.none.rawValue
        return ExternalPlayerKind(rawValue: raw) ?? .none
    }

    static var isEnabled: Bool { selected != .none }

    static func launch(streamURL: URL) {
        launch(streamURL: streamURL, using: selected)
    }

    static func launch(streamURL: URL, using kind: ExternalPlayerKind) {
        guard kind != .none else { return }

        if kind == .iina {
            let encoded = streamURL.absoluteString
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? streamURL.absoluteString
            if let iinaURL = URL(string: "iina://weblink?url=\(encoded)"),
               NSWorkspace.shared.urlForApplication(toOpen: iinaURL) != nil {
                NSWorkspace.shared.open(iinaURL)
                return
            }
        }

        if let bundleID = kind.bundleIdentifier,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([streamURL], withApplicationAt: appURL, configuration: config, completionHandler: nil)
            return
        }

        NSWorkspace.shared.open(streamURL)
    }
}
