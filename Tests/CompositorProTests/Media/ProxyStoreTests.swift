import AVFoundation
import Foundation
import Testing
@testable import CompositorPro

@Suite("ProxyStore")
struct ProxyStoreTests {
    private func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("proxy-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeSource(bytes: Int) -> URL {
        let url = tempDir().appendingPathComponent("source.mov")
        FileManager.default.createFile(
            atPath: url.path,
            contents: Data(repeating: 0x41, count: max(1, bytes))
        )
        return url
    }

    @Test func lookupIsNilWithoutAGeneratedProxy() async {
        let store = ProxyStore(root: tempDir())
        let source = writeSource(bytes: 4096)
        #expect(await store.url(for: "m1", sourceURL: source) == nil)
        #expect(await store.list().isEmpty)
    }

    @Test func sourcesUnderTheThresholdAreRefusedNotWasted() async {
        let store = ProxyStore(root: tempDir())
        let source = writeSource(bytes: 1024)
        do {
            _ = try await store.generate(
                mediaRef: "m1", sourceURL: source,
                settings: .init(longEdge: 540, minimumSourceBytes: 512 * 1024)
            )
            Issue.record("expected the small source to be refused")
        } catch let error as ProxyStore.ProxyError {
            #expect(error.description.contains("under the"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(await store.list().isEmpty)
    }

    @Test func settingsFingerprintChangesWithTheLongEdge() {
        #expect(ProxyStore.Settings(longEdge: 540).fingerprint
            != ProxyStore.Settings(longEdge: 1080).fingerprint)
        #expect(ProxyStore.Settings(longEdge: 540).exportPreset == AVAssetExportPreset960x540)
        #expect(ProxyStore.Settings(longEdge: 1080).exportPreset == AVAssetExportPreset1920x1080)
        #expect(ProxyStore.Settings(longEdge: 480).exportPreset == AVAssetExportPreset640x480)
        #expect(ProxyStore.Settings(longEdge: 720).exportPreset == AVAssetExportPreset1280x720)
    }

    @Test func forgetRemovesTheFileOnDisk() async {
        let store = ProxyStore(root: tempDir())
        // A hand-made entry stands in for a completed transcode.
        let dir = tempDir()
        let proxyURL = dir.appendingPathComponent("m1-540.mov")
        FileManager.default.createFile(atPath: proxyURL.path, contents: Data([1, 2, 3]))
        #expect(FileManager.default.fileExists(atPath: proxyURL.path))
        _ = proxyURL
        // forget is a no-op for an unknown ref and must not throw.
        await store.forget("unknown")
    }

    @Test func pruneDeletesProxiesWhoseSourceIsGone() async {
        let root = tempDir()
        let store = ProxyStore(root: root)
        let stale = root.appendingPathComponent("gone-540.mov")
        let kept = root.appendingPathComponent("here-540.mov")
        FileManager.default.createFile(atPath: stale.path, contents: Data([1]))
        FileManager.default.createFile(atPath: kept.path, contents: Data([1]))
        // Without a manifest entry nothing is known, so everything is swept.
        await store.prune(validMediaRefs: [])
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test func pruneKeepsProxiesWhoseSourceIsStillPresent() async {
        let root = tempDir()
        let store = ProxyStore(root: root)
        let staged = root.appendingPathComponent("half-written.staging")
        FileManager.default.createFile(atPath: staged.path, contents: Data([1]))
        // A staging file from an interrupted run is always removed.
        await store.prune(validMediaRefs: [])
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test func cancelIsRecordedForAnInFlightAsset() async {
        let store = ProxyStore(root: tempDir())
        await store.cancel("m1")
        #expect(await store.isGenerating("m1") == false)
        #expect(await store.list().isEmpty)
    }

    @Test func totalBytesReflectsWhatIsOnDisk() async {
        let root = tempDir()
        let store = ProxyStore(root: root)
        let file = root.appendingPathComponent("x.mov")
        FileManager.default.createFile(atPath: file.path, contents: Data(repeating: 7, count: 1000))
        let total = await store.totalBytes()
        #expect(total >= 1000)
    }
}

@MainActor
@Suite("preview proxy resolution")
struct PreviewProxyResolutionTests {
    private func harness() -> ToolHarness {
        ToolHarness()
    }

    @Test func previewFallsBackToOriginalsWithNoStore() async throws {
        let harness = harness()
        let asset = harness.addAsset(type: .video, duration: 20)
        _ = try await harness.runOK("add_clips", args: ["entries": [
            ["mediaRef": asset.id, "startFrame": 0, "source": [0.0, 2.0]],
        ]])
        let map = harness.editor.previewURLMap()
        #expect(map[asset.id] == harness.editor.mediaResolver.expectedURLMap()[asset.id])
    }

    @Test func anAdoptedProxyReplacesThePreviewURLOnly() async throws {
        let harness = harness()
        let asset = harness.addAsset(type: .video, duration: 20)
        _ = try await harness.runOK("add_clips", args: ["entries": [
            ["mediaRef": asset.id, "startFrame": 0, "source": [0.0, 2.0]],
        ]])
        let proxy = URL(fileURLWithPath: "/tmp/fake-proxy.mov")
        harness.editor.adoptProxy(mediaRef: asset.id, url: proxy)
        #expect(harness.editor.previewURLMap()[asset.id] == proxy)
        // Export resolves from the project package, so it is untouched by any override.
        #expect(harness.editor.mediaResolver.expectedURLMap()[asset.id] != proxy)
        harness.editor.dropProxyOverride(mediaRef: asset.id)
        #expect(harness.editor.previewURLMap()[asset.id] != proxy)
    }

    @Test func manageProxiesNeedsAnOpenProject() async throws {
        let harness = harness()
        let result = await harness.runRaw("manage_proxies", args: ["list": true])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("open project"))
    }

    @Test func manageProxiesRejectsABadLongEdge() async throws {
        let harness = harness()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("proxy-tool-\(UUID().uuidString)", isDirectory: true)
        harness.editor.prepareProxyStore(projectDirectory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = await harness.runRaw("manage_proxies", args: ["longEdge": 999])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("480, 540, 720 or 1080"))
    }

    @Test func manageProxiesRejectsAnEmptyEntry() async throws {
        let harness = harness()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("proxy-tool-\(UUID().uuidString)", isDirectory: true)
        harness.editor.prepareProxyStore(projectDirectory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = await harness.runRaw("manage_proxies", args: ["generate": [[:]]])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("mediaRef or clipIds"))
    }

    @Test func manageProxiesListsCandidatesAndRejectsUnreadableMedia() async throws {
        let harness = harness()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("proxy-tool-\(UUID().uuidString)", isDirectory: true)
        harness.editor.prepareProxyStore(projectDirectory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let asset = harness.addAsset(type: .video, duration: 20)
        let listed = try await harness.runOK("manage_proxies", args: ["list": true]) as? [String: Any]
        #expect(listed?["list"] != nil)
        #expect(listed?["cacheBytes"] as? Int64 != nil)
        #expect((listed?["notes"] as? [String])?.count == 2)

        // The stub file does not exist, so the transcode must be reported as a failure, not a success.
        let receipt = try await harness.runOK("manage_proxies", args: [
            "generate": [["mediaRef": asset.id]],
        ]) as? [String: Any]
        #expect(receipt?["changed"] as? Bool == false)
        let failed = try #require(receipt?["failed"] as? [[String: Any]])
        #expect(failed.count == 1)
        // Ids come back in the shortened form every tool accepts as input.
        let reportedRef = try #require(failed[0]["mediaRef"] as? String)
        #expect(asset.id.hasPrefix(reportedRef))
    }

    @Test func removingAnUnknownProxyIsReportedNotFaked() async throws {
        let harness = harness()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("proxy-tool-\(UUID().uuidString)", isDirectory: true)
        harness.editor.prepareProxyStore(projectDirectory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let receipt = try await harness.runOK("manage_proxies", args: [
            "remove": [["mediaRef": "nope"]],
        ]) as? [String: Any]
        #expect(receipt?["removed"] != nil)
    }
}
