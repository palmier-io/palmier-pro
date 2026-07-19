// Unit tests for the caption-settings resolvers behind B1's Line breaks / Max words rows and B2's
// Mode↔transcriptionPreference reconciliation. Pure logic — no filesystem or view needed.

import Testing
@testable import PalmierPro

@Suite("CaptionSettingsResolver")
struct CaptionSettingsResolverTests {
    private func profile(segmentation: String? = nil, maxWords: Int? = nil) -> CaptionStyleProfile {
        var p = CaptionStyleProfile.builtInDefault
        p.typography = CaptionStyleProfile.Typography(maxWords: maxWords, segmentation: segmentation)
        return p
    }

    // MARK: - Segmentation

    @Test func segmentationFollowsProfileWhenNoOverride() {
        let resolved = CaptionSettingsResolver.segmentation(userOverride: nil, profile: profile(segmentation: "fixedChars"))
        #expect(resolved.value == .fixedChars)
        #expect(resolved.fromProfile == true)
    }

    @Test func segmentationUserOverrideWinsAndIsNotProfileSourced() {
        let resolved = CaptionSettingsResolver.segmentation(userOverride: .natural, profile: profile(segmentation: "fixedChars"))
        #expect(resolved.value == .natural)
        #expect(resolved.fromProfile == false)
    }

    @Test func segmentationFallsBackToNaturalWhenProfileSilent() {
        let resolved = CaptionSettingsResolver.segmentation(userOverride: nil, profile: profile())
        #expect(resolved.value == .natural)
        #expect(resolved.fromProfile == false)
    }

    @Test func segmentationIgnoresUnknownProfileValue() {
        let resolved = CaptionSettingsResolver.segmentation(userOverride: nil, profile: profile(segmentation: "bogus"))
        #expect(resolved.value == .natural)
        #expect(resolved.fromProfile == false)
    }

    // MARK: - Max words

    @Test func maxWordsShowsProfileValueWhenUnset() {
        let resolved = CaptionSettingsResolver.maxWords(userSet: false, userValue: nil, profile: profile(maxWords: 8))
        #expect(resolved.value == 8)
        #expect(resolved.fromProfile == true)
    }

    @Test func maxWordsExplicitNoneOverridesProfile() {
        let resolved = CaptionSettingsResolver.maxWords(userSet: true, userValue: nil, profile: profile(maxWords: 8))
        #expect(resolved.value == nil)
        #expect(resolved.fromProfile == false)
    }

    @Test func maxWordsUserNumberWins() {
        let resolved = CaptionSettingsResolver.maxWords(userSet: true, userValue: 3, profile: profile(maxWords: 8))
        #expect(resolved.value == 3)
        #expect(resolved.fromProfile == false)
    }

    @Test func maxWordsUnsetWithNoProfileIsNil() {
        let resolved = CaptionSettingsResolver.maxWords(userSet: false, userValue: nil, profile: profile())
        #expect(resolved.value == nil)
        #expect(resolved.fromProfile == false)
    }

    @Test func maxWordsIgnoresNonPositiveProfileValue() {
        let resolved = CaptionSettingsResolver.maxWords(userSet: false, userValue: nil, profile: profile(maxWords: 0))
        #expect(resolved.value == nil)
        #expect(resolved.fromProfile == false)
    }
}

@Suite("TranscriptionModeReconciler")
struct TranscriptionModeReconcilerTests {
    @Test func autoResolvesToCloudWhenReachableElseLocal() {
        #expect(TranscriptionModeReconciler.provider(for: .auto, canUseCloud: true) == .cloud)
        #expect(TranscriptionModeReconciler.provider(for: .auto, canUseCloud: false) == .local)
    }

    @Test func explicitPreferencesMapDirectly() {
        #expect(TranscriptionModeReconciler.provider(for: .local, canUseCloud: true) == .local)
        #expect(TranscriptionModeReconciler.provider(for: .cloud, canUseCloud: false) == .cloud)
    }

    @Test func pickingProviderCollapsesToConcretePreference() {
        #expect(TranscriptionModeReconciler.preference(for: .local) == .local)
        #expect(TranscriptionModeReconciler.preference(for: .cloud) == .cloud)
    }
}
