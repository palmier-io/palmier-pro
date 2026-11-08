import Foundation

struct VisualSourceAliases: Sendable, Equatable {
    static let maximumEntityIdLength = 200
    static let maximumSourceIdLength = 256
    struct Source: Sendable {
        let mediaRef: String
        let inputId: String?
        let origin: MediaImportOrigin?
    }

    private let roots: [String: String]
    private let members: [String: Set<String>]

    init(manifest: MediaManifest) {
        self.init(sources: manifest.entries.map {
            Source(mediaRef: $0.id, inputId: $0.inputIdentity.flatMap { $0.isValid ? $0.inputId : nil },
                   origin: $0.importInput?.origin)
        })
    }

    init(sources: [Source] = []) {
        var aliases = UnionFind()
        var tokens = Set<String>()
        for source in sources {
            let ids = Self.sourceIds(mediaRef: source.mediaRef, inputId: source.inputId, origin: source.origin)
            tokens.formUnion(ids)
            for id in ids { aliases.join(ids[0], id) }
        }
        var roots: [String: String] = [:]
        var members: [String: Set<String>] = [:]
        for id in tokens {
            let root = aliases.root(id)
            roots[id] = root
            members[root, default: []].insert(id)
        }
        self.roots = roots
        self.members = members
    }

    func root(_ sourceId: String) -> String { roots[sourceId] ?? sourceId }

    func expanded(_ sourceIds: Set<String>) -> Set<String> {
        Set(sourceIds.map(root)).reduce(into: Set<String>()) { result, root in
            result.formUnion(members[root] ?? [root])
        }
    }

    static func sourceIds(mediaRef: String?, inputId: String?, origin: MediaImportOrigin?) -> [String] {
        var ids: [String] = []
        if let mediaRef { ids.append("media:\(mediaRef)") }
        if let inputId, isValidInputId(inputId) { ids.append(inputId) }
        if let origin, isCanonicalSourceId(origin.sourceId) { ids.append(origin.sourceId) }
        return ids
    }

    static func isValidInputId(_ value: String) -> Bool {
        guard value.count == 71, value.hasPrefix("sha256:") else { return false }
        return MediaInputIdentity(contentSHA256: String(value.dropFirst(7)), byteCount: 1).isValid
    }

    static func isCanonicalSourceId(_ value: String) -> Bool {
        guard value.count <= maximumSourceIdLength else { return false }
        if isValidInputId(value) { return true }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, parts[0] == "media" { return isValidEntityId(String(parts[1])) }
        if parts.count == 3, parts[0] == "stock" {
            guard value.utf8.count <= 256,
                  let providerStart = parts[1].utf8.first, let assetStart = parts[2].utf8.first,
                  isAlphanumeric(providerStart), isAlphanumeric(assetStart) else { return false }
            return parts[1].utf8.allSatisfy {
                (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
            } && parts[2].utf8.allSatisfy { isAlphanumeric($0) || $0 == 45 || $0 == 95 || $0 == 46 }
        }
        return false
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    static func isValidEntityId(_ value: String) -> Bool {
        !value.isEmpty && value.count <= maximumEntityIdLength
            && !value.contains(":") && !value.unicodeScalars.contains {
                CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
            }
    }

    private struct UnionFind {
        var parents: [String: String] = [:]

        mutating func root(_ id: String) -> String {
            var value = id
            var path: [String] = []
            while let parent = parents[value], parent != value {
                path.append(value)
                value = parent
            }
            for item in path { parents[item] = value }
            return value
        }

        mutating func join(_ a: String, _ b: String) {
            let first = root(a)
            let second = root(b)
            if first != second { parents[max(first, second)] = min(first, second) }
        }
    }
}
