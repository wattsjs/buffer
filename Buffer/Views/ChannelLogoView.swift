import SwiftUI
import NukeUI
import Nuke

/// Channel logo backed by `LogoAtlas`. A row resolves its URL to an integer
/// handle once at init; rendering is an array read of the published slot
/// image. Misses decode off the main thread at slot size and re-render this
/// view when the slot becomes resident.
struct ChannelLogoView: View {
    let url: URL?
    var fallbackSystemImage: String = "tv"
    var contentInset: CGFloat = 5
    var onComputedColor: ((NSColor) -> Void)? = nil

    private let handle: LogoHandle?
    @State private var generation: UInt32 = 0

    init(
        url: URL?,
        fallbackSystemImage: String = "tv",
        contentInset: CGFloat = 5,
        onComputedColor: ((NSColor) -> Void)? = nil
    ) {
        self.url = url
        self.fallbackSystemImage = fallbackSystemImage
        self.contentInset = contentInset
        self.onComputedColor = onComputedColor
        self.handle = url.map { LogoAtlas.shared.handle(for: $0) }
    }

    /// For rows that already hold a logo handle (no URL interning).
    init(
        handle: LogoHandle,
        fallbackSystemImage: String = "tv",
        contentInset: CGFloat = 5,
        onComputedColor: ((NSColor) -> Void)? = nil
    ) {
        self.url = nil
        self.fallbackSystemImage = fallbackSystemImage
        self.contentInset = contentInset
        self.onComputedColor = onComputedColor
        self.handle = handle
    }

    var body: some View {
        // `generation` bumps when a load finishes so the body re-reads the atlas.
        let _ = generation
        Group {
            if let handle {
                let atlas = LogoAtlas.shared
                if let image = atlas.image(handle) {
                    logo(image)
                } else if atlas.isFailed(handle) {
                    placeholder
                } else {
                    placeholder
                        .task(id: handle) { await load(handle, atlas: atlas) }
                }
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load(_ handle: LogoHandle, atlas: LogoAtlas) async {
        // Parent tiles seed their background from the colour column at init.
        // Only deliver a colour that this load produced, so an already-known
        // colour never kicks the parent's @State into a re-render loop.
        let hadColor = atlas.packedColor(handle) != 0
        let loaded = await atlas.load(handle)
        if loaded, !hadColor, let onComputedColor,
           let color = LogoColorAnalyzer.color(packed: atlas.packedColor(handle)) {
            onComputedColor(color)
        }
        generation &+= 1
    }

    private func logo(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .padding(contentInset)
    }

    private var placeholder: some View {
        ZStack {
            Color.clear
            Image(systemName: fallbackSystemImage)
                .font(BufferFont.iconLarge)
                .foregroundStyle(.secondary)
        }
    }
}

struct RemoteArtworkView: View {
    let url: URL?
    let fallbackSystemImage: String
    let width: CGFloat
    let height: CGFloat
    var scaledToFill = true

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            if let url, !ImageLoader.isFailed(url) {
                let request = artworkRequest(for: url)
                if let cached = ImageLoader.pipeline.cache[request] {
                    artwork(Image(nsImage: cached.image))
                } else {
                    LazyImage(request: request) { state in
                        if let image = state.image {
                            artwork(image)
                        } else {
                            fallbackIcon
                        }
                    }
                    .onCompletion { result in
                        if case .failure(let error) = result {
                            ImageLoader.markFailed(url, unlessCancelled: error)
                        }
                    }
                    .pipeline(ImageLoader.pipeline)
                }
            } else {
                fallbackIcon
            }
        }
        .frame(width: width, height: height)
    }

    private func artwork(_ image: Image) -> some View {
        image
            .resizable()
            .interpolation(.medium)
            .aspectRatio(contentMode: scaledToFill ? .fill : .fit)
    }

    private var fallbackIcon: some View {
        Image(systemName: fallbackSystemImage)
            .font(.system(size: min(width, height) * 0.42, weight: .regular))
            .foregroundStyle(.tertiary)
    }

    private func artworkRequest(for url: URL) -> ImageRequest {
        ImageLoader.artworkRequest(
            for: url,
            size: CGSize(width: width, height: height),
            displayScale: displayScale,
            contentMode: scaledToFill ? .aspectFill : .aspectFit
        )
    }
}

struct ChannelLogoTile: View {
    let channel: Channel
    var cornerRadius: CGFloat = 8
    var contentInset: CGFloat = 6

    @State private var bgColor: Color

    init(channel: Channel, cornerRadius: CGFloat = 8, contentInset: CGFloat = 6) {
        self.channel = channel
        self.cornerRadius = cornerRadius
        self.contentInset = contentInset
        if let url = channel.logoURL, let cached = LogoColorAnalyzer.cachedColor(for: url) {
            _bgColor = State(initialValue: Color(nsColor: cached))
        } else {
            _bgColor = State(initialValue: Color(nsColor: .textBackgroundColor))
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(bgColor)
            ChannelLogoView(url: channel.logoURL, contentInset: contentInset) { color in
                withAnimation(.easeInOut(duration: 0.25)) {
                    bgColor = Color(nsColor: color)
                }
            }
        }
    }
}
