import Foundation

/// A named look, expressed as a complete grade in `apply_color`'s own vocabulary.
///
/// A preset is only a grade. Anything a look implies beyond color — a music bed, transitions,
/// loudness — is a separate decision the Agent makes explicitly, so applying a look never
/// silently changes the edit's structure.
struct StylePreset: Equatable, Identifiable {
    var id: String
    /// When to reach for it, and what it is for. Part of the tool contract, not localized.
    var intent: String
    /// The grade, pasteable straight into `apply_color`'s `color` parameter.
    var color: [String: Any]

    static func == (lhs: StylePreset, rhs: StylePreset) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
enum StylePresets {
    /// Curated so each entry differs from the others in more than one axis: a user can tell them
    /// apart on screen without reading the numbers.
    static let all: [StylePreset] = [
        StylePreset(
            id: "documentary",
            intent: "Honest and unobtrusive. Neutral white balance, gentle contrast, a little "
                + "shadow detail. Interviews, archival, anything where the subject must look real.",
            color: [
                "exposure": 0.0, "contrast": 1.04, "saturation": 0.94, "vibrance": 0.12,
                "temperature": 6300, "tint": 0, "highlights": -0.1, "shadows": 0.12,
                "blacks": -0.04, "whites": 0.0,
            ]
        ),
        StylePreset(
            id: "cinematic",
            intent: "The teal-and-orange blockbuster look: cool shadows against warm skin and "
                + "highlights, with a soft S-curve. Narrative and trailer work.",
            color: [
                "exposure": -0.1, "contrast": 1.12, "saturation": 1.08, "vibrance": 0.1,
                "temperature": 6600, "tint": 2, "highlights": -0.14, "shadows": -0.06,
                "blacks": -0.1, "whites": 0.04,
                "shadowsHue": 200, "shadowsAmount": 0.16,
                "highsHue": 38, "highsAmount": 0.1,
                "masterCurve": [[0, 0.04], [0.25, 0.22], [0.75, 0.78], [1, 0.96]],
            ]
        ),
        StylePreset(
            id: "travelVlog",
            intent: "Bright, warm and inviting, with the saturation pushed and the blacks kept "
                + "open so a shot in shade still reads. Travel, vlog, real estate.",
            color: [
                "exposure": 0.18, "contrast": 1.06, "saturation": 1.18, "vibrance": 0.2,
                "temperature": 7100, "tint": 3, "highlights": 0.04, "shadows": 0.18,
                "blacks": 0.04, "whites": 0.06,
            ]
        ),
        StylePreset(
            id: "warmFilm",
            intent: "Faded film: a lifted toe, warm whites, slightly muted color. Nostalgia, "
                + "wedding, music video, anything shot to look remembered.",
            color: [
                "exposure": 0.05, "contrast": 0.94, "saturation": 0.88, "vibrance": 0.08,
                "temperature": 6900, "tint": 4, "highlights": 0.1, "shadows": 0.14,
                "blacks": 0.1, "whites": 0.08,
                "masterCurve": [[0, 0.07], [0.5, 0.5], [1, 0.93]],
            ]
        ),
        StylePreset(
            id: "noir",
            intent: "Near-monochrome and hard. High contrast, desaturated, deep blacks. Stylised "
                + "drama, crime, anything that should feel severe.",
            color: [
                "exposure": -0.08, "contrast": 1.24, "saturation": 0.15, "vibrance": 0,
                "temperature": 6200, "tint": 0, "highlights": -0.16, "shadows": -0.14,
                "blacks": -0.22, "whites": 0.02,
                "masterCurve": [[0, 0.0], [0.5, 0.5], [1, 1.0]],
            ]
        ),
        StylePreset(
            id: "cleanCorporate",
            intent: "Neutral, bright and even, with no visible character. Explainer, training, "
                + "anything that must not compete with on-screen text.",
            color: [
                "exposure": 0.1, "contrast": 1.0, "saturation": 1.0, "vibrance": 0.05,
                "temperature": 6500, "tint": 0, "highlights": -0.04, "shadows": 0.06,
                "blacks": 0.0, "whites": 0.04,
            ]
        ),
        StylePreset(
            id: "socialPunch",
            intent: "Stop-scroll: saturated, contrasty, cool shadows against warm faces. Short-form "
                + "vertical, hooks, anything that has to win attention in one second.",
            color: [
                "exposure": 0.08, "contrast": 1.18, "saturation": 1.32, "vibrance": 0.16,
                "temperature": 6400, "tint": 0, "highlights": -0.08, "shadows": -0.08,
                "blacks": -0.14, "whites": 0.06,
                "shadowsHue": 215, "shadowsAmount": 0.12,
            ]
        ),
    ]

    static func preset(id: String) -> StylePreset? {
        all.first { $0.id == id }
    }

    /// Every id, for error messages, so a wrong name is always correctable.
    static var ids: [String] { all.map(\.id) }
}
