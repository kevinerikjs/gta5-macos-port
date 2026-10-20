import Foundation

#if targetEnvironment(macCatalyst)
/// The Mac's cursor while playing with a mouse: hidden and held still, as Mac games do it, so moving the mouse only
/// turns the camera (GCMouse still reports the movement). UIKit's pointer lock doesn't hold the cursor in a Mac window.
/// The CoreGraphics calls are looked up at run time: the Mac Catalyst SDK leaves them out.
enum MacCursor {
    private typealias Associate = @convention(c) (Int32) -> Int32
    private typealias DisplayCall = @convention(c) (UInt32) -> Int32
    private typealias MainDisplay = @convention(c) () -> UInt32
    private static func function<T>(_ name: String, as type: T.Type) -> T? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) }   // RTLD_DEFAULT
    }
    private static let associate = function("CGAssociateMouseAndMouseCursorPosition", as: Associate.self)
    private static let hide = function("CGDisplayHideCursor", as: DisplayCall.self)
    private static let show = function("CGDisplayShowCursor", as: DisplayCall.self)
    private static let mainDisplay = function("CGMainDisplayID", as: MainDisplay.self)
    private(set) static var captured = false

    /// Captures or releases the cursor; calls only change something when the state changes.
    static func capture(_ on: Bool) {
        guard on != captured, let associate, let hide, let show, let mainDisplay else { return }
        captured = on
        _ = associate(on ? 0 : 1)
        _ = on ? hide(mainDisplay()) : show(mainDisplay())
    }
}

/// The app's AppKit window (Mac Catalyst hosts the UIWindow in an NSWindow), reached by name: UIKit has no fullscreen call.
enum MacWindow {
    private static var window: NSObject? {
        guard let app = (NSClassFromString("NSApplication") as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject else { return nil }
        if let window = app.value(forKey: "keyWindow") as? NSObject ?? (app.value(forKey: "mainWindow") as? NSObject) { return window }
        // Not key yet (for example right after launch): the visible titled window.
        return (app.value(forKey: "windows") as? [NSObject])?.first {
            ($0.value(forKey: "isVisible") as? Bool) == true && (($0.value(forKey: "styleMask") as? UInt) ?? 0) & 1 != 0   // NSWindowStyleMaskTitled
        }
    }
    static var isFullScreen: Bool { ((window?.value(forKey: "styleMask") as? UInt) ?? 0) & (1 << 14) != 0 }   // NSWindowStyleMaskFullScreen
    /// Starts the switch to fullscreen; false when the window is fullscreen already (or not found).
    static func enterFullScreen() -> Bool {
        guard let window, !isFullScreen else { return false }
        window.perform(NSSelectorFromString("toggleFullScreen:"), with: nil)
        return true
    }
}
#endif
