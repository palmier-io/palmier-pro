# Fork Customizations

This document records intentional Gitnapp/open-palmier behavior that differs from, or is likely to conflict with, upstream `palmier-io/palmier-pro`.

Last upstream check: `upstream/main` at `9bea812` (`fix(agent): make placed clips extendable + symmetric trim model (#236)`).

When syncing upstream, review this document against the current implementation before resolving conflicts. If a listed area is changed, update the corresponding entry in the same commit.

## Upstream Update Notification Only

Intent: agents should tell the user when upstream has new commits, but must not merge, rebase, cherry-pick, or otherwise apply upstream changes unless the user explicitly asks.

Primary paths:

- `AGENTS.md`
- `CLAUDE.md`

Upstream sync note: preserve this as a project-level operating rule for both Codex and Claude.

## OpenAI-Compatible BYOK Agent Runtime

Intent: keep an independent OpenAI-compatible backend for user-provided keys instead of patching the Anthropic backend.

Primary paths:

- `Sources/PalmierPro/Agent/Clients/OpenAICompatibleClient.swift`
- `Sources/PalmierPro/Agent/Clients/AnthropicProtocol.swift`
- `Sources/PalmierPro/Agent/Clients/AgentClientTypes.swift`
- `Sources/PalmierPro/Agent/AgentService.swift`
- `Sources/PalmierPro/Settings/AgentPane.swift`
- `Sources/PalmierPro/Agent/Panel/AgentPanelView.swift`
- `Tests/PalmierProTests/Agent/OpenAICompatibleClientTests.swift`

Upstream sync note: preserve the provider boundary. Anthropic-specific request/streaming behavior should stay in the Anthropic path; OpenAI-compatible request/streaming behavior should stay in the independent client.

## Tool Error Pass-Through

Intent: tool-call errors are returned to the model as-is. The runtime should not silently fill missing arguments, rewrite tool calls, or add fallback behavior after a tool error.

Primary paths:

- `AGENTS.md`
- `CLAUDE.md`
- `Sources/PalmierPro/Agent/AgentService.swift`
- `Sources/PalmierPro/Agent/Tools/ToolExecutor*.swift`

Upstream sync note: reject changes that hide tool failures from the model or transform them into successful fallback edits.

## Agent Tool Contract Documentation

Intent: keep the Agent tool surface documented and checked against `ToolDefinitions.swift`.

Primary paths:

- `docs/agent-tools/agent-tool-contract.md`
- `scripts/sync-agent-tool-docs.swift`
- `.githooks/pre-commit`
- `.githooks/post-merge`
- `.githooks/post-rewrite`
- `.github/workflows/ci.yml`

Upstream sync note: after any tool definition merge, run `swift scripts/sync-agent-tool-docs.swift --write`, then review and commit the generated diff.

## Transcript-Driven Cut Guardrails

Intent: transcript edits should prefer stable word-index cuts. Raw ripple range deletion is reserved for non-word-aligned spans.

Primary paths:

- `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift`
- `Sources/PalmierPro/Agent/Tools/AgentInstructions.swift`
- `Sources/PalmierPro/Agent/Tools/ToolExecutor+Clips.swift`
- `Sources/PalmierPro/Transcription/TranscriptCache.swift`
- `Tests/PalmierProTests/Agent/RemoveTracksTests.swift`
- `Tests/PalmierProTests/Agent/ToolExecutorTests.swift`

Upstream sync note: preserve the `remove_words` first workflow and locale-specific transcript cache behavior.

## Caption Readability And Safety

Intent: generated captions should respect user character limits, language, aspect ratio, font size, and safe-area layout.

Primary paths:

- `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift`
- `Sources/PalmierPro/Agent/Tools/AgentInstructions.swift`
- `Sources/PalmierPro/Agent/Tools/ToolExecutor+Captions.swift`
- `Sources/PalmierPro/Editor/ViewModel/EditorViewModel+Captions.swift`
- `Sources/PalmierPro/MediaPanel/CaptionsTab/CaptionBuilder.swift`
- `Sources/PalmierPro/UI/AppTheme.swift`
- `Tests/PalmierProTests/Captions/CaptionLayoutTests.swift`

Upstream sync note: keep `maxCharacters` visible to the agent and keep generated caption boxes inside the safe canvas area.

## NaturalLanguage Tokenizer Caption Splitting

Intent: generated captions should split at language-aware word boundaries using macOS `NaturalLanguage.NLTokenizer`, so English words and CJK words are not split in the middle when enforcing caption length.

Primary paths:

- `Sources/PalmierPro/Models/DisplayTextTokenizer.swift`
- `Sources/PalmierPro/MediaPanel/CaptionsTab/CaptionBuilder.swift`
- `Sources/PalmierPro/Compositing/TextFrameRenderer.swift`
- `Tests/PalmierProTests/Captions/CaptionBuilderTests.swift`
- `Tests/PalmierProTests/Rendering/TextAnimationRenderTests.swift`

Upstream sync note: preserve deterministic local tokenization as the default. AI-based semantic regrouping can be layered later, but it should not replace the local tokenizer or rewrite transcript text.

## Palmier UI Feature Policy

Intent: the Gitnapp build exposes model-management settings for local provider configuration, while anonymous crash/error reporting is forced off.

Primary paths:

- `Sources/PalmierPro/App/AppFeaturePolicy.swift`
- `Sources/PalmierPro/Settings/SettingsView.swift`
- `Sources/PalmierPro/Settings/ModelsPane.swift`
- `Sources/PalmierPro/Settings/PrivacyPane.swift`
- `Sources/PalmierPro/Telemetry/Telemetry.swift`

Upstream sync note: keep model-management settings visible unless the fork intentionally removes local provider configuration. If upstream adds new model-settings entry points, wire them through `AppFeaturePolicy`.

## OpenRouter Visual Generation Endpoint

Intent: route optional BYOK image and video generation through OpenRouter, while keeping Palmier responsible for audio and upscale.

Primary paths:

- `Sources/PalmierPro/Generation/OpenRouter/OpenRouterService.swift`
- `Sources/PalmierPro/Generation/GenerationService.swift`
- `Sources/PalmierPro/Generation/UI/GenerationView.swift`
- `Sources/PalmierPro/Settings/ModelsPane.swift`
- `Sources/PalmierPro/App/main.swift`

Upstream sync note: preserve the `openrouter:` stored model-id prefix and keep OpenRouter out of audio and upscale paths.
