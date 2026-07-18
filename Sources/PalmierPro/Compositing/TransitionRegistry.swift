import CoreImage
import Foundation

struct TransitionDescriptor: Identifiable, Sendable {
    let id: String
    let displayName: String
    let category: String
    let apply: @Sendable (_ outgoing: CIImage, _ incoming: CIImage, _ progress: Double, _ extent: CGRect) -> CIImage
}

enum TransitionRegistry {

    static let all: [TransitionDescriptor] = dissolve + wipe + push + zoom + flash

    private static let byId: [String: TransitionDescriptor] = {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }()

    static func descriptor(id: String) -> TransitionDescriptor? { byId[id] }

    static func contains(_ id: String) -> Bool { byId[id] != nil }

    static func catalogLine() -> String {
        all.map { "• \($0.id) — \($0.displayName) (\($0.category))" }.joined(separator: "\n")
    }

    static func apply(
        type: String,
        outgoing: CIImage,
        incoming: CIImage,
        progress: Double,
        extent: CGRect
    ) -> CIImage {
        let t = min(1, max(0, progress))
        guard let descriptor = descriptor(id: type) else {
            return dissolve(outgoing, incoming, t, extent)
        }
        return descriptor.apply(outgoing, incoming, t, extent).cropped(to: extent)
    }

    // MARK: - Catalog

    private static let dissolve: [TransitionDescriptor] = [
        TransitionDescriptor(
            id: "dissolve", displayName: "Cross Dissolve", category: "Dissolve",
            apply: dissolve
        ),
        TransitionDescriptor(
            id: "fade.black", displayName: "Fade Through Black", category: "Dissolve",
            apply: fadeBlack
        ),
    ]

    private static let wipe: [TransitionDescriptor] = [
        swipe("wipe.left", "Wipe Left", angle: .pi),
        swipe("wipe.right", "Wipe Right", angle: 0),
        swipe("wipe.up", "Wipe Up", angle: .pi / 2),
        swipe("wipe.down", "Wipe Down", angle: -.pi / 2),
    ]

    private static let push: [TransitionDescriptor] = [
        push("push.left", "Push Left", dx: -1, dy: 0),
        push("push.right", "Push Right", dx: 1, dy: 0),
        push("push.up", "Push Up", dx: 0, dy: -1),
        push("push.down", "Push Down", dx: 0, dy: 1),
    ]

    private static let zoom: [TransitionDescriptor] = [
        TransitionDescriptor(
            id: "zoom.in", displayName: "Zoom In", category: "Zoom",
            apply: zoomIn
        ),
        TransitionDescriptor(
            id: "zoom.out", displayName: "Zoom Out", category: "Zoom",
            apply: zoomOut
        ),
    ]

    private static let flash: [TransitionDescriptor] = [
        TransitionDescriptor(
            id: "flash.white", displayName: "Flash White", category: "Flash",
            apply: flashWhite
        ),
    ]

    // MARK: - Implementations

    private static func dissolve(
        _ outgoing: CIImage, _ incoming: CIImage, _ t: Double, _ extent: CGRect
    ) -> CIImage {
        let f = CIFilter(name: "CIDissolveTransition")
        f?.setValue(outgoing.cropped(to: extent), forKey: kCIInputImageKey)
        f?.setValue(incoming.cropped(to: extent), forKey: "inputTargetImage")
        f?.setValue(t, forKey: kCIInputTimeKey)
        return (f?.outputImage ?? incoming).cropped(to: extent)
    }

    private static func fadeBlack(
        _ outgoing: CIImage, _ incoming: CIImage, _ t: Double, _ extent: CGRect
    ) -> CIImage {
        let black = CIImage(color: .black).cropped(to: extent)
        if t < 0.5 {
            return dissolve(outgoing, black, t * 2, extent)
        }
        return dissolve(black, incoming, (t - 0.5) * 2, extent)
    }

    private static func swipe(_ id: String, _ name: String, angle: Double) -> TransitionDescriptor {
        TransitionDescriptor(id: id, displayName: name, category: "Wipe") { outgoing, incoming, t, extent in
            let f = CIFilter(name: "CISwipeTransition")
            f?.setValue(outgoing.cropped(to: extent), forKey: kCIInputImageKey)
            f?.setValue(incoming.cropped(to: extent), forKey: "inputTargetImage")
            f?.setValue(t, forKey: kCIInputTimeKey)
            f?.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
            f?.setValue(angle, forKey: kCIInputAngleKey)
            f?.setValue(extent.width * 0.08, forKey: kCIInputWidthKey)
            f?.setValue(CIColor.black, forKey: kCIInputColorKey)
            return (f?.outputImage ?? incoming).cropped(to: extent)
        }
    }

    private static func push(_ id: String, _ name: String, dx: CGFloat, dy: CGFloat) -> TransitionDescriptor {
        TransitionDescriptor(id: id, displayName: name, category: "Push") { outgoing, incoming, t, extent in
            let ox = dx * extent.width * t
            let oy = dy * extent.height * t
            let ix = dx * extent.width * (t - 1)
            let iy = dy * extent.height * (t - 1)
            // CI y-up: flip vertical push direction into CI space.
            let outT = CGAffineTransform(translationX: ox, y: -oy)
            let inT = CGAffineTransform(translationX: ix, y: -iy)
            let movedOut = outgoing.transformed(by: outT).cropped(to: extent)
            let movedIn = incoming.transformed(by: inT).cropped(to: extent)
            return movedIn.composited(over: movedOut)
        }
    }

    private static func zoomIn(
        _ outgoing: CIImage, _ incoming: CIImage, _ t: Double, _ extent: CGRect
    ) -> CIImage {
        let outScale = 1 + 0.35 * t
        let inScale = 0.65 + 0.35 * t
        let scaledOut = scaled(outgoing, by: outScale, extent: extent)
        let scaledIn = scaled(incoming, by: inScale, extent: extent)
        return dissolve(scaledOut, scaledIn, t, extent)
    }

    private static func zoomOut(
        _ outgoing: CIImage, _ incoming: CIImage, _ t: Double, _ extent: CGRect
    ) -> CIImage {
        let outScale = 1 - 0.35 * t
        let inScale = 1.35 - 0.35 * t
        let scaledOut = scaled(outgoing, by: max(0.01, outScale), extent: extent)
        let scaledIn = scaled(incoming, by: inScale, extent: extent)
        return dissolve(scaledOut, scaledIn, t, extent)
    }

    private static func flashWhite(
        _ outgoing: CIImage, _ incoming: CIImage, _ t: Double, _ extent: CGRect
    ) -> CIImage {
        let white = CIImage(color: .white).cropped(to: extent)
        if t < 0.5 {
            return dissolve(outgoing, white, t * 2, extent)
        }
        return dissolve(white, incoming, (t - 0.5) * 2, extent)
    }

    private static func scaled(_ image: CIImage, by scale: Double, extent: CGRect) -> CIImage {
        let cx = extent.midX
        let cy = extent.midY
        let t = CGAffineTransform(translationX: cx, y: cy)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -cx, y: -cy)
        return image.transformed(by: t).cropped(to: extent)
    }
}
