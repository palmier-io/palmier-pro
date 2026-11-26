import Foundation
import Testing
@testable import CompositorPro

@Suite("Plugin CLI")
struct PluginCLITests {
    private let fm = FileManager.default

    private func makeStore() -> PluginStore {
        PluginStore(rootDirectory: fm.temporaryDirectory.appendingPathComponent("plugin-cli-\(UUID().uuidString)"))
    }

    @Test func listsRunsAndTrustsPluginsHeadlessly() async throws {
        let store = makeStore()
        defer { try? fm.removeItem(at: store.rootDirectory) }
        _ = await store.installBuiltInSampleIfNeeded()

        let listed = try await PluginCLI.run(["list"], store: store)
        #expect(listed.contains("\"tool\" : \"sample_echo\""))
        #expect(listed.contains("trusted"))

        let executed = try await PluginCLI.run(["run", "sample_echo", "--args", "{\"message\":\"hi\"}"], store: store)
        #expect(executed.contains("compositor.sample.echo"))

        let trusted = try await PluginCLI.run(["trust", "compositor.sample.echo", "untrusted"], store: store)
        #expect(trusted.contains("untrusted"))

        await #expect(throws: PluginRunError.self) {
            _ = try await PluginCLI.run(["run", "sample_echo", "--args", "{}"], store: store)
        }
    }

    @Test func rejectsMalformedArgumentsAndUnknownTools() async throws {
        let store = makeStore()
        defer { try? fm.removeItem(at: store.rootDirectory) }
        _ = await store.installBuiltInSampleIfNeeded()

        await #expect(throws: CLIError.self) {
            _ = try await PluginCLI.run(["run", "sample_echo", "--args", "not-json"], store: store)
        }
        await #expect(throws: CLIError.self) {
            _ = try await PluginCLI.run(["run", "missing_tool"], store: store)
        }
        await #expect(throws: CLIError.self) {
            _ = try await PluginCLI.run(["trust", "compositor.sample.echo"], store: store)
        }
    }
}
