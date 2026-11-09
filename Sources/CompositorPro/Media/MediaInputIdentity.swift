import CryptoKit
import Foundation

struct MediaInputIdentity: Codable, Sendable, Equatable {
    let contentSHA256: String
    let byteCount: Int64

    var inputId: String { "sha256:\(contentSHA256)" }

    var isValid: Bool {
        byteCount > 0 && contentSHA256.count == 64
            && contentSHA256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func receipt(identity: MediaInputIdentity?, verified: Bool, origin: MediaImportOrigin?) -> [String: Any] {
        var out: [String: Any] = ["inputIdentityState": "unresolved"]
        if let identity, identity.isValid {
            out["inputId"] = identity.inputId
            out["inputIdentityState"] = verified ? "verified" : "unverified"
        }
        if let origin { out["origin"] = origin.receipt }
        return out
    }
}

struct MediaImportOrigin: Codable, Sendable, Equatable {
    let provider: String
    let assetId: String
    let landingPageURL: String?

    init(provider: String, assetId: String, landingPageURL: String? = nil) {
        self.provider = provider
        self.assetId = assetId
        self.landingPageURL = landingPageURL
    }

    var sourceId: String { "stock:\(provider):\(assetId)" }

    var receipt: [String: Any] {
        var out: [String: Any] = ["provider": provider, "assetId": assetId, "sourceId": sourceId]
        if let landingPageURL { out["landingPageUrl"] = landingPageURL }
        return out
    }
}

actor MediaInputIdentityService {
    static let shared = MediaInputIdentityService()
    private let gate = AsyncSemaphore(value: 1)
    private var cache: [URL: Measurement] = [:]
    private var recency: [URL] = []
    private let capacity = 64

    private struct Revision: Sendable, Equatable {
        let size: Int64
        let modified: Date
        let created: Date
        let fileNumber: UInt64
    }

    private struct Measurement: Sendable {
        let identity: MediaInputIdentity
        let revision: Revision
    }

    func identify(_ url: URL, force: Bool = false) async throws -> MediaInputIdentity {
        try await gate.wait()
        do {
            let measurement = try await Self.measure(url, cached: force ? nil : cache[url])
            try Task.checkCancellation()
            cache[url] = measurement
            recency.removeAll { $0 == url }
            recency.append(url)
            if recency.count > capacity { cache.removeValue(forKey: recency.removeFirst()) }
            await gate.signal()
            return measurement.identity
        } catch {
            await gate.signal()
            throw error
        }
    }

    @concurrent
    private static func measure(_ url: URL, cached: Measurement?) async throws -> Measurement {
        try Task.checkCancellation()
        let before = try revision(url)
        if let cached, cached.revision == before { return cached }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var count: Int64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            let addition = count.addingReportingOverflow(Int64(data.count))
            guard !addition.overflow else { throw CocoaError(.fileReadTooLarge) }
            count = addition.partialValue
            hash.update(data: data)
        }
        try Task.checkCancellation()
        guard count == before.size, try revision(url) == before else { throw CocoaError(.fileReadUnknown) }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return Measurement(identity: MediaInputIdentity(contentSHA256: digest, byteCount: count), revision: before)
    }

    private static func revision(_ url: URL) throws -> Revision {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value > 0,
              let modified = attributes[.modificationDate] as? Date,
              let created = attributes[.creationDate] as? Date,
              let fileNumber = attributes[.systemFileNumber] as? NSNumber else { throw CocoaError(.fileReadCorruptFile) }
        return Revision(size: size.int64Value, modified: modified, created: created, fileNumber: fileNumber.uint64Value)
    }
}
