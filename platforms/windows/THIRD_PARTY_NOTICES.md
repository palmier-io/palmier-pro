# Third-Party Notices — Windows

PalmierPro (Windows) is GPLv3, matching the root project. This file tracks
third-party dependencies and their licenses for the Windows port. Sections below
are placeholders — filled in with actual version, license text, and source URL as
each dependency lands.

## FFmpeg (GPL build)

**Status: landed (milestone E1).**

Demux/decode/mux/encode. GPL build (`--enable-gpl`, x264/x265/nvcodec) —
license-compatible with this GPLv3 repo. Dynamic DLLs, not statically linked;
`avformat`/`avcodec`/`avutil`/`swscale`/`swresample` DLLs ship next to
`PalmierPro.App.exe` (see `PalmierPro.Rendering.csproj`).

Pinned build: **FFmpeg n8.1.2** (BtbN/FFmpeg-Builds, release-branch autobuild
`autobuild-2026-07-10-13-44`, revision `g94138f6973`, `win64-gpl-shared`
variant — a versioned release-branch build rather than the rolling
`master-latest` tag, so the pin is reproducible). Restored by
`scripts/ci-restore-ffmpeg.ps1` against `ffmpeg.lock.json` (URL + sha256,
hard-fails on hash mismatch) to `third_party/ffmpeg/{bin,include,lib}`, gitignored.
`scripts/dev.ps1` runs the restore automatically if `third_party/ffmpeg` is
missing. Local/release builds may instead use vcpkg
(`ffmpeg[gpl,x264,x265,nvcodec]:x64-windows`) if a from-source build is needed.

FFmpeg source for this build is available from the upstream FFmpeg project
(https://ffmpeg.org, git tag `n8.1.2`) and from BtbN/FFmpeg-Builds' build
scripts (https://github.com/BtbN/FFmpeg-Builds), per GPLv3 §6's source-
availability requirement. `third_party/ffmpeg/LICENSE.txt` (restored alongside
the binaries, not checked in) carries the full GPLv3 text and per-component
license notices for the enabled third-party codecs (x264, x265, etc.).

## ThorVG

**Status: added when the dependency lands (milestone E4.7).**

Lottie rasterization for offline bake (mirrors the Mac's `LottieVideoGenerator`
architecture — bake to an alpha-capable intermediate, composite as normal
footage). Replaces `lottie-ios`; not Lottie-Windows (Composition-based, no
deterministic frame readback).

## simdjson

**Status: landed (Stage B / E2 — timeline ABI).**

Native-side parser for the UTF-8 JSON timeline snapshot passed across the C ABI
each edit generation (`PE_OpenTimeline`/`PE_UpdateTimeline`; see
`TimelineSnapshotParser.cpp`). Apache-2.0 licensed.

Pinned build: **simdjson v3.10.1**, vendored as the official amalgamated
single-header/single-source pair (`singleheader/simdjson.h` +
`singleheader/simdjson.cpp` from the `v3.10.1` tag,
https://github.com/simdjson/simdjson), checked in unmodified under
`native/third_party/simdjson/` alongside its upstream `LICENSE` file. No build
step or package manager involved — `PalmierEngine.vcxproj` compiles
`simdjson.cpp` directly as a translation unit.

## signalsmith-stretch

**Status: landed (milestone E4.5, retime slice).**

Realtime pitch-preserving time stretch for retimed audio during preview
(`clip.speed != 1.0` in `AudioMixer`'s per-clip decode path — export uses
FFmpeg `atempo` instead, a separate, already-scoped path). MIT licensed.

Pinned build: **signalsmith-stretch v1.1.0** (tag `1.1.0`,
https://github.com/Signalsmith-Audio/signalsmith-stretch), vendored unmodified
under `native/third_party/signalsmith-stretch/`: the top-level
`signalsmith-stretch.h` plus its `dsp/` header dependencies (`common.h`,
`perf.h`, `fft.h`, `windows.h`, `delay.h`, `spectral.h` — the subset of the
sibling `signalsmith-linear`/`dsp` library it `#include`s; the repo's other
`dsp/*.h` modules are unused and not vendored), each carrying its own
`LICENSE.txt` (MIT, Geraint Luff / Signalsmith Audio Ltd.) alongside it. Header-
only — `native/RetimeStretcher.h/.cpp` is the only translation unit that
includes it, no separate build step.

## Windows App SDK / WinUI3 native interop (MIT)

**Status: landed (Stage A / D3D11 presentation).**

`native/WinUISwapChainInterop.h` hand-declares the `ISwapChainPanelNative` COM
interface (GUID `63aad0b8-7c24-40ff-85a8-640d944cc325`) that WinUI3's
`Microsoft.UI.Xaml.Controls.SwapChainPanel` implements, matching the vtable
Microsoft ships in the `Microsoft.WindowsAppSDK.WinUI` NuGet package's
`include/microsoft.ui.xaml.media.dxinterop.h` (MIT-licensed). Declared by hand
rather than vendoring that generated header because it isn't available at
native-engine build time (native builds via `msbuild` before `dotnet restore`
pulls NuGet packages — see `docs/README.md`). Do not confuse with the
similarly-named but differently-GUID'd `ISwapChainPanelNative` in the Windows
SDK's `<windows.ui.xaml.media.dxinterop.h>`, which targets the OS-shipped UWP
`Windows.UI.Xaml.Controls.SwapChainPanel`, not WinUI3's.

## Bundled fonts (OFL / Apache)

**Status: landed (Stage 0b).** `PalmierPro.App.csproj` links (does not copy) all
font files from `Sources/PalmierPro/Resources/Fonts/**` into `Assets/Fonts/` —
one on-disk copy, shared with the Mac target. Variable-font files whose names
contain `[wght]`/`[opsz,wght]` axis tags are relinked as `*-Variable.ttf`
(brackets break `ms-appx:///` URIs).

Inter (OFL) is the Windows UI chrome font (sanctioned parity exception — SF Pro's
license prohibits use off Apple platforms) — see `AppThemeTokens.FontFamily` and
`Theme.xaml`'s `AppFontFamily` resource. The other 12 open-license caption/title
families mirrored from `Utilities/BundledFonts.swift` on the Mac side (OFL and
Apache-licensed) are bundled for text-clip compositing and the caption/title
font picker: Anton, Basement Grotesque, Bebas Neue, Caveat, DM Sans, Geist,
Geist Mono, Permanent Marker, Playfair Display, Poppins, Shrikhand, Space Grotesk.
