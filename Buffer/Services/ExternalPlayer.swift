import AppKit
import Foundation

enum ExternalPlayerKind: String, CaseIterable, Identifiable {
    case none
    case iina
    case vidhub

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .iina: return "IINA"
        case .vidhub: return "VidHub"
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .none: return nil
        case .iina: return "com.colliderli.iina"
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
            var components = URLComponents(string: "iina://weblink")!
            components.queryItems = [URLQueryItem(name: "url", value: raw)]
            if let url = components.url,
               NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
                NSWorkspace.shared.open(url)
                return
            }

        case .vidhub:
            var components = URLComponents(string: "open-vidhub://x-callback-url/open")!
            components.queryItems = [URLQueryItem(name: "url", value: raw)]
            if let url = components.url,
               NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
                NSWorkspace.shared.open(url)
                return
            }
        }

        NSWorkspace.shared.open(streamURL)
    }
}
