import Foundation

/// Versioned baseline filmmaking playbooks available offline.
enum FilmmakingPlaybooks {
    struct PlaybookDefinition: Sendable {
        let id: String
        let name: String
        let description: String
        let content: String
    }

    static let all: [PlaybookDefinition] = [
        narratedBRoll,
        interviewStory,
        productShowcase,
        rhythmicMontage,
    ]

    static let narratedBRoll = PlaybookDefinition(
        id: "narrated-broll-playbook",
        name: "Narrated B-Roll Filmmaking Playbook",
        description: "Professional workflow for narrated, footage-driven films with motivated pacing and dialogue-first mixing.",
        content: """
        # Narrated B-Roll Filmmaking Playbook

        ## 1. Editorial Brief & Structure
        - Establish hook in the first 3 seconds with a strong visual and clear spoken statement.
        - Alternate shot sizes: wide establishing -> medium action -> macro/detail shot.
        - Average shot duration: 2.5–4.5 seconds. Never hold a static shot beyond 5 seconds without motion.

        ## 2. Visual Selection & Inspection
        - Always inspect candidate thumbnails and representative frames before placement.
        - Reject still images for motion-led briefs; reject wrong subjects despite matching keywords.
        - Maintain consistent color temperature, exposure, and aspect framing across adjacent edits.

        ## 3. Transitions & Pacing
        - Use straight cuts by default. Restrain transitions to intentional chapter or scene shifts.
        - Cut on visual action or phrase boundaries, avoiding arbitrary jump cuts within the same subject.

        ## 4. Dialogue-First Audio Mixing
        - Dialogue is authoritative: target -16 LUFS integrated, true peak <= -1 dBTP.
        - Music beds must duck -9 to -14 dB under speech with smooth lookahead/attack/release.
        - Sound effects (SFX) must align precisely to visible transients (doors, impacts, movements).
        - Maintain continuous room tone or subtle ambience under narration.

        ## 5. Captions & Titles
        - High-contrast, platform-safe caption placement.
        - Keep 1–2 lines per subtitle cue, matched to spoken phrase cadence.
        """
    )

    static let interviewStory = PlaybookDefinition(
        id: "interview-playbook",
        name: "Interview & Documentary Playbook",
        description: "Workflow for talking heads with illustrative B-roll cutaways and vocal cleanup.",
        content: """
        # Interview & Documentary Playbook

        ## 1. Narrative Flow
        - Primary dialogue (A-roll) anchors the story; B-roll cuts away to illustrate spoken concepts.
        - Return to the interview subject on emotional beats and major topic transitions.

        ## 2. Audio Processing & Cleanup
        - Apply vocal enhancement: denoise ambient hum, control sibilance, and tame loud breaths.
        - Use J-cuts (audio leads visual) and L-cuts (audio trails visual) to soften transitions.
        - Duck background music bed by -12 to -18 dB to ensure pristine vocal clarity.

        ## 3. B-Roll Continuity
        - Keep cutaways relevant to the exact words being spoken in that second.
        - Minimum B-roll hold is 1.5 seconds; avoid flash cuts unless motivated by high-energy pacing.
        """
    )

    static let productShowcase = PlaybookDefinition(
        id: "product-playbook",
        name: "Product Showcase Playbook",
        description: "Commercial and product workflow focusing on hero angles, feature clarity, and payoff.",
        content: """
        # Product Showcase Playbook

        ## 1. Visual Hierarchy
        - Shot 1: Hero reveal or dynamic macro shot grabbing immediate attention.
        - Shots 2–4: Key product features shown in use (hands-on, real-world context).
        - Final Shot: Clean product beauty shot with call-to-action or logo overlay.

        ## 2. Motion & Framing
        - Smooth camera movements: parallax push-ins, slow pans, or crisp locked-off shots.
        - Consistent lighting and color grading matching brand aesthetic.

        ## 3. Sound Design
        - Tactile sound effects: clicks, snaps, swooshes, and mechanical textures tied to product interactions.
        - Upbeat, polished music track driving the commercial energy.
        """
    )

    static let rhythmicMontage = PlaybookDefinition(
        id: "montage-playbook",
        name: "Rhythmic Montage Playbook",
        description: "Dynamic musical montage timed to beats, accents, and movement arcs.",
        content: """
        # Rhythmic Montage Playbook

        ## 1. Music & Beat Synchronization
        - Use beat detection to locate musical downbeats and rhythmic transients.
        - Cut on musical phrases and strong downbeats rather than cutting every single eighth note.

        ## 2. Visual Movement Matching
        - Match screen direction: a subject moving left-to-right should cut to motion continuing in that direction.
        - Build momentum: shorten shot durations progressively leading up to the musical climax.
        """
    )

    /// Convert definitions to `Skill` models when scanning skills.
    static func skills(directory: URL) -> [Skill] {
        all.map { def in
            Skill(
                id: def.id,
                name: def.name,
                description: def.description,
                path: directory.appendingPathComponent(def.id).appendingPathComponent("SKILL.md")
            )
        }
    }
}

