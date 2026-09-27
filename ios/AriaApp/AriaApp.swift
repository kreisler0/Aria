import SwiftUI
import UIKit
import AriaKit

@main
struct AriaApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        if UITestPreview.isUITest { UIView.setAnimationsEnabled(false) }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(AriaTheme.accent(named: model.accentName))
                .onOpenURL { model.handle(url: $0) }
                .task { await model.start() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            model.scenePhaseChanged(newPhase)
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.taskIdentifier)) {
            await BackgroundRefresh.run()
        }
    }
}
