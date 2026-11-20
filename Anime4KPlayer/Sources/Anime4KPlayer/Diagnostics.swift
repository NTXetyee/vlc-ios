import Foundation
import os

/// In-app log ring buffer (exportable later through the share sheet) mirrored to os_log.
public final class A4KLog {
    public static let shared = A4KLog()
    private let lock = NSLock()
    private var lines: [String] = []
    private let capacity = 1000
    private let osLog = Logger(subsystem: "Anime4KPlayer", category: "pipeline")
    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public func log(_ message: String) {
        osLog.info("\(message, privacy: .public)")
        let line = fmt.string(from: Date()) + " " + message
        lock.lock()
        lines.append(line)
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        lock.unlock()
    }

    public func dump() -> String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

func a4kLog(_ message: String) { A4KLog.shared.log(message) }

/// Per-frame pipeline statistics. Thread-safe; written from the vout and Metal completion threads.
public final class FrameStats {
    public struct Snapshot {
        public var gpuP50: Double = 0, gpuP95: Double = 0     // ms, measured with gpuStartTime/gpuEndTime
        public var upscaled = 0                                // frames that went through the model
        public var reused = 0                                  // redisplays served from the last output (paused)
        public var late = 0                                    // finished after their presentation time
        public var passThrough: [String: Int] = [:]            // original frame shown, by reason
        public var sourceSize = "-", outputSize = "-", pixelFormat = "-"
        public var engine = "-"
        public var passes = 0
        public var lastBuildMs: Double = 0
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
        lock.lock(); gpuMs.removeAll(); s.upscaled = 0; s.reused = 0; s.late = 0; s.passThrough = [:]; lock.unlock()
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
