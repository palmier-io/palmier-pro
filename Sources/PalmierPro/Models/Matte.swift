import AppKit
import Foundation
import SwiftUI

enum MatteAspect: String, CaseIterable, Identifiable {
    case project = "Project", sixteenNine = "16:9", nineSixteen = "9:16"
    case oneOne = "1:1", fourThree = "4:3", nineFourteen = "9:14", twoPointFourOne = "2.4:1"
    var id: String { rawValue }

    private var ratio: (Int, Int)? {
        switch self {
        case .project: nil
        case .sixteenNine: (16, 9)
        case .nineSixteen: (9, 16)
        case .oneOne: (1, 1)
        case .fourThree: (4, 3)
        case .nineFourteen: (9, 14)
        case .twoPointFourOne: (24, 10)
        }
    }

    func pixelSize(timelineWidth w: Int, timelineHeight h: Int) -> (width: Int, height: Int) {
        guard let (aw, ah) = ratio else { return Matte.even(w, h) }
        return Matte.fit(short: min(w, h), aspectW: aw, aspectH: ah)
    }

    static func parse(_ raw: String?) -> MatteAspect? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.caseInsensitiveCompare("project") == .orderedSame { return .project }
        return MatteAspect(rawValue: raw)
    }
}

enum Matte {
    enum Error: LocalizedError {
        case renderFailed, noProject
        var errorDescription: String? {
            switch self {
            case .renderFailed: "Couldn't render matte image."
            case .noProject: "Open a project before creating a matte."
            }
        }
    }

    static func even(_ w: Int, _ h: Int) -> (width: Int, height: Int) {
        (max(2, (max(2, w) / 2) * 2), max(2, (max(2, h) / 2) * 2))
    }

    static func fit(short edge: Int, aspectW: Int, aspectH: Int) -> (width: Int, height: Int) {
        let e = max(2, edge)
        let aw = Double(aspectW), ah = Double(aspectH)
        if aw >= ah { return even(Int((Double(e) * aw / ah).rounded()), e) }
        return even(e, Int((Double(e) * ah / aw).rounded()))
    }

    static func png(hex: String, width: Int, height: Int) throws -> Data {
        guard let color = TextStyle.RGBA(hex: hex) else { throw Error.renderFailed }
        let (ew, eh) = even(width, height)
        guard let ctx = CGContext(
            data: nil, width: ew, height: eh, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Error.renderFailed }
        ctx.setFillColor(red: CGFloat(color.r), green: CGFloat(color.g), blue: CGFloat(color.b), alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: ew, height: eh))
        guard let image = ctx.makeImage(), let data = ImageEncoder.encodePNG(image) else { throw Error.renderFailed }
        return data
    }
}

extension Color {
    var matteHex: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
