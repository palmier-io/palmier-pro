import Foundation

extension ToolExecutor {
    private struct ManageProxiesInput: DecodableToolArgs {
        struct Request: Decodable {
            let mediaRef: String?
            let clipIds: [String]?
        }
        let generate: [Request]?
        let remove: [Request]?
        let list: Bool?
        let longEdge: Int?
        let force: Bool?
        static let allowedKeys: Set<String> = [
            "generate", "remove", "list", "longEdge", "force",
        ]
    }

    /// Builds or clears preview proxies for large source media, and reports what is worth proxying.
    func manageProxies(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: ManageProxiesInput = try decodeToolArgs(args, path: "manage_proxies")
        guard let store = editor.proxyStoreIfPresent() else {
            throw ToolError("Proxies need an open project.")
        }
        var settings = ProxyStore.Settings()
        if let longEdge = input.longEdge {
            guard [480, 540, 720, 1080].contains(longEdge) else {
                throw ToolError("longEdge must be 480, 540, 720 or 1080.")
            }
            settings.longEdge = longEdge
        }

        var generated: [[String: Any]] = []
        var failed: [[String: Any]] = []
        var removed: [String] = []
        let originals = editor.mediaResolver.expectedURLMap()

        for request in input.generate ?? [] {
            let refs = try proxyTargets(editor, request, originals)
            for ref in refs {
                guard let source = originals[ref] else {
                    failed.append(["mediaRef": ref, "reason": "media is missing from disk"])
                    continue
                }
                do {
                    let entry = try await store.generate(mediaRef: ref, sourceURL: source, settings: settings)
                    editor.adoptProxy(mediaRef: ref, url: entry.proxyURL)
                    generated.append([
                        "mediaRef": ref,
                        "proxyBytes": DiskCache.bytes(at: entry.proxyURL.deletingLastPathComponent()),
                        "sourceBytes": entry.sourceByteCount,
                    ])
                } catch is CancellationError {
                    failed.append(["mediaRef": ref, "reason": "cancelled"])
                } catch let error as ProxyStore.ProxyError {
                    failed.append(["mediaRef": ref, "reason": error.description])
                } catch {
                    failed.append(["mediaRef": ref, "reason": error.localizedDescription])
                }
            }
        }

        for request in input.remove ?? [] {
            for ref in try proxyTargets(editor, request, originals) {
                await store.forget(ref)
                editor.dropProxyOverride(mediaRef: ref)
                removed.append(ref)
            }
        }

        if input.list == true || (input.generate == nil && input.remove == nil && input.list == nil) {
            let entries = await store.list()
            var listed = entries.map { entry -> [String: Any] in
                [
                    "mediaRef": entry.mediaRef,
                    "longEdge": entry.settings.longEdge,
                    "sourceBytes": entry.sourceByteCount,
                    "inUse": editor.proxyURLOverrides[entry.mediaRef] != nil,
                ]
            }
            let payload: [String: Any] = [
                "list": listed,
                "cacheBytes": await store.totalBytes(),
                "candidates": await proxyCandidates(editor, originals, settings: settings),
                "notes": [
                    "Proxies speed up preview and scrubbing only. Export always reads the original, "
                        + "so a proxy can never reach a master render.",
                    "Only sources at or above the threshold are worth proxying; smaller ones are "
                        + "listed under candidates when they are below it.",
                ],
            ]
            return .ok(Self.jsonString(payload) ?? "{}")
        }

        let payload: [String: Any] = [
            "generated": generated,
            "failed": failed,
            "removed": removed.map { $0 as Any },
            "changed": !generated.isEmpty || !removed.isEmpty,
            "inUse": editor.proxyURLOverrides.count,
        ]
        return .ok(Self.jsonString(payload) ?? "{}")
    }

    /// A request names either a media asset or the clips that use it.
    private func proxyTargets(
        _ editor: EditorViewModel, _ request: ManageProxiesInput.Request, _ originals: [String: URL]
    ) throws -> [String] {
        if let mediaRef = request.mediaRef, !mediaRef.isEmpty { return [mediaRef] }
        if let clipIds = request.clipIds, !clipIds.isEmpty {
            var refs: [String] = []
            for id in clipIds {
                guard let clip = editor.clipFor(id: id) else { throw ToolError("Clip not found: \(id)") }
                refs.append(clip.mediaRef)
            }
            return Array(Set(refs))
        }
        throw ToolError("Each generate/remove entry needs a mediaRef or clipIds.")
    }

    /// Assets large enough to be worth a proxy, so the Agent can decide without guessing sizes.
    private func proxyCandidates(
        _ editor: EditorViewModel, _ originals: [String: URL], settings: ProxyStore.Settings
    ) async -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for (ref, url) in originals {
            guard let asset = editor.mediaAssetsById[ref] else { continue }
            guard asset.type == .video else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            let bytes = Int64(values?.fileSize ?? 0)
            let hasProxy = await store(for: editor)?.url(for: ref, sourceURL: url) != nil
            guard bytes >= settings.minimumSourceBytes || hasProxy else { continue }
            rows.append([
                "mediaRef": ref,
                "name": asset.name,
                "sourceMB": bytes / 1_048_576,
                "proxied": hasProxy,
            ])
        }
        return rows.sorted { ($0["sourceMB"] as? Int ?? 0) > ($1["sourceMB"] as? Int ?? 0) }
    }

    private func store(for editor: EditorViewModel) -> ProxyStore? { editor.proxyStoreIfPresent() }
}
