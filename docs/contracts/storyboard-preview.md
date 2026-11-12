# Sequential storyboard preview

Storyboard review can render a low-resolution animatic without editing the live
timeline, importing media, approving production, or adding undo entries.

## Supported cut

- Authored scenes and their shared resolved ranges must be consecutive from
  frame zero. Gaps, overlaps, reordered timing, and empty boards are refused.
- Still images and ordinary opaque video use the shared source-range resolver,
  editor fitting operation, composition builder, and compositor.
- Without measured narration, the preview is silent and labeled estimated.
- With measured narration, every scene must have current resolved timing. The
  measured source fingerprint and full audio/visual frame coverage must match.
- Canvas geometry stays in the plan's coordinate space. Output is at most
  1024 pixels on its longest edge, with encoder-safe even dimensions.
- Maximum duration is 30 minutes. Semantic graphics, nested timelines, alpha
  video, and partially measured narration are not silently substituted.

## Ownership and freshness

`StoryboardPreviewSnapshot` derives an immutable request from the current
plan, manifest, shared storyboard report, source URLs, and fitted transforms.
Its request key covers authored intent, resolved timing, geometry, identity
metadata, and measured/silent mode. The renderer verifies actual source bytes;
its output key also pins any source identity missing from the manifest.

`StoryboardPreviewService` permits one render at a time. Filesystem work,
hashing, image preparation, AVFoundation setup, export, and disposal execute
off the main actor. The service verifies actual source durations, source-span
insertion, exact target coverage, encoded tracks, and source bytes again after
export. Source-timescale quantization follows the shared composition operation,
not a separate storyboard calculation.

Each render owns its temporary still proxies and disposes them after export,
including failure or cancellation. The resulting MP4 belongs to the review
controller until replacement, cancellation, dismissal, or teardown. Neither
the preview nor its temporary files become project-package content.

`StoryboardPreviewController` owns the current task, cancellation generation,
player, and output. Identical in-flight editor requests share one operation.
Replacement waits for earlier work and cleanup. Stale completion cannot
publish after plan, timeline, package URL, selected source, source fitting,
availability, or selection changes.

## Review boundary

This animatic does not grant approval or record source inspection. A shortened
preview, source thumbnail, or successful render is not evidence of complete
face, rights, factual, or final-framing coverage. Production still requires the
persisted approval and source-review gates. Preview is currently a native
storyboard surface, not an MCP production command.

## Manual verification

Use an isolated development project; preserve the installed signed app.

1. Add two distinct stills and a video with a selected source span. Open the
   storyboard and choose **Preview Storyboard**. Play continuously, scrub, and
   verify scene order, fitting, selected span, duration, and silence.
2. Measure narration covering the same cut. Preview again; verify full playback
   with sound, scene timing, first/last frames, and no missing narration tail.
3. Change a scene, source URL, source geometry, or active timeline while
   preparing. No stale result should appear. Preview the current board again.
4. Cancel, replace, dismiss with Escape, close the document, and repeat. Check
   focus, native transport controls, disabled state, missing media, and no
   leftover owned outputs. Save As must invalidate the old package context.
5. Inspect live timeline, undo history, and approval before/after preview. All
   must remain unchanged. Empty, gapped, overlapping, unsupported, stale-timing,
   or unavailable inputs must explain refusal rather than produce a partial cut.

Human continuous playback, native UI/lifecycle verification, provider narration,
and representative long-form responsiveness remain separate release checks.
