import UIKit

/// Where the game draws its minimap for a place in its HUD units (GTA-131). The game keeps its HUD in a 16:9
/// area centred on wider screens and measures the minimap's corner from that area's bottom left: the
/// common/data/ui/frontend.xml "minimap" entry (posX -0.0045, posY 0.002, size 0.15 × 0.188888), with
/// alignY="B", so a negative posY is higher up. Checked against a moved map on an iPhone 13 Pro Max.
enum MinimapGeometry {
    static let corner = CGPoint(x: -0.0045, y: 0.002)
    static let size = CGSize(width: 0.150, height: 0.188888)

    static func hudArea(_ bounds: CGRect) -> CGRect {
        let width = min(bounds.width, bounds.height * 16 / 9)
        return CGRect(x: bounds.midX - width / 2, y: bounds.minY, width: width, height: bounds.height)
    }
    /// The map's rectangle on screen for a place.
    static func rect(_ layout: (dx: Double, dy: Double, scale: Double), in bounds: CGRect) -> CGRect {
        let area = hudArea(bounds), s = CGFloat(layout.scale)
        let posX = corner.x + CGFloat(layout.dx), posY = corner.y + CGFloat(layout.dy)
        let height = size.height * s * area.height
        return CGRect(x: area.minX + posX * area.width, y: area.maxY + posY * area.height - height,
                      width: size.width * s * area.width, height: height)
    }
    /// The place for a rectangle on screen (the inverse of `rect`).
    static func layout(for rect: CGRect, in bounds: CGRect) -> (dx: Double, dy: Double, scale: Double) {
        let area = hudArea(bounds)
        let scale = rect.width / (size.width * area.width)
        let posX = (rect.minX - area.minX) / area.width
        let posY = (rect.maxY - area.maxY) / area.height
        return (Double(posX - corner.x), Double(posY - corner.y), Double(scale))
    }
}

/// Settings › Touch controls › Minimap › Custom: drag the map where you want it, pinch to resize. The touch
/// controls show dimmed underneath so the map can be kept clear of them. The game reads the place when it starts.
final class MinimapEditorController: UIViewController {
    var onDone: (() -> Void)?
    private let background = UIImageView()
    private let controls = TouchControlsView(frame: .zero)
    private let map = UIView()
    private let toolbar = UIStackView()
    private let hint = UILabel()
    private var layout = GameSettings.shared.minimapPlace == .custom ? GameSettings.shared.minimapCustom : GameSettings.shared.minimapLayout
    private var dragOffset = CGPoint.zero
    private var pinchStartScale = 1.0

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

        // The map: a rounded square like the game's, with a map symbol.
        map.backgroundColor = UIColor(red: 0.35, green: 0.6, blue: 0.45, alpha: 0.75)
        map.layer.cornerRadius = 10
        map.layer.borderWidth = 2
        map.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
        map.isAccessibilityElement = true
        map.accessibilityLabel = AppLanguage.choose("Minimap")
        let symbol = UIImageView(image: UIImage(systemName: "map.fill"))
        symbol.tintColor = .white
        symbol.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(symbol)
        NSLayoutConstraint.activate([symbol.centerXAnchor.constraint(equalTo: map.centerXAnchor), symbol.centerYAnchor.constraint(equalTo: map.centerYAnchor)])
        view.addSubview(map)

        hint.text = AppLanguage.choose("Drag the map to move it · pinch to resize")
        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.textColor = UIColor.white.withAlphaComponent(0.85)
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)

        let reset = UIButton(type: .system)
        reset.setTitle(AppLanguage.choose("Reset"), for: .normal)
        reset.addAction(UIAction { [weak self] _ in self?.layout = (0, 0, 1); self?.view.setNeedsLayout() }, for: .touchUpInside)
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
        // Top centre: the map's usual places are the left corners.
        NSLayoutConstraint.activate([
            toolbar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hint.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        for gesture in [pan, pinch] as [UIGestureRecognizer] { gesture.delegate = self; view.addGestureRecognizer(gesture) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        map.frame = MinimapGeometry.rect(layout, in: view.bounds)
    }

    /// Keeps the whole map on screen.
    private func place(_ frame: CGRect) {
        var frame = frame
        frame.origin.x = min(max(frame.minX, view.bounds.minX), view.bounds.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, view.bounds.minY), view.bounds.maxY - frame.height)
        layout = MinimapGeometry.layout(for: frame, in: view.bounds)
        map.frame = frame
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: view)
        switch gesture.state {
        case .began:
            let moved = gesture.translation(in: view)
            let start = CGPoint(x: point.x - moved.x, y: point.y - moved.y)
            dragOffset = CGPoint(x: map.frame.minX - start.x, y: map.frame.minY - start.y)
        case .changed:
            place(CGRect(origin: CGPoint(x: point.x + dragOffset.x, y: point.y + dragOffset.y), size: map.frame.size))
        default:
            break
        }
    }
    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStartScale = layout.scale
        case .changed:
            // Around the map's bottom-left corner, as the game scales it.
            let scale = max(0.6, min(1.8, pinchStartScale * Double(gesture.scale)))
            let base = MinimapGeometry.rect((layout.dx, layout.dy, 1), in: view.bounds)
            let size = CGSize(width: base.width * CGFloat(scale), height: base.height * CGFloat(scale))
            place(CGRect(x: map.frame.minX, y: map.frame.maxY - size.height, width: size.width, height: size.height))
        default:
            break
        }
    }

    private func finish() {
        GameSettings.shared.minimapCustom = layout
        GameSettings.shared.minimapPlace = layout == (0, 0, 1) ? .bottomLeft : .custom
        onDone?()
        dismiss(animated: true)
    }
}

extension MinimapEditorController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view = touch.view else { return true }
        return !view.isDescendant(of: toolbar)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer
    }
}
