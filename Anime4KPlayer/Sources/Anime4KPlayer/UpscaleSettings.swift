import Foundation

/// Which upscaling model family runs. Only Anime4K exists today; new models add a case
/// plus an `Upscaler` implementation (see `UpscalerFactory`).
public enum UpscaleModel: String, Codable, CaseIterable, Sendable {
    case anime4k

    public var displayName: String {
        switch self {
        case .anime4k: return "Anime4K"
        }
    }
}

/// Anime4K "modes" as defined by bloc97's mpv templates.
/// A: restore + upscale (most sources). B: soft restore (blurry/ringing sources).
/// C: upscale+denoise (low quality sources). Doubled modes run a second restore pass.
public enum Anime4KMode: String, Codable, CaseIterable, Sendable {
    case a = "A"
    case b = "B"
    case c = "C"
    case aa = "A+A"
    case bb = "B+B"
    case ca = "C+A"

    public var displayName: String { "Mode " + rawValue }
}

/// CNN network size. Bigger = sharper and slower. Anime4K naming: S, M, L, VL, UL.
public enum ModelSize: String, Codable, CaseIterable, Comparable, Sendable {
    case s = "S"
    case m = "M"
    case l = "L"
    case vl = "VL"
    case ul = "UL"

    public static func < (a: ModelSize, b: ModelSize) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    /// One step smaller (clamped at S). Used for the secondary passes of a preset.
    public var smaller: ModelSize {
        let all = ModelSize.allCases
        return all[max(0, all.firstIndex(of: self)! - 1)]
    }
}

/// How the ×2 networks are fed. Anime4K's own rule only runs them when the screen is more
/// than 1.2× the video, so 1080p on an iPad mini (1.17×) gets Restore only.
public enum UpscalePath: String, Codable, CaseIterable, Sendable {
    /// Anime4K's rules as shipped.
    case auto
    /// Always run the ×2 network on the full-resolution frame, then resample down to the screen.
    case full2x
    /// Shrink the frame to half the on-screen size first, then Restore + ×2 land on the screen
    /// size. Much cheaper (the networks see ~1/3 of the pixels) at the cost of source detail.
    case half2x

    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .full2x: return "Full-res ×2"
        case .half2x: return "Half-res ×2"
        }
    }

    public var detail: String {
        switch self {
        case .auto: return "Anime4K default: ×2 only above 1.2× scale"
        case .full2x: return "×2 on the full frame, then down to screen"
        case .half2x: return "Shrink to ½ screen, then ×2 (cheaper)"
        }
    }

    /// Short tag for the pill / labels; empty for auto.
    public var tag: String {
        switch self {
        case .auto: return ""
        case .full2x: return "×2"
        case .half2x: return "½×2"
        }
    }
}

/// User-facing upscaling configuration. Value type; persisted as JSON in UserDefaults.
public struct UpscaleSettings: Codable, Equatable, Sendable {
    public var enabled: Bool = false
    public var model: UpscaleModel = .anime4k
    public var mode: Anime4KMode = .a
    public var size: ModelSize = .m
    public var showStats: Bool = true
    public var path: UpscalePath = .auto

    public init() {}

    private enum CodingKeys: String, CodingKey { case enabled, model, mode, size, showStats, path
        case forceUpscale   // legacy (one build): true == .full2x
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(model, forKey: .model)
        try c.encode(mode, forKey: .mode)
        try c.encode(size, forKey: .size)
        try c.encode(showStats, forKey: .showStats)
        try c.encode(path, forKey: .path)
    }


    // Hand-written so settings saved by older builds (missing newer keys) still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = UpscaleSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        model = (try? c.decodeIfPresent(UpscaleModel.self, forKey: .model)) ?? d.model
        mode = (try? c.decodeIfPresent(Anime4KMode.self, forKey: .mode)) ?? d.mode
        size = (try? c.decodeIfPresent(ModelSize.self, forKey: .size)) ?? d.size
        showStats = try c.decodeIfPresent(Bool.self, forKey: .showStats) ?? d.showStats
        if let p = try? c.decodeIfPresent(UpscalePath.self, forKey: .path) {
            path = p
        } else if (try? c.decodeIfPresent(Bool.self, forKey: .forceUpscale)) == true {
            path = .full2x
        } else {
            path = d.path
        }
    }

    /// Short label for toasts and the overlay, e.g. "Anime4K · Mode A · M".
    public var label: String {
        guard enabled else { return "Off" }
        return "\(model.displayName) · \(mode.displayName) · \(size.rawValue)" + (path == .auto ? "" : " · \(path.displayName)")
    }

    private static let defaultsKey = "Anime4KPlayer.settings.v1"

    public static func load(_ defaults: UserDefaults = .standard) -> UpscaleSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let s = try? JSONDecoder().decode(UpscaleSettings.self, from: data) else {
            return UpscaleSettings()
        }
        return s
    }

    public func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
