# Media undo after Save As

The saved manifest owns source location. Library undo snapshots retain asset objects and source entries, not ownership of the old package URL.

Restoration resolves every saved source through `MediaResolver.expectedURLMap` against the editor's current package before publishing library membership. Package sources therefore follow Save As even when the asset was absent from the live library during rebasing. External sources retain their saved absolute URLs. `relocate(to:)` invalidates URL-bound thumbnail and input verification state while retaining the measured byte identity for revalidation.

Deletion, undo, and redo retain backing files. Save As copies the retained media directory even when its library record is currently deleted. No filesystem work runs in the synchronous undo path.

Both regression cases passed in frozen focused gate 5: delete a packaged or external image, Save As, remove the original temporary package, undo deletion, independently verify bytes and metadata, save/read the source entry, then redo/undo again. Package sources remain project-relative; external sources do not move. The broader gate failed unrelated reservation, accessibility, and import assertions; no full-suite or final integration pass is claimed.

Frozen `integrated-8` passed 230 tests in 32 suites, including both media-undo cases and actual MCP import/undo/native-redo readback. Frozen `tsan-2` passed 160 tests in 22 suites without race diagnostics, including package media undo; source hashes remained unchanged. The full run retains one unchanged custom-model issue. No native UI or complete quit verification is claimed.

Manual verification uses a disposable project: import media, delete it from the library, Save As, move the original package aside, undo, open the restored asset, and redo/undo. Confirm current package playback and stable selection/IDs. Test missing copied media and unavailable external media; undo must not invent replacement bytes.
