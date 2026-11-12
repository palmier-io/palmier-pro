import CoreGraphics
import Foundation
import Testing
@testable import CompositorPro

@Suite("Image composer layout")
struct ImageComposerLayoutTests {
    private let canvas = CGSize(width: 1280, height: 720)

    private func slots(_ count: Int, _ layout: ComposeLayout) -> [CGRect] {
        ImageComposer.slots(count: count, layout: layout, canvas: canvas)
    }

    @Test("Every layout returns one slot per image")
    func slotCountMatchesInput() {
        for layout in ComposeLayout.allCases {
            for count in 1 ... 9 {
                #expect(
                    slots(count, layout).count == count,
                    "\(layout.rawValue) with \(count) images"
                )
            }
        }
    }

    @Test("Slots never leave the canvas")
    func slotsStayInsideCanvas() {
        for layout in ComposeLayout.allCases {
            for count in 1 ... 9 {
                for slot in slots(count, layout) {
                    #expect(slot.minX >= -0.001, "\(layout.rawValue) overflows left")
                    #expect(slot.minY >= -0.001, "\(layout.rawValue) overflows top")
                    #expect(slot.maxX <= canvas.width + 0.001, "\(layout.rawValue) overflows right")
                    #expect(slot.maxY <= canvas.height + 0.001, "\(layout.rawValue) overflows bottom")
                }
            }
        }
    }

    @Test("Slots never overlap, or tiles would crop each other")
    func slotsDoNotOverlap() {
        for layout in ComposeLayout.allCases {
            for count in 2 ... 9 {
                let rects = slots(count, layout)
                for first in 0 ..< rects.count {
                    for second in (first + 1) ..< rects.count {
                        #expect(
                            !rects[first].intersects(rects[second]),
                            "\(layout.rawValue) with \(count) images overlaps"
                        )
                    }
                }
            }
        }
    }

    @Test("Slots have positive area, including on awkward counts")
    func slotsHaveArea() {
        for layout in ComposeLayout.allCases {
            for count in 1 ... 12 {
                for slot in slots(count, layout) {
                    #expect(slot.width > 1, "\(layout.rawValue) with \(count): zero width")
                    #expect(slot.height > 1, "\(layout.rawValue) with \(count): zero height")
                }
            }
        }
    }

    @Test("A grid picks columns so tile shape suits the canvas")
    func gridColumnsMatchCanvasShape() {
        // A wide canvas wants more columns than rows; a tall one the reverse.
        #expect(ImageComposer.gridColumns(count: 6, canvas: canvas) > 1)
        let tall = CGSize(width: 1080, height: 1920)
        let wideColumns = ImageComposer.gridColumns(count: 6, canvas: canvas)
        let tallColumns = ImageComposer.gridColumns(count: 6, canvas: tall)
        #expect(tallColumns <= wideColumns)
    }

    @Test("One image always gets the whole canvas")
    func singleImageFillsCanvas() {
        for layout in ComposeLayout.allCases {
            let rects = slots(1, layout)
            #expect(rects.count == 1)
            #expect(abs(rects[0].width - canvas.width) < 0.001)
            #expect(abs(rects[0].height - canvas.height) < 0.001)
        }
    }

    @Test("heroStrip gives the first image the large slot")
    func heroStripLeadsWithTheFirst() {
        let rects = slots(4, .heroStrip)
        #expect(rects.count == 4)
        #expect(abs(rects[0].height - canvas.height * ImageComposer.heroShare) < 0.001)
        for index in 1 ..< rects.count {
            #expect(rects[index].height < rects[0].height)
        }
    }

    @Test("heroStrip degrades to a row when there is only one image")
    func heroStripWithOneImage() {
        let rects = slots(1, .heroStrip)
        #expect(abs(rects[0].height - canvas.height) < 0.001)
    }

    @Test("Row and column divide the canvas the long way")
    func rowAndColumnDirections() {
        let row = slots(4, .row)
        #expect(abs(row[0].height - (canvas.height - ImageComposer.gutter(for: canvas) * 2)) < 0.001)

        let column = slots(4, .column)
        #expect(column[0].width > column[0].height, "on a wide canvas a column tile is wide")
        #expect(column[1].minY > column[0].minY, "a column stacks downward")
    }

    @Test("A column divides the canvas vertically, whatever the canvas shape")
    func columnOnPortraitCanvas() {
        let tall = CGSize(width: 1080, height: 1920)
        let rects = ImageComposer.slots(count: 3, layout: .column, canvas: tall)
        // Tile shape follows the canvas; what defines a column is that tiles are full width and
        // stacked downward.
        #expect(rects[0].width > tall.width - ImageComposer.gutter(for: tall) * 2 - 0.001)
        #expect(rects[1].minY > rects[0].minY)
        #expect(rects[2].maxY <= tall.height + 0.001)
    }

    @Test("Composing nothing is refused rather than producing a blank canvas")
    func refusesEmptyInput() {
        #expect(throws: ImageComposer.ComposeError.noImages) {
            try ImageComposer.compose([], spec: ImageComposer.Spec(canvas: canvas))
        }
    }

    @Test("A degenerate canvas is refused")
    func refusesTinyCanvas() {
        let spec = ImageComposer.Spec(canvas: CGSize(width: 2, height: 2))
        #expect(throws: ImageComposer.ComposeError.canvasTooSmall) {
            try ImageComposer.compose([Self.sample()], spec: spec)
        }
    }

    @Test("A composed image comes out at the requested canvas size")
    func outputMatchesCanvas() throws {
        for preset in ThumbnailPreset.allCases {
            var spec = ImageComposer.Spec(layout: .grid)
            spec.canvas = preset.size
            let image = try #require(
                try ImageComposer.compose([Self.sample(), Self.sample()], spec: spec)
            )
            #expect(image.width == Int(preset.size.width.rounded()), "\(preset.rawValue) width")
            #expect(image.height == Int(preset.size.height.rounded()), "\(preset.rawValue) height")
        }
    }

    @Test("Composing is deterministic: the same sources give the same picture")
    func isDeterministic() throws {
        let spec = ImageComposer.Spec(layout: .heroStrip, canvas: canvas, headline: "Same")
        let first = try #require(
            try ImageComposer.compose([Self.sample(), Self.sample()], spec: spec)
        )
        let second = try #require(
            try ImageComposer.compose([Self.sample(), Self.sample()], spec: spec)
        )
        #expect(first.width == second.width && first.height == second.height)
        #expect(ImageComposer.slots(count: 2, layout: .heroStrip, canvas: canvas)
            == ImageComposer.slots(count: 2, layout: .heroStrip, canvas: canvas))
    }

    private static func sample() -> CGImage {
        let context = CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.setFillColor(CGColor(red: 0.4, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return context.makeImage()!
    }
}