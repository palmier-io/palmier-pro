import Testing
import Foundation
@testable import PalmierPro

@Suite("Blend modes")
struct BlendModeTests {

    @Test func normalHasNoFilterEverythingElseDoes() {
        #expect(BlendMode.normal.ciFilterName == nil)
        for mode in BlendMode.allCases where mode != .normal {
            #expect(mode.ciFilterName != nil, "\(mode) should map to a CIFilter")
        }
        #expect(BlendMode.screen.ciFilterName == "CIScreenBlendMode")
        #expect(BlendMode.multiply.ciFilterName == "CIMultiplyBlendMode")
    }

    @Test func clipBlendModeRoundTrips() throws {
        var clip = Clip(mediaRef: "m", startFrame: 0, durationFrames: 30)
        clip.blendMode = .overlay
        let decoded = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(clip))
        #expect(decoded.blendMode == .overlay)
    }

    @Test func oldClipJSONDecodesWithNilBlendMode() throws {
        let json = #"{"mediaRef":"m","startFrame":0,"durationFrames":30}"#
        let clip = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        #expect(clip.blendMode == nil)
    }
}
