import AppKit
import Foundation

enum ExternalPlayerKind: String, CaseIterable, Identifiable {
    case none
    case iina
    case vlc
    case infuse
    case vidhub

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .iina: return "IINA"
        case .vlc: return "VLC"
        case .infuse: return "Infuse"
        case .vidhub: return "VidHub"
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .none: return nil
        case .iina: return "com.colliderli.iina"
        case .vlc: return "org.videolan.vlc"
        case .infuse: return "com.firecore.infuse"
        case .vidhub: return nil
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

        let raw = streamURL.absoluteString

        switch kind {
        case .none:
            return

        case .iina:
            var components = URLComponents(string: "iina://weblink") ?? URLComponents()
            components.queryItems = [URLQueryItem(name: "url", value: raw)]
            if let url = components.url,
               NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
                NSWorkspace.shared.open(url)
                return
            }

        case .vlc:
            // VLC supports vlc:// and x-callback style
            var components = URLComponents(string: "vlc://") ?? URLComponents()
            components.queryItems = [URLQueryItem(name: "url", value: raw)]
            if let url = components.url,
               NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
                NSWorkspace.shared.open(url)
                return
            }
            // Fallback: try direct open with VLC bundle if available
            if let vlcURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.videolan.vlc") {
                NSWorkspace.shared.open([streamURL], withApplicationAt: vlcURL, configuration: .init(), completionHandler: nil)
                return
            }

        case .infuse:
            var components = URLComponents(string: "infuse://x-callback-url/open") ?? URLComponents()
            components.queryItems = [URLQueryItem(name: "url", value: raw)]
            if let url = components.url,
               NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
                NSWorkspace.shared.open(url)
                return
            }

        case .vidhub:
            var components = URLComponents(string: "open-vidhub://x-callback-url/open") ?? URLComponents()
            components.queryItems = [URLQueryItem(name: "url", value: raw)]
            if let url = components.url,
               NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
                NSWorkspace.shared.open(url)
                return
            }
        }

        // Final fallback: let the system decide (or open in browser for http streams)
        NSWorkspace.shared.open(streamURL)
    }
}
