import Foundation

/// A disclosure is local to the currently matched channels. Source changes
/// with reused channel IDs must reset it too, so identity includes the URL.
nonisolated struct StreamMatchDisclosureIdentity: Equatable {
    let channelID: String
    let streamURL: URL
    let isHidden: Bool
}

nonisolated struct StreamMatchVisibility {
    let visible: [StreamMatch]
    let hidden: [StreamMatch]
    let disclosureIdentity: [StreamMatchDisclosureIdentity]

    init(matches: [StreamMatch]) {
        visible = matches.filter { !$0.isHidden }
        hidden = matches.filter(\.isHidden)
        disclosureIdentity = matches.map {
            StreamMatchDisclosureIdentity(channelID: $0.channel.preferenceIdentity, streamURL: $0.channel.streamURL, isHidden: $0.isHidden)
        }
    }

    var hasOnlyHiddenMatches: Bool { visible.isEmpty && !hidden.isEmpty }

    func displayedMatches(showHidden: Bool) -> [StreamMatch] {
        hasOnlyHiddenMatches && showHidden ? hidden : visible
    }
}
