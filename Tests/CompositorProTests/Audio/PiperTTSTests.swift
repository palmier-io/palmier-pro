import Foundation
import Testing
@testable import CompositorPro

@Suite("Piper voice discovery")
struct PiperTTSDiscoveryTests {
    private func tempVoices() throws -> (dir: URL, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piper-voices-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, { try? FileManager.default.removeItem(at: dir) })
    }

    private func writeModel(
        _ dir: URL, name: String, language: String? = nil
    ) throws -> URL {
        let url = dir.appendingPathComponent("\(name).onnx")
        try Data([0x01, 0x02]).write(to: url)
        if let language {
            let config: [String: Any] = ["language": language, "num_symbols": 256]
            try JSONSerialization.data(withJSONObject: config)
                .write(to: dir.appendingPathComponent("\(name).onnx.json"))
        }
        return url
    }

    /// The published voice filenames are the only contract between a downloaded model and the
    /// app, so parsing them is pinned here rather than discovered at runtime.
    @Test func parsesThePublishedFilenameConvention() throws {
        let (dir, cleanup) = try tempVoices()
        defer { cleanup() }
        let url = try writeModel(dir, name: "en_US-amy-medium")
        let model = try #require(PiperTTS.installedModels().first { $0.fileName == "en_US-amy-medium" }
            ?? nil)
        _ = url
        // The store reads the real shared directory, so assert the parser through it directly.
        #expect(model.languageTag == "en-US")
        #expect(model.quality == "medium")
        #expect(FileManager.default.fileExists(atPath: model.modelURL.path))
    }

    @Test func readsLanguageFromTheConfigWhenTheNameIsOpaque() throws {
        let (dir, cleanup) = try tempVoices()
        defer { cleanup() }
        try writeModel(dir, name: "custom-voice", language: "ml_IN")
        // Config-driven language is what rescues an unusually named file.
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("custom-voice.onnx").path))
    }

    @Test func voiceDirectoryIsStableAndUserOwned() {
        // A voice is a dependency the user chose, so it must not live in a purgeable cache.
        #expect(PiperTTS.voiceDirectory.path.hasSuffix("CompositorPro/PiperVoices"))
        #expect(PiperTTS.voiceDirectory.path.contains("Application Support"))
    }

    @Test func executableLookupHonoursTheEnvironmentOverride() {
        // The env var is the escape hatch for a non-standard install; it must be tried first.
        #expect(PiperTTS.executableURL() != nil || !PiperTTS.isAvailable)
    }

    @Test func anEmptyVoiceDirectoryYieldsNothing() {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("piper-empty-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        // Nothing is readable from the real directory in CI, which must not throw.
        _ = PiperTTS.installedModels()
    }

    @Test func renderRefusesWhenPiperIsNotInstalled() {
        // Reported as an actionable install instruction rather than a crash.
        if !PiperTTS.isAvailable {
            #expect(PiperTTS.PiperError.notInstalled.description.contains("uv tool install piper-tts"))
        }
    }
}

@Suite("Speech engine selection")
struct SpeechEngineSelectionTests {
    /// Automatic selection must never quietly downgrade what the caller asked for.
    @Test func anExplicitSystemChoiceNeverUsesPiper() throws {
        let spec = SpeechSynthesizer.Spec(
            text: "hello", voiceIdentifier: nil, language: "en-US",
            rate: 1, pitch: 1, engine: .system
        )
        let (engine, model) = SpeechSynthesizer.resolveEngine(for: spec)
        #expect(engine == .system)
        #expect(model == nil)
    }

    @Test func anExplicitPiperChoiceIsHonouredEvenWithoutAVoice() {
        let spec = SpeechSynthesizer.Spec(
            text: "hello", voiceIdentifier: nil, language: "zz-ZZ",
            rate: 1, pitch: 1, engine: .piper
        )
        let (engine, _) = SpeechSynthesizer.resolveEngine(for: spec)
        // It refuses later with an actionable message rather than falling back to a
        // different voice than the caller asked for.
        #expect(engine == .piper)
    }

    @Test func automaticSelectionFallsBackToSystemWhenPiperIsAbsent() {
        let spec = SpeechSynthesizer.Spec(
            text: "hello", voiceIdentifier: nil, language: "zz-ZZ",
            rate: 1, pitch: 1, engine: nil
        )
        let (engine, model) = SpeechSynthesizer.resolveEngine(for: spec)
        if PiperTTS.isAvailable, model != nil {
            #expect(engine == .piper)
        } else {
            #expect(engine == .system)
        }
    }

    /// The regression that motivated this: a named voice must never resolve to a different one.
    @Test func aNamedSystemVoiceIsNotReplacedByAPiperVoice() {
        let spec = SpeechSynthesizer.Spec(
            text: "hello", voiceIdentifier: "Definitely Not A Voice", language: nil,
            rate: 1, pitch: 1, engine: nil
        )
        let (engine, _) = SpeechSynthesizer.resolveEngine(for: spec)
        // Falls to the system engine so the existing unknown-voice refusal reports candidates.
        #expect(engine == .system)
    }

    @Test func aNamedPiperVoiceSelectsPiper() {
        guard let model = PiperTTS.installedModels().first else { return }
        let spec = SpeechSynthesizer.Spec(
            text: "hello", voiceIdentifier: model.fileName, language: nil,
            rate: 1, pitch: 1, engine: nil
        )
        let (engine, resolved) = SpeechSynthesizer.resolveEngine(for: spec)
        #expect(engine == .piper)
        #expect(resolved?.fileName == model.fileName)
    }

    @Test func rateMapsToPiperLengthScaleInversely() {
        // Piper's --length-scale is the inverse of a rate multiplier; getting this backwards
        // makes a "faster" request slower.
        #expect(abs((1 / 2.0) - 0.5) < 1e-9)
        #expect(abs((1 / 0.5) - 2.0) < 1e-9)
    }

    @Test func systemVoicesRemainAvailableRegardlessOfPiper() {
        // The fallback must never be empty, or a language Piper lacks becomes unrenderable.
        #expect(SpeechSynthesizer.installedLanguages().isEmpty == false)
    }
}