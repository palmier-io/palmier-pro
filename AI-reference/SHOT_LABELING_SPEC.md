# Shot-by-shot labeling spec (for the scraping / vision agent)

## Why
The app learns "how Malay wedding videos are usually sequenced" from real edited videos.
Today each reference video has only ~6 sampled labels (with repeats), which is too thin
to learn ordering. We need the **full edit timeline of each video**: one labeled record
per **shot** (per cut), in order, so we can reconstruct exactly how an editor sequenced it.

## What to produce
For each reference video, walk it start→finish and emit **one JSONL record per shot**
(a continuous take between two cuts). Highlight reels cut every ~2–6 s, so expect dozens
of shots per video. Detect cuts (scene/shot-boundary detection) or, if that's not
available, sample every ~2 s and merge identical adjacent samples into one shot.

Each shot must be **vision-verified** (look at a frame from the shot, don't guess from
the title).

## Append target
Append new records to:

```
References/MalayWedding/metadata/references_malay_wedding.jsonl
```

One JSON object per line. **Append only** — never rewrite existing lines.

## Record schema (per shot)
Match the existing rich schema so the data stays consistent:

```json
{
  "id": "<sourceVideoId>_<shotIndex>",
  "sourceVideoId": "0vP_PakG7_E",
  "sourceURL": "https://youtube.com/watch?v=0vP_PakG7_E",
  "sourcePlatform": "youtube",
  "channel": "Blastphere Ventures",
  "creatorName": "Blastphere Ventures",
  "title": "MALAY WEDDING | RISA and AZIM Reception",
  "duration": 249.1,
  "license": "youtube_standard",
  "permissionStatus": "usable_media",

  "primaryMoment": "venue_establishing",
  "momentTypes": ["venue_establishing"],
  "momentSequenceHint": 3,
  "timecodeStart": 124,
  "timecodeEnd": 130,

  "audioImportance": "replaceable",
  "preferredShotQualities": ["stable_camera", "clear_faces"],
  "avoidQualities": ["shaky_camera", "fast_panning", "overexposed"],
  "culturalNotes": "Venue establishing shot. Ballroom with lights and greenery. Scene: a musical performance on a decorated stage.",

  "labelConfidence": 0.92,
  "visualVerificationMethod": "gemini_vision"
}
```

Field rules:
- **`id`** — `"<sourceVideoId>_<shotIndex>"`, shotIndex starting at 0 per video. Must be unique.
- **`momentSequenceHint`** — the shot's **0-based position in the edit** (0 = first shot, 1 = second…). This is the ordering signal; it must be monotonic per video.
- **`timecodeStart` / `timecodeEnd`** — the shot's seconds within the source video (the cut points). Used for clip length / pacing.
- **`primaryMoment`** — the single best moment label for the shot (see taxonomy below).
- **`momentTypes`** — usually `[primaryMoment]`; add more only if a shot genuinely spans two.
- **`audioImportance`** — one of `crucial` (vows/speech/recitation — must be heard),
  `replaceable` (music can sit over it), `ambient` (room tone, not important).
- **`preferredShotQualities` / `avoidQualities`** — what makes this kind of shot good/bad.
- **`labelConfidence`** — 0–1; only emit shots at **≥ 0.7** (the pack later keeps ≥ 0.8).
- **`visualVerificationMethod`** — `gemini_vision` (or whatever model verified it).

## Open taxonomy — THIS IS IMPORTANT
The current moment list is **incomplete**. You will hit many scenes it doesn't cover
(e.g. `outdoor_shoot`, `pelamin_shoot`, `sarung_cincin`, `bunga_telur`, `kompang`,
`merenjis`, `tepung_tawar`, `cake_cutting`, `first_dance`, `bridal_march`). Do **not**
force these into an existing label.

Rule:
1. If a shot clearly matches an existing moment, use it.
2. If it doesn't, **create a new `snake_case` moment type** and use it.
3. Every new moment type you introduce must also be added to the taxonomy file
   `AI-reference/taxonomy_malay_wedding.json` under `momentCategories`, assigned to one of:
   `scene`, `preparation`, `ceremony`, `family`, `celebration`. (If unsure, put it in the
   closest stage; it can be re-categorized by hand later.)

Existing 15 moments (use these names when they fit):
```
akad_nikah, ring_exchange, bride_prep, groom_prep, hantaran_detail, salam_family,
family_portrait, guest_reaction, couple_portrait, venue_establishing, decor_detail,
pelamin, reception, makan_beradab, exit_or_closing
```

## Idempotency
- Before labeling a video, check whether its `sourceVideoId` already has shot-level records
  (records whose `id` is `<sourceVideoId>_<n>`). If yes, skip it — don't duplicate.
- The old sparse records can stay; the denser shot records supersede them at build time
  (the build script prefers shot-level data when present).

## After labeling
The app does **not** read this file directly. When a batch is done, the curated data is
copied into `AI-reference/` and `python scripts/build_domain_pack.py` regenerates the
bundled pack (which then learns ordering from the reconstructed timelines). Keep the
schema above exact so that step stays clean.
```
