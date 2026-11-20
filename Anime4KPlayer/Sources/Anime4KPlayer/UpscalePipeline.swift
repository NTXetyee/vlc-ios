import Foundation
import Metal
import CoreMedia
import CoreVideo
import IOSurface
import QuartzCore
import Anime4KMetalCore

/// Turns one decoded VLC frame (CMSampleBuffer wrapping an IOSurface CVPixelBuffer) into an
/// upscaled BGRA frame at display resolution, entirely on the GPU, then hands it back with the
/// original presentation time. Every unsupported or not-ready case returns `false` so the
/// caller shows the original frame unchanged.
final class UpscalePipeline {
    let stats = FrameStats()

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let ingestPSO: MTLComputePipelineState
    private let resizePSO: MTLComputePipelineState
    private let buildQueue = DispatchQueue(label: "Anime4KPlayer.build", qos: .userInitiated)
    private let maxInFlight = Anime4K.bufferCount
    var deviceName: String { device.name }

    // State below is guarded by `lock`.
    private let lock = NSLock()
    private var settings = UpscaleSettings()
    private var suspended = false
    private var upscaler: Upscaler?
    private var readyKey: ConfigKey?
    private var buildingKey: ConfigKey?
    private var failedKey: ConfigKey?
    private var inFlight = 0
    private var generation = 0
    private var outputPool: CVPixelBufferPool?
    private var outputPoolSize = (0, 0)
    private var sourceTextures: [MTLTexture] = []
    private var sourceSlot = 0
    private var loggedFormats = Set<OSType>()
    private var lastFrame: LastFrame?
    private var reuseStreak = 0
    private var lastGeometry = ""   // vout thread only
    private var lastFormat: OSType = 0

    private struct ConfigKey: Equatable {
        var model: UpscaleModel, mode: Anime4KMode, size: ModelSize, force: Bool
        var srcW: Int, srcH: Int, outW: Int, outH: Int

        /// Output size the model is configured for. Anime4K only enables its ×2 networks when
        /// the output is > 1.2× their input; with `force` we ask for at least 2× so the first
        /// upscale runs (and only that one: at exactly 2× the pre-downscale and second ×2 stay
        /// off), and the pipeline resamples the 2× result down to the real output.
        var modelOutput: (w: Int, h: Int) {
            let scale = min(Double(outW) / Double(srcW), Double(outH) / Double(srcH))
            return force && scale < 2 ? (srcW * 2, srcH * 2) : (outW, outH)
        }
    }

    /// Identity of a decoded picture. While paused, VLC redisplays the current picture by
    /// enqueueing the same CVPixelBuffer again with a new timestamp (RenderPicture in
    /// VLCSampleBufferDisplay.m). A decoder buffer can't come back as the very next frame with
    /// new content (VLC holds the displayed picture until its successor is shown), so "same
    /// buffer as the previous frame" means "same picture". The IOSurface seed is a cheap extra
    /// guard against in-place rewrites.
    private struct FrameID: Equatable {
        var buffer: UnsafeMutableRawPointer, surface: IOSurfaceID, seed: UInt32

        init(_ pb: CVPixelBuffer) {
            buffer = Unmanaged.passUnretained(pb).toOpaque()
            if let io = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() {
                surface = IOSurfaceGetID(io); seed = IOSurfaceGetSeed(io)
            } else {
                surface = 0; seed = 0
            }
        }
    }

    /// The last picture sent to the model and, once the GPU finishes, its upscaled output.
    private struct LastFrame {
        var id: FrameID, key: ConfigKey, generation: Int
        var output: CVPixelBuffer?
    }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        do {
            let lib = try device.makeDefaultLibrary(bundle: .module)
            ingestPSO = try device.makeComputePipelineState(function: lib.makeFunction(name: "IngestBiPlanar")!)
            resizePSO = try device.makeComputePipelineState(function: lib.makeFunction(name: "ResizeFill")!)
        } catch {
            a4kLog("pipeline init failed: \(error)")
            return nil
        }
        self.device = device
        self.queue = queue
        self.textureCache = cache
        queue.label = "Anime4KPlayer"
        a4kLog("pipeline ready on \(device.name)")
    }

    // MARK: - Control

    func apply(settings new: UpscaleSettings) {
        lock.lock()
        let old = settings
        settings = new
        lock.unlock()
        if !new.enabled {
            releaseResources(reason: "disabled")
        } else if old.model != new.model || old.mode != new.mode || old.size != new.size
                    || old.forceUpscale != new.forceUpscale || !old.enabled {
            stats.resetCounters()
            prewarm(new)
        }
    }

    /// iOS forbids GPU work in the background: stop submitting and free memory.
    func setSuspended(_ value: Bool) {
        lock.lock(); suspended = value; lock.unlock()
        if value { releaseResources(reason: "background") }
    }

    /// Drop frames still in flight (seek / flush on the display layer).
    func flush() {
        lock.lock(); generation &+= 1; lastFrame = nil; lock.unlock()
        stats.update { $0.flushes += 1 }
    }

    func releaseResources(reason: String) {
        lock.lock()
        let had = upscaler != nil
        upscaler = nil
        readyKey = nil
        failedKey = nil
        outputPool = nil
        outputPoolSize = (0, 0)
        sourceTextures = []
        lastFrame = nil
        generation &+= 1
        lock.unlock()
        CVMetalTextureCacheFlush(textureCache, 0)
        if had { a4kLog("released GPU resources (\(reason))") }
    }

    // MARK: - Per frame

    /// - Parameters:
    ///   - layerPixelSize: bounds of the display layer in screen pixels. The video is
    ///     aspect-fitted inside it (letterboxed), so this is not the video's own size.
    ///   - enqueue: called later (Metal completion thread) with the upscaled sample buffer.
    /// - Returns: false if the caller must show the original frame now.
    func process(_ sampleBuffer: CMSampleBuffer, layerPixelSize: CGSize,
                 enqueue: @escaping (CMSampleBuffer) -> Void) -> Bool {
        lock.lock()
        let settings = self.settings
        let suspended = self.suspended
        lock.unlock()
        guard settings.enabled, !suspended else { return false }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            stats.passThrough("no image"); return false
        }
        stats.frameSeen()
        // Only the immediately preceding picture may be reused: any other frame, whatever path it
        // takes below, invalidates the cache (its decoder buffer may be recycled later).
        let frameID = FrameID(pixelBuffer)
        lock.lock()
        if lastFrame?.id != frameID { lastFrame = nil }
        let endedStreak = lastFrame == nil ? reuseStreak : 0
        if endedStreak > 0 { reuseStreak = 0 }
        lock.unlock()
        if endedStreak > 0 { a4kLog("redisplay: same picture reused \(endedStreak)x, new picture arrived") }

        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard let input = InputFormat(format) else {
            noteUnsupported(format, pixelBuffer)
            stats.passThrough("format"); return false
        }
        if format != lastFormat {   // vout thread only
            lastFormat = format
            let name = Self.fourCC(format)
            stats.update { $0.pixelFormat = name }
            a4kLog("input pixel format \(name) \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))")
        }
        if Self.isHDR(pixelBuffer) {
            noteUnsupported(format, pixelBuffer, why: "HDR transfer")
            stats.passThrough("HDR"); return false
        }

        let srcW = CVPixelBufferGetWidth(pixelBuffer), srcH = CVPixelBufferGetHeight(pixelBuffer)
        // Output = the on-screen video rect (aspect-fitted, padding cropped), capped at 4096.
        let visible = DisplayGeometry.visibleRect(of: pixelBuffer)
        let fitted = DisplayGeometry.aspectFit(visible: visible.size,
                                               pixelAspect: DisplayGeometry.pixelAspectRatio(of: pixelBuffer),
                                               into: layerPixelSize)
        let cap = min(1, 4096 / CGFloat(max(fitted.width, fitted.height, 1)))
        let outW = Int((CGFloat(fitted.width) * cap).rounded())
        let outH = Int((CGFloat(fitted.height) * cap).rounded())
        let par = DisplayGeometry.pixelAspectRatio(of: pixelBuffer)
        let geometry = "layer \(Int(layerPixelSize.width))x\(Int(layerPixelSize.height)) px · src \(srcW)x\(srcH)"
            + " · visible \(Int(visible.minX)),\(Int(visible.minY)) \(Int(visible.width))x\(Int(visible.height))"
            + " · PAR \(String(format: "%.3f", par)) · out \(outW)x\(outH)"
            + " (\(String(format: "%.2f", Double(outW) / Double(max(1, Int(visible.width)))))x)"
        if geometry != lastGeometry {
            lastGeometry = geometry
            stats.update { $0.geometry = geometry }
            a4kLog("geometry: " + geometry)
        }
        // Nothing to gain when the video is shown at (or below) its native size, e.g. PiP or a small window.
        guard outW > Int(visible.width) || outH > Int(visible.height) else {
            stats.passThrough("no upscale")
            stats.update { $0.sourceSize = "\(Int(visible.width))x\(Int(visible.height))"; $0.outputSize = "\(outW)x\(outH)" }
            return false
        }
        // Normalized crop of the visible area; the model upscales uniformly, so it applies to its output too.
        var crop = SIMD4<Float>(Float(visible.minX) / Float(srcW), Float(visible.minY) / Float(srcH),
                                Float(visible.width) / Float(srcW), Float(visible.height) / Float(srcH))

        let key = ConfigKey(model: settings.model, mode: settings.mode, size: settings.size, force: settings.forceUpscale,
                            srcW: srcW, srcH: srcH, outW: outW, outH: outH)

        lock.lock()
        // Redisplay of the picture we just upscaled (paused, subtitle/OSD change): reuse the output.
        if let last = lastFrame, last.id == frameID, last.key == key, last.generation == generation {
            let cached = last.output
            reuseStreak += 1
            let firstReuse = reuseStreak == 1
            lock.unlock()
            if firstReuse { a4kLog("redisplay: same picture re-enqueued (paused?), reusing upscaled output") }
            guard let cached else {
                // Its GPU work is still in flight and will be enqueued when done; skip this copy.
                stats.reused(); return true
            }
            let pts = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
            guard let out = Self.sampleBuffer(with: cached, timing: pts) else {
                stats.passThrough("output buffer"); return false
            }
            stats.reused()
            enqueue(out)
            return true
        }
        guard let upscaler = self.upscaler, readyKey == key else {
            let shouldBuild = buildingKey != key && failedKey != key
            if shouldBuild { buildingKey = key }
            lock.unlock()
            if shouldBuild { build(key: key, settings: settings) }
            stats.passThrough("warming up"); return false
        }
        guard inFlight < maxInFlight else {
            lock.unlock(); stats.passThrough("GPU busy"); return false
        }
        inFlight += 1
        let gen = generation
        lastFrame = LastFrame(id: frameID, key: key, generation: gen, output: nil)
        let pool = reuseOrMakeOutputPool(width: outW, height: outH)
        let sourceTex: MTLTexture? = input.needsIngest ? nextSourceTexture(width: srcW, height: srcH) : nil
        lock.unlock()

        func bail(_ reason: String) -> Bool {
            lock.lock()
            inFlight -= 1
            if lastFrame?.id == frameID { lastFrame = nil }
            lock.unlock()
            stats.passThrough(reason)
            return false
        }

        // Zero-copy views of the decoder's planes.
        var keepAlive: [CVMetalTexture] = []
        let modelInput: MTLTexture
        var params: YCbCrParams?
        var ingest: (luma: MTLTexture, chroma: MTLTexture)?
        switch input {
        case .bgra:
            guard let t = makeTexture(pixelBuffer, plane: 0, format: .bgra8Unorm, keep: &keepAlive) else { return bail("texture") }
            modelInput = t
        case .biPlanar(let bits, let fullRange):
            let lumaFmt: MTLPixelFormat = bits == 8 ? .r8Unorm : .r16Unorm
            let chromaFmt: MTLPixelFormat = bits == 8 ? .rg8Unorm : .rg16Unorm
            guard let src = sourceTex,
                  let luma = makeTexture(pixelBuffer, plane: 0, format: lumaFmt, keep: &keepAlive),
                  let chroma = makeTexture(pixelBuffer, plane: 1, format: chromaFmt, keep: &keepAlive) else {
                return bail("texture")
            }
            params = YCbCrParams.make(matrix: YCbCrMatrix.of(pixelBuffer), fullRange: fullRange,
                                      bitDepth: bits, msbPacked16: bits > 8)
            modelInput = src
            ingest = (luma, chroma)
        }

        var outBuffer: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer) == kCVReturnSuccess,
              let outBuffer,
              let outTex = makeTexture(outBuffer, plane: 0, format: .bgra8Unorm, keep: &keepAlive, writable: true),
              let cmd = queue.makeCommandBuffer() else {
            return bail("output buffer")
        }
        cmd.label = "Anime4K frame"

        do {
            if var p = params, let ingest, let enc = cmd.makeComputeCommandEncoder() {
                enc.label = "Ingest YCbCr"
                enc.setComputePipelineState(ingestPSO)
                enc.setTexture(ingest.luma, index: 0)
                enc.setTexture(ingest.chroma, index: 1)
                enc.setTexture(modelInput, index: 2)
                enc.setBytes(&p, length: MemoryLayout<YCbCrParams>.stride, index: 0)
                dispatch(enc, ingestPSO, modelInput)
                enc.endEncoding()
            }
            let upscaled = try upscaler.encode(source: modelInput, commandBuffer: cmd)
            guard let enc = cmd.makeComputeCommandEncoder() else { return bail("encoder") }
            enc.label = "Resize to display"
            enc.setComputePipelineState(resizePSO)
            enc.setTexture(upscaled, index: 0)
            enc.setTexture(outTex, index: 1)
            enc.setBytes(&crop, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            dispatch(enc, resizePSO, outTex)
            enc.endEncoding()
        } catch {
            a4kLog("encode failed: \(error.localizedDescription)")
            return bail("encode error")
        }
        let pts = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
        let original = sampleBuffer
        cmd.addCompletedHandler { [weak self] cb in
            _ = keepAlive // keep CVMetalTextures (and their IOSurfaces) alive until the GPU is done
            guard let self else { return }
            self.lock.lock()
            self.inFlight -= 1
            let stale = gen != self.generation
            if !stale, self.lastFrame?.id == frameID, self.lastFrame?.generation == gen {
                if cb.status == .completed { self.lastFrame?.output = outBuffer } else { self.lastFrame = nil }
            }
            self.lock.unlock()
            if stale { return }   // flushed (seek) or released while in flight: drop
            if cb.status != .completed {
                a4kLog("command buffer failed: \(cb.error?.localizedDescription ?? "unknown")")
                self.stats.passThrough("GPU error")
                enqueue(original)
                return
            }
            let gpuMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            let late = pts.isValid && CACurrentMediaTime() > pts.seconds
            self.stats.recordFrame(gpuMs: gpuMs, late: late)
            if let out = Self.sampleBuffer(with: outBuffer, timing: pts) {
                enqueue(out)
            } else {
                enqueue(original)
            }
        }
        cmd.commit()
        return true
    }

    // MARK: - Helpers

    private enum InputFormat {
        case bgra
        case biPlanar(bits: Int, fullRange: Bool)

        init?(_ f: OSType) {
            switch f {
            case kCVPixelFormatType_32BGRA: self = .bgra
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: self = .biPlanar(bits: 8, fullRange: false)
            case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: self = .biPlanar(bits: 8, fullRange: true)
            case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: self = .biPlanar(bits: 10, fullRange: false)
            case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: self = .biPlanar(bits: 10, fullRange: true)
            default: return nil
            }
        }

        var needsIngest: Bool { if case .bgra = self { return false } else { return true } }
    }

    static func fourCC(_ f: OSType) -> String {
        let bytes = [UInt8((f >> 24) & 0xff), UInt8((f >> 16) & 0xff), UInt8((f >> 8) & 0xff), UInt8(f & 0xff)]
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) { return String(bytes: bytes, encoding: .ascii) ?? "\(f)" }
        return String(f)
    }

    private static func isHDR(_ pb: CVPixelBuffer) -> Bool {
        guard let tf = CVBufferCopyAttachment(pb, kCVImageBufferTransferFunctionKey, nil) as? String else { return false }
        return tf == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
            || tf == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
    }

    private func noteUnsupported(_ f: OSType, _ pb: CVPixelBuffer, why: String = "pixel format") {
        lock.lock()
        let first = loggedFormats.insert(f).inserted
        lock.unlock()
        if first {
            a4kLog("showing original: unsupported \(why) \(Self.fourCC(f)) \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))")
        }
        stats.update { $0.pixelFormat = Self.fourCC(f) + " (unsupported)" }
    }

    private func makeTexture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat,
                             keep: inout [CVMetalTexture], writable: Bool = false) -> MTLTexture? {
        let planar = CVPixelBufferIsPlanar(pb)
        let w = planar ? CVPixelBufferGetWidthOfPlane(pb, plane) : CVPixelBufferGetWidth(pb)
        let h = planar ? CVPixelBufferGetHeightOfPlane(pb, plane) : CVPixelBufferGetHeight(pb)
        var attrs: CFDictionary?
        if writable {
            let usage: MTLTextureUsage = [.shaderRead, .shaderWrite]
            attrs = [kCVMetalTextureUsage as String: NSNumber(value: usage.rawValue)] as CFDictionary
        }
        var cvTex: CVMetalTexture?
        let r = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pb, attrs,
                                                          format, w, h, plane, &cvTex)
        guard r == kCVReturnSuccess, let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { return nil }
        keep.append(cvTex)
        return tex
    }

    /// Caller holds `lock`.
    private func reuseOrMakeOutputPool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let p = outputPool, outputPoolSize == (width, height) { return p }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: maxInFlight + 2] as CFDictionary,
                                attrs as CFDictionary, &pool)
        outputPool = pool
        outputPoolSize = (width, height)
        return pool
    }

    /// Caller holds `lock`. Ring of RGB textures the ingest pass writes (one per in-flight frame).
    private func nextSourceTexture(width: Int, height: Int) -> MTLTexture? {
        if sourceTextures.first.map({ $0.width != width || $0.height != height }) ?? true {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            sourceTextures = (0..<maxInFlight).compactMap { _ in device.makeTexture(descriptor: d) }
            sourceSlot = 0
        }
        guard !sourceTextures.isEmpty else { return nil }
        sourceSlot = (sourceSlot + 1) % sourceTextures.count
        return sourceTextures[sourceSlot]
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder, _ pso: MTLComputePipelineState, _ target: MTLTexture) {
        let w = pso.threadExecutionWidth
        let h = max(1, pso.maxTotalThreadsPerThreadgroup / w)
        enc.dispatchThreadgroups(MTLSize(width: (target.width + w - 1) / w, height: (target.height + h - 1) / h, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }

    private static func sampleBuffer(with pb: CVPixelBuffer, timing pts: CMTime) -> CMSampleBuffer? {
        var desc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb,
                                                           formatDescriptionOut: &desc) == noErr, let desc else { return nil }
        var t = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb,
                                                       formatDescription: desc, sampleTiming: &t,
                                                       sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }

    /// Compile the shaders for `settings` ahead of the first frame (e.g. when the player opens
    /// with upscaling already on). Runs on the build queue, so a build that follows reuses it.
    func prewarm(_ settings: UpscaleSettings) {
        guard settings.enabled else { return }
        buildQueue.async { [device] in
            let files: [String]
            switch settings.model {
            case .anime4k: files = Anime4KUpscaler.shaderFiles(mode: settings.mode, size: settings.size)
            }
            let t0 = CACurrentMediaTime()
            let n = ShaderLibraryCache.shared.prewarm(files, device: device)
            if n > 0 { a4kLog("prewarm: compiled \(n) shader files for \(settings.label) in \(Int((CACurrentMediaTime() - t0) * 1000)) ms") }
        }
    }

    /// Compile the model for `key` in the background; frames show the original until it's ready.
    private func build(key: ConfigKey, settings: UpscaleSettings) {
        buildQueue.async { [weak self] in
            guard let self else { return }
            let t0 = CACurrentMediaTime()
            let cache = ShaderLibraryCache.shared
            let (hits0, misses0) = (cache.hits, cache.misses)
            do {
                let u = try UpscalerFactory.make(settings: settings, device: self.device)
                let t1 = CACurrentMediaTime()
                let target = key.modelOutput
                try u.configure(sourceWidth: key.srcW, sourceHeight: key.srcH, outputWidth: target.w, outputHeight: target.h)
                let t2 = CACurrentMediaTime()
                let ms = (t2 - t0) * 1000
                self.lock.lock()
                if self.buildingKey == key {
                    self.upscaler = u
                    self.readyKey = key
                    self.buildingKey = nil
                }
                self.lock.unlock()
                self.stats.update {
                    $0.engine = u.summary
                    $0.passes = u.activePassCount
                    $0.lastBuildMs = ms
                    $0.sourceSize = "\(key.srcW)x\(key.srcH)"
                    $0.outputSize = "\(key.outW)x\(key.outH)"
                }
                let forced = key.force ? " via model \(target.w)x\(target.h) (force ×2)" : ""
                a4kLog("built \(u.summary): \(u.activePassCount) passes, \(key.srcW)x\(key.srcH) -> \(key.outW)x\(key.outH)\(forced)"
                       + " in \(Int(ms)) ms (shaders \(Int((t1 - t0) * 1000)) ms: \(cache.misses - misses0) compiled,"
                       + " \(cache.hits - hits0) cached · pipelines \(Int((t2 - t1) * 1000)) ms)")
            } catch {
                self.lock.lock()
                if self.buildingKey == key { self.buildingKey = nil; self.failedKey = key }
                self.lock.unlock()
                a4kLog("build failed for \(settings.label): \(error.localizedDescription)")
            }
        }
    }
}
