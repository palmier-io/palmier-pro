#include "TextAnimator.h"

#include <windows.h>

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cwctype>

namespace TextAnimator
{
    namespace
    {
        std::string WideToUtf8(const wchar_t* data, size_t length)
        {
            if (length == 0)
            {
                return std::string();
            }
            int len = WideCharToMultiByte(CP_UTF8, 0, data, static_cast<int>(length),
                nullptr, 0, nullptr, nullptr);
            std::string out(static_cast<size_t>(std::max(0, len)), '\0');
            if (len > 0)
            {
                WideCharToMultiByte(CP_UTF8, 0, data, static_cast<int>(length), out.data(), len, nullptr, nullptr);
            }
            return out;
        }

        // NSString isSpace over CharacterSet.whitespacesAndNewlines (TextFrameRenderer.swift:389):
        // approximated with the wide-char whitespace class, which covers the ASCII/Latin-1 range
        // real captions live in — full Unicode whitespace parity is not required for word
        // tokenization to land on the right boundaries for typical transcript text.
        bool IsSpace(wchar_t c) { return std::iswspace(static_cast<wint_t>(c)) != 0; }

        // TextAnimator.linear (TextAnimator.swift:82-86): 0 at/below start, 1 at/above start+dur.
        double Linear(int64_t rel, int64_t start, int64_t dur)
        {
            if (rel <= start) return 0.0;
            if (rel >= start + dur) return 1.0;
            return static_cast<double>(rel - start) / static_cast<double>(dur);
        }

        // TextAnimator.progress (swift:76-79): smoothstep(linear(...)).
        double Progress(int64_t rel, int64_t start, int64_t dur) { return SmoothStep(Linear(rel, start, dur)); }

        // TextAnimator.overshoot (swift:89-92): back-ease that overshoots past 1 before settling.
        double Overshoot(double t)
        {
            constexpr double s = 1.70158;
            double p = t - 1.0;
            return 1.0 + (s + 1.0) * p * p * p + s * p * p;
        }

        // TextAnimator.activeRamp (swift:95-103): 0 outside the active span, ramp shortened so
        // fast (short) words still reach 1.
        double ActiveRamp(int64_t rel, const SnapshotWordTiming& word, int64_t ramp)
        {
            if (rel < word.startFrame || rel >= word.endFrame) return 0.0;
            int64_t span = std::max<int64_t>(1, word.endFrame - word.startFrame);
            if (span <= 1) return 1.0;
            int64_t r = std::min(std::max<int64_t>(1, ramp), std::max<int64_t>(1, span / 2));
            double rampIn = SmoothStep(std::min(1.0, static_cast<double>(rel - word.startFrame) / static_cast<double>(r)));
            double rampOut = SmoothStep(std::min(1.0, static_cast<double>(word.endFrame - rel) / static_cast<double>(r)));
            return std::min(rampIn, rampOut);
        }

        // TextAnimator.lerp (swift:105-113).
        SnapshotRgba Lerp(const SnapshotRgba& a, const SnapshotRgba& b, double t)
        {
            t = std::min(1.0, std::max(0.0, t));
            SnapshotRgba out;
            out.r = a.r + (b.r - a.r) * t;
            out.g = a.g + (b.g - a.g) * t;
            out.b = a.b + (b.b - a.b) * t;
            out.a = a.a + (b.a - a.a) * t;
            return out;
        }

        // TextAnimator.activeTint (swift:68-72): only tints when the clip has an EXPLICIT
        // highlight — highlightPop/highlightBlock's defaultHighlight fallback does NOT apply here.
        SnapshotRgba ActiveTint(const SnapshotTextAnimation& anim, const SnapshotWordTiming& word,
            int64_t rel, const SnapshotRgba& base)
        {
            if (!anim.highlight.has_value()) return base;
            double on = ActiveRamp(rel, word, std::max<int64_t>(1, anim.perWordFrames));
            return Lerp(base, *anim.highlight, on);
        }

        // TextAnimation.defaultHighlight (Models/TextAnimation.swift:60).
        SnapshotRgba DefaultHighlight() { return SnapshotRgba{1.0, 0.85, 0.0, 1.0}; }

        // normalizedTimingText (TextFrameRenderer.swift:377-383): alnum-only, lowercased.
        std::string NormalizedTimingText(const std::string& text)
        {
            std::string out;
            out.reserve(text.size());
            for (unsigned char c : text)
            {
                if (std::isalnum(c))
                {
                    out.push_back(static_cast<char>(std::tolower(c)));
                }
            }
            return out;
        }

        std::vector<SnapshotWordTiming> EvenTokenTimings(const std::vector<Token>& tokens, int64_t duration)
        {
            int64_t d = std::max<int64_t>(0, duration);
            int64_t n = std::max<size_t>(1, tokens.size());
            std::vector<SnapshotWordTiming> out;
            out.reserve(tokens.size());
            for (size_t i = 0; i < tokens.size(); ++i)
            {
                SnapshotWordTiming t;
                t.text = tokens[i].text;
                t.startFrame = d * static_cast<int64_t>(i) / n;
                t.endFrame = d * static_cast<int64_t>(i + 1) / n;
                out.push_back(std::move(t));
            }
            return out;
        }

        SnapshotWordTiming ClampedTiming(const SnapshotWordTiming& timing, const std::string& text, int64_t duration)
        {
            int64_t maxFrame = std::max<int64_t>(0, duration);
            int64_t start = std::min(std::max<int64_t>(0, timing.startFrame), maxFrame);
            int64_t end = std::min(std::max(start, timing.endFrame), maxFrame);
            SnapshotWordTiming out;
            out.text = text;
            out.startFrame = start;
            out.endFrame = end;
            return out;
        }

        struct TimingAlignmentGroup
        {
            size_t tokenStart, tokenEnd; // [tokenStart, tokenEnd)
            size_t wordStart, wordEnd;   // [wordStart, wordEnd)
        };

        // shouldAppendTokenText (swift:327-338): greedily grows whichever side's normalized text
        // is shorter (or must — the other side is exhausted) until the two sides match.
        bool ShouldAppendTokenText(const std::string& tokenText, const std::string& wordText,
            size_t tokenEnd, size_t wordEnd, size_t tokenCount, size_t wordCount)
        {
            if (wordEnd >= wordCount) return true;
            if (tokenEnd >= tokenCount) return false;
            return tokenText.size() <= wordText.size();
        }

        // nextAlignedTimingGroup (swift:289-325).
        std::optional<TimingAlignmentGroup> NextAlignedTimingGroup(const std::vector<Token>& tokens,
            const std::vector<SnapshotWordTiming>& words, size_t tokenStart, size_t wordStart)
        {
            size_t tokenEnd = tokenStart, wordEnd = wordStart;
            std::string tokenText, wordText;
            while (tokenEnd < tokens.size() || wordEnd < words.size())
            {
                if (ShouldAppendTokenText(tokenText, wordText, tokenEnd, wordEnd, tokens.size(), words.size()))
                {
                    tokenText += NormalizedTimingText(tokens[tokenEnd].text);
                    ++tokenEnd;
                }
                else
                {
                    wordText += NormalizedTimingText(words[wordEnd].text);
                    ++wordEnd;
                }
                if (!tokenText.empty() && tokenText == wordText)
                {
                    return TimingAlignmentGroup{tokenStart, tokenEnd, wordStart, wordEnd};
                }
            }
            return std::nullopt;
        }

        // timingsForAlignedGroup (swift:340-368).
        std::vector<SnapshotWordTiming> TimingsForAlignedGroup(const std::vector<Token>& tokens,
            const std::vector<SnapshotWordTiming>& words, const TimingAlignmentGroup& g, int64_t duration)
        {
            size_t tokenCount = g.tokenEnd - g.tokenStart;
            size_t wordCount = g.wordEnd - g.wordStart;
            std::vector<SnapshotWordTiming> out;
            if (tokenCount == wordCount)
            {
                out.reserve(tokenCount);
                for (size_t i = 0; i < tokenCount; ++i)
                {
                    out.push_back(ClampedTiming(words[g.wordStart + i], tokens[g.tokenStart + i].text, duration));
                }
                return out;
            }

            int64_t maxFrame = std::max<int64_t>(0, duration);
            int64_t start = std::min(std::max<int64_t>(0, words[g.wordStart].startFrame), maxFrame);
            int64_t end = std::min(std::max(start, words[g.wordEnd - 1].endFrame), maxFrame);
            int64_t span = std::max<int64_t>(0, end - start);
            out.reserve(tokenCount);
            for (size_t offset = 0; offset < tokenCount; ++offset)
            {
                int64_t tokenStart = start + span * static_cast<int64_t>(offset) / static_cast<int64_t>(tokenCount);
                int64_t tokenEnd = (offset == tokenCount - 1)
                    ? end
                    : start + span * static_cast<int64_t>(offset + 1) / static_cast<int64_t>(tokenCount);
                SnapshotWordTiming t;
                t.text = tokens[g.tokenStart + offset].text;
                t.startFrame = tokenStart;
                t.endFrame = tokenEnd;
                out.push_back(std::move(t));
            }
            return out;
        }

        // alignedTokenTimings (swift:257-287).
        std::optional<std::vector<SnapshotWordTiming>> AlignedTokenTimings(
            const std::vector<Token>& tokens, const std::vector<SnapshotWordTiming>& words, int64_t duration)
        {
            std::vector<SnapshotWordTiming> result;
            size_t tokenIndex = 0, wordIndex = 0;
            while (tokenIndex < tokens.size() && wordIndex < words.size())
            {
                auto group = NextAlignedTimingGroup(tokens, words, tokenIndex, wordIndex);
                if (!group.has_value()) return std::nullopt;
                auto piece = TimingsForAlignedGroup(tokens, words, *group, duration);
                result.insert(result.end(), piece.begin(), piece.end());
                tokenIndex = group->tokenEnd;
                wordIndex = group->wordEnd;
            }
            if (tokenIndex != tokens.size() || wordIndex != words.size() || result.size() != tokens.size())
            {
                return std::nullopt;
            }
            return result;
        }
    }

    RenderMode ModeFor(const std::string& preset)
    {
        if (preset == "typewriter") return RenderMode::Typewriter;
        if (preset == "wordReveal" || preset == "wordSlide" || preset == "wordPop" ||
            preset == "wordCycle" || preset == "highlightPop" || preset == "highlightBlock")
        {
            return RenderMode::PerWord;
        }
        return RenderMode::Entrance; // "none", fadeIn/popIn/slideUp, and any unrecognized name
    }

    ClipState ClipEntry(const SnapshotTextAnimation& anim, int64_t rel)
    {
        int64_t dur = std::max<int64_t>(1, anim.perWordFrames);
        double t = Progress(rel, 0, dur);
        ClipState st;
        if (anim.preset == "fadeIn")
        {
            st.opacity = t;
        }
        else if (anim.preset == "popIn")
        {
            st.opacity = t;
            st.scale = 0.6 + 0.4 * t;
        }
        else if (anim.preset == "slideUp")
        {
            st.opacity = t;
            st.dy = 0.05 * (1.0 - t);
        }
        return st; // default-constructed identity for everything else, including "typewriter"/"none"
    }

    WordState WordStateFor(const SnapshotTextAnimation& anim, const SnapshotWordTiming& word,
        int64_t rel, const SnapshotRgba& base)
    {
        SnapshotRgba highlight = anim.highlight.value_or(DefaultHighlight());
        int64_t hand = std::max<int64_t>(1, anim.perWordFrames);
        WordState st;
        st.color = base;

        if (anim.preset == "wordReveal")
        {
            double t = Progress(rel, word.startFrame, hand);
            st.opacity = t;
            st.color = ActiveTint(anim, word, rel, base);
        }
        else if (anim.preset == "wordSlide")
        {
            double t = Progress(rel, word.startFrame, hand);
            st.opacity = t;
            st.dy = 0.5 * (1.0 - t);
            st.color = ActiveTint(anim, word, rel, base);
        }
        else if (anim.preset == "wordPop")
        {
            double u = Linear(rel, word.startFrame, hand);
            st.opacity = SmoothStep(u);
            st.scale = 0.6 + 0.4 * Overshoot(u);
            st.color = ActiveTint(anim, word, rel, base);
        }
        else if (anim.preset == "wordCycle")
        {
            double on = ActiveRamp(rel, word, hand);
            st.opacity = on;
            st.color = ActiveTint(anim, word, rel, base);
        }
        else if (anim.preset == "highlightPop")
        {
            double on = ActiveRamp(rel, word, std::min<int64_t>(hand, 4));
            st.scale = 1.0 + 0.15 * on;
            st.color = Lerp(base, highlight, on);
        }
        else if (anim.preset == "highlightBlock")
        {
            double on = ActiveRamp(rel, word, std::min<int64_t>(hand, 4));
            SnapshotRgba bg = highlight;
            bg.a *= on;
            st.color = base;
            st.bgColor = bg;
        }
        // default (including unrecognized preset names): static full-opacity base color.
        return st;
    }

    TypewriterState Typewriter(const std::vector<Token>& tokens,
        const std::vector<SnapshotWordTiming>& tokenTimings, int64_t rel, int64_t durationFrames)
    {
        // renderTypewriter's reveal-length loop (TextFrameRenderer.swift:201-213).
        uint32_t visLen = 0;
        for (size_t i = 0; i < tokens.size(); ++i)
        {
            const SnapshotWordTiming& t = tokenTimings[i];
            if (rel >= t.endFrame)
            {
                visLen = tokens[i].utf16Start + tokens[i].utf16Length;
            }
            else if (rel >= t.startFrame)
            {
                double span = static_cast<double>(std::max<int64_t>(1, t.endFrame - t.startFrame));
                double p = static_cast<double>(rel - t.startFrame) / span;
                visLen = tokens[i].utf16Start +
                    static_cast<uint32_t>(std::floor(static_cast<double>(tokens[i].utf16Length) * p));
                break;
            }
            else
            {
                break;
            }
        }

        // Caret blinks (~0.5s @30fps) until shortly after the last word finishes (swift:216-217).
        int64_t doneAt = tokenTimings.empty() ? durationFrames : tokenTimings.back().endFrame;
        bool caretOn = rel <= doneAt + 18 && ((rel / 15) % 2) == 0;

        TypewriterState out;
        out.visibleUtf16Length = visLen;
        out.caretOn = caretOn;
        return out;
    }

    std::vector<Token> Tokenize(const std::wstring& contentUtf16)
    {
        std::vector<Token> result;
        size_t i = 0;
        size_t n = contentUtf16.size();
        while (i < n)
        {
            while (i < n && IsSpace(contentUtf16[i])) ++i;
            if (i >= n) break;
            size_t start = i;
            while (i < n && !IsSpace(contentUtf16[i])) ++i;
            Token tok;
            tok.utf16Start = static_cast<uint32_t>(start);
            tok.utf16Length = static_cast<uint32_t>(i - start);
            tok.text = WideToUtf8(contentUtf16.data() + start, i - start);
            result.push_back(std::move(tok));
        }
        return result;
    }

    std::vector<SnapshotWordTiming> TokenTimings(
        const std::vector<Token>& tokens, const std::vector<SnapshotWordTiming>& words, int64_t duration)
    {
        if (tokens.empty()) return {};
        if (words.empty()) return EvenTokenTimings(tokens, duration);
        if (words.size() == tokens.size())
        {
            std::vector<SnapshotWordTiming> out;
            out.reserve(tokens.size());
            for (size_t i = 0; i < tokens.size(); ++i)
            {
                out.push_back(ClampedTiming(words[i], tokens[i].text, duration));
            }
            return out;
        }
        auto aligned = AlignedTokenTimings(tokens, words, duration);
        return aligned.has_value() ? std::move(*aligned) : EvenTokenTimings(tokens, duration);
    }
}
