import XCTest
import Metal
@testable import Anime4KMetalCore

/// GPU-free checks: these run even where `MTLCreateSystemDefaultDevice()` is nil
/// (e.g. CI VMs without Metal), unlike MPVShaderTests which compile on the GPU.
final class ShaderParseTests: XCTestCase {

    static let presetShaders: [(String, String)] = [
        ("Anime4K_Clamp_Highlights.glsl", "Restore"),
        ("Anime4K_Restore_CNN_M.glsl", "Restore"),
        ("Anime4K_Restore_CNN_VL.glsl", "Restore"),
        ("Anime4K_Upscale_CNN_x2_S.glsl", "Upscale"),
        ("Anime4K_Upscale_CNN_x2_M.glsl", "Upscale"),
        ("Anime4K_Upscale_CNN_x2_VL.glsl", "Upscale"),
        ("Anime4K_AutoDownscalePre_x2.glsl", "Upscale"),
        ("Anime4K_AutoDownscalePre_x4.glsl", "Upscale"),
    ]

    func testPresetShadersAreBundled() {
        for (name, subdir) in Self.presetShaders {
            XCTAssertNotNil(Anime4KResources.glslURL(name, subdir: subdir), "missing \(subdir)/\(name)")
        }
    }

    func testPresetShadersParseToMetal() throws {
        for (name, subdir) in Self.presetShaders {
            let url = try XCTUnwrap(Anime4KResources.glslURL(name, subdir: subdir))
            let glsl = try String(contentsOf: url, encoding: .utf8)
            let passes = try MPVShader.parse(glsl)
            XCTAssertFalse(passes.isEmpty, "\(name) produced no passes")
            for pass in passes {
                XCTAssertTrue(pass.metalCode.contains("kernel void"), "\(name)/\(pass.name) has no kernel")
            }
            print("[parse] \(name): \(passes.count) passes")
        }
    }

    func testMetalDeviceAvailability() {
        // Informational: tells us from the CI log whether the runner exposes Metal.
        let device = MTLCreateSystemDefaultDevice()
        print("[metal] device = \(device?.name ?? "nil (no Metal on this runner)")")
    }
}
