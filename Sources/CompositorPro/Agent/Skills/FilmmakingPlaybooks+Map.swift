import Foundation

extension FilmmakingPlaybooks {
    static let mapExplainer = PlaybookDefinition(
        id: "map-explainer-playbook", name: "Animated Map Explainer Playbook",
        description: "Narrated geography Shorts: relief maps, region/flag fills, camera flights, distance arcs, typography and five reference storytelling patterns.",
        content: """
        # Animated Map Explainer Playbook

        ## Story structure and reference patterns
        Choose the structure that explains this topic; do not apply every effect to every film.
        - Same Name, 10,000 Kilometers Apart (o5PJaIjbIMs, 57s): comparison hook, distant locators,
          flag-filled silhouettes, a distance arc and a historical/naming twist. Intercontinental
          flights orient each reveal. Wine/crown illustrations give the history a concrete visual.
        - Asia regions (NO20UYpSdCI, 103s): a persistent color per region, wide classification view,
          then close views with country labels, demographic symbols, comparison and compass cues.
          Define the grouping convention; political, geographic and cultural regions differ.
        - Darien Gap (tT-BzWbyqkw, 60s): danger hook, locate the corridor, red/glowing custom polygon,
          interrupted road and directional arrows, then jungle, heat/rain, people and hazards.
        - Malaysia geography (PImrCxx6ZJU, 57s): split mainland/island geography, separate land-mass
          fills, an annotated sea separation, then rainforest/biodiversity, mountains and coastline.
        - Australia geography (Rc40jDjW2Cw, 28s): rapid subdivision fills and name reveals, a dominant
          interior statistic, then people concentrated around named coastal cities and a close view.
        References are editorial examples, not evidence. Independently verify names, classifications,
        quantities and dates. In particular Northern Territory is a territory; the Australia clip's
        classification is wrong. Do not repeat unverified Malaysia species/forest/coastline claims.

        ## Native tool workflow
        1. Read get_timeline/get_media and get_capabilities. Use 1080x1920 at the timeline fps for a
           Shorts brief. Keep existing edits when generating additions; present the sourced storyboard
           and narrator intent through the app's normal storyboard review before full production.
        2. Search list_map_regions. Use country:GEO and subdivision:US-GA to disambiguate Georgia.
           Query country:MYS and inspect numbered components for Peninsular/East Malaysia. Use
           componentIndices for individual land masses; never invent a component index or boundary.
           Subdivisions are available only where the bundled atlas supplies them. Detailed corridors,
           deserts and cultural groupings need independently sourced, closed [longitude,latitude]
           polygons or multiple exact atlas regions; custom labels alone do not create geography.
        3. Build a beat sheet with one spoken idea, geographic target, camera action, region/route,
           text cue, object/effect and evidence source per beat. Prepare narration with the approved
           voice, then use its measured word/beat timing. Every map frame uses the scene fps:
           floor(seconds * fps). start/reveal frames are inclusive; endFrame is exclusive.
        4. Call build_map_scene with places, regions, camera, connections, objects and texts. Use
           showPin:false/showLabel:false on place anchors when the country fill or title already
           labels the area. Regions can use opacity, color, pulse, imageMediaRef and timed windows.
           For repeated highlights of one region give each event a distinct id. Imported flag/still
           image fills are masked to its outline. Verify rights and source geography independently.
        5. Camera keys use a place or explicit latitude/longitude, zoom 0.05...128, rotation -180...180,
           tilt 0...60. Easing on the incoming key controls interpolation: easeInOut, easeOut, linear,
           or hold for a cut. Establish wide geography before a close view; use a move to explain a
           change in location, scale or relationship. The renderer is an equirectangular plane;
           tilt is simulated. It does not render a globe or supply navigational measurements.
        6. Routes connect declared place names/IDs. Give id for moving objects, revealFrame,
           revealFrames (0 for instant, otherwise up to 120), endFrame, color, width and optional
           label. Use arc (-1...1) for a quadratic curve OR via coordinates for a road/sea corridor.
           distanceLabel shows an approximate spherical endpoint distance, never a measured road
           or shipping distance. Illustrative is the default; sourced requires actual claimIds.
        7. Use bold short text cues rather than paragraphs: x/y are normalized screen coordinates
           (top-left origin) or place attaches to geography. fontSize is in output pixels. Entrance
           may be none, fade, pop, slide, typewriter. Keep safe margins: titles around y=0.12...0.2,
           avoid the rightmost 15% and bottom 20% occupied by Shorts controls/captions. Caption tools
           provide synchronized spoken phrases separately. Numeric/source cards use build_graphic_scene.
        8. addToTimeline publishes library media and optional placement in one undo action. Output
           is silent H.264; source frames may differ from timeline frames (placement rounds down to
           complete timeline frames). Prefer scene fps equal to timeline fps. Identical retries reuse
           bytes and matching placement. Read read_map_scene's spec.input to revise the authored
           scene; regenerate and explicitly replace/trim the intended clip for a revision.
        9. Inspect the encoded video at the hook, each reveal, route midpoint/arrival and ending.
           Check labels, camera continuity, north-up image registration, region/color continuity,
           safe margins and audio sync. Finish through mix_audio, qc_timeline, review_timeline and
           export_project/manage_exports. Stills do not certify motion or voice intelligibility.
        """
    )

    static let mapObjectChoreography = PlaybookDefinition(
        id: "map-object-choreography-playbook", name: "Map Objects, Trade & Effects Playbook",
        description: "Stage ships, packages, trade flows, vehicles, people, gunfire and weather along geographic routes with timed entrances, arrivals and effects.",
        content: """
        # Map Objects, Trade & Effects Playbook

        ## Spatial and timing contract
        build_map_scene.objects supports ship, airplane, truck, train, package, person, factory,
        money, tank, arrow, pin, circle, gunfire, explosion, heat, rain, image and flag. Built-in
        symbols are local vector artwork; image/flag require a ready imageMediaRef from the library.
        Use a transparent imported image for subjects absent from the symbol set (wildlife, minerals,
        crops, crates, weapons, logos). Verify its appearance and rights before use.
        Each object needs a unique id and exactly one geographic anchor (place OR latitude/longitude),
        routeId, or waypoint path. It appears on [startFrame,endFrame). Size is 8...320 screen pixels;
        it stays geographically attached while the camera moves. Labels stay readable and upright.
        rotateToPath rotates the object along the transformed route tangent; use it for aircraft,
        trucks or arrows, and omit it for upright ships/people/packages. rotation supplies a fixed
        screen angle or a tangent offset, useful for arrows/custom sprites. Choose linear easing for
        transport and easeOut for arrivals. Effects are deterministic at any sampled frame.

        ## Motion recipes
        - Shipping/trade: declare port place anchors and a route with an ocean-safe via path or arc.
          Show the route first, then a ship moving from origin to destination. Use package objects
          with staggered start/end windows to explain cargo volume; loopCount 1...16 repeats route
          traversal. Keep units and observed volume independent of illustrative icon counts.
        - Supply chain: factories remain anchored; trucks/packages traverse separate factory-port,
          sea and port-customer routes. End the arrival at endFrame-1 and reveal the next transfer
          on that frame or the next. Give each transfer/object a stable distinct id.
        - Timed waypoints: use 2...128 strictly increasing frames within the object's visible window,
          each with a place or coordinates. These are geographic positions at those exact frames.
          The object waits before the first key and after the last key; timed waypoints cannot loop.
          Extend/repeat the keys explicitly when a timed path should repeat.
        - Conflict/hazards: anchor a tank or a supplied illustration, then place a short gunfire
          window at the muzzle/target coordinate and an explosion at impact. Align a separate SFX
          clip with the first visible burst or impact. Clearly distinguish a diagram from recorded
          footage; do not imply a specific unverified event, position, target, or casualty count.
        - Weather/terrain: heat and rain are timed graphic effects at an anchor or moving path.
          Use small repeated anchors for a wider area and a polygon fill for geographic extent.
        - Population/economy: reveal person, factory and money symbols in clusters near verified
          locations. Icons are illustrative unless an explicit sourced legend defines their units.

        ## Readability and proof
        Limit simultaneously moving subjects so the narrator's current claim remains dominant.
        Separate decorative effects from geographic evidence. SFX and graphic gunfire are separate
        assets: map rendering synthesizes no audio. Use one consistent palette and object scale.
        Inspect start, midpoint, arrival and the frame after endFrame; check tangent rotations and
        effects when the camera is also moving. Read the persisted spec with read_map_scene and
        verify actual timeline placement before declaring completion. Undo restores the entire intent.
        """
    )

    static let mapNarration = PlaybookDefinition(
        id: "map-narration-playbook", name: "Map Narration & Synchronization Playbook",
        description: "Confident factual narration, available local neural voices, measured beat timing, phrase captions and dialogue-first finishing for map explainers.",
        content: """
        # Map Narration & Synchronization Playbook

        ## Delivery
        References use continuous assertive narration: a short curiosity/danger/comparison hook,
        compact explanatory sentences, emphasis on names/numbers, brief pauses before a reveal,
        and a closing fact or twist. Write original narration in this cadence. Similar energy does
        not require copying wording or impersonating the reference narrator. No voice match is
        certified without auditioning the actual output.
        List available voices with list_speech_voices; do not invent voice identifiers or silently
        replace the approved narrator. When present, an installed high-quality Piper English voice
        is a useful neural starting point; engine:system explicitly selects installed macOS voices.
        Audition a short hook with the selected engine/voice before producing the full narration.
        Use punctuation, questions, paragraph/line breaks, and rate around 1.0...1.15 for expressive
        pacing. Pitch 1.0 preserves the voice's natural character. Faster is not automatically stronger.
        For a managed plan use its pinned narrationIntent and prepare_narration after storyboard
        approval. generate_speech is available for standalone voice assets/auditions; preserve the
        engine, voice, language, rate and pitch in the approved intent.

        ## Synchronization
        Actual synthesized or recorded duration is authoritative. Use get_transcript/managed
        narrationTiming to obtain measured word/beat times; never label estimated script timings
        as measured. If alignment is unavailable, resolve its stated blocker before final delivery.
        Convert measured seconds into map frames at the scene fps; subtract the scene's narration
        offset first. Schedule the location/region reveal at the phrase that names it, the route
        reveal before the object departs, arrival/impact at the explanatory word, and the camera
        settle just before the next fact. Allow short reading holds for complex names/numbers.
        Make phrase captions with add_captions using the approved style and actual transcript.
        Bold headline text and captions have separate purposes; avoid obscuring the same map target.
        Add music/ambience and local/imported SFX only when they support the brief. Assign all audio
        clips to voice, music, ambience or effects in mix_audio. A useful short-form starting target
        is -16 LUFS with true peak <= -1 dBTP; the summed measured delivery governs the final mix.
        Duck under measured speech, preserve manual automation, and synchronize transient effects.
        Inspect review_timeline and audition the rendered hook, dense geographic sequence and ending.
        Listen for name pronunciation, harshness, buried words, clipped effects and abrupt tails.
        A transcript or loudness meter cannot establish a strong, intelligible voice performance.
        """
    )
}
