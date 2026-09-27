import Foundation
import AriaKit

/// Services shared by the app and the widget extension (both compile this file). They
/// share state through the App Group: widget cache and settings in `SharedStore`, and the
/// Supabase session in the Keychain under the App Group access group.
struct SharedEnvironment {
    let store: SharedStore
    let sessionKeychain: KeychainStore

    init(bundle: Bundle = .main) {
        let group = SharedStore.appGroupFromBundle(bundle)
        store = SharedStore(appGroup: group)
        sessionKeychain = KeychainStore(service: "aria.supabase", accessGroup: group)
    }

    /// Supabase settings baked into the build (Config/Secrets.xcconfig), else the ones
    /// entered in the app.
    var config: SupabaseConfig? {
        Self.bundledConfig() ?? store.supabaseConfig
    }

    var hasBundledConfig: Bool { Self.bundledConfig() != nil }

    func makeClient() -> SupabaseClient? {
        guard let config else { return nil }
        return SupabaseClient(config: config, sessionStore: KeychainSessionStore(keychain: sessionKeychain))
    }

    static func bundledConfig(_ bundle: Bundle = .main) -> SupabaseConfig? {
        guard let url = bundle.object(forInfoDictionaryKey: "AriaSupabaseURL") as? String,
              let key = bundle.object(forInfoDictionaryKey: "AriaSupabaseAnonKey") as? String,
              !url.isEmpty, !key.isEmpty, !url.hasPrefix("$(") else { return nil }
        return SupabaseConfig(urlString: url, anonKey: key)
    }
}

/// Deep links (`aria://…`) used by widgets and the Live Activity.
enum AriaLink {
    static let scheme = "aria"
    static let quickAdd = URL(string: "aria://quick-add")!
    static let today = URL(string: "aria://today")!
    static let tasks = URL(string: "aria://tasks")!
    static let calendar = URL(string: "aria://calendar")!
    static let assistant = URL(string: "aria://assistant")!
}

enum WidgetKinds {
    static let tasks = "AriaTaskWidget"
    static let calendar = "AriaCalendarWidget"
    static let quickAdd = "AriaQuickAddWidget"
}
