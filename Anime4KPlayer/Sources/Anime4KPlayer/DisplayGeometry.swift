import CoreGraphics
import CoreVideo
import QuartzCore

/// Where a decoded frame actually lands on screen, in pixels.
///
/// VLC's AVSampleBufferDisplayLayer fills the whole player view and letterboxes the video with
/// `resizeAspect`, so neither the layer's bounds nor its `contentsScale` (1.0 on a layer that
/// is not a view's backing layer) say how many screen pixels the video covers.
enum DisplayGeometry {
    /// Pixels per point for `layer`: the largest `contentsScale` along its superlayer chain.
    /// UIKit sets the screen scale on view backing layers (including on external displays) but
    /// not on sublayers created with `[AVSampleBufferDisplayLayer new]` like VLC's.
    static func pixelScale(of layer: CALayer) -> CGFloat {
        var scale = layer.contentsScale
        var l = layer.superlayer
        while let current = l {
            scale = max(scale, current.contentsScale)
            l = current.superlayer
        }
        return max(scale, 1)
    }

    /// Visible part of the frame (clean aperture), in source pixels, with a top-left origin.
    /// Decoders often pad 1080p to 1088 rows; the padding must not be upscaled onto the screen.
    static func visibleRect(of pb: CVPixelBuffer) -> CGRect {
        let w = CGFloat(CVPixelBufferGetWidth(pb)), h = CGFloat(CVPixelBufferGetHeight(pb))
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        // QuickTime 'clap' semantics: size plus the offset of its centre from the frame centre
        // (x right, y down).
        guard let clap = CVBufferCopyAttachment(pb, kCVImageBufferCleanApertureKey, nil) as? [String: Any],
              let cw = (clap[kCVImageBufferCleanApertureWidthKey as String] as? NSNumber)?.doubleValue,
              let ch = (clap[kCVImageBufferCleanApertureHeightKey as String] as? NSNumber)?.doubleValue else { return full }
        let dx = (clap[kCVImageBufferCleanApertureHorizontalOffsetKey as String] as? NSNumber)?.doubleValue ?? 0
        let dy = (clap[kCVImageBufferCleanApertureVerticalOffsetKey as String] as? NSNumber)?.doubleValue ?? 0
        let clean = CGRect(x: (w - cw) / 2 + dx, y: (h - ch) / 2 + dy, width: cw, height: ch)
        let r = clean.integral.intersection(full)
        return r.isNull || r.width < 1 || r.height < 1 ? full : r
    }

    /// Horizontal / vertical pixel spacing (anamorphic DVDs etc.), 1 when unspecified.
    static func pixelAspectRatio(of pb: CVPixelBuffer) -> CGFloat {
        guard let par = CVBufferCopyAttachment(pb, kCVImageBufferPixelAspectRatioKey, nil) as? [String: Any],
              let hs = (par[kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String] as? NSNumber)?.doubleValue,
              let vs = (par[kCVImageBufferPixelAspectRatioVerticalSpacingKey as String] as? NSNumber)?.doubleValue,
              hs > 0, vs > 0 else { return 1 }
        return CGFloat(hs / vs)
    }

    /// Size in pixels of a `visible`-sized picture (with `pixelAspect`) aspect-fitted into
    /// `bounds` (also pixels), the way `AVLayerVideoGravity.resizeAspect` draws it.
    static func aspectFit(visible: CGSize, pixelAspect: CGFloat, into bounds: CGSize) -> (width: Int, height: Int) {
        let dispW = visible.width * pixelAspect, dispH = visible.height
        guard dispW > 0, dispH > 0, bounds.width > 0, bounds.height > 0 else { return (0, 0) }
        let s = min(bounds.width / dispW, bounds.height / dispH)
        return (Int((dispW * s).rounded()), Int((dispH * s).rounded()))
    }
}
