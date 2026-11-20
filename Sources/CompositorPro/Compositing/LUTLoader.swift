import CryptoKit
import Foundation

enum LUTStoreError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let name): "Not a valid .cube 3D LUT: \(name)"
        }
    }
}

/// Parses .cube 3D LUT files into CIColorCube-ready RGBA float data.
enum LUTLoader {

    struct CubeLUT {
        let dimension: Int
        let data: Data
    }

    private static let storageIO = ProjectPackageIO()

    static func store(path: String, projectId: String?, storageDirectory: URL? = nil) async throws -> String {
        try Task.checkCancellation()
        return try await storageIO.perform {
            let fm = FileManager.default
            let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let bytes = try Data(contentsOf: source)
            guard let text = String(data: bytes, encoding: .utf8), let lut = parse(text) else {
                throw LUTStoreError.invalid(source.lastPathComponent)
            }
            let directory = storageDirectory ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CompositorPro/luts/\(projectId ?? "default")", isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let contentDirectory = directory.appendingPathComponent(digest, isDirectory: true)
            try fm.createDirectory(at: contentDirectory, withIntermediateDirectories: true)
            let destination = contentDirectory.appendingPathComponent(source.lastPathComponent)
            if fm.fileExists(atPath: destination.path) {
                guard try Data(contentsOf: destination) == bytes else { throw CocoaError(.fileReadCorruptFile) }
            } else {
                let stage = directory.appendingPathComponent(".lut-\(UUID().uuidString)")
                do {
                    try bytes.write(to: stage)
                    // A hard link publishes complete bytes without replacing an existing grade.
                    try fm.linkItem(at: stage, to: destination)
                    try fm.removeItem(at: stage)
                } catch {
                    let original = error
                    do {
                        if fm.fileExists(atPath: stage.path) { try fm.removeItem(at: stage) }
                    } catch {
                        throw ProjectPackageCleanupError(operationError: original, cleanupError: error)
                    }
                    throw original
                }
            }
            cache(lut, path: destination.path)
            return destination.path
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedLUTs: [String: CubeLUT] = [:]
    /// Retained bytes of parsed LUT data, tracked so the cache stays inside its budget.
    nonisolated(unsafe) private static var cachedBytes = 0
    /// Least-recently-used first.
    nonisolated(unsafe) private static var cacheOrder: [String] = []

    /// Upper bound on retained parsed LUT bytes. A 128-point cube is about 32 MiB, so this
    /// keeps a handful resident without unbounded growth.
    nonisolated(unsafe) static var cacheByteLimit = 64 * 1024 * 1024

    /// Bytes currently retained by the parsed LUT cache.
    static var cachedByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cachedBytes
    }

    static func load(path: String) -> CubeLUT? {
        lock.lock()
        if let lut = cachedLUTs[path] {
            touch(path)
            lock.unlock()
            return lut
        }
        lock.unlock()

        guard let lut = loadFromDisk(path: path) else { return nil }
        return cacheIfAbsent(lut, path: path)
    }

    /// Drops every parsed LUT, so a closed project or a quitting app releases the bytes.
    static func releaseCachedLUTs() {
        lock.lock()
        cachedLUTs.removeAll()
        cacheOrder.removeAll()
        cachedBytes = 0
        lock.unlock()
    }

    private static func loadFromDisk(path: String) -> CubeLUT? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let lut = parse(text) else { return nil }
        return lut
    }

    /// Caches an already-parsed LUT under `path`, evicting older entries if the budget needs it.
    static func cache(_ lut: CubeLUT, path: String) {
        _ = cacheIfAbsent(lut, path: path)
    }

    private static func cacheIfAbsent(_ lut: CubeLUT, path: String) -> CubeLUT {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedLUTs[path] {
            touch(path)
            return cached
        }
        cachedLUTs[path] = lut
        cachedBytes += lut.data.count
        touch(path)
        evictIfNeeded()
        return lut
    }

    private static func touch(_ path: String) {
        if let index = cacheOrder.firstIndex(of: path) {
            cacheOrder.remove(at: index)
        }
        cacheOrder.append(path)
    }

    /// Evicts least-recently-used entries until the cache fits its budget. The newest entry is
    /// kept even when it alone exceeds the budget, so a single large grade still loads.
    private static func evictIfNeeded() {
        while cachedBytes > cacheByteLimit, cacheOrder.count > 1 {
            let oldest = cacheOrder.removeFirst()
            if let removed = cachedLUTs.removeValue(forKey: oldest) {
                cachedBytes -= removed.data.count
            }
        }
    }

    static func parse(_ text: String) -> CubeLUT? {
        var dimension = 0
        var domainMin: [Float] = [0, 0, 0]
        var domainMax: [Float] = [1, 1, 1]
        var values: [Float] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let first = parts.first else { continue }
            switch first.uppercased() {
            case "TITLE", "LUT_1D_SIZE":
                if first.uppercased() == "LUT_1D_SIZE" { return nil }
            case "LUT_3D_SIZE":
                dimension = Int(parts.last.map(String.init) ?? "") ?? 0
            case "DOMAIN_MIN":
                domainMin = parts.dropFirst().compactMap { Float($0) }
            case "DOMAIN_MAX":
                domainMax = parts.dropFirst().compactMap { Float($0) }
            default:
                guard parts.count >= 3 else { continue }
                let rgb = parts.prefix(3).compactMap { Float($0) }
                guard rgb.count == 3 else { return nil }
                values.append(contentsOf: rgb)
            }
        }

        guard dimension > 1, dimension <= 128,
              values.count == dimension * dimension * dimension * 3,
              domainMin.count == 3, domainMax.count == 3 else { return nil }

        // Normalize domain and pack as RGBA float32 (r fastest), as CIColorCube expects.
        var rgba = [Float]()
        rgba.reserveCapacity(dimension * dimension * dimension * 4)
        for i in 0..<(values.count / 3) {
            for c in 0..<3 {
                let span = max(0.0001, domainMax[c] - domainMin[c])
                rgba.append(min(1, max(0, (values[i * 3 + c] - domainMin[c]) / span)))
            }
            rgba.append(1)
        }
        return CubeLUT(dimension: dimension, data: rgba.withUnsafeBufferPointer { Data(buffer: $0) })
    }
}
