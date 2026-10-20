import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // The Lite build (PGLiteMode in Info.plist, build_ipa.sh --lite): the engine and renderer read PG_LITE.
        if Theme.isLite && getenv("PG_LITE") == nil { setenv("PG_LITE", "1", 1) }
        GameSettings.applyExperimentalSwitches()
        ModInstaller.applyPending()
        #if targetEnvironment(simulator)
        // Test: --import-save <file> runs Settings › Import a Story save on that file at launch.
        let arguments = ProcessInfo.processInfo.arguments
        if let i = arguments.firstIndex(of: "--import-save"), i + 1 < arguments.count {
            switch SaveImport.importSave(from: URL(fileURLWithPath: arguments[i + 1])) {
            case let .imported(title, slot): NSLog("[native-port] TEST: save imported: \(title) into slot \(slot)")
            case let .failed(message): NSLog("[native-port] TEST: save import failed: \(message)")
            }
        }
        #endif
        Analytics.shared.start()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = NativePortViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    #if targetEnvironment(macCatalyst)
    /// The Mac menu bar: Settings… (⌘,) in the app menu, as every Mac app has it.
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        let settings = UIKeyCommand(title: AppLanguage.choose("Settings"), action: #selector(NativePortViewController.openSettingsFromMenu),
                                    input: ",", modifierFlags: .command)
        builder.insertSibling(UIMenu(options: .displayInline, children: [settings]), afterMenu: .about)
    }
    #endif
}
