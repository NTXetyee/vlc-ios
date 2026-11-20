import XCTest
@testable import Anime4KPlayer

final class DiagnosticsTests: XCTestCase {
    func testHeartbeatReportsDeltas() {
        var old = FrameStats.Snapshot()
        old.frames = 100; old.upscaled = 90; old.passThrough = ["GPU busy": 10]
        var new = old
        new.frames = 250; new.upscaled = 90; new.reused = 150; new.passThrough = ["GPU busy": 10, "no upscale": 0]
        let line = new.heartbeat(since: old, seconds: 5)
        XCTAssertTrue(line.contains("150 frames (30.0/s)"), line)
        XCTAssertTrue(line.contains("reused +150"), line)
        XCTAssertTrue(line.contains("upscaled +0"), line)
        XCTAssertFalse(line.contains("original:"), line)   // no pass-through changes
        XCTAssertFalse(line.contains("GPU p50"), line)     // nothing upscaled in this window
    }

    func testMarkersAreNumberedAndLogged() {
        let a = A4KLog.shared.mark(), b = A4KLog.shared.mark()
        XCTAssertEqual(b, a + 1)
        XCTAssertTrue(A4KLog.shared.dump().contains("MARK \(b)"))
    }

    func testSettingsFromOlderBuildsStillLoad() throws {
        // Saved before the upscale path existed.
        let old = #"{"enabled":true,"model":"anime4k","mode":"A+A","size":"L","showStats":false}"#
        let s = try JSONDecoder().decode(UpscaleSettings.self, from: Data(old.utf8))
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.mode, .aa)
        XCTAssertEqual(s.size, .l)
        XCTAssertFalse(s.showStats)
        XCTAssertEqual(s.path, .auto)
        var round = s; round.path = .half2x
        let back = try JSONDecoder().decode(UpscaleSettings.self, from: JSONEncoder().encode(round))
        XCTAssertEqual(back, round)
    }

    func testLegacyForceFlagMapsToFullRes() throws {
        let saved = #"{"enabled":true,"model":"anime4k","mode":"A","size":"M","showStats":true,"forceUpscale":true}"#
        let s = try JSONDecoder().decode(UpscaleSettings.self, from: Data(saved.utf8))
        XCTAssertEqual(s.path, .full2x)
    }
}
