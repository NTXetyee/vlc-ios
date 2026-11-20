import Foundation
import Metal

/// vlc-ios fork: process-wide cache of GLSL files translated to Metal and compiled to libraries.
///
/// Translating + compiling a GLSL file is the slow part of building a model (seconds for the
/// larger networks), and the result depends only on the file and the device, not on video or
/// display sizes. Caching it makes rebuilds (mode/size switches, rotation, PiP, external
/// display) cost only pipeline-state creation, and lets callers compile ahead of time
/// (`prewarm`). The passes of a file are compiled in parallel across CPU cores.
public final class ShaderLibraryCache {
    public static let shared = ShaderLibraryCache()

    struct Entry {
        let shaders: [MPVShader]
        let libraries: [MTLLibrary]
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var defaultLibraries: [ObjectIdentifier: MTLLibrary] = [:]

    /// Cumulative counters, for logs.
    public private(set) var hits = 0, misses = 0

    private init() {}

    private static func key(_ name: String, _ subdir: String, _ device: MTLDevice) -> String {
        "\(UInt(bitPattern: ObjectIdentifier(device).hashValue))/\(subdir)/\(name)"
    }

    /// Whether `subdir/name` is already compiled for `device`.
    public func contains(_ name: String, subdir: String, device: MTLDevice) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries[Self.key(name, subdir, device)] != nil
    }

    func entry(_ name: String, subdir: String, device: MTLDevice) throws -> Entry {
        let key = Self.key(name, subdir, device)
        lock.lock()
        if let e = entries[key] { hits += 1; lock.unlock(); return e }
        lock.unlock()

        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "glsl/" + subdir) else {
            throw Anime4KError.fileNotFound(name)
        }
        guard let glsl = String(data: try Data(contentsOf: url), encoding: .utf8) else {
            throw Anime4KError.fileCorrupt(name)
        }
        let shaders = try MPVShader.parse(glsl)

        // One Metal compile per pass; they are independent, so use all cores.
        var libraries = [MTLLibrary?](repeating: nil, count: shaders.count)
        var firstError: Error?
        let resultLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: shaders.count) { i in
            do {
                let lib = try device.makeLibrary(source: shaders[i].metalCode, options: nil)
                resultLock.lock(); libraries[i] = lib; resultLock.unlock()
            } catch {
                resultLock.lock(); if firstError == nil { firstError = error }; resultLock.unlock()
            }
        }
        if let firstError { throw firstError }
        let entry = Entry(shaders: shaders, libraries: libraries.compactMap { $0 })

        lock.lock(); defer { lock.unlock() }
        if let raced = entries[key] { hits += 1; return raced }   // another thread finished first
        misses += 1
        entries[key] = entry
        return entry
    }

    func defaultLibrary(device: MTLDevice) throws -> MTLLibrary {
        let id = ObjectIdentifier(device)
        lock.lock()
        if let lib = defaultLibraries[id] { lock.unlock(); return lib }
        lock.unlock()
        let lib = try device.makeDefaultLibrary(bundle: .module)
        lock.lock(); defaultLibraries[id] = lib; lock.unlock()
        return lib
    }

    /// Compile `files` ("Subdir/Name.glsl") that aren't cached yet. Blocking; call off the main thread.
    /// Returns how many files were compiled.
    @discardableResult
    public func prewarm(_ files: [String], device: MTLDevice) -> Int {
        let missing = files.filter { path in
            let p = path.split(separator: "/", maxSplits: 1).map(String.init)
            return p.count == 2 && !contains(p[1], subdir: p[0], device: device)
        }
        DispatchQueue.concurrentPerform(iterations: missing.count) { i in
            let p = missing[i].split(separator: "/", maxSplits: 1).map(String.init)
            _ = try? entry(p[1], subdir: p[0], device: device)
        }
        return missing.count
    }

    /// Drop everything (memory warning). Rebuilding after this compiles again.
    public func removeAll() {
        lock.lock(); entries.removeAll(); lock.unlock()
    }
}
