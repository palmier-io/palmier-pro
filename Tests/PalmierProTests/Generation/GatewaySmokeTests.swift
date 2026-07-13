import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PalmierPro

/// Live smoke against a real gateway — runs only when GATEWAY_SMOKE_KEY is set:
///   GATEWAY_SMOKE_KEY=sk-... [GATEWAY_SMOKE_URL=https://.../v1] \
///   [GATEWAY_SMOKE_OUT=/tmp/out] swift test --filter GatewaySmoke
/// Exercises every op through the real client + runner; ops whose alias is
/// absent from the gateway's model list are skipped and reported, not failed.
@Suite(
    "GatewaySmoke — live image suite",
    .enabled(if: ProcessInfo.processInfo.environment["GATEWAY_SMOKE_KEY"] != nil),
    .serialized
)
struct GatewaySmokeTests {
    static let env = ProcessInfo.processInfo.environment

    private var client: OpenAICompatGenerationClient {
        OpenAICompatGenerationClient(
            baseURL: URL(string: Self.env["GATEWAY_SMOKE_URL"] ?? "https://api.proto-labs.ai/v1")!,
            apiKey: Self.env["GATEWAY_SMOKE_KEY"] ?? ""
        )
    }

    private var outDir: URL {
        let dir = URL(fileURLWithPath: Self.env["GATEWAY_SMOKE_OUT"] ?? NSTemporaryDirectory())
            .appendingPathComponent("gateway-smoke", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func save(_ urls: [URL], as name: String) throws -> URL {
        let url = try #require(urls.first)
        let dest = outDir.appendingPathComponent("\(name).png")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: url, to: dest)
        let source = try #require(CGImageSourceCreateWithData(try Data(contentsOf: dest) as CFData, nil))
        #expect(CGImageSourceGetCount(source) >= 1, "\(name) is not a decodable image")
        return dest
    }

    /// End-to-end video through the real bridge + our runner (create → poll →
    /// download). Run alone: `GATEWAY_SMOKE_KEY=… swift test --filter liveVideoGeneration`.
    @Test func liveVideoGeneration() async throws {
        let client = client
        GatewayGenerationRunner.videoPollInterval = .seconds(3)
        GatewayGenerationRunner.videoTimeout = .seconds(300)
        // Unique per run: the bridge doesn't yet nonce its video workflow, so an
        // identical prompt hits ComfyUI's execution cache and 500s ("completed but
        // no output file recorded"). See the protoBanana#38 finding.
        let job = GatewayVideoJob(
            model: GatewayVideoModels.resolve(GatewayVideoModels.gen),
            prompt: "a slow drone push-in over a misty pine forest at dawn [\(UUID().uuidString.prefix(8))]",
            seconds: 2, size: "768x512"
        )
        var createdId: String?
        let url = try await GatewayGenerationRunner.executeVideo(job, client: client) { id in
            createdId = id
        }
        let id = try #require(createdId)
        let bytes = try Data(contentsOf: url)
        // mp4/ISO-BMFF: 'ftyp' box marker at offset 4.
        let ftyp = bytes.count > 8 ? String(decoding: bytes[4..<8], as: UTF8.self) : ""
        #expect(ftyp == "ftyp", "downloaded content is not an mp4 (marker=\(ftyp))")
        #expect(bytes.count > 10_000, "suspiciously small clip: \(bytes.count) bytes")
        let dest = outDir.appendingPathComponent("video-\(id).mp4")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: url, to: dest)
        print("gateway-smoke VIDEO: job \(id) → \(bytes.count) bytes → \(dest.path)")
    }

    @Test func fullImageSuite() async throws {
        let client = client
        let available = Set(try await client.listModels().map(\.id))
        var skipped: [String] = []
        func alias(_ a: GatewayImageModels.Alias) -> String? {
            available.contains(a.fallback) ? a.fallback : { skipped.append("\(a.label): \(a.fallback)"); return nil }()
        }

        // generate (turbo for speed) — the seed policy is exercised by the runner
        let genModel = try #require(alias(GatewayImageModels.turbo) ?? alias(GatewayImageModels.gen))
        let genJob = GatewayImageJob(op: .generate, model: genModel,
                                     prompt: "a red bicycle leaning against a white brick wall, photo")
        let gen = try await GatewayGenerationRunner.execute(genJob, client: client)
        let genURL = try save(gen, as: "01-generate")

        // edit
        var editURL: URL?
        if let m = alias(GatewayImageModels.edit) {
            var job = GatewayImageJob(op: .edit, model: m, prompt: "make the bicycle blue")
            job.referenceURLs = [genURL]
            editURL = try save(try await GatewayGenerationRunner.execute(job, client: client), as: "02-edit")
        }

        // compose (2 refs via chat alias)
        if let m = alias(GatewayImageModels.chat), let editURL {
            var job = GatewayImageJob(op: .compose, model: m,
                                      prompt: "one image combining both bicycles side by side")
            job.referenceURLs = [genURL, editURL]
            _ = try save(try await GatewayGenerationRunner.execute(job, client: client), as: "03-compose")
        }

        // background removal — result must carry alpha
        if let m = alias(GatewayImageModels.bgremove) {
            var job = GatewayImageJob(op: .edit, model: m, prompt: "remove the background")
            job.referenceURLs = [genURL]
            let dest = try save(try await GatewayGenerationRunner.execute(job, client: client), as: "04-bgremove")
            let source = try #require(CGImageSourceCreateWithData(try Data(contentsOf: dest) as CFData, nil))
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            #expect(props?[kCGImagePropertyHasAlpha] as? Bool == true, "bgremove result has no alpha channel")
        }

        // region edit
        if let m = alias(GatewayImageModels.region) {
            var job = GatewayImageJob(op: .edit, model: m, prompt: "a green vespa scooter")
            job.referenceURLs = [genURL]
            job.fields["grounding"] = "the bicycle"
            _ = try save(try await GatewayGenerationRunner.execute(job, client: client), as: "05-region")
        }

        // outpaint
        if let m = alias(GatewayImageModels.outpaint) {
            var job = GatewayImageJob(op: .edit, model: m, prompt: "continue the street scene")
            job.referenceURLs = [genURL]
            job.fields["left"] = "256"
            job.fields["right"] = "256"
            _ = try save(try await GatewayGenerationRunner.execute(job, client: client), as: "06-outpaint")
        }

        // identity edit (single-ref)
        if let m = alias(GatewayImageModels.identity) {
            var portrait = GatewayImageJob(op: .generate, model: genModel,
                                           prompt: "portrait photo of a middle-aged man with a gray beard, neutral background")
            let portraitURL = try save(try await GatewayGenerationRunner.execute(portrait, client: client), as: "07a-portrait")
            var job = GatewayImageJob(op: .edit, model: m, prompt: "give him a red beanie hat")
            job.referenceURLs = [portraitURL]
            _ = try save(try await GatewayGenerationRunner.execute(job, client: client), as: "07b-identity")
        }

        // typography
        if let m = alias(GatewayImageModels.typography) {
            var job = GatewayImageJob(op: .generate, model: m,
                                      prompt: "minimal poster that says \"PROTO\" in bold sans-serif, black on silver")
            _ = try save(try await GatewayGenerationRunner.execute(job, client: client), as: "08-typography")
        }

        // Catalog assembly against the live alias set (Phase 2 acceptance).
        let entries = try await MainActor.run {
            try GatewayCatalog.entries(fromTemplate: GatewayCatalog.templateData(), availableAliases: available)
        }
        #expect(entries.contains { $0.kind == .image }, "live gateway yields no image catalog entries")
        print("gateway-smoke catalog: \(entries.map(\.id).joined(separator: ", "))")

        // Video bridge probe — informational until protoBanana#38 piece 2 ships.
        do {
            let id = try await client.createVideo(
                model: GatewayVideoModels.resolve(GatewayVideoModels.gen),
                prompt: "a slow pan over a mountain lake at dawn", seconds: 4, size: "1216x704"
            )
            print("gateway-smoke VIDEO BRIDGE LIVE: job \(id) created (not polled to completion here)")
        } catch {
            print("gateway-smoke video bridge not available (expected until protoBanana#38 ships): \(error.localizedDescription.prefix(160))")
        }

        print("gateway-smoke outputs: \(outDir.path)")
        if !skipped.isEmpty {
            print("gateway-smoke SKIPPED (alias not on gateway): \(skipped.joined(separator: "; "))")
        }
    }
}
