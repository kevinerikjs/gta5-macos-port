import UIKit

/// Where the game draws its help messages (the box with "Press … to …", HUD_HELP_TEXT in frontend.xml) for a place in
/// its HUD units: the component's top-left corner in fractions of the 16:9 HUD area. Measured in the simulator with a
/// three-line message placed off the top: the box starts 0.0165 right of and 0.015 below the place, 0.2 wide and 0.095
/// high (a line is about 0.03).
enum HelpTextGeometry {
    static let inset = CGPoint(x: 0.0165, y: 0.015)
    /// The box of a typical message (two to three lines), in HUD units.
    static let size = CGSize(width: 0.2, height: 0.095)

    /// The box's rectangle on screen for a place.
    static func rect(_ layout: (x: Double, y: Double, scale: Double), in bounds: CGRect) -> CGRect {
        let area = MinimapGeometry.hudArea(bounds)
        return CGRect(x: area.minX + (CGFloat(layout.x) + inset.x) * area.width, y: area.minY + (CGFloat(layout.y) + inset.y) * area.height,
                      width: size.width * area.width, height: size.height * area.height)
    }
    /// The place for a rectangle on screen (the inverse of `rect`).
    static func layout(for rect: CGRect, in bounds: CGRect) -> (x: Double, y: Double, scale: Double) {
        let area = MinimapGeometry.hudArea(bounds)
        return (Double((rect.minX - area.minX) / area.width - inset.x), Double((rect.minY - area.minY) / area.height - inset.y), 1)
    }
}

/// Settings › Touch controls › Help messages › Custom: drag the help box where you want it. The minimap shows where it
/// is now, and the touch controls show dimmed underneath. The game reads the place when it starts.
final class HelpTextEditorController: UIViewController {
    var onDone: (() -> Void)?
    private let background = UIImageView()
    private let controls = TouchControlsView(frame: .zero)
    private let map = UIView()
    private let box = UIView()
    private let sample = UILabel()
    private let toolbar = UIStackView()
    private let hint = UILabel()
    private var layout = GameSettings.shared.helpTextLayout
    private var dragOffset = CGPoint.zero

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.16, green: 0.2, blue: 0.24, alpha: 1)
        background.contentMode = .scaleAspectFill
        background.clipsToBounds = true
        background.alpha = 0.55
        background.image = UIImage(named: "LaunchBackground")
        controls.editing = true
        controls.isUserInteractionEnabled = false
        controls.alpha = 0.35
        controls.updateContext(vehicle: 0, pauseMenu: false)
        controls.updateVisibility()
        for item in [background, controls] as [UIView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
            NSLayoutConstraint.activate([
                item.leadingAnchor.constraint(equalTo: view.leadingAnchor), item.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                item.topAnchor.constraint(equalTo: view.topAnchor), item.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }

        // The minimap where it is now, dimmed, so the box can be kept off it.
        map.backgroundColor = UIColor(red: 0.35, green: 0.6, blue: 0.45, alpha: 0.4)
        map.layer.cornerRadius = 10
        map.isUserInteractionEnabled = false
        let mapSymbol = UIImageView(image: UIImage(systemName: "map.fill"))
        mapSymbol.tintColor = UIColor.white.withAlphaComponent(0.6)
        mapSymbol.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(mapSymbol)
        NSLayoutConstraint.activate([mapSymbol.centerXAnchor.constraint(equalTo: map.centerXAnchor), mapSymbol.centerYAnchor.constraint(equalTo: map.centerYAnchor)])
        view.addSubview(map)

        // The help box: dark like the game's, with a sample message.
        box.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        box.layer.borderWidth = 2
        box.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
        box.isAccessibilityElement = true
        box.accessibilityLabel = AppLanguage.choose("Help messages")
        sample.text = AppLanguage.choose("Press ⓐ to talk. Help messages show here.")
        sample.textColor = .white
        sample.numberOfLines = 0
        sample.adjustsFontSizeToFitWidth = true
        sample.minimumScaleFactor = 0.5
        sample.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(sample)
        NSLayoutConstraint.activate([
            sample.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8), sample.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            sample.topAnchor.constraint(equalTo: box.topAnchor, constant: 6), sample.bottomAnchor.constraint(lessThanOrEqualTo: box.bottomAnchor, constant: -6),
        ])
        view.addSubview(box)

        hint.text = AppLanguage.choose("Drag the box to move it")
        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.textColor = UIColor.white.withAlphaComponent(0.85)
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)

        let reset = UIButton(type: .system)
        reset.setTitle(AppLanguage.choose("Reset"), for: .normal)
        reset.addAction(UIAction { [weak self] _ in
            self?.layout = GameSettings.shared.helpTextLayout(for: GameSettings.shared.defaultHelpTextPlace); self?.view.setNeedsLayout()
        }, for: .touchUpInside)
        let done = UIButton(type: .system)
        done.setTitle(AppLanguage.choose("Done"), for: .normal)
        done.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        done.addAction(UIAction { [weak self] _ in self?.finish() }, for: .touchUpInside)
        for item in [reset, done] as [UIView] { toolbar.addArrangedSubview(item) }
        toolbar.axis = .horizontal
        toolbar.spacing = 18
        toolbar.isLayoutMarginsRelativeArrangement = true
        toolbar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        toolbar.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        toolbar.layer.cornerRadius = 14
        toolbar.overrideUserInterfaceStyle = .dark
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)
        // Bottom centre: the box's usual places are along the top.
        NSLayoutConstraint.activate([
            toolbar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -6),
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        map.frame = MinimapGeometry.rect(GameSettings.shared.minimapLayout, in: view.bounds)
        box.frame = HelpTextGeometry.rect(layout, in: view.bounds)
        sample.font = .systemFont(ofSize: max(9, box.frame.height / 4.2), weight: .medium)
    }

    /// Keeps the whole box on screen.
    private func place(_ frame: CGRect) {
        var frame = frame
        frame.origin.x = min(max(frame.minX, view.bounds.minX), view.bounds.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, view.bounds.minY), view.bounds.maxY - frame.height)
        layout = HelpTextGeometry.layout(for: frame, in: view.bounds)
        box.frame = frame
        sample.font = .systemFont(ofSize: max(9, frame.height / 4.2), weight: .medium)
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: view)
        switch gesture.state {
        case .began:
            let moved = gesture.translation(in: view)
            let start = CGPoint(x: point.x - moved.x, y: point.y - moved.y)
            dragOffset = CGPoint(x: box.frame.minX - start.x, y: box.frame.minY - start.y)
        case .changed:
            place(CGRect(origin: CGPoint(x: point.x + dragOffset.x, y: point.y + dragOffset.y), size: box.frame.size))
        default:
            break
        }
    }

    private func finish() {
        GameSettings.shared.helpTextCustom = layout
        GameSettings.shared.helpTextPlace = .custom
        onDone?()
        dismiss(animated: true)
    }
}

extension HelpTextEditorController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view = touch.view else { return true }
        return !view.isDescendant(of: toolbar)
    }
}
