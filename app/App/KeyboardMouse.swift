import GameController
import UIKit

/// A hardware keyboard and mouse (iPad, or iPhone with a keyboard) drive the game through its own
/// PC controls: every key reaches the game as the PC key, so the game's PC bindings all work
/// (WASD, E to interact, Q radio wheel, mouse look and aim, scroll wheel for weapons). The game
/// switches its prompts between controller and keyboard by itself, from the last device used.
final class KeyboardMouse {
    static let shared = KeyboardMouse()
    /// Called when a keyboard or mouse connects or disconnects.
    var changed: (() -> Void)?
    var hasKeyboard: Bool { GCKeyboard.coalesced != nil }
    var hasMouse: Bool { !GCMouse.mice().isEmpty }

    private var started = false
    private var enabled: Bool { GameSettings.shared.keyboardMouse }
    private var dx: Double = 0, dy: Double = 0, wheel: Double = 0
    private var remainderX = 0.0, remainderY = 0.0
    private var buttons: Int32 = 0
    /// The left mouse button is down (the Mac's paused-game buttons are clicked with the game's cursor).
    var leftDown: Bool { buttons & 1 != 0 }
    private var held = Set<UInt8>()

    func start() {
        guard !started else { return }
        started = true
        attachKeyboard(GCKeyboard.coalesced)
        GCMouse.mice().forEach(attachMouse)
        let center = NotificationCenter.default
        center.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] note in
            self?.attachKeyboard(note.object as? GCKeyboard); self?.changed?()
        }
        center.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.releaseAll(); self?.changed?()
        }
        center.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] note in
            if let mouse = note.object as? GCMouse { self?.attachMouse(mouse) }
            self?.changed?()
        }
        center.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.buttons = 0; self?.changed?()
        }
    }

    private func attachKeyboard(_ keyboard: GCKeyboard?) {
        keyboard?.keyboardInput?.keyChangedHandler = { [weak self] _, _, code, pressed in
            guard let self, self.enabled, let key = Self.virtualKey(code) else { return }
            self.set(key, pressed)
            // The game also reads the side-less Shift/Ctrl/Alt codes.
            if let generic = [0xA0: 0x10, 0xA1: 0x10, 0xA2: 0x11, 0xA3: 0x11, 0xA4: 0x12, 0xA5: 0x12][Int(key)] {
                let sides: [UInt8] = generic == 0x10 ? [0xA0, 0xA1] : generic == 0x11 ? [0xA2, 0xA3] : [0xA4, 0xA5]
                self.set(UInt8(generic), sides.contains(where: self.held.contains))
            }
        }
    }

    private func attachMouse(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        // GCMouse reports up as positive; the game's mouse moves in screen coordinates (down positive).
        input.mouseMovedHandler = { [weak self] _, x, y in
            guard let self, self.enabled else { return }
            self.dx += Double(x); self.dy -= Double(y)
        }
        input.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in self?.setButton(1, pressed) }
        input.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in self?.setButton(2, pressed) }
        input.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in self?.setButton(4, pressed) }
        #if !targetEnvironment(macCatalyst)
        input.scroll.valueChangedHandler = { [weak self] _, _, y in
            guard let self, self.enabled else { return }
            self.wheel += Double(y)
        }
        #endif
    }

    private func set(_ key: UInt8, _ down: Bool) {
        if down { held.insert(key) } else { held.remove(key) }
        PGSetKey(key, down)
        PGAsiSetKey(Int32(key), down)  // script mods (.asi) read the same Windows keys
    }
    private func setButton(_ bit: Int32, _ pressed: Bool) {
        guard enabled else { return }
        if pressed { buttons |= bit } else { buttons &= ~bit }
    }

    /// Every frame while the game runs: movement since last time (whole pixels), buttons, wheel.
    func send(focused: Bool) {
        guard enabled else { return }
        PGSetMouseFocus(focused, focused && hasMouse)
        let x = dx + remainderX, y = dy + remainderY
        let ix = Int32(x.rounded(.towardZero)), iy = Int32(y.rounded(.towardZero))
        remainderX = x - Double(ix); remainderY = y - Double(iy); dx = 0; dy = 0
        if ix != 0 || iy != 0 || buttons != 0 || hasMouse { PGMouseInput(ix, iy, buttons) }
        let notches = Int32(wheel.rounded(.towardZero))
        if notches != 0 { PGMouseWheel(notches); wheel -= Double(notches) }
    }

    /// Leaving the app or losing focus: nothing stays held down.
    func releaseAll() {
        held.removeAll()
        buttons = 0
        PGReleaseAllKeys()
    }

    #if targetEnvironment(macCatalyst)
    /// The Mac's scroll wheel, from the window's scroll events (NativePortViewController): GameController's mouse
    /// scroll on macOS reports about 0.1 per notch and sometimes only the first scroll in a direction, so each scroll
    /// counts as one notch, at most one every 60 ms (a trackpad sends many small ones).
    private var lastScrollAt: CFTimeInterval = 0
    func scroll(up: Bool) {
        guard enabled else { return }
        let now = CACurrentMediaTime()
        guard now - lastScrollAt > 0.06 else { return }
        lastScrollAt = now
        wheel += up ? 1 : -1
    }
    #endif

    /// Automation: types a key or moves the mouse as if a real device did (simulator checks).
    func inject(key: UInt8, down: Bool) { set(key, down) }
    func inject(dx x: Double, dy y: Double) { dx += x; dy += y }

    /// GCKeyCode is the USB HID usage; the game wants Windows virtual-key codes.
    static func virtualKey(_ code: GCKeyCode) -> UInt8? {
        let usage = Int(code.rawValue)
        switch usage {
        case 4...29: return UInt8(0x41 + usage - 4)                 // A-Z
        case 30...38: return UInt8(0x31 + usage - 30)               // 1-9
        case 39: return 0x30                                         // 0
        case 58...69: return UInt8(0x70 + usage - 58)               // F1-F12
        case 89...97: return UInt8(0x61 + usage - 89)               // keypad 1-9
        case 98: return 0x60                                         // keypad 0
        default: break
        }
        let table: [Int: UInt8] = [
            40: 0x0D, 41: 0x1B, 42: 0x08, 43: 0x09, 44: 0x20, 45: 0xBD, 46: 0xBB, 47: 0xDB, 48: 0xDD, 49: 0xDC,
            51: 0xBA, 52: 0xDE, 53: 0xC0, 54: 0xBC, 55: 0xBE, 56: 0xBF, 57: 0x14, 70: 0x2C, 71: 0x91, 72: 0x13,
            73: 0x2D, 74: 0x24, 75: 0x21, 76: 0x2E, 77: 0x23, 78: 0x22, 79: 0x27, 80: 0x25, 81: 0x28, 82: 0x26,
            83: 0x90, 84: 0x6F, 85: 0x6A, 86: 0x6D, 87: 0x6B, 88: 0x0D, 99: 0x6E, 100: 0xE2,
            224: 0xA2, 225: 0xA0, 226: 0xA4, 227: 0x5B, 228: 0xA3, 229: 0xA1, 230: 0xA5, 231: 0x5C]
        return table[usage]
    }
}
