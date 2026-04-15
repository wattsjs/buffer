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
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .padding(contentInset)
                    } else {
                        placeholder
                    }
                }
                .onCompletion { result in
                    handleCompletion(url: url, result: result)
                }
                .pipeline(ImageLoader.pipeline)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholder: some View {
        ZStack {
            Color.clear
            Image(systemName: fallbackSystemImage)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.secondary)
        }
    }

    private func handleCompletion(url: URL, result: Result<ImageResponse, Error>) {
        switch result {
        case .failure:
            ImageLoader.markFailed(url)
        case .success(let response):
            // Parent cells seed their background from `LogoColorAnalyzer.cachedColor`
            // at init. If that cache already holds a value, delivering it again
            // here would kick the parent's @State and re-render the cell, which
            // in turn re-instantiates this view and refires onCompletion — a
            // tight feedback loop that pegged the CPU when combined with
            // uncached failing logo URLs.
            if LogoColorAnalyzer.cachedColor(for: url) != nil {
                return
            }
            guard let cgImage = response.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return
            }
            LogoColorAnalyzer.color(for: url, image: cgImage) { color in
                onComputedColor?(color)
            }
        }
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
            ChannelLogoView(url: channel.logoURL) { color in
                withAnimation(.easeInOut(duration: 0.25)) {
                    bgColor = Color(nsColor: color)
                }
            }
            .padding(contentInset)
        }
    }
}
