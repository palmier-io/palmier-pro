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

**Status: added when the dependency lands (Stage A / timeline snapshot contract).**

Native-side parser for the UTF-8 JSON timeline snapshot passed across the C ABI
each edit generation.

## Time-stretch library (signalsmith-stretch or SoundTouch)

**Status: added when the dependency lands (milestone E4.5).**

Realtime WSOLA-style pitch-preserving time stretch for retimed audio during
preview (export uses FFmpeg `atempo` instead). Choice between the two candidates
finalized when the audio engine milestone starts; both are GPL-compatible.

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
