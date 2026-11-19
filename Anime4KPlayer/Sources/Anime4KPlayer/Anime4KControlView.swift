import UIKit

/// Phase-1 controls: a glass pill (tap = menu with on/off, mode, model size, model, stats),
/// a stats overlay and iPhone-style toasts. The polished player UI comes later.
final class Anime4KControlView: UIView {
    private weak var controller: Anime4KController?
    private let button = UIButton(type: .system)
    private let pill: UIVisualEffectView
    private let statsLabel = UILabel()
    private let statsBox: UIVisualEffectView
    private var timer: Timer?

    init(controller: Anime4KController) {
        self.controller = controller
        pill = UIVisualEffectView(effect: Self.glass())
        statsBox = UIVisualEffectView(effect: Self.glass())
        super.init(frame: .zero)

        pill.layer.cornerRadius = 18
        pill.clipsToBounds = true
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)

        button.translatesAutoresizingMaskIntoConstraints = false
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        button.tintColor = .white
        button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        button.showsMenuAsPrimaryAction = true
        pill.contentView.addSubview(button)

        statsBox.layer.cornerRadius = 12
        statsBox.clipsToBounds = true
        statsBox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statsBox)
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        statsLabel.numberOfLines = 0
        statsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statsLabel.textColor = .white
        statsBox.contentView.addSubview(statsLabel)

        NSLayoutConstraint.activate([
            pill.topAnchor.constraint(equalTo: topAnchor),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor),
            pill.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            button.topAnchor.constraint(equalTo: pill.contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: pill.contentView.bottomAnchor),
            button.leadingAnchor.constraint(equalTo: pill.contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: pill.contentView.trailingAnchor),

            statsBox.topAnchor.constraint(equalTo: pill.bottomAnchor, constant: 8),
            statsBox.trailingAnchor.constraint(equalTo: trailingAnchor),
            statsBox.leadingAnchor.constraint(equalTo: leadingAnchor),
            statsBox.bottomAnchor.constraint(equalTo: bottomAnchor),
            statsLabel.topAnchor.constraint(equalTo: statsBox.contentView.topAnchor, constant: 8),
            statsLabel.bottomAnchor.constraint(equalTo: statsBox.contentView.bottomAnchor, constant: -8),
            statsLabel.leadingAnchor.constraint(equalTo: statsBox.contentView.leadingAnchor, constant: 10),
            statsLabel.trailingAnchor.constraint(equalTo: statsBox.contentView.trailingAnchor, constant: -10),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: Anime4KController.settingsDidChange, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { timer?.invalidate() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        timer?.invalidate()
        timer = nil
        if window != nil {
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.refreshStats() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    // Let touches outside the pill (e.g. on the stats box) reach the player underneath.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit?.isDescendant(of: pill) == true ? hit : nil
    }

    private static func glass() -> UIVisualEffect {
        if #available(iOS 26.0, *) {
            return UIGlassEffect()
        }
        return UIBlurEffect(style: .systemUltraThinMaterialDark)
    }

    @objc private func settingsChanged() {
        refresh()
        if let s = controller?.settings {
            showToast(s.enabled ? "Anime4K on · \(s.mode.displayName) (\(s.size.rawValue))" : "Anime4K off")
        }
    }

    private func refresh() {
        guard let controller else { return }
        let s = controller.settings
        let title = s.enabled ? "✦ \(s.mode.rawValue) · \(s.size.rawValue)" : "✦ Off"
        button.setTitle(title, for: .normal)
        button.menu = makeMenu(s)
        statsBox.isHidden = !(s.enabled && s.showStats)
        refreshStats()
    }

    private func refreshStats() {
        guard !statsBox.isHidden, let snap = controller?.statsSnapshot() else { return }
        statsLabel.text = snap.overlayText
    }

    private func makeMenu(_ s: UpscaleSettings) -> UIMenu {
        let c = controller
        let toggle = UIAction(title: s.enabled ? "Turn Off" : "Turn On",
                              image: UIImage(systemName: s.enabled ? "sparkles.slash" : "sparkles")) { _ in
            c?.update { $0.enabled.toggle() }
        }
        let modes = UIMenu(title: "Mode", options: .displayInline, children: Anime4KMode.allCases.map { m in
            UIAction(title: m.displayName, state: s.mode == m ? .on : .off) { _ in
                c?.update { $0.mode = m; $0.enabled = true }
            }
        })
        let sizes = UIMenu(title: "Model size", image: UIImage(systemName: "cpu"), children: ModelSize.allCases.map { z in
            UIAction(title: z.rawValue + Self.sizeHint(z), state: s.size == z ? .on : .off) { _ in
                c?.update { $0.size = z; $0.enabled = true }
            }
        })
        let models = UIMenu(title: "Model", image: UIImage(systemName: "square.stack.3d.up"), children: UpscaleModel.allCases.map { m in
            UIAction(title: m.displayName, state: s.model == m ? .on : .off) { _ in
                c?.update { $0.model = m }
            }
        })
        let stats = UIAction(title: "Show Stats", image: UIImage(systemName: "speedometer"),
                             state: s.showStats ? .on : .off) { _ in
            c?.update { $0.showStats.toggle() }
        }
        let copyLog = UIAction(title: "Copy Log", image: UIImage(systemName: "doc.on.doc")) { _ in
            UIPasteboard.general.string = c?.exportLog()
        }
        return UIMenu(title: "Anime4K", children: [toggle, modes, sizes, models,
                                                   UIMenu(options: .displayInline, children: [stats, copyLog])])
    }

    private static func sizeHint(_ z: ModelSize) -> String {
        switch z {
        case .s: return "  (fastest)"
        case .m: return "  (Fast presets)"
        case .vl: return "  (HQ presets)"
        case .ul: return "  (heaviest)"
        case .l: return ""
        }
    }

    private func showToast(_ text: String) {
        guard let host = superview else { return }
        let toast = UIVisualEffectView(effect: Self.glass())
        toast.layer.cornerRadius = 18
        toast.clipsToBounds = true
        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.isUserInteractionEnabled = false
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        toast.contentView.addSubview(label)
        host.addSubview(toast)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: toast.contentView.topAnchor, constant: 9),
            label.bottomAnchor.constraint(equalTo: toast.contentView.bottomAnchor, constant: -9),
            label.leadingAnchor.constraint(equalTo: toast.contentView.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: toast.contentView.trailingAnchor, constant: -16),
            toast.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            toast.topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor, constant: 12),
        ])
        toast.alpha = 0
        UIView.animate(withDuration: 0.2) { toast.alpha = 1 }
        UIView.animate(withDuration: 0.3, delay: 1.6, options: []) { toast.alpha = 0 } completion: { _ in
            toast.removeFromSuperview()
        }
    }
}
