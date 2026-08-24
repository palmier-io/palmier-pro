using System.Drawing;
using System.Drawing.Imaging;
using NAudio.Wave;
using PalmierPro.Media.Audio;
using PalmierPro.Media.Images;
using Xunit;

namespace PalmierPro.Media.Tests;

public class DecodePipelineTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "palmier-media-" + Guid.NewGuid().ToString("N"));

    public DecodePipelineTests() => Directory.CreateDirectory(_root);

    public void Dispose()
    {
        try { Directory.Delete(_root, recursive: true); } catch { }
    }

    [Fact]
    public void ImageThumbnailScalesDownPreservingAspect()
    {
        var path = Path.Combine(_root, "wide.png");
        using (var source = new Bitmap(1600, 800))
        {
            using var graphics = Graphics.FromImage(source);
            graphics.Clear(Color.Coral);
            source.Save(path, ImageFormat.Png);
        }

        using var thumb = ImageThumbnailer.Thumbnail(path, 320);
        Assert.NotNull(thumb);
        Assert.Equal(320, thumb!.Width);
        Assert.Equal(160, thumb.Height);

        var jpeg = ImageThumbnailer.EncodeJpeg(thumb, 0.75);
        Assert.True(jpeg.Length > 100);
        Assert.Equal(0xFF, jpeg[0]);
        Assert.Equal(0xD8, jpeg[1]);
    }

    [Fact]
    public void SmallerImageIsNotUpscaled()
    {
        var path = Path.Combine(_root, "small.png");
        using (var source = new Bitmap(100, 60))
        {
            source.Save(path, ImageFormat.Png);
        }
        using var thumb = ImageThumbnailer.Thumbnail(path, 320);
        Assert.Equal(100, thumb!.Width);
        Assert.Equal(60, thumb.Height);
    }

    [Fact]
    public async Task WaveformFromSineWavIsLoudAndSized()
    {
        var path = Path.Combine(_root, "tone.wav");
        WriteSineWav(path, seconds: 2.0, frequency: 440, amplitude: 0.8f);

        var envelope = await WaveformExtractor.PeakEnvelopeAsync(path);

        // 2 s at 200 samples/s ⇒ ~400 hops (codec padding allows slack).
        Assert.InRange(envelope.Length, 380, 420);
        Assert.All(envelope, v => Assert.InRange(v, 0f, 1f));
        // 0.8 amplitude ≈ -1.9 dB ⇒ normalized ≈ 0.039 (0 = loud).
        Assert.True(envelope.Average() < 0.1f);
    }

    [Fact]
    public async Task WaveformOfSilenceIsOne()
    {
        var path = Path.Combine(_root, "silence.wav");
        WriteSineWav(path, seconds: 0.5, frequency: 440, amplitude: 0f);
        var envelope = await WaveformExtractor.PeakEnvelopeAsync(path);
        Assert.All(envelope, v => Assert.Equal(1f, v));
    }

    private static void WriteSineWav(string path, double seconds, double frequency, float amplitude)
    {
        var format = new WaveFormat(44100, 16, 1);
        using var writer = new WaveFileWriter(path, format);
        var total = (int)(seconds * format.SampleRate);
        var samples = new float[total];
        for (var i = 0; i < total; i++)
            samples[i] = amplitude * (float)Math.Sin(2 * Math.PI * frequency * i / format.SampleRate);
        writer.WriteSamples(samples, 0, total);
    }
}
