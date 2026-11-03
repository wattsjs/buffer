import SwiftUI

@main
struct BufferMobileApp: App {
    @State private var model = TouchAppModel()

    init() {
        TouchAppModel.configureAudioSession()
        _ = AppLifecycleCoordinator.shared
    }

    var body: some Scene {
        WindowGroup {
            MobileRootView(model: model)
        }
    }
}
