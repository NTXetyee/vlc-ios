import XCTest
import simd
@testable import Anime4KPlayer
@testable import Anime4KMetalCore

/// GPU-free logic tests (simulator tier).
final class Anime4KPlayerTests: XCTestCase {

    func testEveryModeAndSizeResolvesToBundledShaders() {
        for mode in Anime4KMode.allCases {
            for size in ModelSize.allCases {
                for path in Anime4KUpscaler.shaderFiles(mode: mode, size: size) {
                    let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
                    XCTAssertNotNil(Anime4KResources.glslURL(parts[1], subdir: parts[0]),
                                    "\(mode.rawValue)/\(size.rawValue): missing \(path)")
                }
            }
        }
    }

    func testOfficialPresetsAreReproduced() {
        // Anime4KMetal's "Mode A (Fast)" preset == our Mode A, size M.
        XCTAssertEqual(Anime4KUpscaler.shaderFiles(mode: .a, size: .m), [
            "Restore/Anime4K_Clamp_Highlights.glsl",
            "Restore/Anime4K_Restore_CNN_M.glsl",
            "Upscale/Anime4K_Upscale_CNN_x2_M.glsl",
            "Upscale/Anime4K_AutoDownscalePre_x2.glsl",
            "Upscale/Anime4K_AutoDownscalePre_x4.glsl",
            "Upscale/Anime4K_Upscale_CNN_x2_S.glsl",
        ])
        // HQ presets use VL with M secondaries.
        XCTAssertEqual(Anime4KUpscaler.shaderFiles(mode: .a, size: .vl).last, "Upscale/Anime4K_Upscale_CNN_x2_M.glsl")
    }

    private func rgb(_ p: YCbCrParams, _ y: Float, _ cb: Float, _ cr: Float) -> SIMD3<Float> {
        p.m * (SIMD3(y, cb, cr) - p.offset)
    }

    func testVideoRange8BitBlackWhite() {
        let p = YCbCrParams.make(matrix: .bt709, fullRange: false, bitDepth: 8, msbPacked16: false)
        let black = rgb(p, 16 / 255, 128 / 255, 128 / 255)
        let white = rgb(p, 235 / 255, 128 / 255, 128 / 255)
        for i in 0..<3 {
            XCTAssertEqual(black[i], 0, accuracy: 1e-4)
            XCTAssertEqual(white[i], 1, accuracy: 1e-4)
        }
    }

    func testVideoRange10BitMSBPacked() {
        // x420: 10-bit code c is stored as c << 6 in 16 bits -> r16Unorm reads c * 64 / 65535.
        let p = YCbCrParams.make(matrix: .bt709, fullRange: false, bitDepth: 10, msbPacked16: true)
        func n(_ code: Float) -> Float { code * 64 / 65535 }
        let white = rgb(p, n(940), n(512), n(512))
        let black = rgb(p, n(64), n(512), n(512))
        for i in 0..<3 {
            XCTAssertEqual(white[i], 1, accuracy: 1e-3)
            XCTAssertEqual(black[i], 0, accuracy: 1e-3)
        }
    }

    func testBT601PureRed() {
        // Full-range BT.601 red: Y = 0.299, Cb = 0.5 - 0.1687, Cr = 1.0
        let p = YCbCrParams.make(matrix: .bt601, fullRange: true, bitDepth: 8, msbPacked16: false)
        let mid: Float = 128 / 255
        let red = rgb(p, 0.299, mid - 0.168736, mid + 0.5)
        XCTAssertEqual(red.x, 1, accuracy: 0.01)
        XCTAssertEqual(red.y, 0, accuracy: 0.01)
        XCTAssertEqual(red.z, 0, accuracy: 0.01)
    }

    func testSettingsRoundTrip() {
        let defaults = UserDefaults(suiteName: "Anime4KPlayerTests")!
        var s = UpscaleSettings()
        s.enabled = true; s.mode = .aa; s.size = .vl
        s.save(defaults)
        XCTAssertEqual(UpscaleSettings.load(defaults), s)
        XCTAssertEqual(s.label, "Anime4K · Mode A+A · VL")
    }

    func testMetalStructLayoutMatchesShader() {
        // Kernels.metal: float3x3 (48 bytes) + float3 (16 bytes)
        XCTAssertEqual(MemoryLayout<YCbCrParams>.stride, 64)
    }
}
