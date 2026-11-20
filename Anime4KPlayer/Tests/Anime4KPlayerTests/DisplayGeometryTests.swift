import XCTest
import CoreVideo
import QuartzCore
@testable import Anime4KPlayer

final class DisplayGeometryTests: XCTestCase {

    func testSublayerInheritsScreenScaleFromBackingLayer() {
        // VLC's AVSampleBufferDisplayLayer is a plain sublayer: contentsScale stays 1.
        let backing = CALayer(); backing.contentsScale = 2
        let display = CALayer(); display.contentsScale = 1
        backing.addSublayer(display)
        XCTAssertEqual(DisplayGeometry.pixelScale(of: display), 2)
        XCTAssertEqual(DisplayGeometry.pixelScale(of: CALayer()), 1)
    }

    func testLetterboxedFitOnIPadMini() {
        // 1080p in a full-screen 1133x744 pt @2x layer -> 2266x1275, upscale needed.
        let fit = DisplayGeometry.aspectFit(visible: CGSize(width: 1920, height: 1080), pixelAspect: 1,
                                            into: CGSize(width: 2266, height: 1488))
        XCTAssertEqual(fit.width, 2266)
        XCTAssertEqual(fit.height, 1275)
    }

    func testAnamorphicPixelAspect() {
        // 720x480 NTSC DVD, 32:27 PAR -> 16:9 picture.
        let fit = DisplayGeometry.aspectFit(visible: CGSize(width: 720, height: 480), pixelAspect: 32.0 / 27.0,
                                            into: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(fit.width, 1920)
        XCTAssertEqual(fit.height, 1080)
    }

    func testEmptyBounds() {
        let fit = DisplayGeometry.aspectFit(visible: CGSize(width: 1920, height: 1080), pixelAspect: 1, into: .zero)
        XCTAssertEqual(fit.width, 0)
        XCTAssertEqual(fit.height, 0)
    }

    func testCleanApertureCropsDecoderPadding() throws {
        var pb: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 1920, 1088, kCVPixelFormatType_32BGRA, nil, &pb), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pb)
        // No clean aperture: 16:9 macroblock padding is recognised.
        XCTAssertEqual(DisplayGeometry.visibleRect(of: buffer), CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let aperture: [String: Any] = [
            kCVImageBufferCleanApertureWidthKey as String: 1920,
            kCVImageBufferCleanApertureHeightKey as String: 1080,
            kCVImageBufferCleanApertureHorizontalOffsetKey as String: 0,
            kCVImageBufferCleanApertureVerticalOffsetKey as String: -4, // centred offset: top-aligned 1080 in 1088
        ]
        CVBufferSetAttachment(buffer, kCVImageBufferCleanApertureKey, aperture as CFDictionary, .shouldPropagate)
        XCTAssertEqual(DisplayGeometry.visibleRect(of: buffer), CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    func testMacroblockPaddingHeuristic() {
        XCTAssertEqual(DisplayGeometry.paddedHeight(width: 1920, height: 1088), 1080)
        XCTAssertEqual(DisplayGeometry.paddedHeight(width: 960, height: 544), 540)
        XCTAssertNil(DisplayGeometry.paddedHeight(width: 1440, height: 1088))   // not 16:9: leave alone
        XCTAssertNil(DisplayGeometry.paddedHeight(width: 1920, height: 1080))
        XCTAssertNil(DisplayGeometry.paddedHeight(width: 1280, height: 720))
    }

    func testExplicitCleanApertureWinsOverHeuristic() {
        let fullClap: [String: Any] = [
            kCVImageBufferCleanApertureWidthKey as String: 1920,
            kCVImageBufferCleanApertureHeightKey as String: 1088,
        ]
        XCTAssertEqual(DisplayGeometry.visibleRect(width: 1920, height: 1088, cleanAperture: fullClap),
                       CGRect(x: 0, y: 0, width: 1920, height: 1088))
    }
}
