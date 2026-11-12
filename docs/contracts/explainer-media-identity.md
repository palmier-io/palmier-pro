# Media input identity

Three identities serve different purposes:

- Clip `id`: one timeline placement; moves preserve it, placement/paste/split create new IDs.
- `mediaRef`: one library record; importing the same file twice creates separate records.
- `inputId`: `sha256:<digest>` of source bytes; identical copies share it, regardless of filename or library record.

Inventory, inspection, timeline readback, mutation receipts, and library shot candidates expose input identity. Different source spans remain separate candidates, not separate inputs. A stock hit also returns `origin`; pass it unchanged as `import_media.source.origin` to retain provider, original catalog ID, and source page. Renditions can share `origin.sourceId` despite different bytes. Origin is caller-supplied provenance, not verification of rights, factual content, or uniqueness.

## Preparation and persistence

Import finalization hashes usable files off-main before recording identity. Byte imports now await finalization instead of reporting corrupt or unprepared bytes as ready. `inspect_media` prepares identity on demand. Identity readback never hashes or accesses the filesystem.

One shared service serializes hashing, checks cancellation between bounded chunks, and rejects files changing during measurement. Its 64-entry cache is keyed by URL and validated file metadata (size, modification/creation dates, inode). Force measurement bypasses this cache; narration alignment uses that path to preserve its source-byte checks. Metadata caching does not detect modifications deliberately hiding their metadata changes; final production validation must request fresh measurement where required.

`inputIdentityState` is `verified` after successful preparation, `unverified` for retained/restored identity, or `unresolved` when absent/invalid. “Verified” describes measured bytes, not perpetual file immutability or editorial safety. Relinking invalidates identity and origin; package relocation preserves identity but requires revalidation. An intervening URL change rejects an old completion even if the original URL returns.

Manifest persistence retains content identity and import provenance. Download status, not the presence of provenance, identifies interrupted imports on reopen. Persisted request and imported source-page URLs omit user information, query strings, and fragments so signed-query credentials are not retained. The in-flight request still uses the original URL. Query-only resource identity must come from content measurement or explicit stock origin.

## Not yet enforced

These identities let the Agent recognize reuse; they do not yet implement the mandatory whole-output uniqueness gate in `done.md` task 5b (formerly `todo.md`). Different encodings/crops can have different hashes; provider origin is not universal cross-provider identity. Perceptual matching, frozen derivative lineage, nested-output occurrence calculation, storyboard approval, and final delivery gates remain unfinished. Face avoidance is Agent guidance, not automatic detection. Do not describe these foundations as a certified unique or faceless export.

## Manual verification

1. Import a valid image and a renamed byte-identical copy. Inventory must show different library records with one `inputId`.
2. Place both in a test timeline. Select/move either independently, then undo. Clip IDs must be different; input identity must remain shared. Repeated visuals are not acceptable in the finished explainer.
3. Import a stock URL with its returned `origin`. After readiness, save/reopen and confirm origin remains; restored identity is unverified until inspection. Missing completed media must be offline, not an interrupted download.
4. Save As, inspect retained identity, then relink a record to different content. Old identity/origin must disappear; inspection must report the new input.
5. Begin preparation, switch/relink/remove the asset, then close. Check no stale result appears on another asset/project. Cancelled and failed work must not claim readiness.
6. Review actual selected video spans for faces, including motion, reflections, crowds, and screens. Sparse thumbnails do not pass this check. Present storyboard and obtain explicit approval before building the film.

Manual UI, real stock download, and full Save As/close/quit verification remain unperformed.
