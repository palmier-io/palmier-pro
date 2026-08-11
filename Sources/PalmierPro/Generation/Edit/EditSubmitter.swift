import Foundation

@MainActor
enum EditSubmitter {
    static func effectiveDuration(
        for asset: MediaAsset,
        trimmedSource: TrimmedSource?
    ) -> Int {
        let seconds = trimmedSource?.hasTrim == true
            ? trimmedSource?.durationSeconds ?? asset.duration
            : asset.duration
        return max(1, Int(seconds.rounded()))
    }

    static func prefixedName(_ prefix: String, for asset: MediaAsset) -> String {
        let prefixes = ["Upscaled ", "Edited ", "Rerun "]
        let base = prefixes.first(where: asset.name.hasPrefix)
            .map { String(asset.name.dropFirst($0.count)) }
            ?? asset.name
        return "\(prefix) \(base)"
    }
}
