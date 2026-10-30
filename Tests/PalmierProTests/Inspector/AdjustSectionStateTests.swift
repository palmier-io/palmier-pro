import Testing
@testable import PalmierPro

@Suite struct AdjustSectionStateTests {
    @Test func sectionInteractionDistinguishesBypassMixedAndSamplingStates() {
        let ids: Set<String> = ["blur.gaussian", "key.chroma", "stylize.invert"]
        func state(_ effects: [Effect], sampling: Bool = false) -> AdjustSectionState {
            var clip = Fixtures.clip(id: "clip", start: 0, duration: 30)
            clip.effects = effects
            return AdjustSectionState(
                effectIds: ids,
                clips: [clip],
                chromaKeySamplingClipId: sampling ? clip.id : nil
            )
        }

        #expect(!state([Effect(type: "blur.gaussian", enabled: false)]).isEnabled)
        #expect(state([
            Effect(type: "blur.gaussian", enabled: false),
            Effect(type: "stylize.invert"),
        ]).isEnabled)
        #expect(state([Effect(type: "key.chroma", enabled: false)], sampling: true).isEnabled)
    }
}
