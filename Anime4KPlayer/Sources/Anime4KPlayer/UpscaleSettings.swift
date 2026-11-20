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

/// User-facing upscaling configuration. Value type; persisted as JSON in UserDefaults.
public struct UpscaleSettings: Codable, Equatable, Sendable {
    public var enabled: Bool = false
    public var model: UpscaleModel = .anime4k
    public var mode: Anime4KMode = .a
    public var size: ModelSize = .m
    public var showStats: Bool = true
    /// Always run the ×2 upscale network, even when the screen is less than 1.2× the video
    /// (Anime4K's own threshold skips it), then resample down to the screen.
    public var forceUpscale: Bool = false

    public init() {}

    private enum CodingKeys: String, CodingKey { case enabled, model, mode, size, showStats, forceUpscale }

    // Hand-written so settings saved by older builds (missing newer keys) still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = UpscaleSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        model = (try? c.decodeIfPresent(UpscaleModel.self, forKey: .model)) ?? d.model
        mode = (try? c.decodeIfPresent(Anime4KMode.self, forKey: .mode)) ?? d.mode
        size = (try? c.decodeIfPresent(ModelSize.self, forKey: .size)) ?? d.size
        showStats = try c.decodeIfPresent(Bool.self, forKey: .showStats) ?? d.showStats
        forceUpscale = try c.decodeIfPresent(Bool.self, forKey: .forceUpscale) ?? d.forceUpscale
    }

    /// Short label for toasts and the overlay, e.g. "Anime4K · Mode A · M".
    public var label: String {
        guard enabled else { return "Off" }
        return "\(model.displayName) · \(mode.displayName) · \(size.rawValue)" + (forceUpscale ? " · force ×2" : "")
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
