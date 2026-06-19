import Foundation
import Testing
@testable import PalmierPro

@Suite("Project transcription language")
struct ProjectTranscriptionLanguageTests {
    @Test func timelineDefaultsToAuto() {
        #expect(Timeline().transcriptionLanguage == nil)
    }

    @Test func timelineRoundTripsLanguage() throws {
        var timeline = Timeline()
        timeline.transcriptionLanguage = "fr-FR"
        let decoded = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(timeline))
        #expect(decoded.transcriptionLanguage == "fr-FR")
    }

    @Test func autoIsOmittedFromEncoding() throws {
        // nil (Auto) should not bloat the project file or get_timeline output.
        let json = String(decoding: try JSONEncoder().encode(Timeline()), as: UTF8.self)
        #expect(!json.contains("transcriptionLanguage"))
    }
}

@Suite("resolveTranscriptionLocale precedence")
struct ResolveTranscriptionLocaleTests {
    @Test func nilWhenNeitherSet() async throws {
        let locale = try await resolveTranscriptionLocale(explicit: nil, projectDefault: nil, path: "test")
        #expect(locale == nil)
    }

    @Test func explicitUnsupportedLanguageThrows() async {
        // "zz" matches no on-device locale whether or not models are installed → deterministic throw.
        do {
            _ = try await resolveTranscriptionLocale(explicit: "zz", projectDefault: nil, path: "get_transcript")
            Issue.record("expected unsupported language to throw")
        } catch let error as ToolError {
            #expect(error.message.contains("does not support language 'zz'"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func unsupportedProjectDefaultIsIgnored() async throws {
        // A stale/unsupported saved value must not fail every transcript call — fall back to auto.
        let locale = try await resolveTranscriptionLocale(explicit: nil, projectDefault: "zz", path: "test")
        #expect(locale == nil)
    }
}

@Suite("Transcript tools language argument")
@MainActor
struct TranscriptToolLanguageTests {
    @Test func getTranscriptRejectsUnsupportedLanguage() async {
        let harness = ToolHarness()
        let result = await harness.runRaw("get_transcript", args: ["language": "zz"])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("does not support language 'zz'"))
    }

    @Test func inspectMediaRejectsUnsupportedLanguage() async {
        let harness = ToolHarness()
        let result = await harness.runRaw("inspect_media", args: ["mediaRef": "missing", "language": "zz"])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("does not support language 'zz'"))
    }

    @Test func setTranscriptionLanguagePersistsOnTimeline() {
        let harness = ToolHarness()
        harness.editor.setTranscriptionLanguage("fr-FR")
        #expect(harness.editor.timeline.transcriptionLanguage == "fr-FR")
        harness.editor.setTranscriptionLanguage(nil)
        #expect(harness.editor.timeline.transcriptionLanguage == nil)
    }
}
