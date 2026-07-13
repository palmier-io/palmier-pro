import Foundation

/// The protoBanana image suite as agent tools (GENERATION_GATEWAY_PLAN.md Phase 1).
/// Every op resolves references to local files and hands a GatewayImageJob to
/// GenerationService.generateViaGateway; results land as image assets.
extension ToolExecutor {
    /// generate_image when the gateway is configured: reference count picks the op —
    /// 0 → generations, 1 → edits, 2–3 → chat compose.
    func gatewayGenerateImage(
        _ editor: EditorViewModel, _ args: [String: Any], prompt: String
    ) throws -> ToolResult {
        let refs = try gatewayImageAssets(args.stringArray("referenceMediaRefs"), editor: editor)
        guard let op = GatewayImageRouting.op(forReferenceCount: refs.count) else {
            throw ToolError("The gateway image path takes at most 3 reference images (got \(refs.count)). Compose in stages.")
        }
        switch op {
        case .generate:
            var job = GatewayImageJob(
                op: .generate,
                model: args.string("model") ?? GatewayImageModels.resolve(GatewayImageModels.gen),
                prompt: prompt
            )
            job.size = GatewayGenerationRunner.sizeParameter(resolution: args.string("resolution"))
            job.n = max(1, min(4, args.int("numImages") ?? 1))
            job.seed = args.int("seed")
            return try startGatewayImageJob(job, args, editor: editor, refs: refs)
        case .edit:
            var job = GatewayImageJob(
                op: .edit,
                model: args.string("model") ?? GatewayImageModels.resolve(GatewayImageModels.edit),
                prompt: prompt
            )
            job.referenceURLs = refs.map(\.url)
            job.seed = args.int("seed")
            return try startGatewayImageJob(job, args, editor: editor, refs: refs)
        case .compose:
            var job = GatewayImageJob(
                op: .compose,
                model: GatewayImageModels.resolve(GatewayImageModels.chat),
                prompt: prompt
            )
            job.referenceURLs = refs.map(\.url)
            return try startGatewayImageJob(job, args, editor: editor, refs: refs)
        }
    }

    func editImageTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let prompt = try args.requireString("prompt")
        var job = GatewayImageJob(
            op: .edit, model: GatewayImageModels.resolve(GatewayImageModels.edit), prompt: prompt
        )
        job.referenceURLs = [try gatewayImageAsset(args, editor: editor).url]
        job.seed = args.int("seed")
        return try startGatewayImageJob(job, args, editor: editor)
    }

    func regionEdit(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let region = try args.requireString("region")
        let prompt = try args.requireString("prompt")
        var job = GatewayImageJob(
            op: .edit, model: GatewayImageModels.resolve(GatewayImageModels.region), prompt: prompt
        )
        job.referenceURLs = [try gatewayImageAsset(args, editor: editor).url]
        job.fields["grounding"] = region
        job.seed = args.int("seed")
        return try startGatewayImageJob(job, args, editor: editor)
    }

    func removeBackground(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        var job = GatewayImageJob(
            op: .edit, model: GatewayImageModels.resolve(GatewayImageModels.bgremove),
            prompt: "remove the background"
        )
        job.referenceURLs = [try gatewayImageAsset(args, editor: editor).url]
        return try startGatewayImageJob(job, args, editor: editor)
    }

    func outpaintImage(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let margins = ["left", "top", "right", "bottom"].map { ($0, args.int($0) ?? 0) }
        guard margins.contains(where: { $0.1 > 0 }) else {
            throw ToolError("Give at least one non-zero pixel margin (left/top/right/bottom).")
        }
        var job = GatewayImageJob(
            op: .edit, model: GatewayImageModels.resolve(GatewayImageModels.outpaint),
            prompt: args.string("prompt") ?? "extend the scene"
        )
        job.referenceURLs = [try gatewayImageAsset(args, editor: editor).url]
        for (name, value) in margins where value > 0 { job.fields[name] = String(value) }
        job.seed = args.int("seed")
        return try startGatewayImageJob(job, args, editor: editor)
    }

    func identityEdit(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let prompt = try args.requireString("prompt")
        let realism = (args["realism"] as? Bool) ?? false
        let alias = realism ? GatewayImageModels.realismIdentity : GatewayImageModels.identity
        var job = GatewayImageJob(op: .edit, model: GatewayImageModels.resolve(alias), prompt: prompt)
        job.referenceURLs = [try gatewayImageAsset(args, editor: editor).url]
        if let personRef = args.string("personMediaRef"), !personRef.isEmpty {
            job.personURL = try gatewayImageAssets([personRef], editor: editor)[0].url
        }
        if let groundingPx = args.int("groundingPx") {
            guard (512...1536).contains(groundingPx) else {
                throw ToolError("groundingPx must be 512–1536 (got \(groundingPx)).")
            }
            job.fields["grounding_px"] = String(groundingPx)
        }
        job.seed = args.int("seed")
        return try startGatewayImageJob(job, args, editor: editor)
    }

    func composeImages(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let prompt = try args.requireString("prompt")
        let refs = try gatewayImageAssets(args.stringArray("imageMediaRefs"), editor: editor)
        guard (2...3).contains(refs.count) else {
            throw ToolError("compose_images takes 2–3 imageMediaRefs (got \(refs.count)).")
        }
        var job = GatewayImageJob(
            op: .compose, model: GatewayImageModels.resolve(GatewayImageModels.chat), prompt: prompt
        )
        job.referenceURLs = refs.map(\.url)
        return try startGatewayImageJob(job, args, editor: editor, refs: refs)
    }

    func typographyImage(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let prompt = try args.requireString("prompt")
        var job = GatewayImageJob(
            op: .generate, model: GatewayImageModels.resolve(GatewayImageModels.typography), prompt: prompt
        )
        job.size = GatewayGenerationRunner.sizeParameter(resolution: args.string("resolution"))
        job.seed = args.int("seed")
        return try startGatewayImageJob(job, args, editor: editor)
    }

    // MARK: - Shared

    private func startGatewayImageJob(
        _ job: GatewayImageJob, _ args: [String: Any],
        editor: EditorViewModel, refs: [MediaAsset] = []
    ) throws -> ToolResult {
        guard OpenAICompatGenerationClient.gatewayConfigured else {
            throw ToolError("Image tools need an OpenAI-compatible gateway. Tell the user to configure one in Settings → Agent.")
        }
        let folderId = try resolveFolder(args, editor: editor, fallbackReferences: refs)
        let placeholderId = editor.generationService.generateViaGateway(
            job: job,
            name: args.string("name"),
            folderId: folderId,
            projectURL: editor.projectURL,
            editor: editor
        )
        return .ok("Started. Placeholder asset ID: \(placeholderId). Model: \(job.model). Poll get_media with this id; the result lands as an image asset.")
    }

    private func gatewayImageAsset(_ args: [String: Any], editor: EditorViewModel) throws -> MediaAsset {
        try gatewayImageAssets([try args.requireString("imageMediaRef")], editor: editor)[0]
    }

    private func gatewayImageAssets(_ ids: [String], editor: EditorViewModel) throws -> [MediaAsset] {
        try ids.map { id in
            let a = try asset(id, editor: editor, label: "Reference image")
            guard a.type == .image else {
                throw ToolError("'\(id)' must be an image asset (got \(a.type.rawValue)). For video, inspect_media a frame and generate from that.")
            }
            guard FileManager.default.fileExists(atPath: a.url.path) else {
                throw ToolError("'\(id)' has no file on disk yet — it may still be generating. Poll get_media first.")
            }
            return a
        }
    }
}
