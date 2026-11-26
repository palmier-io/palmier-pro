import Foundation

extension ToolExecutor {

    func addHybridComposition(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        guard let html = args.string("html"), !html.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolError("add_hybrid_composition: 'html' is required.")
        }

        let blockId = args.string("blockId")
        let params = args["parameters"] as? [String: String]
        let trackIndex = args.int("trackIndex")
        let startFrame = args.int("startFrame")
        let durationFrames = args.int("durationFrames")

        let layerString = args.string("compositeLayer") ?? "overlay"
        let compositeLayer = CompositeLayer(rawValue: layerString) ?? .overlay

        let clipId = try editor.insertHybridCompositionClip(
            html: html,
            blockId: blockId,
            parameters: params,
            trackIndex: trackIndex,
            startFrame: startFrame,
            durationFrames: durationFrames,
            compositeLayer: compositeLayer
        )

        let receipt: [String: Any] = [
            "clipId": clipId,
            "blockId": blockId ?? "custom",
            "startFrame": startFrame ?? editor.currentFrame,
            "durationFrames": durationFrames ?? 90,
            "compositeLayer": compositeLayer.rawValue,
            "status": "inserted"
        ]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: .fragmentsAllowed)
        return .ok(String(data: data, encoding: .utf8) ?? "{}")
    }

    func updateHybridComposition(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        guard let clipId = args.string("clipId") else {
            throw ToolError("update_hybrid_composition: 'clipId' is required.")
        }
        let params = args["parameters"] as? [String: String]
        let html = args.string("html")

        try editor.updateHybridCompositionClip(clipId: clipId, parameters: params, html: html)

        let receipt: [String: Any] = [
            "clipId": clipId,
            "status": "updated"
        ]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: .fragmentsAllowed)
        return .ok(String(data: data, encoding: .utf8) ?? "{}")
    }

    func renderHybridFrame(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        var html = args.string("html")
        if html == nil, let clipId = args.string("clipId") {
            html = editor.clipFor(id: clipId)?.htmlContent
        }
        guard let resolvedHTML = html else {
            throw ToolError("render_hybrid_frame: provide either 'html' or a valid 'clipId' containing htmlContent.")
        }

        let frame = max(0, args.int("frame") ?? 0)
        let width = max(16, args.int("width") ?? editor.timeline.width)
        let height = max(16, args.int("height") ?? editor.timeline.height)

        let cgImage = try await HybridCompositionRenderer.shared.renderFrame(
            html: resolvedHTML,
            frame: frame,
            fps: editor.timeline.fps,
            width: width,
            height: height
        )

        let receipt: [String: Any] = [
            "frame": frame,
            "width": cgImage.width,
            "height": cgImage.height,
            "rendered": true
        ]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: .fragmentsAllowed)
        return .ok(String(data: data, encoding: .utf8) ?? "{}")
    }

    func importCommunityHyperframesTemplate(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let catalog = HyperframesCommunityCatalog.shared
        if let path = args.string("path") {
            let url = URL(fileURLWithPath: path)
            let issues = try await catalog.validateTemplate(at: url)
            if issues.contains(where: { $0.severity == .error }) {
                let errorMessages = issues.filter { $0.severity == .error }.map { "\($0.field): \($0.message)" }
                throw ToolError("Template validation failed: \(errorMessages.joined(separator: ", "))")
            }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let specURL = isDir ? url.appendingPathComponent("template.json") : url
            let data = try Data(contentsOf: specURL)
            let spec = try JSONDecoder().decode(HyperframesBlockSpec.self, from: data)
            let htmlURL = isDir ? url.appendingPathComponent("index.html") : url.deletingLastPathComponent().appendingPathComponent("index.html")
            let html = (try? String(contentsOf: htmlURL, encoding: .utf8)) ?? spec.htmlTemplate ?? ""

            let installed = try await catalog.installTemplate(spec: spec, html: html)
            return .ok(#"{"status":"installed","id":"\#(installed.id)","name":"\#(installed.name)"}"#)
        } else if let html = args.string("htmlTemplate"), let id = args.string("id") {
            let name = args.string("name") ?? id
            let category = args.string("category") ?? "Community"
            let spec = HyperframesBlockSpec(id: id, name: name, category: category)
            let installed = try await catalog.installTemplate(spec: spec, html: html)
            return .ok(#"{"status":"installed","id":"\#(installed.id)","name":"\#(installed.name)"}"#)
        } else {
            throw ToolError("import_community_hyperframes_template: provide either 'path' or 'id' + 'htmlTemplate'.")
        }
    }

    func listCommunityHyperframesTemplates(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let blocks = HyperframesCommunityCatalog.shared.loadCommunityBlocks()
        let category = args.string("category")
        let filtered = category != nil ? blocks.filter { $0.category.localizedCaseInsensitiveContains(category!) } : blocks
        let out = filtered.map { [
            "id": $0.id,
            "name": $0.name,
            "category": $0.category,
            "description": $0.description
        ] }
        let data = try JSONSerialization.data(withJSONObject: out, options: .fragmentsAllowed)
        return .ok(String(data: data, encoding: .utf8) ?? "[]")
    }
}

