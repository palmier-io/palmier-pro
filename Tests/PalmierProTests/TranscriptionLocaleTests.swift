import Foundation
import Testing
@testable import PalmierPro

@Suite("Transcription.matchLocale")
struct TranscriptionLocaleTests {
    // A representative slice of SpeechTranscriber.supportedLocales (clean language_region).
    private let supported = ["en_US", "en_GB", "fr_FR", "fr_CA", "es_ES"].map(Locale.init(identifier:))

    @Test func regionOverrideKeywordIsStrippedToLanguageMatch() {
        // French user on an English UI → en_US@rg=frzzzz. Should resolve to an en_* model.
        let result = Transcription.matchLocale(candidates: [Locale(identifier: "en_US@rg=frzzzz")], supported: supported)
        #expect(result?.identifier == "en_US")
    }

    @Test func languageRegionMismatchFallsBackToSameLanguage() {
        // n_FR (English language, France region) has no en_FR model → any en_*.
        let result = Transcription.matchLocale(candidates: [Locale(identifier: "en_FR")], supported: supported)
        #expect(result?.language.languageCode?.identifier == "en")
    }

    @Test func exactRegionIsPreferredOverSameLanguage() {
        let result = Transcription.matchLocale(candidates: [Locale(identifier: "fr_CA")], supported: supported)
        #expect(result?.identifier == "fr_CA")
    }

    @Test func preferredLanguageOrderWins() {
        // A French speaker whose preferred list leads with fr should transcribe in French.
        let result = Transcription.matchLocale(
            candidates: ["fr_FR", "en_US"].map(Locale.init(identifier:)), supported: supported
        )
        #expect(result?.identifier == "fr_FR")
    }

    @Test func languageOnlyCandidateMatchesAnyRegion() {
        let result = Transcription.matchLocale(candidates: [Locale(identifier: "fr")], supported: supported)
        #expect(result?.language.languageCode?.identifier == "fr")
    }

    @Test func noSharedLanguageReturnsNil() {
        let result = Transcription.matchLocale(candidates: [Locale(identifier: "ja_JP")], supported: supported)
        #expect(result == nil)
    }
}
