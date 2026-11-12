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
        hyperframesMotion,
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

    static let hyperframesMotion = PlaybookDefinition(
        id: "hyperframes-motion-playbook",
        name: "HyperFrames Motion & Kinetic Typography Playbook",
        description: "Dynamic motion design workflow combining catalog motion blocks, kinetic typography, brand styling (frame.md), and multi-track placement.",
        content: """
        # HyperFrames Motion & Kinetic Typography Playbook

        ## 1. Brand System & Design Alignment
        - Parse or declare the project visual design spec (frame.md / design.md) using apply_design_spec.
        - Strict brand token enforcement: background, surface, text, primary, accent, and border colors.
        - Establish canvas geometry (e.g. 16:9 for landscape showcases, 9:16 for vertical reels/shorts).
        - Typography pairing: high-impact display font for title cards and hooks (e.g. Anton, Montserrat, Futura); legible sans-serif for body/captions (e.g. Inter, Helvetica).

        ## 2. Catalog Motion Block Discovery & Ingestion
        - Search catalog blocks using search_hyperframes_catalog by query or category:
          - transitions: dynamic wipes, zooms, and glitch cuts between scenes.
          - overlays: animated badges, stickers, and decorative motion vectors.
          - captions: pre-styled kinetic typography and speech callouts.
          - charts: animated bar, line, and KPI metric presentations.
          - maps: geographical flyovers and route visualizers.
          - kinetic: title entrances, word pop-ups, and hero reveal blocks.
        - Verify block asset integrity and install into project media library with insert_hyperframes_block(blockId:).

        ## 3. Kinetic Typography & Animated Captions
        - Immediate hook: animated headline within the first 2 seconds to capture viewer retention.
        - Fast-cadence reading: 1–3 words per caption cluster, timed tightly to speech syllables.
        - Style with high-contrast outlines and brand accent highlights (e.g. template bold-pop or punchIn motion preset).
        - Position within platform-safe margins: center-weighted or lower-third (y: 0.75–0.85).

        ## 4. Track Stacking Hierarchy
        - Track 1 (V1) — Background Plate: Live-action video or ambient visual loop, graded consistently to match brand tone.
        - Track 2 (V2) — Motion Graphics & Vector Overlays: HyperFrames catalog blocks, Lottie animations, and graphic cards.
        - Track 3 (V3) — Kinetic Typography & Brand Marks: Animated titles, callout badges, and captions.
        - Add restrained motion treatments with apply_motion_preset:
          - fadeIn: smooth alpha reveal without positional shift.
          - slideUp: crisp upward entrance for cards and lower-thirds.
          - punchIn: dynamic scale pop for punchlines and hero items.
          - gentlePush: slow continuous 6% push across the entire shot.

        ## 5. Audio & Impact Synchronization
        - Motion hits must land on musical transients or dedicated sound effects.
        - Add punctuation SFX (whoosh, pop, click, riser) at keyframe transitions.
        - Voiceover clarity: duck background music bed by -12 dB to -16 dB beneath speech using duck_audio or mix_audio.
        """
    )

    /// Resolves a playbook by canonical id or alias.
    static func playbook(for id: String) -> PlaybookDefinition? {
        let normalized = id.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "")
        if normalized == "hyperframes" || normalized == "hyperframes-motion-playbook" {
            return hyperframesMotion
        }
        return all.first { $0.id == id || $0.id == normalized }
    }

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

