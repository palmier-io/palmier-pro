# Third-Party Notices — Windows

PalmierPro (Windows) is GPLv3, matching the root project. This file tracks
third-party dependencies and their licenses for the Windows port. Sections below
are placeholders — filled in with actual version, license text, and source URL as
each dependency lands.

## FFmpeg (GPL build)

**Status: added when the dependency lands (milestone E1).**

Demux/decode/mux/encode. GPL build (`--enable-gpl`, x264/x265/nvcodec) —
license-compatible with this GPLv3 repo. Dynamic DLLs, not statically linked.
Local/release builds via vcpkg (`ffmpeg[gpl,x264,x265,nvcodec]:x64-windows`); CI
consumes a pinned, hash-verified prebuilt GPL shared build (BtbN), restored by
`scripts/ci-restore-ffmpeg.ps1` against `ffmpeg.lock.json`.

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
