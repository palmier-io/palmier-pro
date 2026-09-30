import AVFoundation
import Foundation
import Testing
@testable import CompositorPro

@Suite(.serialized)
struct SpeechSynthesizerTests {
    @Test func shortSentencesMergeWithoutLosingWordSpacing() {
        // Merging must not eat the space after a full stop, or the voice runs words together.
        #expect(SpeechSynthesizer.chunks(of: "One. Two! Three? Four") == ["One. Two! Three? Four"])
    }

    @Test func longTextSplitsAtTheCeilingWithoutLosingCharacters() {
        let runOn = String(repeating: "word ", count: 4_000)
        let pieces = SpeechSynthesizer.chunks(of: runOn)
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { $0.count <= SpeechSynthesizer.maxChunkCharacters })
        #expect(pieces.joined() == runOn)
    }

    @Test func chunksDropWhitespaceOnlyInput() {
        #expect(SpeechSynthesizer.chunks(of: "   \n  ").isEmpty)
    }

    @Test func renderWritesPlayableAudioFile() async throws {
        let url = try await SpeechSynthesizer.render(
            spec: SpeechSynthesizer.Spec(text: "The timeline is ready for review.", rate: 1.0, pitch: 1.0)
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(tracks.count == 1)
        let range = try await tracks[0].load(.timeRange)
        // Default delivery, not the engine's maximum rate: seven words cannot fit in half a
        // second of normal speech.
        #expect(range.duration.seconds > 1.0)
    }

    @Test func longerTextRendersMoreAudioThanShorterText() async throws {
        let short = try await SpeechSynthesizer.render(
            spec: SpeechSynthesizer.Spec(text: "One two three.", rate: 1.0, pitch: 1.0)
        )
        defer { try? FileManager.default.removeItem(at: short) }
        let long = try await SpeechSynthesizer.render(
            spec: SpeechSynthesizer.Spec(
                text: (1...6).map { "Sentence number \($0) of the longer passage." }.joined(separator: " "),
                rate: 1.0,
                pitch: 1.0
            )
        )
        defer { try? FileManager.default.removeItem(at: long) }

        func seconds(_ url: URL) async throws -> Double {
            let asset = AVURLAsset(url: url)
            let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
            return try await track.load(.timeRange).duration.seconds
        }
        let shortSeconds = try await seconds(short)
        let longSeconds = try await seconds(long)
        #expect(longSeconds > shortSeconds * 3)
    }

    @Test func emptyTextIsRefusedBeforeAnyWork() async {
        await #expect(throws: SpeechSynthesizer.SpeechError.emptyText) {
            try await SpeechSynthesizer.render(spec: SpeechSynthesizer.Spec(text: "   ", rate: 1.0, pitch: 1.0))
        }
    }

    @Test func overlongTextIsRefusedWithTheLimit() async {
        let text = String(repeating: "a", count: SpeechSynthesizer.maxCharacters + 1)
        await #expect(throws: SpeechSynthesizer.SpeechError.textTooLong(SpeechSynthesizer.maxCharacters)) {
            try await SpeechSynthesizer.render(spec: SpeechSynthesizer.Spec(text: text, rate: 1.0, pitch: 1.0))
        }
    }

    @Test func unknownVoiceIsRefusedWithCandidates() {
        let spec = SpeechSynthesizer.Spec(text: "hi", voiceIdentifier: "No Such Voice", rate: 1.0, pitch: 1.0)
        #expect(throws: SpeechSynthesizer.SpeechError.self) {
            try SpeechSynthesizer.resolveVoice(spec: spec)
        }
    }

    @Test func installedLanguagesCoverTheVoicesReported() {
        let voices = SpeechSynthesizer.voices()
        #expect(Set(voices.map(\.language)) == Set(SpeechSynthesizer.installedLanguages()))
        #expect(voices.allSatisfy { !$0.name.isEmpty && !$0.identifier.isEmpty })
    }

    @Test func resolvingByIdentifierReturnsThatVoice() throws {
        let installed = try #require(SpeechSynthesizer.voices().first)
        let spec = SpeechSynthesizer.Spec(text: "hi", voiceIdentifier: installed.identifier, rate: 1.0, pitch: 1.0)
        #expect(try SpeechSynthesizer.resolveVoice(spec: spec).identifier == installed.identifier)
    }

    @Test func rateAndPitchAreClampedToWhatTheVoiceAccepts() async throws {
        // Out-of-range multipliers must not throw or produce silence.
        let url = try await SpeechSynthesizer.render(
            spec: SpeechSynthesizer.Spec(text: "Clamped delivery.", rate: 99, pitch: 99)
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        #expect(file.length > 0)
    }
}
