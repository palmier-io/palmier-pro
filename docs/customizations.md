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

Intent: keep independent non-Palmier agent backends for user-provided keys and local OAuth credentials instead of patching the Anthropic backend. Zhipu GLM uses its OpenAI-compatible endpoint with a Keychain API key. Codex OAuth signs in through the official ChatGPT PKCE browser flow, stores tokens in the local Codex auth file, refreshes access tokens before streaming, and calls the official ChatGPT Codex backend `https://chatgpt.com/backend-api/codex/responses` with the Codex account header instead of the OpenAI-compatible Chat Completions path. The agent panel keeps a visible cancel control during streaming, and Codex Responses streams that emit tool calls must continue into local tool execution even when `response.completed` follows the function-call item.

Primary paths:

- `Sources/PalmierPro/Agent/Clients/OpenAICompatibleClient.swift`
- `Sources/PalmierPro/Agent/Clients/CodexOAuthClient.swift`
- `Sources/PalmierPro/Agent/Clients/CodexOAuthStore.swift`
- `Sources/PalmierPro/Agent/Clients/AgentProviderCredentials.swift`
- `Sources/PalmierPro/Agent/Clients/AnthropicProtocol.swift`
- `Sources/PalmierPro/Agent/Clients/AgentClientTypes.swift`
- `Sources/PalmierPro/Agent/AgentService.swift`
- `Sources/PalmierPro/Settings/AgentPane.swift`
- `Sources/PalmierPro/Agent/Panel/AgentPanelView.swift`
- `Tests/PalmierProTests/Agent/CodexResponsesClientTests.swift`
- `Tests/PalmierProTests/Agent/CodexOAuthStoreTests.swift`
- `Tests/PalmierProTests/Agent/OpenAICompatibleClientTests.swift`

Upstream sync note: preserve the provider boundary. Anthropic-specific request/streaming behavior should stay in the Anthropic path; OpenAI-compatible request/streaming behavior should stay in the independent client. Codex OAuth must remain on the ChatGPT Codex Responses backend, not `api.openai.com/v1/chat/completions`. Do not remove the Zhipu GLM or Codex OAuth options from Settings > Agent.

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

- `Package.swift`
- `Sources/PalmierPro/Agent/Skills/SkillStore.swift`
- `Sources/PalmierPro/Agent/Skills/SkillCatalog.swift`
- `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift`
- `Sources/PalmierPro/Agent/Tools/AgentInstructions.swift`
- `Sources/PalmierPro/Agent/Tools/ToolExecutor+Captions.swift`
- `Sources/PalmierPro/Editor/ViewModel/EditorViewModel+Captions.swift`
- `Sources/PalmierPro/MediaPanel/CaptionsTab/CaptionBuilder.swift`
- `Sources/PalmierPro/UI/AppTheme.swift`
- `Tests/PalmierProTests/Captions/CaptionLayoutTests.swift`
- `Tests/PalmierProTests/Agent/SkillStoreTests.swift`
- `Gitnapp/palmier-skill` (`PalmierSkillBundle`, `caption-readability`)

Upstream sync note: keep `maxCharacters` visible to the agent, keep generated caption boxes inside the safe canvas area, and preserve the bundled editable `caption-readability` skill as the default caption-generation guidance.

## NaturalLanguage Tokenizer Caption Splitting

Intent: generated captions should split at language-aware word boundaries using macOS `NaturalLanguage.NLTokenizer`, so English words and CJK words are not split in the middle when enforcing caption length.

Primary paths:

- `Sources/PalmierPro/Models/DisplayTextTokenizer.swift`
- `Sources/PalmierPro/MediaPanel/CaptionsTab/CaptionBuilder.swift`
- `Sources/PalmierPro/Compositing/TextFrameRenderer.swift`
- `Tests/PalmierProTests/Captions/CaptionBuilderTests.swift`
- `Tests/PalmierProTests/Rendering/TextAnimationRenderTests.swift`

Upstream sync note: preserve deterministic local tokenization as the default. AI-based semantic regrouping can be layered later, but it should not replace the local tokenizer or rewrite transcript text.

## Volcengine Speech Captions

Intent: users can choose Volcengine Seed ASR as an independent caption transcription backend, store their own API key in Keychain, and expose precise caption alignment tools only when that backend is configured.

Primary paths:

- `Sources/PalmierPro/Transcription/TranscriptionProvider.swift`
- `Sources/PalmierPro/Transcription/VolcengineSpeechClient.swift`
- `Sources/PalmierPro/Transcription/Transcription.swift`
- `Sources/PalmierPro/Transcription/TranscriptCache.swift`
- `Sources/PalmierPro/Editor/ViewModel/EditorViewModel+Captions.swift`
- `Sources/PalmierPro/MediaPanel/CaptionsTab/CaptionTab.swift`
- `Sources/PalmierPro/Settings/ProvidersPane.swift`
- `Sources/PalmierPro/Settings/VolcengineSpeechPane.swift`
- `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift`
- `Sources/PalmierPro/Agent/MCP/MCPService.swift`
- `Tests/PalmierProTests/Agent/ToolDefinitionAvailabilityTests.swift`

Upstream sync note: keep the local Apple Speech backend as the default and keep Volcengine as a separate provider under Settings > Providers. `align_captions` must remain hidden unless the Volcengine Speech API key and resource configuration are available.

## Palmier UI Feature Policy

Intent: the Gitnapp build exposes local provider configuration, hides Palmier account/subscription as a required setup path, and forces anonymous crash/error reporting off.

Primary paths:

- `Sources/PalmierPro/App/AppFeaturePolicy.swift`
- `Sources/PalmierPro/Settings/SettingsView.swift`
- `Sources/PalmierPro/Settings/ProvidersPane.swift`
- `Sources/PalmierPro/Settings/ModelsPane.swift`
- `Sources/PalmierPro/Settings/PrivacyPane.swift`
- `Sources/PalmierPro/Telemetry/Telemetry.swift`
- `Sources/PalmierPro/Project/HomeView.swift`
- `Sources/PalmierPro/Project/WelcomeOverlay.swift`

Upstream sync note: keep local provider settings visible and keep Account/Providers/Models legacy settings routes redirected to the fork's credential tabs. If upstream adds new model-settings or provider entry points, wire them through `AppFeaturePolicy` or the fork's generation settings tabs.

## OpenRouter Visual Generation Endpoint

Intent: route optional BYOK image and video generation through OpenRouter. OpenRouter model catalogs are loaded only after an API key is configured, and the key is sent to the corresponding model endpoints.

Primary paths:

- `Sources/PalmierPro/Generation/OpenRouter/OpenRouterService.swift`
- `Sources/PalmierPro/Generation/GenerationService.swift`
- `Sources/PalmierPro/Generation/UI/GenerationView.swift`
- `Sources/PalmierPro/Settings/ProvidersPane.swift`
- `Sources/PalmierPro/Settings/ModelsPane.swift`
- `Sources/PalmierPro/Agent/Tools/ToolExecutor+Generate.swift`
- `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift`
- `Sources/PalmierPro/App/main.swift`

Upstream sync note: preserve the `openrouter:` stored model-id prefix, keep API-key management under Settings > Video Generation, and do not add fallback/default OpenRouter models when no key is configured or the endpoint fails.

## Generation Auth Gate Removal

Intent: generation, upscale, AI edit, and Agent tool surfaces should not require Palmier sign-in or Palmier subscription credits before attempting provider-backed work. Provider/backend errors should surface directly instead of being rewritten into login or billing instructions.

Primary paths:

- `Sources/PalmierPro/Agent/AgentService.swift`
- `Sources/PalmierPro/Agent/Clients/PalmierClient.swift`
- `Sources/PalmierPro/Agent/Tools/AgentInstructions.swift`
- `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift`
- `Sources/PalmierPro/Agent/Tools/ToolExecutor+Generate.swift`
- `Sources/PalmierPro/Agent/Tools/ToolExecutor+Timeline.swift`
- `Sources/PalmierPro/Editor/ViewModel/EditorViewModel+AIEdit.swift`
- `Sources/PalmierPro/Generation/Edit/EditSubmitter.swift`
- `Sources/PalmierPro/Generation/UI/GenerationView.swift`
- `Sources/PalmierPro/Inspector/Tabs/AIEditTab.swift`
- `Sources/PalmierPro/MediaPanel/MediaTab/MediaTab.swift`
- `Sources/PalmierPro/MediaPanel/MusicTab.swift`

Upstream sync note: reject sign-in/credits preflight checks around generation tools or UI controls. It is acceptable for a provider client to return its real unauthenticated or not-configured error.

## Generation Credential Settings

Intent: Settings groups model credentials into Agent, Video Generation, and Audio Generation tabs. Users configure provider keys there; model lists are loaded from provider endpoints only after the relevant key exists. MiniMax exposes a Mainland China / International API region picker because keys are region-bound and the wrong endpoint returns unauthorized. MiniMax audio models are loaded into a local provider catalog after the selected region's model endpoint accepts the key; if that endpoint omits music_generation IDs, the configured MiniMax catalog exposes the supported music-2.6-free and music-2.6 generation models. Generation calls use the selected MiniMax region endpoint directly.

Primary paths:

- `Sources/PalmierPro/Settings/SettingsView.swift`
- `Sources/PalmierPro/Settings/ProvidersPane.swift`
- `Sources/PalmierPro/Settings/ModelsPane.swift`
- `Sources/PalmierPro/Generation/AudioProviderSettings.swift`
- `Sources/PalmierPro/Generation/AudioProviderCatalog.swift`
- `Sources/PalmierPro/Generation/MiniMaxAudioService.swift`
- `Sources/PalmierPro/Generation/OpenRouter/OpenRouterService.swift`
- `Sources/PalmierPro/Generation/Submission/AudioGenerationSubmission.swift`
- `Sources/PalmierPro/Agent/Tools/ToolExecutor+Generate.swift`
- `Tests/PalmierProTests/Generation/AudioProviderSettingsTests.swift`

Upstream sync note: do not restore Account as the default Settings tab. Do not reintroduce a static default model catalog to mask missing provider credentials; MiniMax music models should only appear after an authenticated region probe succeeds.
