# Media processing and performance

Read for playback/scrubbing, decoding, audio, rendering/export, indexing, inference, or caches.

## Media semantics

- Use AVFoundation asynchronous property loading; deprecated synchronous asset, track, and metadata properties may block. Keep blocking AVFoundation/Core Audio setup and control calls off-main.
- Keep exact media time in `CMTime` or frame integers until explicit UI/external boundaries. Preserve time scale, rounding, source/timeline time, speed, trim, channel layout, transforms, color/alpha attachments, frame timing, and metadata unless the feature changes them.
- Reuse readers, render contexts, audio graphs, pipelines, Core Image/Metal/model objects when documented lifecycle permits; invalidate on relevant configuration and app lifecycle changes.
- Bound decoders, readers, exports, model inference, thumbnails, and waveform extraction. Propagate cancellation between decode/render/inference/export chunks and before publication.
- Cover missing audio/video tracks, corrupt/offline media, zero/indefinite duration, unusual containers, variable frame rates, non-integer speeds, rotated/alpha media, nonstandard sample rates, long timelines, and cancellation as applicable.
- Speech/MLX/transcription changes require both ordinary and `BundledSpeech` builds; conditional behavior needs trait-enabled tests. AWS rendering needs `AWSSupport` verification.

## Hot paths and scaling

- Treat rendering, playback, scrubbing, metering, timeline input, view updates, import/indexing, restore/save, and export as performance-sensitive.
- Never put filesystem access, logging/JSON encoding, model/decoder/reader/audio-graph setup, LUT parsing, or `CIContext` creation in per-frame/sample/grain/item-view or repeated interaction paths.
- Fix unnecessary work and complexity first: nested scans, repeated sorting, copy-on-write loops, intermediate arrays, actor hops, observation invalidations, and repeated setup.
- Batch/coalesce bulk state updates with explicit flush boundaries before save, undo, export, close, and current-state reads.
- Hydrate thumbnails, waveforms, filmstrips, metadata, transcripts, and models only when consumed. Do not decode all media during restore or panel rendering.
- Cache expensive reusable work only with a complete key, capacity, invalidation/replacement rules, lifecycle reset, in-flight deduplication, and stale-result policy. Account for changed file bytes/URL/configuration.
- Keep progress, meters, hover, and playheads narrowly observable. A high-frequency update must not invalidate a whole panel or large grid; view bodies stay fast and side-effect free.
- Bound retained media/cache memory and release buffers promptly. Use scoped autorelease pools for Objective-C loops when profiling demonstrates retained temporaries.
- Avoid per-item success logging in release hot paths; retain actionable failures and batch summaries without evaluating verbose messages unnecessarily.

## Evidence

- Reproduce with a stable representative workload. Compare before/after under the same configuration using Instruments, signposts, a focused benchmark, or a meaningful performance test.
- Do not call an actor extraction, added cache, or passing correctness test a measured performance improvement.
- Follow [concurrency rules](concurrency.md) for executor/cancellation safety and [package rules](project-packages.md) when results touch project storage.

References: [asynchronous media loading](https://developer.apple.com/documentation/avfoundation/loading-media-data-asynchronously), [app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness), [early performance diagnosis](https://developer.apple.com/documentation/xcode/diagnosing-performance-issues-early), and [performance measurement](https://developer.apple.com/documentation/xcode/improving-your-app-s-performance).
