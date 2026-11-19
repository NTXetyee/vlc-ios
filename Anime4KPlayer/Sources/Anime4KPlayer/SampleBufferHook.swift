import AVFoundation
import ObjectiveC

/// Intercepts `-[AVSampleBufferDisplayLayer enqueueSampleBuffer:]` and `flush`.
///
/// libvlc 4's default iOS video output (modules/video_output/apple/VLCSampleBufferDisplay.m)
/// wraps every decoded frame in a CMSampleBuffer and enqueues it, ahead of its display time,
/// into the AVSampleBufferDisplayLayer of a `VLCSampleBufferDisplayView` inside the player's
/// drawable. Subtitles live in a sibling view above it, so they never reach this hook.
/// Layers that don't belong to VLC are passed through untouched.
enum SampleBufferHook {
    typealias EnqueueIMP = @convention(c) (AnyObject, Selector, CMSampleBuffer) -> Void
    typealias VoidIMP = @convention(c) (AnyObject, Selector) -> Void

    /// Return true if the frame was taken over (it will be enqueued later via `enqueueOriginal`).
    typealias FrameHandler = (AVSampleBufferDisplayLayer, CMSampleBuffer) -> Bool

    private static let enqueueSel = NSSelectorFromString("enqueueSampleBuffer:")
    private static let flushSel = NSSelectorFromString("flush")
    private static let flushRemoveSel = NSSelectorFromString("flushAndRemoveImage")

    private static var originalEnqueue: EnqueueIMP?
    private static var originalFlush: VoidIMP?
    private static var originalFlushRemove: VoidIMP?
    private static var installed = false

    static func install(onFrame: @escaping FrameHandler, onFlush: @escaping (AVSampleBufferDisplayLayer) -> Void) {
        guard !installed else { return }
        installed = true
        let cls: AnyClass = AVSampleBufferDisplayLayer.self

        if let m = class_getInstanceMethod(cls, enqueueSel) {
            originalEnqueue = unsafeBitCast(method_getImplementation(m), to: EnqueueIMP.self)
            let block: @convention(block) (AVSampleBufferDisplayLayer, CMSampleBuffer) -> Void = { layer, sb in
                if isVLCLayer(layer), onFrame(layer, sb) { return }
                originalEnqueue?(layer, enqueueSel, sb)
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        } else {
            a4kLog("hook: enqueueSampleBuffer: not found, upscaling unavailable")
        }

        for (sel, store) in [(flushSel, 0), (flushRemoveSel, 1)] {
            guard let m = class_getInstanceMethod(cls, sel) else { continue }
            let orig = unsafeBitCast(method_getImplementation(m), to: VoidIMP.self)
            if store == 0 { originalFlush = orig } else { originalFlushRemove = orig }
            let block: @convention(block) (AVSampleBufferDisplayLayer) -> Void = { layer in
                if isVLCLayer(layer) { onFlush(layer) }
                orig(layer, sel)
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        a4kLog("hook installed on AVSampleBufferDisplayLayer")
    }

    /// Enqueue on the layer without going through our hook, serialised the same way VLC does
    /// (`@synchronized(displayLayer)` in VLCSampleBufferDisplay.m).
    static func enqueueOriginal(_ layer: AVSampleBufferDisplayLayer, _ sb: CMSampleBuffer) {
        objc_sync_enter(layer)
        originalEnqueue?(layer, enqueueSel, sb)
        objc_sync_exit(layer)
    }

    static func isVLCLayer(_ layer: AVSampleBufferDisplayLayer) -> Bool {
        guard let delegate = layer.delegate else { return false }
        return NSStringFromClass(type(of: delegate as AnyObject)) == "VLCSampleBufferDisplayView"
    }
}
