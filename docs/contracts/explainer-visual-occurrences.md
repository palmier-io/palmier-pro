# Visual source occurrence review

`qc_timeline.visualIdentity` reviews an immutable snapshot of the current output and retained manifest identities. Work executes off-main, checks cancellation, and rejects results after timeline, media-manifest, active-timeline, or project changes. It performs no filesystem access or mutation.

## Occurrences

- Image/video placements on enabled visual lanes include overlays and nested visual carriers. Linked audio and hidden tracks do not count. Occlusion and per-clip opacity do not suppress occurrences; this conservative audit can flag a source hidden behind another enabled placement.
- Shared `NestFlattener` supplies the same nested trimming and placement rules used by rendering and decomposition. Child-lane IDs remain stable even when trimming removes another lane.
- Distinct placements are separate occurrences unless they form one uninterrupted run on the same lane and library source. Adjacent video splits must advance the source continuously; their source boundary may differ by at most half a source-frame-domain unit because shared split operations round trims. An adjacent replay is not continuous. Adjacent still-image splits constitute one continuous image appearance.
- Different library records remain separate occurrences, even when adjacent. Hash and provider-origin aliases then identify repeated sources across those records.
- Aliases are transitive: identical bytes connect renamed imports, while retained provider/source identity connects alternate renditions. Different source spans, crops, transforms, or simultaneous overlays do not make a source unique.
- Reports retain occurrence clip IDs and root-output half-open frame ranges. Nested IDs include their carrier instance paths.
- Invalid timing, IDs, cycles, excessive nesting, missing media, absent/invalid hashes, and unknown rendered-input lineage remain unresolved. Traversal is bounded to 100,000 placements; reaching its limit cannot produce a clean report.

## Limits

`knownIdentityReuseFree` means no conflict or unresolved case was found in this retained-identity review. It is **not delivery approval**. Top-level QC `pass` remains structural, so ordinary editing experiments can still contain intentional reused footage.

`deliveryVerified` is always false. Identity freshness, perceptual similarity, and face inspection are explicitly `not_checked`. Files can change outside the app; hashes do not recognize arbitrary crops/re-encodes. Caller-supplied stock origin is not independent verification. Lottie and generated derivatives remain unresolved until frozen input lineage is implemented.

Storyboard approval, protected explainer mutations, final export gates, perceptual matching, face-coverage review, and provisional source assignments remain unfinished. Do not use this report alone to claim unique or faceless delivery.

## Manual checks

In an isolated project, import an image and a byte-identical renamed copy. Place both, including an overlay or nested instance. QC must report one canonical conflict with separate output occurrences without changing timeline or undo. Split one uninterrupted placement; its count must stay one. Replay it later; its count must increase. Hide a visual track; it must leave the rendered occurrence set. Undo restores edits normally; QC creates no undo entries.

Manual UI and continuous-render comparison remain pending. Automated tests cover retained identities and frame-domain structure, not visual or audible quality.
