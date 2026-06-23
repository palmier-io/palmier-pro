# Intel Editor-Only Status

This branch contains an experimental Intel Mac editor-only build mode for Palmier Pro.
It is not official Palmier support. The GitHub Actions build has produced an
Intel app artifact, and that artifact has been smoke-tested on an Intel iMac,
but the branch is still a reduced editor-only experiment.

The normal Palmier Pro build path is unchanged when `PALMIER_EDITOR_ONLY` is not
set: it remains the full macOS 26 Apple Silicon build with the normal backend and
AI features.

## Build Mode

Enable the experimental mode with:

```bash
PALMIER_EDITOR_ONLY=1
```

In this mode, `Package.swift` lowers the package platform target to macOS 15.0,
defines `PALMIER_EDITOR_ONLY`, and removes Clerk/Convex backend package products
from the SwiftPM dependency graph.

Local SwiftPM build command:

```bash
PALMIER_EDITOR_ONLY=1 swift build --arch x86_64
```

Local debug app bundle command:

```bash
PALMIER_EDITOR_ONLY=1 SIGNING_IDENTITY=- SWIFT_BUILD_ARGS="--arch x86_64" ./scripts/bundle.sh debug --fast
```

This creates `.build/PalmierPro.app` using ad-hoc signing. It does not notarize
the app, install it globally, use Apple IDs, or use signing certificates.

For editor-only app bundles, `scripts/bundle.sh` also lowers
`LSMinimumSystemVersion` to `15.0` and disables Sparkle's automatic checks
against the official Palmier update feed.

## Capability Source Of Truth

Runtime feature visibility is centralized in:

```text
Sources/PalmierPro/Utilities/FeatureGate.swift
```

`FeatureGate` answers:

- whether this is the official full build or experimental Intel editor-only build
- whether the current binary is Apple Silicon or Intel
- whether macOS 26 APIs are available at runtime
- whether Palmier backend/auth is available
- whether transcription, hosted AI generation, cloud sync, model catalog, feedback, and official update checks are available

UI entry points should stay visible where practical and use `FeatureGate` to
show a disabled state instead of silently disappearing.

## Feature Status

| Area | Intel editor-only status | Notes |
| --- | --- | --- |
| Launch | Working in smoke test | The app launched on an Intel iMac running macOS 15.7.7. |
| Media import | Working in smoke test | A screen recording imported into the timeline. More formats still need runtime testing. |
| Timeline editing | Expected to work | Core timeline build and tests pass. Trim, split, move, snapping, text, and multi-track editing still need manual runtime testing. |
| Preview/playback | Expected to work | Uses local AVFoundation/editor code paths. Needs runtime playback testing with video, audio, and text layers. |
| Export dialog | Working in smoke test | The export dialog opens. Actual export, output playback, and error handling still need runtime testing. |
| Project save/reopen | Expected to work | Project document IO tests pass. Manual save/reopen testing is still required. |
| Local project export | Expected to work | Palmier project export tests pass. Needs runtime verification with real imported media. |
| Visual search/indexing | Partially available | Local search/indexing code and tests build for x86_64. Core ML model download/load and real Intel performance are unverified. |
| Spoken search | Partially available | Searching existing transcript data can work, but editor-only builds cannot currently generate transcripts from media. |
| Manual text/captions | Expected to work | Text/caption clip infrastructure remains in the editor. |
| Automatic captions | Disabled | Depends on the disabled transcription path. |
| Transcription | Disabled | The official implementation uses macOS 26-only `SpeechTranscriber` and `SpeechAnalyzer`. |
| AI image/video/audio generation | Disabled | Depends on Palmier hosted backend, Clerk auth, Convex subscriptions, upload tickets, credits, and hosted model catalog. |
| Upscale/rerun/download hosted generation | Disabled | Depends on the same hosted generation backend. |
| Hosted model catalog | Disabled | Editor-only mode removes `ConvexMobile` and returns an empty loaded catalog. |
| Account/login/billing/credits | Disabled | Editor-only mode removes Clerk/Convex packages from the SwiftPM graph. |
| Palmier hosted agent streaming | Disabled | Hosted Palmier agent calls require backend auth. BYOK/local tool paths may still be usable but need runtime testing. |
| Feedback submission | Disabled | Depends on backend submission. |
| Cloud/backend sync | Disabled | No Convex backend connection is available in editor-only mode. Local project files remain the intended persistence path. |
| Sparkle updates | Disabled for editor-only artifacts | Official Sparkle metadata stays in the source plist, but the editor-only bundle removes the official feed and disables automatic checks. |

## Visible Disabled States

The experimental Intel editor-only build keeps the following entry points visible
with clear disabled states:

- Settings > Account
- Settings > Models
- Help > Send Feedback
- Media panel > Generate
- Media panel > Music
- Media panel > Captions > Generate Captions
- Inspector > AI tab for visual assets and clips
- App menu > Check for Updates

Disabled feature paths should include the shared message:

```text
This feature is unavailable in the experimental Intel editor-only build.
```

## Disabled Features

The following features are disabled or stubbed only when `PALMIER_EDITOR_ONLY=1`:

- Palmier account login, Clerk sessions, subscriptions, billing, credits, and plan management.
- Convex/ConvexMobile backend subscriptions, mutations, storage tickets, and hosted model catalog sync.
- Generative AI submission, rerun, upscale, download, and hosted generation job updates.
- Hosted Palmier agent streaming that depends on Clerk/Convex authentication.
- On-device Speech framework transcription and automatic caption generation from audio.
- Backend-dependent feedback submission.
- Sparkle automatic update checks against the official Palmier feed in editor-only artifacts.

Disabled feature paths should report or include:

```text
This feature is unavailable in the experimental Intel editor-only build.
```

The intended first working surface is the local editor core: project open/save,
timeline editing, media import, preview/export, local resources, and local MCP or
BYOK paths that do not require Palmier's hosted backend.

## Transcription Fallback Research

The current official transcription path uses `SpeechTranscriber`,
`SpeechAnalyzer`, and speech asset installation APIs that require macOS 26.
Those APIs are not safe to compile into the macOS 15 Intel editor-only build.

A macOS 15-compatible fallback appears realistic, but it should be implemented
as a separate focused change after runtime testing. Apple documents
`SFSpeechRecognizer` as the older recognizer object, `SFSpeechURLRecognitionRequest`
as the path for recognition from an audio file, and `SpeechTranscriber` /
`SpeechAnalyzer` as the newer macOS 26 path.

A possible internal provider shape is:

- Keep using AVFoundation to extract an imported video's audio track to a
  temporary audio file.
- Request Speech authorization with `SFSpeechRecognizer`.
- Select a locale from `SFSpeechRecognizer.supportedLocales()`.
- Use `SFSpeechURLRecognitionRequest` for extracted audio files.
- Prefer on-device recognition by setting `requiresOnDeviceRecognition` only
  when `supportsOnDeviceRecognition` is true.
- Map `SFTranscriptionSegment` values into Palmier's existing
  `TranscriptionWord` and `TranscriptionSegment` models.
- Show a clear disabled/unavailable message when permission is denied, the
  recognizer is unavailable, the locale is unsupported, or on-device recognition
  is not available.

The fallback was not implemented in this branch because the older Speech API has
different privacy, availability, timing, language, and duration behavior from
the macOS 26 transcription stack. In particular, product review is needed before
allowing server-backed recognition as a fallback, and the Intel app needs real
runtime validation of permission prompts, long media files, locale handling, and
caption timing quality.

### Speech Provider Options

| Provider path | Pros | Cons / risks | Status for this branch |
| --- | --- | --- | --- |
| Apple `SpeechTranscriber` / `SpeechAnalyzer` | Modern first-party path, designed for the current Palmier implementation. | Requires macOS 26 APIs and Swift 6.2/macOS 26 SDK. | Official build path only. |
| Apple `SFSpeechRecognizer` + `SFSpeechURLRecognitionRequest` | First-party macOS 15-compatible fallback for prerecorded audio files; can reuse Palmier's AVFoundation audio extraction. | Different permission flow, locale availability, server-vs-on-device behavior, timing quality, and long-file behavior. Needs Intel runtime testing. | Recommended next transcription spike. |
| OpenAI transcription API | High-quality hosted transcription; official API supports file transcription. | Sends user media to a third party, requires explicit consent and user or Palmier API configuration, may have cost/file-size constraints. | Future optional provider only; do not make mandatory. |
| Deepgram prerecorded audio API | Mature hosted STT path with prerecorded audio support. | Requires API key, network upload, consent, cost, and vendor configuration. | Future optional provider only; do not make mandatory. |
| Local Whisper / whisper.cpp | Can run offline and preserve media privacy; plausible on macOS 15 Intel. | Adds binary/model distribution complexity, model downloads, CPU/GPU performance risk on Intel, and packaging/review work. | Future local provider spike. |

External providers must be opt-in, must not hardcode API keys, and must not send
user media off-device without explicit consent.

Useful references:

- Apple Speech framework: https://developer.apple.com/documentation/speech/
- Apple `SFSpeechRecognizer`: https://developer.apple.com/documentation/speech/sfspeechrecognizer
- Apple `SFSpeechURLRecognitionRequest`: https://developer.apple.com/documentation/speech/sfspeechurlrecognitionrequest
- Apple `SpeechTranscriber`: https://developer.apple.com/documentation/speech/speechtranscriber
- OpenAI speech-to-text: https://developers.openai.com/api/docs/guides/speech-to-text
- Deepgram prerecorded audio: https://developers.deepgram.com/docs/pre-recorded-audio
- whisper.cpp: https://github.com/ggml-org/whisper.cpp

## Two-Download Strategy

Recommended release shape for maintainers:

1. Official Apple Silicon / macOS 26 Palmier Pro build
   - Keep the current full backend/auth/generation feature set.
   - Keep the official Sparkle feed and existing signing/notarization process.
   - Publish using the normal Palmier release channel.

2. Experimental Intel editor-only build
   - Publish separately and label clearly as experimental.
   - Keep artifact name `palmier-pro-intel-editor-only-app`.
   - Do not connect this artifact to the official Apple Silicon Sparkle feed.
   - Keep hosted backend, account, generation, and advanced transcription
     unavailable until maintainers validate Intel-compatible backend and
     transcription paths.

Maintainers can later choose a universal release, but separate downloads are
safer while the Intel build is editor-only and differently supported.

## Maintainer Path To Restore Full Intel Features

- Account/login: restore Clerk support only after `clerk-ios` and related auth
  flows compile and run on x86_64/macOS 15, including keychain access groups and
  OAuth callback testing.
- Convex/ConvexMobile: either validate `ConvexMobile` on x86_64/macOS 15 or
  introduce an Intel-compatible backend client abstraction for subscriptions,
  mutations, storage tickets, and account sync.
- Cloud sync: re-enable only after auth and Convex/backend state are stable on
  Intel, then test local/offline project file behavior alongside remote sync.
- Hosted AI generation: re-enable only after account auth, upload tickets,
  model catalog sync, generation job subscriptions, billing, credits, and
  download/rerun/upscale paths work on Intel.
- Billing/credits: re-enable after account state, plan catalog, subscription
  management links, top-offs, and credit accounting are validated.
- Model catalog: re-enable after backend model subscription works on Intel, or
  after maintainers provide a signed/static catalog suitable for editor-only
  review builds.
- Transcription: add a `TranscriptionProvider` abstraction, keep the macOS 26
  `SpeechTranscriber` provider for the official build, and add a tested legacy
  Apple Speech or optional external/local provider for macOS 15.
- Official update checks: use a separate signed Intel appcast/feed or a universal
  release feed that only offers compatible updates to compatible machines.
- Release packaging: keep separate Intel and Apple Silicon artifacts until the
  support matrix, updater feed, signing, notarization, and QA plan are unified.
- Before declaring official Intel support, run GitHub Actions, launch testing,
  import/edit/playback, save/reopen, export/open-in-QuickTime, disabled-feature
  checks, transcription tests if restored, backend account tests if restored, and
  crash/Console log review on real Intel macOS 15 hardware.

## Known Risks

- The branch requires a Swift 6.2-capable toolchain and macOS 26 SDK to compile
  guarded macOS 26 SwiftUI APIs, even though the editor-only package target is
  macOS 15.0.
- The GitHub Actions runner can prove compilation and artifact assembly, but it
  does not prove all runtime behavior on a 2019 Intel iMac running macOS 15.7.7.
- The uploaded app artifact is ad-hoc signed and not notarized.
- Future upstream macOS 26-only API calls may still need availability guards.
- Dependencies such as Sparkle, Lottie, Sentry, MCP, and swift-transformers have
  compiled in the current editor-only package shape, but their runtime behavior
  still needs broader Intel testing.
- Runtime behavior around Core ML model downloads, local visual search, export,
  and media frameworks still needs real Intel hardware testing.

## GitHub Actions

Workflow:

```text
.github/workflows/intel-editor-only-build.yml
```

It can be run from GitHub:

1. Open the fork on GitHub.
2. Go to Actions.
3. Select "Intel Editor-Only Build".
4. Select "Run workflow".
5. Choose branch `intel-mac-support-experiment`.

The workflow also runs on pushes to `intel-mac-support-experiment`, except for
Markdown-only changes.

The workflow runs:

```bash
PALMIER_EDITOR_ONLY=1 swift package --disable-dependency-cache --scratch-path .build/editor-only --manifest-cache local resolve
PALMIER_EDITOR_ONLY=1 swift build --disable-dependency-cache --scratch-path .build/editor-only --manifest-cache local --arch x86_64
PALMIER_EDITOR_ONLY=1 swift test --disable-dependency-cache --scratch-path .build/editor-only --manifest-cache local --arch x86_64
```

If the build or tests fail, the workflow uploads:

```text
intel-editor-only-swiftpm-logs
```

If the build and tests pass, the workflow assembles and uploads:

```text
palmier-pro-intel-editor-only-app
```

That artifact should contain:

```text
PalmierPro-intel-editor-only.app.zip
```
