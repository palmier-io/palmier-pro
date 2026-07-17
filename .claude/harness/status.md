# feature/glossary — Status

Phase 2 complete. Ready for Evaluator.

## Feature

L1 transcript correction layer ("glossary"). Additive corrections applied at READ time; raw
cached ASR JSON on disk is never mutated.

## Delivered

| Area            | Files                                                                                            |
| --------------- | ------------------------------------------------------------------------------------------------ |
| Model           | Glossary/GlossaryTerm.swift (term, document, confidence, type)                                   |
| Text primitives | Glossary/GlossaryText.swift (CJK detection, Latin boundaries)                                    |
| Corrector       | Glossary/GlossaryCorrector.swift (longest-match-first, word-span)                                |
| Materialisation | Glossary/TranscriptionResult+Glossary.swift                                                      |
| Store/layering  | Glossary/GlossaryStore.swift (global→library→project, hotwords, fingerprint)                     |
| Validation      | Glossary/GlossaryValidation.swift (variant safety §5.4)                                          |
| Classifier      | Glossary/GlossaryClassifier.swift + GlossaryCommonWords.swift                                    |
| MCP tools       | Agent/Tools/ToolExecutor+Glossary.swift (list/add/remove/apply)                                  |
| Registration    | ToolDefinitions.swift (ToolName + defs), ToolExecutor.swift (dispatch)                           |
| Read hooks      | get_transcript, inspect_media (video+audio), add_captions, spoken search                         |
| Cache salting   | TranscriptCache.swift cacheTag param                                                             |
| Promotion       | ToolExecutor+Texts.swift update_text hook + origin param                                         |
| Tests           | Tests/PalmierProTests/Glossary/{GlossaryTests,GlossarySearchTests,GlossaryClassifierTests}.swift |

## Verification

- `swift build` — clean.
- `swift test --filter Glossary` — 32/32 pass.
- `swift test` (full) — 1096/1096 pass.

## Integration notes for merge

- Library scope maps to `Project.storageDirectory` (no cross-project media-library root exists).
- update_text conflict surface: added `origin` param + promotion block before the final
  `mutationResult` return. `promoted` rides in `extra`.
- `generatedText` (from another branch) not present on Clip yet — marked with an INTEGRATION TODO
  in update_text; branch compiles standalone on origin/main.
- Decoder-bias wiring intentionally NOT connected (engine on another branch). Public API ready:
  `GlossaryStore.hotwordTerms()`, `GlossaryStore.biasFingerprint()`, and
  `TranscriptCache.transcript(..., cacheTag:)`.
