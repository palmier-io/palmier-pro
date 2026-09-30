import CryptoKit
import Foundation

/// Disk cache for per-asset frame embeddings, keyed by file identity
/// Format: magic + JSON header + rows of (time, shotStart, shotEnd) Float64 + dim Float16.
struct EmbeddingStore {
    struct Header: Codable, Equatable {
        let model: String
        let modelVersion: Int
        let samplerVersion: Int
        let dim: Int
        let count: Int
    }

    struct Row {
        let time: Double
        let shotStart: Double
        let shotEnd: Double
    }

    struct AssetIndex {
        let header: Header
        let rows: [Row]
        /// Flat count×dim, Float32 for vDSP.
        let vectors: [Float]
    }

    enum StoreError: Error { case corrupt }

    private static let magic = Data("PALMEMB1".utf8)

    static let directory = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("\(Log.subsystem)/Embeddings", isDirectory: true)

    static func key(for url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        let identity = "\(url.path)|\(mtime.timeIntervalSince1970)|\(size)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    static func diskURL(_ key: String) -> URL {
        directory.appendingPathComponent("\(key).embed")
    }

    static func header(key: String) -> Header? {
        guard let handle = try? FileHandle(forReadingFrom: diskURL(key)),
              let prefix = try? handle.read(upToCount: magic.count + 4) else { return nil }
        defer { try? handle.close() }
        guard prefix.count == magic.count + 4, prefix.prefix(magic.count) == magic else { return nil }
        let len = prefix.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard let json = try? handle.read(upToCount: Int(len)) else { return nil }
        return try? JSONDecoder().decode(Header.self, from: json)
    }

    static func isCurrent(key: String, model: String, modelVersion: Int, samplerVersion: Int) -> Bool {
        guard let h = header(key: key) else { return false }
        return h.model == model && h.modelVersion == modelVersion && h.samplerVersion == samplerVersion
    }

    static func load(key: String) throws -> AssetIndex {
        let data = try Data(contentsOf: diskURL(key))
        guard data.count > magic.count + 4, data.prefix(magic.count) == magic else { throw StoreError.corrupt }
        var offset = magic.count
        let len = Int(data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        offset += 4
        guard data.count >= offset + len else { throw StoreError.corrupt }
        let header = try JSONDecoder().decode(Header.self, from: data.subdata(in: offset..<offset + len))
        offset += len

        let rowBytes = 3 * 8 + header.dim * 2
        guard data.count == offset + header.count * rowBytes else { throw StoreError.corrupt }

        var rows: [Row] = []
        rows.reserveCapacity(header.count)
        var vectors = [Float](repeating: 0, count: header.count * header.dim)
        data.suffix(from: offset).withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<header.count {
                let base = i * rowBytes
                rows.append(Row(
                    time: raw.loadUnaligned(fromByteOffset: base, as: Double.self),
                    shotStart: raw.loadUnaligned(fromByteOffset: base + 8, as: Double.self),
                    shotEnd: raw.loadUnaligned(fromByteOffset: base + 16, as: Double.self)
                ))
                for d in 0..<header.dim {
                    let half = raw.loadUnaligned(fromByteOffset: base + 24 + d * 2, as: Float16.self)
                    vectors[i * header.dim + d] = Float(half)
                }
            }
        }
        return AssetIndex(header: header, rows: rows, vectors: vectors)
    }

    static func save(header: Header, rows: [Row], vectors: [Float], key: String) throws {
        precondition(rows.count == header.count && vectors.count == header.count * header.dim)
        var data = magic
        let json = try JSONEncoder().encode(header)
        var len = UInt32(json.count)
        data.append(Data(bytes: &len, count: 4))
        data.append(json)
        for (i, row) in rows.enumerated() {
            for value in [row.time, row.shotStart, row.shotEnd] {
                var v = value
                data.append(Data(bytes: &v, count: 8))
            }
            for d in 0..<header.dim {
                var half = Float16(vectors[i * header.dim + d])
                data.append(Data(bytes: &half, count: 2))
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: diskURL(key), options: .atomic)
    }

    static func clearAll() {
        try? FileManager.default.removeItem(at: directory)
    }

}
