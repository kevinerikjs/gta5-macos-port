import UIKit

/// Keys for script mods (.asi, GTA-69). PC mods are driven by keyboard keys (Simple Trainer opens with F3,
/// moves with the number pad, types car names with the letter keys). The mod layer watches what mods do
/// (NativeASI.c: PGAsiKeyInfo), so nothing is set up per mod:
///  - The touch controls get a 🧩 Mods control while a script mod runs; it opens this tray: the menu key
///    ("☰ F3", learned when a press made a menu appear, or named in the mod's .ini), ⌨ Type, pinned keys,
///    then every key the mods use, grouped and laid out once (nothing moves while it's open).
///  - While a mod menu is on screen, a D-pad cross (▲ ▼ ◀ ▶, OK, Back) sits at the bottom centre, mapped
///    to the keys that mod uses in its menu (the number pad for keyboard-handler trainers).
///  - ⌨ Type opens the iPhone keyboard; each character goes to the mods as its PC key (letters, digits,
///    space, Delete/Backspace, Enter). Mods that ask for text with the game's text box get a text field
///    instead (NativePortViewController).
/// A long press pins a key into the tray's first row. Shift, Ctrl and Alt stay down after a tap until
/// the next key. A hardware keyboard works too (KeyboardMouse). The view only takes touches on its keys.
final class ModKeysView: UIView, UIKeyInput {
    /// Where the 🧩 Mods control is (the tray opens below it).
    var anchor: (() -> CGRect?)?
    /// Whether a script mod runs (the touch controls show the 🧩 control then).
    var activeChanged: ((Bool) -> Void)?
    private(set) var active = false

    private let tray = UIView()
    private let firstRow = UIStackView()
    private let scroll = UIScrollView()
    private let grid = UIStackView()
    private let dpad = UIView()
    private var trayTop: NSLayoutConstraint?, trayCenter: NSLayoutConstraint?
    private var keys: [Int] = []
    private var firstRowKeys: [Int] = []
    private var navKeys: [Int] = []
    private var latched = Set<Int>()
    private var timer: Timer?
    private var typing = false
    private static let pinsKey = "modKeysPinned"
    private static let menuKeysKey = "modKeysMenuKeys"
    private var pinned: [Int] {
        get { UserDefaults.standard.array(forKey: Self.pinsKey) as? [Int] ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.pinsKey) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        tray.backgroundColor = UIColor.black.withAlphaComponent(0.62)
        tray.layer.cornerRadius = 14
        tray.isHidden = true
        tray.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tray)
        firstRow.axis = .horizontal
        firstRow.spacing = 6
        firstRow.translatesAutoresizingMaskIntoConstraints = false
        tray.addSubview(firstRow)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        tray.addSubview(scroll)
        grid.axis = .vertical
        grid.spacing = 6
        grid.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(grid)
        dpad.isHidden = true
        addSubview(dpad)
        trayTop = tray.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 60)
        trayCenter = tray.centerXAnchor.constraint(equalTo: centerXAnchor)
        NSLayoutConstraint.activate([
            trayTop!, trayCenter!,
            tray.widthAnchor.constraint(lessThanOrEqualToConstant: 540),
            tray.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
            tray.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 8),
            tray.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
            firstRow.topAnchor.constraint(equalTo: tray.topAnchor, constant: 10),
            firstRow.leadingAnchor.constraint(equalTo: tray.leadingAnchor, constant: 10),
            firstRow.trailingAnchor.constraint(lessThanOrEqualTo: tray.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: firstRow.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: tray.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: tray.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: tray.bottomAnchor, constant: -10),
            scroll.heightAnchor.constraint(lessThanOrEqualToConstant: 170),
            scroll.heightAnchor.constraint(equalTo: grid.heightAnchor).withPriority(.defaultLow),
            grid.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            grid.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            grid.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            grid.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }

    /// Only the open tray and the D-pad take touches; the game and the touch controls get the rest.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    /// The 🧩 control was tapped.
    var trayOpen: Bool { !tray.isHidden }
    func toggleTray() {
        if tray.isHidden { openTray() } else { closeTray() }
    }
    private func openTray() {
        if let frame = anchor?() {
            trayTop?.constant = frame.maxY - safeAreaInsets.top + 8
            trayCenter?.constant = frame.midX - bounds.midX
        }
        rebuild()
        tray.isHidden = false
        dpad.isHidden = true
    }
    private func closeTray() {
        tray.isHidden = true
        releaseAll()
    }

    // MARK: Learning from the mods

    private var menuChips: [Int] = []
    private var menuWasVisible = false
    private func refresh() {
        var info = PGAsiKeyInfo()
        PGAsiGetKeyInfo(&info)
        let closed = withUnsafeBytes(of: info.closed) { Array($0) }, open = withUnsafeBytes(of: info.open) { Array($0) }
        let opens = withUnsafeBytes(of: info.opens) { Array($0) }, hinted = withUnsafeBytes(of: info.hinted) { Array($0) }
        // Mods with a keyboard handler get keys pushed to them and never ask about them: they also get the
        // usual keys (F-keys, number pad, arrows...), and the keys their .ini names.
        var found = (1..<256).filter { (closed[$0] != 0 || open[$0] != 0 || hinted[$0] != 0) && Self.name($0) != nil }
        if info.keyboardHandler { found = Array(Set(found).union(Self.standard)) }
        let nowActive = !found.isEmpty
        if nowActive != active { active = nowActive; activeChanged?(active); if !active { closeTray(); dpad.isHidden = true } }
        guard active else { return }
        // Menu keys: learned from what opened a menu (kept across launches), named by the mod's .ini,
        // otherwise the F-keys the mods check.
        let learnedNow = (1..<256).filter { opens[$0] > 0 && Self.name($0) != nil }
        var remembered = UserDefaults.standard.array(forKey: Self.menuKeysKey) as? [Int] ?? []
        if !Set(learnedNow).isSubset(of: remembered) { remembered = Array(Set(remembered).union(learnedNow)).sorted(); UserDefaults.standard.set(remembered, forKey: Self.menuKeysKey) }
        var chips = learnedNow.sorted { opens[$0] > opens[$1] }
        chips += (1..<256).filter { hinted[$0] != 0 && !chips.contains($0) && Self.name($0) != nil }
        chips += remembered.filter { !chips.contains($0) && (closed[$0] != 0 || info.keyboardHandler) }
        if chips.isEmpty && !info.keyboardHandler { chips = found.filter { (0x70...0x7B).contains($0) && closed[$0] != 0 } }
        menuChips = Array(chips.prefix(3))
        // A menu just came up (say after ☰ F3): the tray makes room for the D-pad. Only when it appears:
        // the tray opened again over an open menu stays open (it used to close again at once).
        if info.menuVisible && !menuWasVisible && !tray.isHidden && !typing { closeTray() }
        menuWasVisible = info.menuVisible
        // The D-pad, while a mod menu is on screen, with the keys that mod checks in its menu. Keyboard-handler
        // mods never say: the number pad, which Script Hook V trainers (Simple Trainer, Menyoo) use.
        let handlerOnly = info.keyboardHandler && ![0x68, 0x26, 0x62, 0x28].contains(where: { open[$0] != 0 })
        let usable = { (key: Int) in open[key] != 0 || (handlerOnly && [0x68, 0x62, 0x64, 0x66, 0x65, 0x60].contains(key)) }
        let pick = { (choices: [Int]) in choices.first(where: usable) ?? 0 }
        let nav = [pick([0x68, 0x26]), pick([0x62, 0x28]), pick([0x64, 0x25]), pick([0x66, 0x27]), pick([0x65, 0x0D]), pick([0x60, 0x08, 0x1B])]
        if nav != navKeys { navKeys = nav; buildDpad() }
        dpad.isHidden = !(info.menuVisible && nav.filter { $0 != 0 }.count >= 2 && tray.isHidden && !typing)
        // The tray's keys are laid out again only while it's closed, so nothing moves under a finger.
        let sorted = found.sorted { Self.rank($0) == Self.rank($1) ? $0 < $1 : Self.rank($0) < Self.rank($1) }
        if sorted != keys && tray.isHidden { keys = sorted }
    }

    // MARK: Building

    private func rebuild() {
        firstRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for key in menuChips { firstRow.addArrangedSubview(makeKey(key, compact: true, title: "☰ " + (Self.name(key) ?? ""))) }
        let type = ModKeyButton(key: 0, title: "⌨ " + AppLanguage.choose("Type"), pinned: false, compact: true)
        type.pressed = { [weak self] down in if !down { self?.startTyping() } }
        firstRow.addArrangedSubview(type)
        firstRow.addArrangedSubview(makeKey(0x0D, compact: true, title: "Enter"))
        for key in pinned where Self.name(key) != nil && !menuChips.contains(key) { firstRow.addArrangedSubview(makeKey(key, compact: true)) }
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // Grouped like a keyboard: F-keys, number pad, arrows and editing keys, modifiers, letters, digits.
        let perRow = 8
        for group in Dictionary(grouping: keys, by: Self.rank).sorted(by: { $0.key < $1.key }).map(\.value) {
            for start in stride(from: 0, to: group.count, by: perRow) {
                var views = group[start..<min(start + perRow, group.count)].map { makeKey($0, compact: false) }
                while views.count < perRow { views.append(UIView()) }   // keeps key sizes even
                let row = UIStackView(arrangedSubviews: views)
                row.axis = .horizontal
                row.spacing = 6
                row.distribution = .fillEqually
                grid.addArrangedSubview(row)
            }
        }
    }

    /// ▲ ▼ ◀ ▶ around OK, Back beside it: a D-pad cross at the bottom centre, between the minimap and the
    /// action buttons.
    private func buildDpad() {
        dpad.subviews.forEach { $0.removeFromSuperview() }
        let size: CGFloat = 46, gap: CGFloat = 4
        // Back in the cross's lower right corner keeps the whole pad inside the free strip (GTA-69: a Back key
        // to the right of the cross sat on the sprint button).
        let spots: [(CGFloat, CGFloat)] = [(1, 0), (1, 2), (0, 1), (2, 1), (1, 1), (2, 2)]
        for (i, key) in navKeys.enumerated() where key != 0 {
            let title = ["▲", "▼", "◀", "▶", "OK", "↩\u{FE0E}"][i]   // text style, not the blue emoji
            let button = makeKey(key, compact: true, title: title)
            button.frame = CGRect(x: spots[i].0 * (size + gap), y: spots[i].1 * (size + gap), width: size, height: size)
            button.translatesAutoresizingMaskIntoConstraints = true
            dpad.addSubview(button)
        }
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = 3 * 46 + 2 * 4, height = 3 * 46 + 2 * 4
        let safe = bounds.inset(by: safeAreaInsets)
        dpad.frame = CGRect(x: safe.minX + safe.width * 0.40 - CGFloat(width) / 2, y: safe.maxY - CGFloat(height) - 14, width: CGFloat(width), height: CGFloat(height))
    }

    private func makeKey(_ key: Int, compact: Bool, title: String? = nil) -> UIView {
        let button = ModKeyButton(key: key, title: title ?? Self.name(key) ?? "?", pinned: pinned.contains(key), compact: compact)
        button.pressed = { [weak self] down in self?.press(key, down) }
        button.longPressed = { [weak self] in self?.togglePin(key) }
        return button
    }

    private func press(_ key: Int, _ down: Bool) {
        if Self.modifiers.contains(key) {
            // Modifiers latch: tap Alt, then A, for Alt + A.
            guard down else { return }
            if latched.contains(key) { latched.remove(key); PGAsiSetKey(Int32(key), false) } else { latched.insert(key); PGAsiSetKey(Int32(key), true) }
            return
        }
        PGAsiSetKey(Int32(key), down)
        if !down { for modifier in latched { PGAsiSetKey(Int32(modifier), false) }; latched.removeAll() }
    }

    private func togglePin(_ key: Int) {
        var list = pinned
        if let index = list.firstIndex(of: key) { list.remove(at: index) } else { list.append(key) }
        pinned = list
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        rebuild()
    }

    private func releaseAll() {
        for key in keys { PGAsiSetKey(Int32(key), false) }
        latched.removeAll()
    }

    // MARK: ⌨ Type: the iPhone keyboard, as PC key presses

    override var canBecomeFirstResponder: Bool { typing }
    var hasText: Bool { true }
    override var inputAccessoryView: UIView? { typingBar }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
    var keyboardType: UIKeyboardType { get { .asciiCapable } set {} }
    var returnKeyType: UIReturnKeyType { get { .done } set {} }
    private let typingLabel = UILabel()
    private lazy var typingBar: UIView = {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        typingLabel.font = .systemFont(ofSize: 15, weight: .medium)
        typingLabel.textColor = .label
        typingLabel.lineBreakMode = .byTruncatingHead
        bar.items = [UIBarButtonItem(customView: typingLabel), UIBarButtonItem(systemItem: .flexibleSpace),
                     UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.stopTyping(submit: true) })]
        return bar
    }()
    private var typingQueue: [Int] = []
    private var deleteKey = 0x2E
    // A mod that asked with the game's text box (DISPLAY_ONSCREEN_KEYBOARD) gets the finished text instead
    // of key presses: the same keyboard, and the bar shows its question and what has been typed.
    private var request: (title: String, maxLength: Int)?
    private var requestText = ""

    /// ⌨ Type: characters go to the mods as PC key presses.
    private func startTyping() {
        closeTray()
        request = nil
        // Simple Trainer erases with Delete (its Backspace leaves the menu); a mod that checks only
        // Backspace gets that.
        var info = PGAsiKeyInfo(); PGAsiGetKeyInfo(&info)
        let checked = withUnsafeBytes(of: info.closed) { Array($0) }
        deleteKey = checked[0x08] != 0 && checked[0x2E] == 0 && !info.keyboardHandler ? 0x08 : 0x2E
        typingLabel.text = AppLanguage.choose("Typing to mods")
        typing = true
        becomeFirstResponder()
    }
    /// A mod asks for text with the game's text box (NativePortViewController polls PGAsiTextRequest).
    func startTextRequest(title: String, text: String, maxLength: Int) {
        closeTray()
        request = (title.isEmpty ? AppLanguage.choose("Type text") : title, maxLength > 0 ? maxLength : 1023)
        requestText = text
        showRequest()
        typing = true
        becomeFirstResponder()
    }
    private func showRequest() {
        guard let request else { return }
        typingLabel.text = request.title + "  " + requestText + "▏"
        typingLabel.sizeToFit()
        typingLabel.frame.size.width = min(typingLabel.frame.width, bounds.width * 0.7)
    }
    private func stopTyping(submit: Bool) {
        if request != nil { PGAsiTextFinish(submit ? requestText : nil); request = nil }
        // Typing key by key (Simple Trainer's spawn by name): Done is Enter, which confirms the text; in that
        // text entry the D-pad's number-pad keys would type digits instead.
        else if submit { typingQueue.append(0x0D); sendTyped() }
        typing = false
        resignFirstResponder()
    }
    func insertText(_ text: String) {
        if let request {
            for character in text where character != "\n" { if requestText.count < request.maxLength { requestText.append(character) } }
            if text.contains("\n") { stopTyping(submit: true) } else { showRequest() }
            return
        }
        for character in text.lowercased() {
            if character == "\n" { typingQueue.append(0x0D); continue }
            if let key = Self.typedKey(character) { typingQueue.append(key) }
        }
        sendTyped()
    }
    func deleteBackward() {
        if request != nil { if !requestText.isEmpty { requestText.removeLast() }; showRequest(); return }
        typingQueue.append(deleteKey); sendTyped()
    }
    /// One key at a time, held for a few frames so mods that ask "is it down?" each frame see it too.
    private var sending = false
    private func sendTyped() {
        guard !sending, !typingQueue.isEmpty else { return }
        sending = true
        let key = typingQueue.removeFirst()
        PGAsiSetKey(Int32(key), true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
            PGAsiSetKey(Int32(key), false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { self.sending = false; self.sendTyped() }
        }
    }
    #if targetEnvironment(simulator)
    func testAnswer(_ answer: String) { requestText = answer; stopTyping(submit: true) }
    #endif
    private static func typedKey(_ c: Character) -> Int? {
        guard let ascii = c.asciiValue else { return nil }
        switch ascii {
        case 97...122: return Int(ascii) - 32      // a-z: the letter keys
        case 48...57: return Int(ascii)            // 0-9
        case 32: return 0x20
        case 45: return 0xBD                        // -
        case 46: return 0xBE                        // .
        case 95: return 0xBD                        // _ (shift is left out: mods read model names in any case)
        default: return nil
        }
    }

    // MARK: Key names (Windows virtual-key codes)
    private static let modifiers: Set<Int> = [0x10, 0x11, 0x12, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5]
    private static let standard = Array(0x70...0x7B) + Array(0x60...0x69) + [0x25, 0x26, 0x27, 0x28, 0x0D, 0x08, 0x1B, 0x20, 0x09, 0x10, 0x11, 0x12]
    private static func rank(_ key: Int) -> Int {
        switch key {
        case 0x70...0x87: return 0          // F1-F24
        case 0x60...0x6F: return 1          // number pad
        case 0x25...0x28, 0x21...0x24, 0x2D, 0x2E: return 2  // arrows, Page Up/Down, Home, End, Insert, Delete
        case 0x0D, 0x08, 0x1B, 0x20, 0x09: return 3
        case _ where modifiers.contains(key): return 4
        case 0x41...0x5A: return 5          // letters
        case 0x30...0x39: return 6          // digits
        default: return 7
        }
    }
    static func name(_ key: Int) -> String? {
        switch key {
        case 0x70...0x87: return "F\(key - 0x6F)"
        case 0x60...0x69: return "Num \(key - 0x60)"
        case 0x6A: return "Num *"; case 0x6B: return "Num +"; case 0x6D: return "Num −"; case 0x6E: return "Num ."; case 0x6F: return "Num /"
        case 0x30...0x39, 0x41...0x5A: return String(UnicodeScalar(UInt8(key)))
        case 0x25: return "←"; case 0x26: return "↑"; case 0x27: return "→"; case 0x28: return "↓"
        case 0x21: return "PgUp"; case 0x22: return "PgDn"; case 0x23: return "End"; case 0x24: return "Home"; case 0x2D: return "Ins"; case 0x2E: return "Del"
        case 0x0D: return "Enter"; case 0x08: return "⌫"; case 0x1B: return "Esc"; case 0x20: return "Space"; case 0x09: return "Tab"
        case 0x10, 0xA0, 0xA1: return key == 0xA1 ? "R Shift" : "Shift"
        case 0x11, 0xA2, 0xA3: return key == 0xA3 ? "R Ctrl" : "Ctrl"
        case 0x12, 0xA4, 0xA5: return key == 0xA5 ? "R Alt" : "Alt"
        case 0xBA: return ";"; case 0xBB: return "="; case 0xBC: return ","; case 0xBD: return "-"; case 0xBE: return "."; case 0xBF: return "/"
        case 0xC0: return "`"; case 0xDB: return "["; case 0xDC: return "\\"; case 0xDD: return "]"; case 0xDE: return "'"
        default: return nil
        }
    }
}

/// One key: held while touched; a long press pins or unpins it.
private final class ModKeyButton: UIView {
    static let idle = UIColor.black.withAlphaComponent(0.5)
    var pressed: ((Bool) -> Void)?
    var longPressed: (() -> Void)?
    private let label = UILabel()
    private var holdTimer: Timer?
    private var didLongPress = false

    init(key: Int, title: String, pinned: Bool, compact: Bool) {
        super.init(frame: .zero)
        // Like the touch controls: dark and translucent, readable over a bright sky or road.
        backgroundColor = Self.idle
        layer.cornerRadius = 10
        layer.borderWidth = pinned && !compact ? 1.5 : 1
        layer.borderColor = (pinned && !compact ? UIColor.systemYellow : UIColor.white.withAlphaComponent(0.28)).cgColor
        label.text = title
        label.textColor = .white
        label.font = .systemFont(ofSize: compact ? 13 : 14, weight: .semibold)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: compact ? 32 : 38),
            widthAnchor.constraint(greaterThanOrEqualToConstant: compact ? 44 : 40),
        ])
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .keyboardKey
        accessibilityHint = AppLanguage.choose("Long press to pin or unpin")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        didLongPress = false
        backgroundColor = UIColor.white.withAlphaComponent(0.45)
        pressed?(true)
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.didLongPress = true
            self.pressed?(false)
            self.longPressed?()
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish() }
    private func finish() {
        holdTimer?.invalidate()
        backgroundColor = Self.idle
        if !didLongPress { pressed?(false) }
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint { self.priority = priority; return self }
}
