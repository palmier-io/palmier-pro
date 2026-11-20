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
        /// Localized key for a concrete request that would produce this, phrased the way a person
        /// would actually ask for it.
        var howTo: String
        /// Tools that implement this. Empty for anything in the interface rather than a tool, and
        /// for workflows that combine tools documented elsewhere.
        var tools: [ToolName]

        /// Takes keys already resolved by `L10n.key`, so each literal sits at the call site where
        /// the localization extractor can read it.
        init(
            _ id: String,
            _ title: String,
            _ summary: String,
            _ howTo: String,
            tools: [ToolName] = []
        ) {
            self.id = id
            self.title = title
            self.summary = summary
            self.howTo = howTo
            self.tools = tools
        }
    }

    struct Category: Identifiable, Sendable, Equatable {
        var id: String
        var title: String
        var icon: String
        var features: [Feature]

        init(_ id: String, _ title: String, _ icon: String, _ features: [Feature]) {
            self.id = id
            self.title = title
            self.icon = icon
            self.features = features
        }
    }

    static let categories: [Category] = [
        Category("start", L10n.key("Getting started"), "sparkles", [
            Feature(
                "project",
                L10n.key("Projects and timelines"),
                L10n.key("""
                A project holds its media and can hold more than one timeline. Duplicate a timeline \
                to try a different cut or build a vertical version without disturbing the original, \
                then switch between them by name.
                """),
                L10n.key("""
                Add a 9:16 version of this timeline called Vertical, and leave the original alone.
                """),
                tools: [.manageProject, .createTimeline, .setActiveTimeline]
            ),
            Feature(
                "canvas",
                L10n.key("Canvas and frame rate"),
                L10n.key("""
                Set the frame size, aspect ratio and rate in project settings. Changing the canvas \
                re-fits the existing clips rather than cropping them, so a landscape edit can become \
                a vertical one and still be usable.
                """),
                L10n.key("""
                Set the canvas to 9:16 at 30fps.
                """),
                tools: [.setProjectSettings]
            ),
            Feature(
                "import",
                L10n.key("Importing media"),
                L10n.key("""
                Bring in video, audio and stills. Missing files stay linked by name, so moving the \
                project or the drive does not break the edit — relink and it picks up where it left off.
                """),
                L10n.key("""
                Bring in everything in ~/Footage into the library, filed under a folder called Trip.
                """),
                tools: [.importMedia, .getMedia, .searchMedia]
            ),
            Feature(
                "tracks",
                L10n.key("Tracks"),
                L10n.key("""
                Add, rename, reorder, mute and hide tracks. Reordering changes the stacking order, \
                so a track moved up is what now renders on top. Hiding is the quick way to check \
                what a graphic is actually sitting on.
                """),
                L10n.key("""
                Add a second video track above the picture and call it Graphics.
                """),
                tools: [.manageTracks]
            ),
            Feature(
                "placing",
                L10n.key("Placing media on the timeline"),
                L10n.key("""
                Put a library asset on a track at a chosen frame, for a chosen length. Placement \
                resolves what it must — a still needs a display length rather than a source range, \
                and it trims or ripples what it displaces rather than overwriting it. This is the \
                operation behind cut, paste and drag.
                """),
                L10n.key("""
                Put that still on the timeline for four seconds, from frame 120.
                """),
                tools: [.addClips]
            ),
            Feature(
                "marks",
                L10n.key("Markers and review notes"),
                L10n.key("""
                Drop point and range markers on the timeline to hold a note about a frame or a range. \
                They persist with the project and give the agent something concrete to aim at.
                """),
                L10n.key("""
                Drop a marker at frame 420 that says "pick a better take here".
                """),
                tools: [.manageMarkers]
            ),
        ]),

        Category("edit", L10n.key("Editing"), "scissors", [
            Feature(
                "trim",
                L10n.key("Trimming and ripple edits"),
                L10n.key("""
                Shorten a clip and let the rest close up, or leave a gap. Removing a range with \
                ripple shifts everything after it and is one undo step, so a restructure never \
                becomes a cascade of small corrections.
                """),
                L10n.key("""
                Tighten this sequence — cut every pause longer than half a second.
                """),
                tools: [.rippleDeleteRanges, .removeClips, .setClipProperties]
            ),
            Feature(
                "split",
                L10n.key("Splitting and moving"),
                L10n.key("""
                Cut a clip at a frame, then move, insert or swap what sits where. Swapping media \
                keeps the timing, so a better take drops into an existing cut without re-timing it.
                """),
                L10n.key("""
                Cut at every marker, then remove the clips between them.
                """),
                tools: [.splitClips, .moveClips, .insertClips, .swapClipMedia]
            ),
            Feature(
                "transitions",
                L10n.key("Transitions"),
                L10n.key("""
                Cross dissolves, dips to black and the rest apply between neighbouring clips. The \
                timeline shows them and they follow the clips they sit between, so trimming the cut \
                takes the transition with it.
                """),
                L10n.key("""
                Cross dissolve between the two shots here, 20 frames.
                """),
                tools: [.applyTransition, .removeTransition]
            ),
            Feature(
                "speed",
                L10n.key("Speed and ramps"),
                L10n.key("""
                Change playback rate, or ramp it — a slow push-in, a whip pan, a drift back to real \
                time. A ramp holds its start and end, and time-based effects follow the retimed clip.
                """),
                L10n.key("""
                Ramp this clip from normal speed down to a quarter speed over the last second.
                """),
                tools: [.setClipSpeedRamp]
            ),
            Feature(
                "freeze",
                L10n.key("Freeze frames"),
                L10n.key("""
                Hold one frame for as long as you need. The picture stops while the audio underneath \
                keeps playing, which is what makes it usable over speech.
                """),
                L10n.key("""
                Hold the frame just before the jump for 12 frames.
                """),
                tools: [.freezeClip]
            ),
            Feature(
                "links",
                L10n.key("Linking picture and sound"),
                L10n.key("""
                Keep a clip's picture and its audio locked together so they move as one, or split \
                them when the sound should run independently. A linked pair is what makes a \
                J-cut or an L-cut possible; an unlinked one is what lets a different take replace \
                the picture without touching the sound.
                """),
                L10n.key("""
                Unlink the audio on this clip — I want to swap the picture and keep the sound.
                """),
                tools: [.manageClipLinks]
            ),
            Feature(
                "copySettings",
                L10n.key("Copying a look across clips"),
                L10n.key("""
                Take one clip's grade, effects and crop and apply them to others, so a sequence \
                matches without re-entering the numbers per shot. Paste onto a selection, or onto \
                every clip in a track when the whole scene should agree.
                """),
                L10n.key("""
                Copy the grade from this clip onto the rest of the track.
                """),
                tools: [.copyClipSettings]
            ),
            Feature(
                "keys",
                L10n.key("Keyframes"),
                L10n.key("""
                Animate position, scale, rotation, opacity, crop or volume over a clip's length. The \
                editor holds the curve and the renderer obeys it in preview and on export alike.
                """),
                L10n.key("""
                Fade this title up over 20 frames as it drifts slightly upward.
                """),
                tools: [.setKeyframes]
            ),
            Feature(
                "layout",
                L10n.key("Layouts and framing"),
                L10n.key("""
                Split, picture-in-picture, side-by-side and stacked grids, with the framing chosen \
                per shot. This is the reliable way to reframe a shot for a new canvas.
                """),
                L10n.key("""
                Put the talking head on the left and the demo on the right, both half width.
                """),
                tools: [.applyLayout]
            ),
            Feature(
                "qc",
                L10n.key("Checking a cut"),
                L10n.key("""
                Audit the timeline for missing media, overlaps, gaps, hard audio joins and stale \
                transitions, and get the frame numbers to act on. Read-only: it reports, it does \
                not change the cut.
                """),
                L10n.key("""
                Check this cut and tell me what needs fixing before I export.
                """),
                tools: [.qcTimeline]
            ),
            Feature(
                "undo",
                L10n.key("Undo"),
                L10n.key("""
                Every edit here is a single step, not a pile of small ones. Undo puts the timeline \
                back exactly as it was, including retimed and restructured clips.
                """),
                L10n.key("""
                Undo the last edit and tell me what it undid.
                """),
                tools: [.undo]
            ),
        ]),

        Category("audio", L10n.key("Audio"), "waveform", [
            Feature(
                "levels",
                L10n.key("Levels and fades"),
                L10n.key("""
                Set clip gain and fades, and match loudness across clips that were recorded under \
                different conditions. The meter reflects what will actually be heard.
                """),
                L10n.key("""
                Even out the loudness across the interview clips.
                """),
                tools: [.matchLoudness]
            ),
            Feature(
                "duck",
                L10n.key("Ducking music under speech"),
                L10n.key("""
                Lower the music exactly where someone is talking and bring it back afterwards, with \
                an adjustable depth and a tail that keeps the music from pumping between words.
                """),
                L10n.key("""
                Duck the music under the speech in this scene.
                """),
                tools: [.duckAudio]
            ),
            Feature(
                "crossfade",
                L10n.key("Crossfades"),
                L10n.key("""
                Blend the end of one clip into the start of the next. Equal-power fades hold a \
                constant loudness through the overlap, which linear fades do not.
                """),
                L10n.key("""
                Crossfade the end of this clip into the start of the next over 24 frames.
                """),
                tools: [.crossfadeAudio]
            ),
            Feature(
                "jl",
                L10n.key("J-cuts and L-cuts"),
                L10n.key("""
                Let the next scene's sound start before its picture, or hold the current scene's \
                sound past its picture. One setting on a linked pair, and both sides still overlap.
                """),
                L10n.key("""
                Let the next scene start talking a second before we see it.
                """),
                tools: [.offsetAudio]
            ),
            Feature(
                "clean",
                L10n.key("Cleaning up dialogue"),
                L10n.key("""
                Reduce steady background noise, soften breaths, and even out level. These run in the \
                packaged app; a command-line build needs the bundled speech models enabled.
                """),
                L10n.key("""
                Clean up the dialogue on this clip — noise, breaths, and level.
                """),
                tools: [.denoiseAudio, .debreatheAudio, .enhanceVoice]
            ),
            Feature(
                "rhythm",
                L10n.key("Beats and cutting to music"),
                L10n.key("""
                Detect the beat grid, then place cuts and effects on it. Downbeats carry the \
                structure; cutting on every beat reads mechanical, so keep the accents sparse.
                """),
                L10n.key("""
                Cut this montage on the downbeats, but only on the first beat of each bar.
                """),
                tools: [.detectBeats, .syncToBeats]
            ),
            Feature(
                "drone",
                L10n.key("Drone beds"),
                L10n.key("""
                Generate a sustained tone to sit under a scene. Useful as a bed, or to hold a gap \
                while you decide what should be there.
                """),
                L10n.key("""
                Put a low drone under this gap.
                """),
                tools: [.generateDrone]
            ),
            Feature(
                "speech",
                L10n.key("Speech synthesis"),
                L10n.key("""
                Turn text into a line of narration. The packaged app uses a local voice when one is \
                installed and falls back to the system voice, and the result lands on the timeline \
                as a normal audio clip you can grade and time like any other.
                """),
                L10n.key("""
                Generate a line of narration reading this script, and time it to the picture.
                """),
                tools: [.generateSpeech, .listSpeechVoices]
            ),
        ]),

        Category("multicam", L10n.key("Multicam"), "rectangle.3.group", [
            Feature(
                "angles",
                L10n.key("Multicam angles"),
                L10n.key("""
                Sync several recordings of the same moment and cut between them as if they were one \
                camera. Angles can be grouped by timecode so a switch picks the right shot.
                """),
                L10n.key("""
                Set up these four recordings as multicam and switch angles on the wide shot.
                """),
                tools: [.manageMulticam, .syncClips, .getMulticam, .changeCam]
            ),
        ]),

        Category("text", L10n.key("Text and captions"), "textformat", [
            Feature(
                "titles",
                L10n.key("Titles and text"),
                L10n.key("""
                Place a title, lower third or any text on a track above the picture. Set the type, \
                colour, outline and fill independently, and animate it in without keyframing by hand.
                """),
                L10n.key("""
                Add a title card that says the film name.
                """),
                tools: [.addTexts, .updateText]
            ),
            Feature(
                "captions",
                L10n.key("Captions"),
                L10n.key("""
                Caption what is actually said, or import an SRT. Captions can be shortened, capped \
                to a line length, profanity-filtered and restyled as a group rather than clip by clip. \
                For vertical delivery, pass the platform so the captions clear its interface.
                """),
                L10n.key("""
                Caption this interview, and keep the captions clear of the Reels interface.
                """),
                tools: [.addCaptions, .getTranscript, .removeWords]
            ),
            Feature(
                "silence",
                L10n.key("Tightening pacing"),
                L10n.key("""
                Find the pauses and dead air and close them, then set how tight you want the result. \
                Runs on the audio, so it needs no transcript.
                """),
                L10n.key("""
                Tighten the pacing in this interview, a little tighter than the default.
                """),
                tools: [.removeSilence]
            ),
            Feature(
                "textStyle",
                L10n.key("Type styles"),
                L10n.key("""
                Restyle a whole family of text at once with a named style, so the decisions that \
                should not vary stop varying: font, weight, size, tracking, case, alignment and \
                the legibility treatment. Eight styles are available, each using a bundled face. \
                Sizes are a fraction of the canvas height, so one style reads the same on a \
                landscape frame and a vertical export — there is no separate vertical style. \
                Restyling a caption track by its group is one undo step, not one per line.
                """),
                L10n.key("""
                Give these captions the caption style.
                """),
                tools: [.applyTextStyle]
            ),
            Feature(
                "outro",
                L10n.key("End credits and subscribe cards"),
                L10n.key("""
                Build the end of the film in one step: a credits roll, a subscribe call to action, or \
                both. The roll handles its own off-screen entry and exit, and platform timing is \
                checked rather than assumed. Click targets are attached when you upload, not rendered.
                """),
                L10n.key("""
                Add end credits for the crew and a subscribe card for Shorts.
                """),
                tools: [.addOutro]
            ),
            Feature(
                "poster",
                L10n.key("Poster images"),
                L10n.key("""
                Render a separate poster frame sized for the destination — landscape, vertical or \
                square — with an optional headline drawn onto it. It is a standalone image and never \
                touches the video.
                """),
                L10n.key("""
                Make a vertical poster frame for this video, with "Summer" as the headline.
                """),
                tools: [.generateThumbnail]
            ),
        ]),

        Category("images", L10n.key("Images"), "photo.on.rectangle", [
            Feature(
                "cutout",
                L10n.key("Cutting a subject out"),
                L10n.key("""
                Lift a subject off its background and keep the result transparent, so it can be \
                placed over anything. Runs entirely on this machine: no model is downloaded and \
                nothing leaves the device. Leave the background transparent by default; flattening \
                onto a colour is for a product shot on white. This is subject segmentation rather \
                than a matting network, so hair and fine edges are rough. For a green screen or a \
                flat chroma background, the chroma key effect is far more reliable.
                """),
                L10n.key("""
                Cut the person out of this photo and keep the background transparent.
                """),
                tools: [.removeImageBackground]
            ),
            Feature(
                "compose",
                L10n.key("Composed images"),
                L10n.key("""
                Build one image out of several of your own frames and stills: a mood board, a \
                contact sheet, a poster frame, a title card. This assembles real pictures from the \
                edit rather than inventing any, so give it a query and the visual index will find \
                the shots that match. A grid suits contact sheets, a hero-and-strip suits posters. \
                The lettering is identical to a thumbnail's. The result is a normal library asset.
                """),
                L10n.key("""
                Find the shots of the sea at sunset and make me a mood board from them.
                """),
                tools: [.composeImage]
            ),
            Feature(
                "captureFrame",
                L10n.key("Grabbing a frame"),
                L10n.key("""
                Save any frame as an image in the library — a shot you want to title, grade or use \
                as a reference. Can come from the composed timeline or from a source clip at a \
                specific time, and the saved frame is indexed for search like any other image.
                """),
                L10n.key("""
                Save the current frame as an image called Cover.
                """),
                tools: [.captureFrame]
            ),
        ]),

        Category("colour", L10n.key("Colour and effects"), "camera.filters", [
            Feature(
                "grade",
                L10n.key("Colour correction and grading"),
                L10n.key("""
                Set exposure, contrast, colour temperature and tint, work in lift/gamma/gain or a \
                curve, and check the result on a video scope rather than by eye alone.
                """),
                L10n.key("""
                Warm this up and lift the shadows.
                """),
                tools: [.applyColor, .inspectColor]
            ),
            Feature(
                "presets",
                L10n.key("Looks"),
                L10n.key("""
                Start from a named look — documentary, cinematic, warm film, noir and others — then \
                adjust the individual clips that need to differ. A look is colour only, so it never \
                changes pacing or sound.
                """),
                L10n.key("""
                Give this whole sequence a cinematic look.
                """),
                tools: [.applyStylePreset]
            ),
            Feature(
                "effects",
                L10n.key("Effects"),
                L10n.key("""
                Blur, glow, vignette, grain and edge rounding, applied per clip with the same keyframe \
                control as anything else on the timeline.
                """),
                L10n.key("""
                Add a soft glow to this clip.
                """),
                tools: [.applyEffect]
            ),
        ]),

        Category("delivery", L10n.key("Delivering"), "square.and.arrow.up", [
            Feature(
                "export",
                L10n.key("Exporting"),
                L10n.key("""
                Export video, a Final Cut XML or FCPXML timeline, or a copy of the project. Codec and \
                resolution are independent, and the export dialog reports the dimensions it will \
                actually produce. Bitrate follows the encoder and is not set by hand.
                """),
                L10n.key("""
                Export this as H.264 1080p.
                """),
                tools: [.exportProject, .manageExports]
            ),
            Feature(
                "delivery",
                L10n.key("Delivering for a platform"),
                L10n.key("""
                Name the destination — YouTube, Shorts or Reels — and the export picks the codec and \
                size that upload expects, while captions and credits are placed to clear the same \
                platform's interface. A canvas facing the wrong way is reported rather than letterboxed.
                It combines the canvas and export features rather than adding tools of its own.
                """),
                L10n.key("""
                Export this for Shorts.
                """),
            ),
            Feature(
                "proxies",
                L10n.key("Proxies"),
                L10n.key("""
                Build lightweight stand-ins for large sources so scrubbing and playback stay \
                smooth. They are preview-only: exports and audio analysis still read the original.
                """),
                L10n.key("""
                Build proxies for the 4K clips so scrubbing is smooth.
                """),
                tools: [.manageProxies]
            ),
        ]),

        Category("agent", L10n.key("The agent"), "sparkle", [
            Feature(
                "agent",
                L10n.key("Editing by description"),
                L10n.key("""
                Describe the change in plain language and it is applied to the timeline as one \
                undoable action — tightening a scene, restyling a sequence, building an outro. The \
                agent reads the timeline before it acts and reports what it changed.
                """),
                L10n.key("""
                Cut this down to 90 seconds, keep the best line from each section.
                """),
                tools: [.getTimeline, .inspectTimeline, .inspectMedia]
            ),
            Feature(
                "plans",
                L10n.key("Plans"),
                L10n.key("""
                For a job with several parts, have it write the plan first. Read it, change it, and \
                apply it only once it matches what you meant.
                """),
                L10n.key("""
                Plan out a three-part edit for this documentary, then show me the plan.
                """),
                tools: [.planEdit, .applyPlan]
            ),
            Feature(
                "skills",
                L10n.key("Skills"),
                L10n.key("""
                Reusable playbooks for the work you do often, installed in Settings and shared with \
                the agent. Create your own from a finished timeline to capture how you edit.
                """),
                L10n.key("""
                Create a skill from this edit so I can reuse how I cut it.
                """),
                tools: [.manageSkills, .readSkill]
            ),
            Feature(
                "external",
                L10n.key("Other agents"),
                L10n.key("""
                Expose the same editing tools to Claude, Cursor, Codex or any MCP client over a local \
                server, so the edit can be described in the tool you already live in.
                """),
                L10n.key("""
                What do I need to connect my own agent to this?
                """),
                tools: [.sendFeedback]
            ),
            Feature(
                "stock",
                L10n.key("Stock footage"),
                L10n.key("""
                Search free stock providers and pull results into the library with their licensing \
                terms attached. Needs a Pexels, Pixabay or Openverse key in Settings.
                """),
                L10n.key("""
                Find some stock footage of a lighthouse on a stormy coast.
                """),
                tools: [.findStockMedia, .findShotCandidates]
            ),
            Feature(
                "organise",
                L10n.key("Organising the library"),
                L10n.key("""
                Rename, move, colour and delete media in bulk. Folders keep long shoots navigable once \
                the library outgrows a flat list.
                """),
                L10n.key("""
                Put all the raw files into a folder called Raw and delete the duplicates.
                """),
                tools: [.organizeMedia]
            ),
        ]),
    ]
}