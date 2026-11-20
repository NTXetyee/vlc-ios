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
    private var lastScaleInfo = ""          // vout thread
    private var heartbeat: Timer?
    private var lastBeat: (time: CFTimeInterval, snap: FrameStats.Snapshot)?
    private var idleLogged = false

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
        if !s.enabled { DispatchQueue.main.async { self.setBypassed(false) } }
        s.save()
        pipeline?.apply(settings: s)
        a4kLog("settings: \(s.label)")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.settingsDidChange, object: self)
        }
    }

    /// A/B compare (not persisted): true shows the original video while upscaling stays ready.
    public private(set) var isBypassed = false

    public func setBypassed(_ value: Bool) {
        guard value != isBypassed else { return }
        isBypassed = value
        pipeline?.setBypass(value)
        a4kLog("A/B: showing \(value ? "original" : "upscaled")")
    }

    @objc public var isEnabled: Bool {
        get { settings.enabled }
        set { update { $0.enabled = newValue } }
    }

    public func statsSnapshot() -> FrameStats.Snapshot? { pipeline?.stats.snapshot() }

    public func exportLog() -> String { exportReport() }

    /// Install the frame hook and app lifecycle observers. Idempotent; call on the main thread.
    @objc public func install() {
        guard !installed, let pipeline else { return }
        installed = true
        SampleBufferHook.install(
            onFrame: { layer, sampleBuffer in
                let size = layer.bounds.size
                let scale = DisplayGeometry.pixelScale(of: layer)
                let info = "layer \(Int(size.width))x\(Int(size.height)) pt, contentsScale \(layer.contentsScale), using \(scale)x"
                if info != self.lastScaleInfo {   // vout thread only
                    self.lastScaleInfo = info
                    a4kLog("display: " + info + ", gravity \(layer.videoGravity.rawValue)")
                }
                let px = CGSize(width: size.width * scale, height: size.height * scale)
                return pipeline.process(sampleBuffer, layerPixelSize: px) { upscaled in
                    SampleBufferHook.enqueueOriginal(layer, upscaled)
                }
            },
            onFlush: { _ in pipeline.flush() })

        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            a4kLog("app: background")
            pipeline.setSuspended(true)
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            a4kLog("app: foreground")
            pipeline.setSuspended(false)
        }
        nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            a4kLog("thermal: \(Self.thermalName)")
        }
        nc.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            a4kLog("low power mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off")")
        }
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.beat() }
        RunLoop.main.add(t, forMode: .common)
        heartbeat = t
        a4kLog(Self.environmentSummary(gpu: pipeline.deviceName))
        nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            pipeline.releaseResources(reason: "memory warning")
        }
        a4kLog("Anime4KController installed, settings: \(settings.label)")
    }

    /// Every 5 s: one log line with what happened since the last one. Quiet while nothing plays.
    private func beat() {
        guard let pipeline else { return }
        let now = CACurrentMediaTime(), snap = pipeline.stats.snapshot()
        defer { lastBeat = (now, snap) }
        guard let last = lastBeat else { return }
        // Counters were reset (settings change): compare against zero.
        let old = snap.frames < last.snap.frames ? FrameStats.Snapshot() : last.snap
        if snap.frames == old.frames {
            if !idleLogged, settings.enabled { a4kLog("stats: no frames (stopped, backgrounded or not playing)") }
            idleLogged = true
            return
        }
        idleLogged = false
        a4kLog(snap.heartbeat(since: old, seconds: now - last.time) + " · thermal \(Self.thermalName)")
    }

    static var thermalName: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "SERIOUS"
        case .critical: return "CRITICAL"
        @unknown default: return "?"
        }
    }

    static func environmentSummary(gpu: String) -> String {
        var sys = utsname()
        uname(&sys)
        let model = withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))"
        let screen = UIScreen.main
        let px = screen.nativeBounds.size
        return "env: \(model) · iOS \(UIDevice.current.systemVersion) · VLC \(version) · GPU \(gpu)"
            + " · screen \(Int(px.width))x\(Int(px.height)) px @\(screen.nativeScale)x"
            + " · low power \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off")"
    }

    /// Mark the log ("something looked wrong here") and return the marker number.
    @discardableResult
    public func addMarker() -> Int { A4KLog.shared.mark() }

    /// Full report for the share sheet: environment, current settings and stats, this session's
    /// log and the previous session's log.
    public func exportReport() -> String {
        let snap = statsSnapshot()
        var out = "Anime4K log report · \(Date())\n"
        out += Self.environmentSummary(gpu: pipeline?.deviceName ?? "none") + "\n"
        out += "settings: \(settings.label) · thermal \(Self.thermalName)\n"
        if let snap {
            out += "geometry: \(snap.geometry)\n"
            out += snap.overlayText + "\n"
        }
        out += "\n===== this session =====\n" + A4KLog.shared.dump() + "\n"
        let prev = A4KLog.shared.previousSession()
        if !prev.isEmpty {
            out += "\n===== previous session (tail) =====\n" + String(prev.suffix(60_000)) + "\n"
        }
        return out
    }

    /// Writes `exportReport()` to a temporary .txt file for sharing.
    public func exportReportFile() -> URL? {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Anime4K-log-\(f.string(from: Date())).txt")
        do { try exportReport().write(to: url, atomically: true, encoding: .utf8) } catch { return nil }
        return url
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
