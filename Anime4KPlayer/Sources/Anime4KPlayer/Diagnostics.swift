import Foundation
import os

/// In-app log: ring buffer for the share sheet, mirrored to os_log and to a file in Caches so
/// the previous session (e.g. one that crashed) can still be exported after a relaunch.
public final class A4KLog {
    public static let shared = A4KLog()
    private let lock = NSLock()
    private var lines: [String] = []
    private let capacity = 3000
    private let osLog = Logger(subsystem: "Anime4KPlayer", category: "pipeline")
    private let fileQueue = DispatchQueue(label: "Anime4KPlayer.log", qos: .utility)
    private var file: FileHandle?
    private var fileBytes = 0
    private let maxFileBytes = 2_000_000
    private var markers = 0
    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static let directory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Anime4KPlayer", isDirectory: true)
    static var currentURL: URL? { directory?.appendingPathComponent("session.log") }
    static var previousURL: URL? { directory?.appendingPathComponent("previous-session.log") }

    private init() {
        fileQueue.async { [self] in
            guard let dir = Self.directory, let cur = Self.currentURL, let prev = Self.previousURL else { return }
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? fm.removeItem(at: prev)
            try? fm.moveItem(at: cur, to: prev)
            fm.createFile(atPath: cur.path, contents: nil)
            file = try? FileHandle(forWritingTo: cur)
        }
    }

    public func log(_ message: String) {
        osLog.info("\(message, privacy: .public)")
        let line = fmt.string(from: Date()) + " " + message
        lock.lock()
        lines.append(line)
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        lock.unlock()
        fileQueue.async { [self] in
            guard let file, fileBytes < maxFileBytes, let data = (line + "\n").data(using: .utf8) else { return }
            file.write(data)
            fileBytes += data.count
        }
    }

    /// A numbered marker the user drops when something looks wrong ("see MARK 3").
    @discardableResult
    public func mark() -> Int {
        lock.lock(); markers += 1; let n = markers; lock.unlock()
        log("──────── MARK \(n) ────────")
        return n
    }

    public func dump() -> String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    /// The previous app session's log, if any (empty on first launch).
    public func previousSession() -> String {
        guard let url = Self.previousURL, let data = try? Data(contentsOf: url) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

func a4kLog(_ message: String) { A4KLog.shared.log(message) }

/// Per-frame pipeline statistics. Thread-safe; written from the vout and Metal completion threads.
public final class FrameStats {
    public struct Snapshot {
        public var gpuP50: Double = 0, gpuP95: Double = 0     // ms, measured with gpuStartTime/gpuEndTime
        public var frames = 0                                  // frames seen while enabled
        public var upscaled = 0                                // frames that went through the model
        public var reused = 0                                  // redisplays served from the last output (paused)
        public var late = 0                                    // finished after their presentation time
        public var passThrough: [String: Int] = [:]            // original frame shown, by reason
        public var sourceSize = "-", outputSize = "-", pixelFormat = "-"
        public var engine = "-"
        public var passes = 0
        public var lastBuildMs: Double = 0
        public var flushes = 0                                 // seeks / layer flushes
        public var geometry = "-"                              // last display-geometry decision
    }

    private let lock = NSLock()
    private var gpuMs: [Double] = []
    private var s = Snapshot()
    private let window = 240

    func recordFrame(gpuMs ms: Double, late: Bool) {
        lock.lock(); defer { lock.unlock() }
        gpuMs.append(ms)
        if gpuMs.count > window { gpuMs.removeFirst(gpuMs.count - window) }
        s.upscaled += 1
        if late { s.late += 1 }
    }

    func frameSeen() {
        lock.lock(); s.frames += 1; lock.unlock()
    }

    func reused() {
        lock.lock(); s.reused += 1; lock.unlock()
    }

    func passThrough(_ reason: String) {
        lock.lock(); s.passThrough[reason, default: 0] += 1; lock.unlock()
    }

    func update(_ body: (inout Snapshot) -> Void) {
        lock.lock(); body(&s); lock.unlock()
    }

    func resetCounters() {
        lock.lock(); gpuMs.removeAll(); s.frames = 0; s.upscaled = 0; s.reused = 0; s.late = 0; s.passThrough = [:]; lock.unlock()
    }

    public func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        var out = s
        if !gpuMs.isEmpty {
            let sorted = gpuMs.sorted()
            out.gpuP50 = sorted[sorted.count / 2]
            out.gpuP95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        }
        return out
    }
}

extension FrameStats.Snapshot {
    public var overlayText: String {
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "SERIOUS"
        case .critical: thermal = "CRITICAL"
        @unknown default: thermal = "?"
        }
        let pt = passThrough.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        return """
        \(engine) · \(passes) passes
        GPU p50 \(String(format: "%.1f", gpuP50)) ms · p95 \(String(format: "%.1f", gpuP95)) ms
        \(sourceSize) → \(outputSize) · \(pixelFormat)
        upscaled \(upscaled) · reused \(reused) · late \(late)
        original: \(pt.isEmpty ? "0" : pt)
        build \(String(format: "%.0f", lastBuildMs)) ms · thermal \(thermal)
        """
    }
}

extension FrameStats.Snapshot {
    /// One-line summary of what changed since `old`, for the periodic log heartbeat.
    func heartbeat(since old: FrameStats.Snapshot, seconds: Double) -> String {
        let df = frames - old.frames
        var parts = ["\(df) frames (\(String(format: "%.1f", Double(df) / seconds))/s)",
                     "upscaled +\(upscaled - old.upscaled)", "reused +\(reused - old.reused)",
                     "late +\(late - old.late)"]
        let pt = passThrough.compactMap { k, v -> String? in
            let d = v - (old.passThrough[k] ?? 0)
            return d > 0 ? "\(k) +\(d)" : nil
        }.sorted()
        if !pt.isEmpty { parts.append("original: " + pt.joined(separator: ", ")) }
        if flushes != old.flushes { parts.append("flushes +\(flushes - old.flushes)") }
        if upscaled > old.upscaled {
            parts.append("GPU p50 \(String(format: "%.1f", gpuP50)) p95 \(String(format: "%.1f", gpuP95)) ms")
        }
        return "stats: " + parts.joined(separator: " · ")
    }
}
