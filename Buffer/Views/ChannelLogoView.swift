import SwiftUI
import NukeUI
import Nuke

struct ChannelLogoView: View {
    let url: URL?
    var fallbackSystemImage: String = "tv"
    var contentInset: CGFloat = 5
    var onComputedColor: ((NSColor) -> Void)? = nil

    var body: some View {
        Group {
            if let url, !ImageLoader.isFailed(url) {
                // Reused guide rows get a fresh LazyImage, which renders its
                // placeholder for a frame even on a memory-cache hit. Draw a
                // cached logo immediately so scrolling never flashes icons.
                if let cached = ImageLoader.pipeline.cache[url] {
                    logo(Image(nsImage: cached.image))
                        .onAppear { analyzeColorIfNeeded(url: url, image: cached.image) }
                } else {
                    LazyImage(url: url) { state in
                        if let image = state.image {
                            logo(image)
                        } else {
                            placeholder
                        }
                    }
                    .onCompletion { result in
                        handleCompletion(url: url, result: result)
                    }
                    .pipeline(ImageLoader.pipeline)
                }
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func logo(_ image: Image) -> some View {
        image
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

    private func handleCompletion(url: URL, result: Result<ImageResponse, Error>) {
        switch result {
        case .failure(let error):
            ImageLoader.markFailed(url, unlessCancelled: error)
        case .success(let response):
            // Parent cells seed their background from `LogoColorAnalyzer.cachedColor`
            // at init. If that cache already holds a value, delivering it again
            // here would kick the parent's @State and re-render the cell, which
            // in turn re-instantiates this view and refires onCompletion — a
            // tight feedback loop that pegged the CPU when combined with
            // uncached failing logo URLs.
            // Only perform (expensive) color analysis when the caller actually
            // subscribes to the result. This eliminates wasted decode + CG work
            // for the many logo sites that only need the image (player chrome,
            // small list rows, etc.).
            analyzeColorIfNeeded(url: url, image: response.image)
        }
    }

    private func analyzeColorIfNeeded(url: URL, image: NSImage) {
        guard onComputedColor != nil else { return }
        if LogoColorAnalyzer.cachedColor(for: url) != nil {
            return
        }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }
        LogoColorAnalyzer.color(for: url, image: cgImage) { color in
            onComputedColor?(color)
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
