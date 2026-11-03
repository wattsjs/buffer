import SwiftUI

@main
struct BufferTVApp: App {
    @State private var model = TouchAppModel()

    init() {
        TouchAppModel.configureAudioSession()
        _ = AppLifecycleCoordinator.shared
    }

    var body: some Scene {
        WindowGroup {
            TVRootView(model: model)
        }
    }
}

/// Siri Remote navigation: a sidebar of sections (guide, sports, search,
/// countries, settings) beside focus-driven content.
struct TVRootView: View {
    let model: TouchAppModel
    @State private var tab = Section.guide

    enum Section: Hashable { case guide, sports, search, countries, settings }

    var body: some View {
        @Bindable var model = model
        @Bindable var search = model.search
        Group {
            if model.viewModel.playlists.isEmpty {
                NavigationStack {
                    WelcomeView { model.isEditingSources = true }
                        .navigationDestination(isPresented: $model.isEditingSources) {
                            SourceEditorForm(viewModel: model.viewModel) { model.isEditingSources = false }
                        }
                }
            } else {
                TabView(selection: $tab) {
                    Tab("Guide", systemImage: "rectangle.grid.1x2", value: Section.guide) {
                        TVGuideScreen(model: model)
                    }
                    Tab("Sports", systemImage: "sportscourt", value: Section.sports) {
                        NavigationStack { SportsListView(model: model) }
                    }
                    Tab("Search", systemImage: "magnifyingglass", value: Section.search) {
                        NavigationStack {
                            TouchSearchResults(model: model)
                                .searchable(text: Binding(get: { search.query }, set: { search.setQuery($0) }),
                                            prompt: "Programmes, channels, movies")
                        }
                    }
                    Tab("Countries", systemImage: "globe.americas", value: Section.countries) {
                        NavigationStack { TVCountryFilterView(viewModel: model.viewModel) }
                    }
                    Tab("Settings", systemImage: "gear", value: Section.settings) {
                        NavigationStack { SettingsScreen(model: model) }
                    }
                }
                .tabViewStyle(.sidebarAdaptable)
            }
        }
        .modifier(TouchAppObservers(model: model))
        .fullScreenCover(item: $model.player) { presentation in
            TouchPlayerView(request: presentation.request, viewModel: model.viewModel) { model.player = nil }
        }
    }
}
