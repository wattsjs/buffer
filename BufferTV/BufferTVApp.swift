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

/// Siri Remote navigation: the tab sidebar lists the guide's groups, then
/// Sports, Search, Sources, Countries and Settings; content is focus-driven.
struct TVRootView: View {
    let model: TouchAppModel
    @State private var tab = Section.guide(.allChannels)

    enum Section: Hashable { case guide(SidebarSelection), sports, search, sources, countries, settings }

    var body: some View {
        @Bindable var model = model
        @Bindable var search = model.search
        let viewModel = model.viewModel
        Group {
            if viewModel.playlists.isEmpty {
                NavigationStack {
                    WelcomeView { model.isEditingSources = true }
                        .navigationDestination(isPresented: $model.isEditingSources) {
                            SourceEditorForm(viewModel: viewModel) { model.isEditingSources = false }
                        }
                }
            } else {
                TabView(selection: $tab) {
                    Tab("All Channels", systemImage: "rectangle.grid.1x2", value: Section.guide(.allChannels)) {
                        TVGuideGrid(model: model)
                    }
                    Tab("Favorites", systemImage: "star", value: Section.guide(.favorites)) {
                        TVGuideGrid(model: model)
                    }
                    TabSection("Groups") {
                        ForEach(viewModel.groups, id: \.self) { group in
                            Tab(group, systemImage: "folder", value: Section.guide(.group(group))) {
                                TVGuideGrid(model: model)
                            }
                        }
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
                    Tab("Sources", systemImage: "server.rack", value: Section.sources) {
                        NavigationStack { List { SourcesList(viewModel: viewModel) }.navigationTitle("Sources") }
                    }
                    Tab("Countries", systemImage: "globe.americas", value: Section.countries) {
                        NavigationStack { TVCountryFilterView(viewModel: viewModel) }
                    }
                    Tab("Settings", systemImage: "gear", value: Section.settings) {
                        NavigationStack { SettingsScreen(model: model) }
                    }
                }
                .tabViewStyle(.sidebarAdaptable)
                .onChange(of: tab, initial: true) { _, next in
                    if case .guide(let selection) = next { viewModel.selection = selection }
                }
            }
        }
        .modifier(TouchAppObservers(model: model))
        .fullScreenCover(item: $model.player) { presentation in
            TouchPlayerView(request: presentation.request, viewModel: viewModel) { model.player = nil }
        }
    }
}
