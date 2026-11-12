# Plan save snapshots

Native document saves capture plan and manifest values on the main actor. Plan
encoding happens when AppKit consumes the immutable snapshot on its write
executor, alongside project and manifest encoding. `EditPlanStore` creates a
separate encoder/decoder for each operation; concurrent document saves do not
share mutable coder instances.

A plan or manifest encoding failure fails the save before package writing
begins. The completion handler receives the error; the last successful package
is not overwritten with stale plan data under a success receipt. A corrected
snapshot can be saved normally afterward.

An explicitly unreadable original plan/manifest remains a different condition:
the existing recovery policy preserves that file instead of replacing it with
an empty in-memory value. An encoding failure of a known current value never
selects that recovery path.

## Manual verification

Use a temporary project with a prepared storyboard and recorded approval.
Save, reopen, and compare stable plan/run IDs, script, approval, inspections,
and timing. Repeat after autosave, Save As, and close/reopen. Simulate a denied
destination and verify the save error remains visible and the last successful
package is readable. Correct the destination and retry.

This slice does not prove complete production durability or move every save
operation off-main. Thumbnail/chat capture, package mutation admission,
Save As coordination, and asynchronous import ownership remain separate work.
