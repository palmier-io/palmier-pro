using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace PalmierPro.Core.Analysis;

/// <summary>Decode any NAudio-readable file to mono float PCM at a target rate.</summary>
public static class AudioPcmDecoder
{
    public static float[] DecodeMono(string path, int sampleRate)
    {
        using var reader = new AudioFileReader(path);
        ISampleProvider mono = reader.WaveFormat.Channels == 1
            ? reader
            : reader.ToMono();
        if (mono.WaveFormat.SampleRate != sampleRate)
            mono = new WdlResamplingSampleProvider(mono, sampleRate);

        var buffer = new float[sampleRate]; // 1s chunks
        var samples = new List<float>((int)(reader.TotalTime.TotalSeconds * sampleRate) + sampleRate);
        int read;
        while ((read = mono.Read(buffer, 0, buffer.Length)) > 0)
        {
            for (var i = 0; i < read; i++)
                samples.Add(buffer[i]);
        }
        return samples.ToArray();
    }
}
