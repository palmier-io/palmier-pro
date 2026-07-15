#pragma once

#include "TimelineSnapshot.h"

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

// Pure per-frame evaluator for text animation — faithful port of
// Compositing/TextAnimator.swift, plus the word-tokenization / timing-alignment helpers
// Compositing/TextFrameRenderer.swift needs to feed it (words(), tokenTimings() and the
// alignment fallback for when transcript word counts don't match token counts). No D2D/
// DirectWrite here: math and UTF-16 string indexing only, driven by clip-relative frame
// time and the word timings carried in the v1.2 snapshot (SnapshotTextClip.wordTimings).
// TextRenderer.cpp is the sole caller — it turns these states into D2D draw calls. Cited
// Swift line numbers appear inline next to the math they mirror.
namespace TextAnimator
{
    // Mirrors TextAnimator.ClipState (TextAnimator.swift:5-11). dy is a fraction of render
    // HEIGHT, positive = down (applyEntrance, swift:97-118).
    struct ClipState
    {
        double opacity = 1.0;
        double scale = 1.0;
        double dy = 0.0;
    };

    // Mirrors TextAnimator.WordState (swift:13-19). dy here is a fraction of FONT SIZE,
    // matching renderPerWord's `ctx.translateBy(x: 0, y: -st.dy * fontSize)` (swift:160).
    struct WordState
    {
        double opacity = 1.0;
        double scale = 1.0;
        double dy = 0.0;
        SnapshotRgba color;
        std::optional<SnapshotRgba> bgColor;
    };

    // One tokenized word (run of non-whitespace) in clip content — mirrors
    // TextFrameRenderer.words() (swift:385-401). Range is in UTF-16 code units (NSRange
    // semantics), matching the wide string TextRenderer builds for DirectWrite and the
    // text the wire's WordTiming entries were measured against.
    struct Token
    {
        uint32_t utf16Start = 0;
        uint32_t utf16Length = 0;
        std::string text; // UTF-8, for transcript-alignment comparisons
    };

    // TextAnimation.Preset.renderMode (Models/TextAnimation.swift:21-30) — which draw strategy
    // TextRenderer should use for a given preset string. Unrecognized preset names fall back to
    // Entrance (== "none"'s behavior), never to a crash or per-word path with no timings.
    enum class RenderMode { Entrance, PerWord, Typewriter };
    RenderMode ModeFor(const std::string& preset);

    // TextAnimator.clipEntry (swift:22-35). Only fadeIn/popIn/slideUp produce a non-identity
    // state; every other preset (including none) is identity.
    ClipState ClipEntry(const SnapshotTextAnimation& anim, int64_t rel);

    // TextAnimator.wordState (swift:38-65). `base` is the clip's static text color.
    WordState WordStateFor(const SnapshotTextAnimation& anim, const SnapshotWordTiming& word,
        int64_t rel, const SnapshotRgba& base);

    // Visible character count (UTF-16 units into `wideContent`) for the typewriter preset at
    // `rel`, plus whether the blink caret is currently on — mirrors renderTypewriter's reveal
    // math (swift:193-227), split from the "|" concatenation so the caller draws the caret
    // itself (D2D has no string-concat-and-measure shortcut worth taking here).
    struct TypewriterState
    {
        uint32_t visibleUtf16Length = 0;
        bool caretOn = false;
    };
    TypewriterState Typewriter(const std::vector<Token>& tokens,
        const std::vector<SnapshotWordTiming>& tokenTimings, int64_t rel, int64_t durationFrames);

    // TextFrameRenderer.words() (swift:385-401): splits `contentUtf16` on whitespace/newline
    // into non-empty runs. Takes the UTF-16 buffer directly (the caller already built one for
    // DirectWrite) so ranges line up with it with no re-encoding.
    std::vector<Token> Tokenize(const std::wstring& contentUtf16);

    // TextFrameRenderer.tokenTimings (swift:230-242): one timing per token, aligning
    // transcript spans (`words`) against tokens when counts differ, falling back to an even
    // split (evenTokenTimings, swift:244-250) when alignment can't reconcile them.
    std::vector<SnapshotWordTiming> TokenTimings(
        const std::vector<Token>& tokens, const std::vector<SnapshotWordTiming>& words, int64_t duration);
}
