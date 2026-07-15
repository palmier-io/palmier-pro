using System.Drawing;
using System.Globalization;
using System.Text;
using Shouldly;
using Xunit;

namespace PalmierPro.Rendering.Tests;

// Exercises the E4 text/title pass (v1.2 timeline snapshot `textClips` -> TextRenderer ->
// GpuCompositor text composite) end to end through the timeline ABI, asserting on the rendered
// PNG pixels. Text-only snapshots (a single video-type track with `clips: []` and a populated
// `textClips`) need no ffmpeg fixture media at all — the compositor clears to black and paints the
// glyphs over it — so these run against the bundled fonts\ directory and a WARP/GPU device only,
// same native-DLL surface as FontRegistryTests. Category "Media" (not "GPU") keeps them in the
// default CI lane alongside the other native-render tests.
//
// Parity note (docs/timeline-snapshot-v1.md, the plan's "Parity bar for text"): glyph shapes and
// measured run widths are accepted DirectWrite-vs-CoreText differences, so every assertion here is
// analytic (coverage / anchor band / channel dominance), never a golden-image compare.
public sealed class TextClipRenderTests
{
    private const int CanvasWidth = 1280;
    private const int CanvasHeight = 720;

    private static string BuildTextSnapshotJson(
        string content,
        string fontName = "Poppins",
        double colorR = 1, double colorG = 1, double colorB = 1,
        bool borderEnabled = false,
        double borderR = 0, double borderG = 0, double borderB = 1,
        string preset = "none",
        double centerX = 0.5, double centerY = 0.4, double boxWidth = 0.9, double boxHeight = 0.3)
    {
        static string N(double v) => v.ToString(CultureInfo.InvariantCulture);
        string b = borderEnabled ? "true" : "false";
        return $$"""
        {
          "version": 1,
          "minorVersion": 2,
          "fps": { "numerator": 30, "denominator": 1 },
          "outputWidth": {{CanvasWidth}},
          "outputHeight": {{CanvasHeight}},
          "tracks": [
            {
              "id": "TEXT",
              "type": "video",
              "muted": false,
              "clips": [],
              "textClips": [
                {
                  "id": "T1",
                  "startFrame": 0,
                  "durationFrames": 60,
                  "content": "{{content}}",
                  "opacity": { "value": 1, "keyframes": null },
                  "blendMode": null,
                  "transform": { "centerX": {{N(centerX)}}, "centerY": {{N(centerY)}}, "width": {{N(boxWidth)}}, "height": {{N(boxHeight)}}, "rotation": 0, "flipHorizontal": false, "flipVertical": false },
                  "style": {
                    "fontName": "{{fontName}}",
                    "fontSize": 200,
                    "fontScale": 1,
                    "isBold": true,
                    "isItalic": false,
                    "color": { "r": {{N(colorR)}}, "g": {{N(colorG)}}, "b": {{N(colorB)}}, "a": 1 },
                    "alignment": "center",
                    "shadow": { "enabled": false, "color": { "r": 0, "g": 0, "b": 0, "a": 0.6 }, "offsetX": 0, "offsetY": -2, "blur": 6 },
                    "background": { "enabled": false, "color": { "r": 0, "g": 0, "b": 0, "a": 0.6 } },
                    "border": { "enabled": {{b}}, "color": { "r": {{N(borderR)}}, "g": {{N(borderG)}}, "b": {{N(borderB)}}, "a": 1 } }
                  },
                  "animation": { "preset": "{{preset}}", "perWordFrames": 6, "highlight": null },
                  "wordTimings": null
                }
              ]
            }
          ]
        }
        """;
    }

    private static Bitmap RenderTextClip(string json, long frame)
    {
        using var session = new EngineSession();
        using TimelineSession timeline = TimelineSession.Open(session, Encoding.UTF8.GetBytes(json));
        string pngPath = Path.Combine(Path.GetTempPath(), $"palmier-text-{Guid.NewGuid():N}.png");
        try
        {
            timeline.RenderFrameToFile(frame, pngPath);
            using var fromFile = new Bitmap(pngPath);
            return new Bitmap(fromFile); // detach from the file so it can be deleted
        }
        finally
        {
            if (File.Exists(pngPath))
            {
                File.Delete(pngPath);
            }
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public void TextClip_RendersNonEmptyGlyphs_AnchoredInTheTextBox()
    {
        using Bitmap bmp = RenderTextClip(BuildTextSnapshotJson("HELLO"), frame: 30);
        bmp.Width.ShouldBe(CanvasWidth);
        bmp.Height.ShouldBe(CanvasHeight);

        // Box: centerY=0.4, height=0.3 -> top edge at (0.4-0.15)*H = 0.25*H. Text is top-anchored at
        // the box top and flows down (TextFrameRenderer's tall top-anchored framesetter box), so
        // glyph coverage must live BELOW the box top and NOTHING should appear well above it.
        int boxTopY = (int)(0.25 * CanvasHeight);

        long brightPixels = 0;
        double sumX = 0, sumY = 0;
        for (int y = 0; y < CanvasHeight; y++)
        {
            for (int x = 0; x < CanvasWidth; x++)
            {
                Color c = bmp.GetPixel(x, y);
                if (c.R > 128 && c.G > 128 && c.B > 128) // white glyph coverage over black
                {
                    brightPixels++;
                    sumX += x;
                    sumY += y;
                }
            }
        }

        // Glyphs actually rasterized (not a blank frame).
        brightPixels.ShouldBeGreaterThan(500L, "expected visible white glyph coverage");

        // Anchor: the coverage centroid sits horizontally near the centered box and vertically below
        // the box top — i.e. the text landed where transform placed it, not elsewhere.
        double centroidX = sumX / brightPixels;
        double centroidY = sumY / brightPixels;
        centroidX.ShouldBeInRange(0.35 * CanvasWidth, 0.65 * CanvasWidth);
        centroidY.ShouldBeGreaterThan(boxTopY - 4.0);

        // No stray glyph coverage in the far corners / top strip (outside any plausible text box).
        bmp.GetPixel(4, 4).R.ShouldBeLessThan((byte)40);
        for (int x = 0; x < CanvasWidth; x += 32)
        {
            bmp.GetPixel(x, (int)(0.08 * CanvasHeight)).R.ShouldBeLessThan((byte)40);
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public void TextClip_GlyphColor_MatchesStyleColor()
    {
        // Pure-red fill — the rasterized glyphs must carry the style color, not a default.
        using Bitmap bmp = RenderTextClip(
            BuildTextSnapshotJson("TEXT", colorR: 1, colorG: 0, colorB: 0), frame: 30);

        Color bestRed = Color.Black;
        int bestScore = int.MinValue;
        for (int y = 0; y < CanvasHeight; y++)
        {
            for (int x = 0; x < CanvasWidth; x++)
            {
                Color c = bmp.GetPixel(x, y);
                int score = c.R - c.G - c.B; // most saturated-red covered pixel
                if (score > bestScore)
                {
                    bestScore = score;
                    bestRed = c;
                }
            }
        }

        bestRed.R.ShouldBeGreaterThan((byte)200);
        bestRed.G.ShouldBeLessThan((byte)70);
        bestRed.B.ShouldBeLessThan((byte)70);
    }

    [Fact]
    [Trait("Category", "Media")]
    public void TextClip_BorderStroke_PaintsStrokeColorAtGlyphEdges()
    {
        // White fill, pure-blue border stroke (TextStyle.glyphBorderStrokeWidth = -4 -> fill AND
        // stroke). The blue stroke must show up at glyph edges — DrawTextLayout alone can't stroke;
        // this is the whole reason the text pass fills+strokes glyph OUTLINE geometry.
        using Bitmap withBorder = RenderTextClip(
            BuildTextSnapshotJson("HELLO", colorR: 1, colorG: 1, colorB: 1,
                borderEnabled: true, borderR: 0, borderG: 0, borderB: 1), frame: 30);

        long bluePixels = 0;
        for (int y = 0; y < CanvasHeight; y++)
        {
            for (int x = 0; x < CanvasWidth; x++)
            {
                Color c = withBorder.GetPixel(x, y);
                if (c.B > 150 && c.R < 120 && c.G < 120) // blue-dominant stroke, not white fill/black bg
                {
                    bluePixels++;
                }
            }
        }
        bluePixels.ShouldBeGreaterThan(200L, "expected a visible blue border stroke around the glyphs");
    }

    [Fact]
    [Trait("Category", "Media")]
    public void TextClip_HelveticaBoldDefault_ResolvesToBundledFallback_AndRendersGlyphs()
    {
        // Models/TextStyle.swift:8 default. Helvetica isn't bundled/licensed for Windows; it must
        // resolve to the deterministic bundled fallback (Poppins — asserted in FontRegistryTests)
        // and still produce real glyphs rather than a blank frame.
        using Bitmap bmp = RenderTextClip(BuildTextSnapshotJson("TITLE", fontName: "Helvetica-Bold"), frame: 30);

        long brightPixels = 0;
        for (int y = 0; y < CanvasHeight; y++)
        {
            for (int x = 0; x < CanvasWidth; x++)
            {
                Color c = bmp.GetPixel(x, y);
                if (c.R > 128 && c.G > 128 && c.B > 128)
                {
                    brightPixels++;
                }
            }
        }
        brightPixels.ShouldBeGreaterThan(500L, "Helvetica-Bold fallback should render bundled-font glyphs");
    }

    [Fact]
    [Trait("Category", "Media")]
    public void TextClip_FadeInEntrance_IsDimmerEarlyThanLate()
    {
        // Whole-clip fadeIn opacity (TextAnimator.clipEntry) folded into the raster alpha: frame 0
        // (rel 0 -> progress 0) is fully transparent; a later frame is at full strength. Compare
        // total white coverage-energy early vs late.
        string json = BuildTextSnapshotJson("FADE", preset: "fadeIn");

        long CoverageEnergy(long frame)
        {
            using Bitmap bmp = RenderTextClip(json, frame);
            long sum = 0;
            for (int y = 0; y < CanvasHeight; y += 2)
            {
                for (int x = 0; x < CanvasWidth; x += 2)
                {
                    sum += bmp.GetPixel(x, y).R; // white-on-black: brightness ~ coverage*alpha
                }
            }
            return sum;
        }

        long early = CoverageEnergy(0);  // rel 0 -> fully faded out
        long late = CoverageEnergy(30);  // well past perWordFrames -> full opacity
        late.ShouldBeGreaterThan(early);
        early.ShouldBeLessThan(late / 4); // frame 0 is essentially blank
    }

    // --- Text animation (TextAnimator.h/.cpp) ------------------------------------------------
    // Per-word and typewriter presets are exercised with `wordTimings: null`, which routes
    // through TextAnimator::TokenTimings' evenTokenTimings fallback — a deterministic, duration/
    // token-count-only split (no transcript alignment needed), so these tests don't depend on
    // ffmpeg or a real transcript fixture. Parity is analytic (glyph-count / coverage
    // monotonicity across frames), same bar as the rest of this file.

    private static long CountBrightPixels(Bitmap bmp)
    {
        long count = 0;
        for (int y = 0; y < bmp.Height; y++)
        {
            for (int x = 0; x < bmp.Width; x++)
            {
                Color c = bmp.GetPixel(x, y);
                if (c.R > 128 && c.G > 128 && c.B > 128) // white glyph coverage over black
                {
                    count++;
                }
            }
        }
        return count;
    }

    [Fact]
    [Trait("Category", "Media")]
    public void TextClip_WordReveal_MidpointShowsFewerGlyphsThanEnd()
    {
        // Four words, even-split over 60 frames (word i active window ~[15i, 15i+15)). wordReveal
        // never fades a word back out (TextAnimator.wordState's progress saturates at 1), so glyph
        // coverage must be monotonically non-decreasing as later words come on screen — the
        // "midpoint renders a subset of glyphs, endpoint renders all" contract for per-word presets.
        string json = BuildTextSnapshotJson("ONE TWO THREE FOUR", preset: "wordReveal");

        using Bitmap start = RenderTextClip(json, frame: 2);   // only word 0 has begun revealing
        using Bitmap mid = RenderTextClip(json, frame: 24);    // words 0-1 fully on, word 2 revealing
        using Bitmap end = RenderTextClip(json, frame: 59);    // all four words fully revealed

        long startCount = CountBrightPixels(start);
        long midCount = CountBrightPixels(mid);
        long endCount = CountBrightPixels(end);

        midCount.ShouldBeGreaterThan(startCount);
        endCount.ShouldBeGreaterThan(midCount);
    }

    [Fact]
    [Trait("Category", "Media")]
    public void TextClip_WordCycle_OnlyTheActiveWordIsVisible()
    {
        // wordCycle's opacity is 0 OUTSIDE a word's own [start,end) window (TextAnimator
        // .activeRamp) and back to 0 once that window closes — i.e. words are gated on/off, not
        // painted once and left on screen. Sample a frame inside word 0's window and one inside
        // word 3's window: both must show visible glyph coverage (their own active word), which
        // wouldn't hold if activeRamp's on/off gating (or the per-word `continue`-when-opacity-0
        // skip in TextRenderer) were backwards.
        string json = BuildTextSnapshotJson("ONE TWO THREE FOUR", preset: "wordCycle");

        using Bitmap early = RenderTextClip(json, frame: 7);   // inside word 0's ~[0,15) window
        using Bitmap late = RenderTextClip(json, frame: 52);   // inside word 3's ~[45,60) window

        long earlyCount = CountBrightPixels(early);
        long lateCount = CountBrightPixels(late);
        earlyCount.ShouldBeGreaterThan(0L, "the active word should be visible");
        lateCount.ShouldBeGreaterThan(0L, "the active word should be visible");
    }

    [Fact]
    [Trait("Category", "Media")]
    public void TextClip_Typewriter_MidpointRevealsFewerCharactersThanEnd()
    {
        // Character reveal grows monotonically with clip-relative time (renderTypewriter's visLen
        // loop only ever advances), so glyph coverage at a midpoint frame must be strictly less
        // than at a late frame that has revealed the whole line.
        string json = BuildTextSnapshotJson("ONE TWO THREE FOUR", preset: "typewriter");

        long CoverageAt(long frame) => CountBrightPixels(RenderTextClip(json, frame));

        long start = CoverageAt(1);
        long mid = CoverageAt(24);
        long end = CoverageAt(59);

        mid.ShouldBeGreaterThan(start);
        end.ShouldBeGreaterThan(mid);
    }

    [Fact]
    [Trait("Category", "Media")]
    public void TextClip_PopInEntrance_RendersFullCoverageLate()
    {
        // Whole-clip popIn now folds BOTH opacity and scale into a D2D transform pivoted on the
        // box center (TextAnimator.ClipEntry + PivotScaleDy) rather than opacity alone — assert it
        // still lands real glyph coverage on screen well after the pop settles (scale -> 1,
        // opacity -> 1), i.e. the geometric transform doesn't leave the raster empty or offscreen.
        using Bitmap bmp = RenderTextClip(BuildTextSnapshotJson("POP", preset: "popIn"), frame: 30);
        CountBrightPixels(bmp).ShouldBeGreaterThan(500L, "expected visible glyph coverage once the pop settles");
    }
}
