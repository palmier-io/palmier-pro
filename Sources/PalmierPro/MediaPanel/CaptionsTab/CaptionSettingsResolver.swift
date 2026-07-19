// Resolves the effective line-break mode and word cap shown in CaptionTab from the caption-style
// profile plus the user's per-generation overrides, tracking whether the shown value came from the
// profile (so the row can annotate "(profile)"). Mirrors add_captions' resolution order.

import Foundation

enum CaptionSettingsResolver {
    /// An effective value plus whether the resolved caption-style profile supplied it (vs. a user
    /// override or the built-in default), so the UI knows when to show the "(profile)" annotation.
    struct Resolved<Value: Equatable>: Equatable {
        let value: Value
        let fromProfile: Bool
    }

    /// Line-break mode: a user override wins; otherwise the profile's typography.segmentation (when a
    /// known value); otherwise the built-in natural default. `fromProfile` is true only when the
    /// profile drove the value, so the row annotates it and the reset button returns to profile-follow.
    static func segmentation(
        userOverride: CaptionBuilder.Segmentation?,
        profile: CaptionStyleProfile
    ) -> Resolved<CaptionBuilder.Segmentation> {
        if let userOverride { return Resolved(value: userOverride, fromProfile: false) }
        if let raw = profile.typography.segmentation,
           let mode = CaptionBuilder.Segmentation(rawValue: raw) {
            return Resolved(value: mode, fromProfile: true)
        }
        return Resolved(value: .default, fromProfile: false)
    }

    /// Words-per-caption cap: a user choice wins (including an explicit "None" → nil). When the user
    /// hasn't set it, a profile value of 1 or more drives the effective cap with `fromProfile`;
    /// otherwise it stays unset (nil = fit each line to the box).
    static func maxWords(
        userSet: Bool,
        userValue: Int?,
        profile: CaptionStyleProfile
    ) -> Resolved<Int?> {
        if userSet { return Resolved(value: userValue, fromProfile: false) }
        if let profileMax = profile.typography.maxWords, profileMax >= 1 {
            return Resolved(value: profileMax, fromProfile: true)
        }
        return Resolved(value: nil, fromProfile: false)
    }
}
