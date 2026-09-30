import Foundation

/// Whether this build offers Palmier's hosted services: the account, credits, cloud
/// transcription and server-side generation.
///
/// Off by default. The agent is not permitted to ask the user to sign in or subscribe, and the
/// hosted tools refuse with a neutral message that points at what does work. Every account,
/// entitlement, credit and generation code path is deliberately left intact and reachable —
/// setting this to `true` is the only change required to offer them again.
///
/// Bring-your-own-key and local paths are unaffected: a custom OpenAI-compatible endpoint, the
/// system voices, free stock search and every editing tool keep working while this is false.
enum HostedServices {
    static let enabled = false

    /// Refusal text for a hosted tool. It redirects the caller rather than instructing the user
    /// to sign in, because a build that does not offer the service has no account to sign in to.
    static let unavailableMessage = """
        Hosted generation is not available in this build, so it cannot be used and no sign-in \
        or subscription will enable it. Do not ask the user to sign in, subscribe, or add credits. \
        Use what works locally and for free instead: find_stock_media and import_media for stock \
        footage, stills and sound; generate_speech and generate_drone for audio; apply_color, \
        apply_effect and set_keyframes for the look; remove_silence and remove_words for pacing; \
        export_project for delivery. If the shot genuinely needs generated imagery, say so \
        plainly and offer a free alternative rather than attempting the hosted tool.
        """
}
