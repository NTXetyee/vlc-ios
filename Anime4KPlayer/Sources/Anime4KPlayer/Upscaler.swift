import Foundation
import Metal
import Anime4KMetalCore

/// A GPU upscaling model. Implementations take linear-ish RGB (`rgba16Float`, source size)
/// and return an RGB texture at any size >= source; the pipeline resamples it to the display size.
public protocol Upscaler: AnyObject {
    /// Human readable description of what runs, for logs and the stats overlay.
    var summary: String { get }
    /// Prepare for a source/output size pair. Can be slow (pipeline compilation): call off the main thread.
    func configure(sourceWidth: Int, sourceHeight: Int, outputWidth: Int, outputHeight: Int) throws
    /// Encode the upscale into `commandBuffer`. Must not block.
    func encode(source: MTLTexture, commandBuffer: MTLCommandBuffer) throws -> MTLTexture
    /// Number of compute passes that will run for the configured sizes.
    var activePassCount: Int { get }
}

public enum UpscalerFactory {
    /// Build the upscaler for `settings`. Slow (compiles Metal from GLSL): call off the main thread.
    public static func make(settings: UpscaleSettings, device: MTLDevice) throws -> Upscaler {
        switch settings.model {
        case .anime4k:
            return try Anime4KUpscaler(mode: settings.mode, size: settings.size, device: device)
        }
    }
}

/// Anime4K via Anime4KMetal's runtime GLSL -> Metal translation (phase 1 engine).
public final class Anime4KUpscaler: Upscaler {
    public let mode: Anime4KMode
    public let size: ModelSize
    private let device: MTLDevice
    private let stages: [Anime4K]

    public init(mode: Anime4KMode, size: ModelSize, device: MTLDevice) throws {
        self.mode = mode
        self.size = size
        self.device = device
        self.stages = try Self.shaderFiles(mode: mode, size: size).map { path in
            let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
            return try Anime4K(parts[1], subdir: parts[0], device: device)
        }
    }

    public var summary: String { "Anime4K \(mode.displayName) \(size.rawValue)" }

    public var activePassCount: Int { stages.reduce(0) { $0 + $1.activePassCount } }

    public func configure(sourceWidth: Int, sourceHeight: Int, outputWidth: Int, outputHeight: Int) throws {
        var w = sourceWidth, h = sourceHeight
        for stage in stages {
            try stage.compileShaders(device, videoInW: sourceWidth, videoInH: sourceHeight,
                                     textureInW: w, textureInH: h,
                                     displayOutW: outputWidth, displayOutH: outputHeight)
            w = Int(stage.outputW)
            h = Int(stage.outputH)
        }
    }

    public func encode(source: MTLTexture, commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        var tex = source
        for stage in stages {
            tex = try stage.encode(device, cmdBuf: commandBuffer, input: tex)
        }
        return tex
    }

    /// Secondary (second upscale / second restore) network size, matching the official
    /// presets: M -> S ("Fast"), VL -> M ("HQ").
    static func secondary(_ size: ModelSize) -> ModelSize {
        switch size {
        case .s, .m, .l: return .s
        case .vl, .ul: return .m
        }
    }

    /// GLSL files (relative to the bundled glsl/ folder) for a mode, following bloc97's mpv templates.
    public static func shaderFiles(mode: Anime4KMode, size x: ModelSize) -> [String] {
        let y = secondary(x)
        let clamp = "Restore/Anime4K_Clamp_Highlights.glsl"
        func restore(_ s: ModelSize) -> String { "Restore/Anime4K_Restore_CNN_\(s.rawValue).glsl" }
        func restoreSoft(_ s: ModelSize) -> String { "Restore/Anime4K_Restore_CNN_Soft_\(s.rawValue).glsl" }
        func upscale(_ s: ModelSize) -> String { "Upscale/Anime4K_Upscale_CNN_x2_\(s.rawValue).glsl" }
        func upDenoise(_ s: ModelSize) -> String { "Upscale+Denoise/Anime4K_Upscale_Denoise_CNN_x2_\(s.rawValue).glsl" }
        let down = ["Upscale/Anime4K_AutoDownscalePre_x2.glsl", "Upscale/Anime4K_AutoDownscalePre_x4.glsl"]

        switch mode {
        case .a:  return [clamp, restore(x), upscale(x)] + down + [upscale(y)]
        case .b:  return [clamp, restoreSoft(x), upscale(x)] + down + [upscale(y)]
        case .c:  return [clamp, upDenoise(x)] + down + [upscale(y)]
        case .aa: return [clamp, restore(x), upscale(x), restore(y)] + down + [upscale(y)]
        case .bb: return [clamp, restoreSoft(x), upscale(x)] + down + [restoreSoft(y), upscale(y)]
        case .ca: return [clamp, upDenoise(x)] + down + [restore(y), upscale(y)]
        }
    }
}
