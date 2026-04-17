import Foundation
import Observation

enum MultiViewLayout: String, CaseIterable, Identifiable {
    case single
    case oneTwo
    case twoByTwo
    case threeByThree
    case focusedThumbnails

    var id: String { rawValue }

    var capacity: Int {
        switch self {
        case .single: return 1
        case .oneTwo: return 3
        case .twoByTwo: return 4
        case .threeByThree: return 9
        case .focusedThumbnails: return 9
        }
    }

    var label: String {
        switch self {
        case .single: return "Single"
        case .oneTwo: return "1 + 2"
        case .twoByTwo: return "2 × 2"
        case .threeByThree: return "3 × 3"
        case .focusedThumbnails: return "Focus + Thumbnails"
        }
    }

    var symbol: String {
        switch self {
        case .single: return "rectangle"
        case .oneTwo: return "rectangle.split.2x1"
        case .twoByTwo: return "rectangle.split.2x2"
        case .threeByThree: return "rectangle.split.3x3"
        case .focusedThumbnails: return "rectangle.grid.1x2"
        }
    }

    static func smallestFitting(_ count: Int) -> MultiViewLayout {
        switch count {
        case ...1: return .single
        case 2...3: return .oneTwo
        case 4: return .twoByTwo
        default: return .threeByThree
        }
    }
}

@MainActor
@Observable
final class PlayerSlot: Identifiable {
    let id = UUID()
    var channel: Channel
    var currentProgram: EPGProgram?

    /// StreamProxy token + localhost URL the mpv player connects to. The
    /// proxy fans bytes out from one upstream broadcaster, so viewer and
    /// recorder share the same provider connection.
    @ObservationIgnored private(set) var proxyToken: UUID
    @ObservationIgnored private(set) var proxiedURL: URL

    // MPVPlayer is created lazily on first access. SwiftUI re-invokes view
    // inits on every parent re-render; a discarded slot must not spawn an
    // mpv instance just to be torn down a moment later.
    @ObservationIgnored private var _player: MPVPlayer?
    @ObservationIgnored var player: MPVPlayer {
        if let existing = _player { return existing }
        let new = MPVPlayer()
        _player = new
        return new
    }

    init(channel: Channel, currentProgram: EPGProgram?) {
        self.channel = channel
        self.currentProgram = currentProgram
        let ref = StreamProxy.shared.proxiedURL(for: channel.streamURL)
        self.proxyToken = ref.token
        self.proxiedURL = ref.url
    }

    func unregisterFromRegistry() {
        // no-op now; kept for call-site compatibility.
    }

    /// Mint a fresh proxy token for the current channel. Proxy URLs are
    /// single-use (the route handler clears the token once mpv connects), so
    /// any reconnect after the first load — e.g. returning from catchup —
    /// needs a new token so bytes still flow through the shared broadcaster
    /// instead of mpv opening a second direct upstream connection.
    func freshProxiedURL() -> URL {
        let ref = StreamProxy.shared.proxiedURL(for: channel.streamURL)
        self.proxyToken = ref.token
        self.proxiedURL = ref.url
        return ref.url
    }
}

@MainActor
@Observable
final class PlayerSession {
    private(set) var slots: [PlayerSlot] = []
    private(set) var focusedSlotID: UUID
    var layout: MultiViewLayout

    private var started = false

    init(initialChannel: Channel, currentProgram: EPGProgram?) {
        let slot = PlayerSlot(channel: initialChannel, currentProgram: currentProgram)
        self.slots = [slot]
        self.focusedSlotID = slot.id
        self.layout = .single
    }

    /// Called from `PlayerView.onAppear`. Side effects (loadURL/play) must
    /// not run in `init` since SwiftUI may discard the PlayerSession.
    /// Pass `skipInitialLoad: true` when the caller is about to issue its own
    /// `loadURL` (e.g. a pending-catchup hand-off) so we don't fire a throw-
    /// away live load that mpv immediately replaces.
    func start(skipInitialLoad: Bool = false) {
        guard !started else { return }
        started = true
        guard !skipInitialLoad else { return }
        let first = slots[0]
        first.player.loadURL(first.proxiedURL)
        first.player.play()
    }

    var focusedSlot: PlayerSlot {
        slots.first { $0.id == focusedSlotID } ?? slots[0]
    }

    var isMulti: Bool { slots.count > 1 }

    func canAddMoreSlots() -> Bool {
        slots.count < MultiViewLayout.threeByThree.capacity
    }

    func addChannel(_ channel: Channel, currentProgram: EPGProgram?) {
        guard canAddMoreSlots() else { return }
        if let existing = slots.first(where: { $0.channel.id == channel.id }) {
            focus(slotID: existing.id)
            return
        }

        let slot = PlayerSlot(channel: channel, currentProgram: currentProgram)
        slots.append(slot)

        slot.player.loadURL(slot.proxiedURL)
        slot.player.play()
        // Apply mute AFTER loadURL+play: mpv initializes its audio output on
        // file load, and setting `mute` before that can race (a burst of
        // audio leaks out before the mute takes effect).
        applySlotPolicies()

        promoteLayoutIfNeeded()
    }

    func removeSlot(id: UUID) {
        guard slots.count > 1 else { return }
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return }

        let removed = slots[index]
        removed.player.setMute(true)
        removed.player.pause()
        removed.unregisterFromRegistry()

        slots.remove(at: index)

        if focusedSlotID == id, let first = slots.first {
            focusedSlotID = first.id
        }

        applySlotPolicies()
        demoteLayoutIfNeeded()
    }

    func focus(slotID: UUID) {
        guard slots.contains(where: { $0.id == slotID }) else { return }
        focusedSlotID = slotID
        applySlotPolicies()
    }

    func setLayout(_ layout: MultiViewLayout) {
        self.layout = layout
    }

    private func applySlotPolicies() {
        let multi = slots.count > 1
        for slot in slots {
            let focused = slot.id == focusedSlotID
            slot.player.setMute(!focused)
            slot.player.configureResources(multiView: multi, focused: focused)
        }
    }

    private func promoteLayoutIfNeeded() {
        let minimum = MultiViewLayout.smallestFitting(slots.count)
        if layout == .single || layout.capacity < slots.count {
            layout = minimum
        }
    }

    private func demoteLayoutIfNeeded() {
        if slots.count == 1 {
            layout = .single
        } else if layout.capacity > slots.count * 2 && layout != .focusedThumbnails {
            layout = MultiViewLayout.smallestFitting(slots.count)
        }
    }
}
