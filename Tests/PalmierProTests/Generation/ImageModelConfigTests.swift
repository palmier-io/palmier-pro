import Testing
@testable import PalmierPro

@Suite("Image model labels")
struct ImageModelConfigTests {

    @Test func aspectRatioDisplayLabels() {
        let cases = [
            "16:9": "16:9",
            "2.35:1": "2.35:1",
            "auto": "Auto",
            "auto_2K": "Auto 2K",
            "square_hd": "Square HD",
            "16_9": "16:9",
            "portrait_4_3": "Portrait 4:3",
            "portrait_16_9": "Portrait 16:9",
            "landscape_4_3": "Landscape 4:3",
            "landscape_16_9": "Landscape 16:9",
        ]

        for (id, label) in cases {
            #expect(ImageModelConfig.aspectRatioDisplayLabel(id) == label)
        }
    }
}
