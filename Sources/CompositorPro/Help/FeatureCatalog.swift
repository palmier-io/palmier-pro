import Foundation

/// What the editor can do, written for people rather than for the agent.
///
/// This is the single owner of user-facing feature copy. Tools carry descriptions written for a
/// model reading a tool call, which is the wrong register for a person deciding what to try next,
/// and duplicating both would guarantee they drift apart. Keys are held rather than resolved text
/// so the view can localize them the same way `HelpTab` does.
///
/// Each feature names the tools that implement it. That is what a test checks: a renamed or
/// removed tool breaks the build here rather than leaving the page advertising something that no
/// longer exists.
struct FeatureCatalog {
    struct Feature: Identifiable, Sendable, Equatable {
        var id: String
        /// Localized key for the feature name.
        var title: String
        /// Localized key for what it does and when to reach for it.
        var summary: String
        /// Tools that implement this. Empty for anything in the interface rather than a tool, and
        /// for workflows that combine tools documented elsewhere.
        var tools: [ToolName]

        init(_ id: String, _ title: StaticString, _ summary: StaticString, tools: [ToolName] = []) {
            self.id = id
            self.title = L10n.key(title)
            self.summary = L10n.key(summary)
            self.tools = tools
        }
    }

    struct Category: Identifiable, Sendable, Equatable {
        var id: String
        var title: String
        var icon: String
        var features: [Feature]

        init(_ id: String, _ title: StaticString, _ icon: String, _ features: [Feature]) {
            self.id = id
            self.title = L10n.key(title)
            self.icon = icon
            self.features = features
        }
    }

    static let categories: [Category] = [
        Category("start", "Getting started", "sparkles", [
            Feature(
                "project",
                "Projects and timelines",
                """
                A project holds its media and can hold more than one timeline. Duplicate a timeline \
                to try a different cut or build a vertical version without disturbing the original, \
                then switch between them by name.
                """,
                tools: [.manageProject, .createTimeline, .setActiveTimeline]
            ),
            Feature(
                "canvas",
                "Canvas and frame rate",
                """
                Set the frame size, aspect ratio and rate in project settings. Changing the canvas \
                re-fits the existing clips rather than cropping them, so a landscape edit can become \
                a vertical one and still be usable.
                """,
                tools: [.setProjectSettings]
            ),
            Feature(
                "import",
                "Importing media",
                """
                Bring in video, audio and stills. Missing files stay linked by name, so moving the \
                project or the drive does not break the edit — relink and it picks up where it left off.
                """,
                tools: [.importMedia, .getMedia, .searchMedia]
            ),
            Feature(
                "marks",
                "Markers and review notes",
                """
                Drop point and range markers on the timeline to hold a note about a frame or a range. \
                They persist with the project and give the agent something concrete to aim at.
                """,
                tools: [.manageMarkers]
            ),
        ]),

        Category("edit", "Editing", "scissors", [
            Feature(
                "trim",
                "Trimming and ripple edits",
                """
                Shorten a clip and let the rest close up, or leave a gap. Removing a range with \
                ripple shifts everything after it and is one undo step, so a restructure never \
                becomes a cascade of small corrections.
                """,
                tools: [.rippleDeleteRanges, .removeClips, .setClipProperties]
            ),
            Feature(
                "split",
                "Splitting and moving",
                """
                Cut a clip at a frame, then move, insert or swap what sits where. Swapping media \
                keeps the timing, so a better take drops into an existing cut without re-timing it.
                """,
                tools: [.splitClips, .moveClips, .insertClips, .swapClipMedia]
            ),
            Feature(
                "transitions",
                "Transitions",
                """
                Cross dissolves, dips to black and the rest apply between neighbouring clips. The \
                timeline shows them and they follow the clips they sit between, so trimming the cut \
                takes the transition with it.
                """,
                tools: [.applyTransition, .removeTransition]
            ),
            Feature(
                "speed",
                "Speed and ramps",
                """
                Change playback rate, or ramp it — a slow push-in, a whip pan, a drift back to real \
                time. A ramp holds its start and end, and time-based effects follow the retimed clip.
                """,
                tools: [.setClipSpeedRamp]
            ),
            Feature(
                "freeze",
                "Freeze frames",
                """
                Hold one frame for as long as you need. The picture stops while the audio underneath \
                keeps playing, which is what makes it usable over speech.
                """,
                tools: [.freezeClip]
            ),
            Feature(
                "keys",
                "Keyframes",
                """
                Animate position, scale, rotation, opacity, crop or volume over a clip's length. The \
                editor holds the curve and the renderer obeys it in preview and on export alike.
                """,
                tools: [.setKeyframes]
            ),
            Feature(
                "layout",
                "Layouts and framing",
                """
                Split, picture-in-picture, side-by-side and stacked grids, with the framing chosen \
                per shot. This is the reliable way to reframe a shot for a new canvas.
                """,
                tools: [.applyLayout]
            ),
            Feature(
                "qc",
                "Checking a cut",
                """
                Audit the timeline for missing media, overlaps, gaps, hard audio joins and stale \
                transitions, and get the frame numbers to act on. Read-only: it reports, it does \
                not change the cut.
                """,
                tools: [.qcTimeline]
            ),
            Feature(
                "undo",
                "Undo",
                """
                Every edit here is a single step, not a pile of small ones. Undo puts the timeline \
                back exactly as it was, including retimed and restructured clips.
                """,
                tools: [.undo]
            ),
        ]),

        Category("audio", "Audio", "waveform", [
            Feature(
                "levels",
                "Levels and fades",
                """
                Set clip gain and fades, and match loudness across clips that were recorded under \
                different conditions. The meter reflects what will actually be heard.
                """,
                tools: [.matchLoudness]
            ),
            Feature(
                "duck",
                "Ducking music under speech",
                """
                Lower the music exactly where someone is talking and bring it back afterwards, with \
                an adjustable depth and a tail that keeps the music from pumping between words.
                """,
                tools: [.duckAudio]
            ),
            Feature(
                "crossfade",
                "Crossfades",
                """
                Blend the end of one clip into the start of the next. Equal-power fades hold a \
                constant loudness through the overlap, which linear fades do not.
                """,
                tools: [.crossfadeAudio]
            ),
            Feature(
                "jl",
                "J-cuts and L-cuts",
                """
                Let the next scene's sound start before its picture, or hold the current scene's \
                sound past its picture. One setting on a linked pair, and both sides still overlap.
                """,
                tools: [.offsetAudio]
            ),
            Feature(
                "clean",
                "Cleaning up dialogue",
                """
                Reduce steady background noise, soften breaths, and even out level. These run in the \
                packaged app; a command-line build needs the bundled speech models enabled.
                """,
                tools: [.denoiseAudio, .debreatheAudio, .enhanceVoice]
            ),
            Feature(
                "rhythm",
                "Beats and cutting to music",
                """
                Detect the beat grid, then place cuts and effects on it. Downbeats carry the \
                structure; cutting on every beat reads mechanical, so keep the accents sparse.
                """,
                tools: [.detectBeats, .syncToBeats]
            ),
            Feature(
                "drone",
                "Drone beds",
                """
                Generate a sustained tone to sit under a scene. Useful as a bed, or to hold a gap \
                while you decide what should be there.
                """,
                tools: [.generateDrone]
            ),
            Feature(
                "speech",
                "Speech synthesis",
                """
                Turn text into a line of narration. The packaged app uses a local voice when one is \
                installed and falls back to the system voice, and the result lands on the timeline \
                as a normal audio clip you can grade and time like any other.
                """,
                tools: [.generateSpeech, .listSpeechVoices]
            ),
        ]),

        Category("multicam", "Multicam", "rectangle.3.group", [
            Feature(
                "angles",
                "Multicam angles",
                """
                Sync several recordings of the same moment and cut between them as if they were one \
                camera. Angles can be grouped by timecode so a switch picks the right shot.
                """,
                tools: [.manageMulticam, .syncClips, .getMulticam, .changeCam]
            ),
        ]),

        Category("text", "Text and captions", "textformat", [
            Feature(
                "titles",
                "Titles and text",
                """
                Place a title, lower third or any text on a track above the picture. Set the type, \
                colour, outline and fill independently, and animate it in without keyframing by hand.
                """,
                tools: [.addTexts, .updateText]
            ),
            Feature(
                "captions",
                "Captions",
                """
                Caption what is actually said, or import an SRT. Captions can be shortened, capped \
                to a line length, profanity-filtered and restyled as a group rather than clip by clip. \
                For vertical delivery, pass the platform so the captions clear its interface.
                """,
                tools: [.addCaptions, .getTranscript, .removeWords]
            ),
            Feature(
                "silence",
                "Tightening pacing",
                """
                Find the pauses and dead air and close them, then set how tight you want the result. \
                Runs on the audio, so it needs no transcript.
                """,
                tools: [.removeSilence]
            ),
            Feature(
                "outro",
                "End credits and subscribe cards",
                """
                Build the end of the film in one step: a credits roll, a subscribe call to action, or \
                both. The roll handles its own off-screen entry and exit, and platform timing is \
                checked rather than assumed. Click targets are attached when you upload, not rendered.
                """,
                tools: [.addOutro]
            ),
            Feature(
                "poster",
                "Poster images",
                """
                Render a separate poster frame sized for the destination — landscape, vertical or \
                square — with an optional headline drawn onto it. It is a standalone image and never \
                touches the video.
                """,
                tools: [.generateThumbnail]
            ),
        ]),

        Category("colour", "Colour and effects", "camera.filters", [
            Feature(
                "grade",
                "Colour correction and grading",
                """
                Set exposure, contrast, colour temperature and tint, work in lift/gamma/gain or a \
                curve, and check the result on a video scope rather than by eye alone.
                """,
                tools: [.applyColor, .inspectColor]
            ),
            Feature(
                "presets",
                "Looks",
                """
                Start from a named look — documentary, cinematic, warm film, noir and others — then \
                adjust the individual clips that need to differ. A look is colour only, so it never \
                changes pacing or sound.
                """,
                tools: [.applyStylePreset]
            ),
            Feature(
                "effects",
                "Effects",
                """
                Blur, glow, vignette, grain and edge rounding, applied per clip with the same keyframe \
                control as anything else on the timeline.
                """,
                tools: [.applyEffect]
            ),
        ]),

        Category("delivery", "Delivering", "square.and.arrow.up", [
            Feature(
                "export",
                "Exporting",
                """
                Export video, a Final Cut XML or FCPXML timeline, or a copy of the project. Codec and \
                resolution are independent, and the export dialog reports the dimensions it will \
                actually produce. Bitrate follows the encoder and is not set by hand.
                """,
                tools: [.exportProject, .manageExports]
            ),
            Feature(
                "delivery",
                "Delivering for a platform",
                """
                Name the destination — YouTube, Shorts or Reels — and the export picks the codec and \
                size that upload expects, while captions and credits are placed to clear the same \
                platform's interface. A canvas facing the wrong way is reported rather than letterboxed.
                It combines the canvas and export features rather than adding tools of its own.
                """
            ),
            Feature(
                "proxies",
                "Proxies",
                """
                Build lightweight stand-ins for large sources so scrubbing and playback stay smooth. \
                They are preview-only: exports and audio analysis still read the original.
                """,
                tools: [.manageProxies]
            ),
        ]),

        Category("agent", "The agent", "sparkle", [
            Feature(
                "agent",
                "Editing by description",
                """
                Describe the change in plain language and it is applied to the timeline as one \
                undoable action — tightening a scene, restyling a sequence, building an outro. The \
                agent reads the timeline before it acts and reports what it changed.
                """,
                tools: [.getTimeline, .inspectTimeline, .inspectMedia]
            ),
            Feature(
                "plans",
                "Plans",
                """
                For a job with several parts, have it write the plan first. Read it, change it, and \
                apply it only once it matches what you meant.
                """,
                tools: [.planEdit, .applyPlan]
            ),
            Feature(
                "skills",
                "Skills",
                """
                Reusable playbooks for the work you do often, installed in Settings and shared with \
                the agent. Create your own from a finished timeline to capture how you edit.
                """,
                tools: [.manageSkills, .readSkill]
            ),
            Feature(
                "external",
                "Other agents",
                """
                Expose the same editing tools to Claude, Cursor, Codex or any MCP client over a local \
                server, so the edit can be described in the tool you already live in.
                """,
                tools: [.sendFeedback]
            ),
            Feature(
                "stock",
                "Stock footage",
                """
                Search free stock providers and pull results into the library with their licensing \
                terms attached. Needs a Pexels, Pixabay or Openverse key in Settings.
                """,
                tools: [.findStockMedia, .findShotCandidates]
            ),
            Feature(
                "organise",
                "Organising the library",
                """
                Rename, move, colour and delete media in bulk. Folders keep long shoots navigable once \
                the library outgrows a flat list.
                """,
                tools: [.organizeMedia]
            ),
        ]),
    ]
}