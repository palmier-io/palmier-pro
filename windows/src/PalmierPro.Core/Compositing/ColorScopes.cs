namespace PalmierPro.Core.Compositing;

/// <summary>
/// Pure color-scope analysis over a BGRA frame. Ports Mac ColorScopes sampling:
/// histogram (R/G/B/Luma) and waveform (per-column luma distribution).
/// </summary>
public static class ColorScopes
{
    public const int HistogramBins = 256;
    public const int WaveformHeight = 256;

    public sealed record Histogram(
        int[] Red, int[] Green, int[] Blue, int[] Luma, int SampleCount);

    public sealed record Waveform(int Width, int Height, float[] Densities);

    public static Histogram ComputeHistogram(ReadOnlySpan<byte> bgra, int width, int height, int stride)
    {
        var red = new int[HistogramBins];
        var green = new int[HistogramBins];
        var blue = new int[HistogramBins];
        var luma = new int[HistogramBins];
        var count = 0;
        for (var y = 0; y < height; y++)
        {
            var row = y * stride;
            for (var x = 0; x < width; x++)
            {
                var i = row + x * 4;
                var b = bgra[i];
                var g = bgra[i + 1];
                var r = bgra[i + 2];
                red[r]++;
                green[g]++;
                blue[b]++;
                var yL = (int)Math.Clamp(Math.Round(0.2126 * r + 0.7152 * g + 0.0722 * b), 0, 255);
                luma[yL]++;
                count++;
            }
        }
        return new Histogram(red, green, blue, luma, count);
    }

    /// <summary>
    /// Column-wise luma density: for each output column, accumulate source pixels into
    /// 256 luma rows (0 = black at bottom). Densities are normalized 0…1 per column max.
    /// </summary>
    public static Waveform ComputeWaveform(
        ReadOnlySpan<byte> bgra, int width, int height, int stride, int outputWidth)
    {
        outputWidth = Math.Max(1, Math.Min(outputWidth, width));
        var densities = new float[outputWidth * WaveformHeight];
        var columnMax = new float[outputWidth];

        for (var y = 0; y < height; y++)
        {
            var row = y * stride;
            for (var x = 0; x < width; x++)
            {
                var i = row + x * 4;
                var b = bgra[i];
                var g = bgra[i + 1];
                var r = bgra[i + 2];
                var yL = (int)Math.Clamp(Math.Round(0.2126 * r + 0.7152 * g + 0.0722 * b), 0, 255);
                var col = x * outputWidth / width;
                // Waveform draws black at the bottom: row 0 = luma 0.
                var index = yL * outputWidth + col;
                densities[index] += 1f;
                if (densities[index] > columnMax[col]) columnMax[col] = densities[index];
            }
        }

        for (var col = 0; col < outputWidth; col++)
        {
            var max = columnMax[col];
            if (max <= 0) continue;
            for (var row = 0; row < WaveformHeight; row++)
                densities[row * outputWidth + col] /= max;
        }

        return new Waveform(outputWidth, WaveformHeight, densities);
    }
}
