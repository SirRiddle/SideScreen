import Cocoa
import Combine
import Sparkle

/// Sparkle auto-update (upstream #107, pointed at this fork's releases). Sparkle
/// checks the appcast once a day and asks before downloading; nothing installs
/// without the user clicking through. Builds without SUFeedURL in Info.plist
/// (swift run, tests, unpackaged binaries) never start it.
///
/// Updates are accepted only when signed with the fork's EdDSA key
/// (SUPublicEDKey) and code-signed by the same identity as the running app, so
/// they keep the Screen Recording / Accessibility grants.
final class AppUpdater: NSObject, ObservableObject, NSMenuItemValidation {
    static let shared = AppUpdater()

    @Published private(set) var canCheckForUpdates = false

    private let controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private var observation: AnyCancellable?

    override private init() {
        super.init()
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            debugLog("Sparkle: no SUFeedURL in Info.plist — update checks disabled (dev build)")
            return
        }
        controller.startUpdater()
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: \.canCheckForUpdates, on: self)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        canCheckForUpdates
    }
}
