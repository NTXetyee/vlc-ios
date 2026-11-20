import XCTest
import Metal
@testable import Anime4KMetalCore

final class ShaderLibraryCacheTests: XCTestCase {
    func testSecondInstanceReusesCompiledLibraries() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Metal is not supported")
        let cache = ShaderLibraryCache.shared
        let name = "Anime4K_Clamp_Highlights.glsl", subdir = "Restore"
        let a = try Anime4K(name, subdir: subdir, device: device)
        XCTAssertTrue(cache.contains(name, subdir: subdir, device: device))
        let hits = cache.hits
        let b = try Anime4K(name, subdir: subdir, device: device)
        XCTAssertEqual(cache.hits, hits + 1)
        XCTAssertEqual(a.libraries.count, b.libraries.count)
        for (x, y) in zip(a.libraries, b.libraries) { XCTAssertTrue(x === y) }
    }

    func testPrewarmSkipsCachedFiles() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Metal is not supported")
        let files = ["Restore/Anime4K_Restore_CNN_S.glsl"]
        ShaderLibraryCache.shared.prewarm(files, device: device)
        XCTAssertEqual(ShaderLibraryCache.shared.prewarm(files, device: device), 0)
    }
}
