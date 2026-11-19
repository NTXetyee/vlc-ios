import UIKit
import AVFoundation

/// Entry point used by VLC. Everything Anime4K-related is reachable from here.
///
/// VLC integration (VideoPlayerViewController.viewDidLoad):
///     Anime4KController.shared.install()
///     Anime4KController.shared.attachControls(to: view)
@objc public final class Anime4KController: NSObject {
    @objc public static let shared = Anime4KController()

    public static let settingsDidChange = Notification.Name("Anime4KPlayer.settingsDidChange")

    private let pipeline: UpscalePipeline?
    private let lock = NSLock()
    private var _settings: UpscaleSettings
    private var installed = false

    private override init() {
        _settings = UpscaleSettings.load()
        pipeline = UpscalePipeline()
        super.init()
        pipeline?.apply(settings: _settings)
        if pipeline == nil { a4kLog("Metal unavailable: upscaling disabled") }
    }

    public var isAvailable: Bool { pipeline != nil }

    public var settings: UpscaleSettings {
        lock.lock(); defer { lock.unlock() }
        return _settings
    }

    /// Change settings (any thread). Persists, reconfigures the pipeline and posts `settingsDidChange`.
    public func update(_ change: (inout UpscaleSettings) -> Void) {
        lock.lock()
        var s = _settings
        change(&s)
        let changed = s != _settings
        _settings = s
        lock.unlock()
        guard changed else { return }
        s.save()
        pipeline?.apply(settings: s)
        a4kLog("settings: \(s.label)")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.settingsDidChange, object: self)
        }
    }

    @objc public var isEnabled: Bool {
        get { settings.enabled }
        set { update { $0.enabled = newValue } }
    }

    public func statsSnapshot() -> FrameStats.Snapshot? { pipeline?.stats.snapshot() }

    public func exportLog() -> String { A4KLog.shared.dump() }

    /// Install the frame hook and app lifecycle observers. Idempotent; call on the main thread.
    @objc public func install() {
        guard !installed, let pipeline else { return }
        installed = true
        SampleBufferHook.install(
            onFrame: { layer, sampleBuffer in
                let size = layer.bounds.size
                let scale = max(layer.contentsScale, 1)
                let px = CGSize(width: size.width * scale, height: size.height * scale)
                return pipeline.process(sampleBuffer, displayPixelSize: px) { upscaled in
                    SampleBufferHook.enqueueOriginal(layer, upscaled)
                }
            },
            onFlush: { _ in pipeline.flush() })

        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            pipeline.setSuspended(true)
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            pipeline.setSuspended(false)
        }
        nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            pipeline.releaseResources(reason: "memory warning")
        }
        a4kLog("Anime4KController installed, settings: \(settings.label)")
    }

    /// Add the (phase 1) Anime4K control pill + stats overlay on top of the player view.
    @objc public func attachControls(to hostView: UIView) {
        guard isAvailable, !hostView.subviews.contains(where: { $0 is Anime4KControlView }) else { return }
        let controls = Anime4KControlView(controller: self)
        controls.translatesAutoresizingMaskIntoConstraints = false
        hostView.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.trailingAnchor.constraint(equalTo: hostView.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            controls.topAnchor.constraint(equalTo: hostView.safeAreaLayoutGuide.topAnchor, constant: 64),
        ])
    }
}
