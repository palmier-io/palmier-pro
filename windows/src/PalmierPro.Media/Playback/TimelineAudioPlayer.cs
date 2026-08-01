using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using PalmierPro.Core.Models;
using PalmierPro.Core.Playback;

namespace PalmierPro.Media.Playback;

/// <summary>
/// WASAPI playback of the timeline's audible clips. The mixer renders each active clip
/// from its own source reader with the shared volume automation (static × keyframes ×
/// fades) sampled per buffer. Scrub audio grains come later; this covers transport play.
/// </summary>
public sealed class TimelineAudioPlayer : IDisposable
{
    public const int SampleRate = 48_000;
    public const int Channels = 2;

    private readonly object _lock = new();
    private WasapiOutWrapper? _output;
    private Timeline? _timeline;
    private Dictionary<string, string> _mediaPaths = [];
    private Dictionary<string, Timeline> _sequences = [];

    public void Rebuild(
        Timeline timeline, IReadOnlyDictionary<string, string> mediaPaths,
        IReadOnlyDictionary<string, Timeline>? sequences = null)
    {
        lock (_lock)
        {
            _timeline = timeline;
            _mediaPaths = new Dictionary<string, string>(mediaPaths);
            _sequences = sequences is null ? [] : new Dictionary<string, Timeline>(sequences);
        }
    }

    public void Start(Timeline timeline, int fromFrame, double rate)
    {
        lock (_lock)
        {
            StopLocked();
            _timeline = timeline;
            var mixer = new TimelineMixerProvider(timeline, _mediaPaths, _sequences, fromFrame, rate);
            try
            {
                _output = new WasapiOutWrapper(mixer);
            }
            catch (Exception)
            {
                _output = null; // No audio device: video playback continues silently.
            }
        }
    }

    public void Stop()
    {
        lock (_lock) StopLocked();
    }

    private void StopLocked()
    {
        _output?.Dispose();
        _output = null;
    }

    public void Dispose() => Stop();

    private sealed class WasapiOutWrapper : IDisposable
    {
        private readonly WasapiOut _out;
        private readonly TimelineMixerProvider _mixer;

        public WasapiOutWrapper(TimelineMixerProvider mixer)
        {
            _mixer = mixer;
            _out = new WasapiOut(NAudio.CoreAudioApi.AudioClientShareMode.Shared, useEventSync: true, latency: 60);
            _out.Init(mixer);
            _out.Play();
        }

        public void Dispose()
        {
            try { _out.Stop(); } catch { }
            _out.Dispose();
            _mixer.Dispose();
        }
    }
}

/// <summary>
/// Pull-based mixer: tracks a timeline position advancing at the playback rate and
/// mixes every audible clip under it, applying the clip's mixed gain per buffer.
/// </summary>
internal sealed class TimelineMixerProvider : ISampleProvider, IDisposable
{
    private readonly Timeline _timeline;
    private readonly Dictionary<string, string> _mediaPaths;
    private readonly Dictionary<string, Timeline> _sequences;
    private readonly double _rate;
    private readonly int _fps;
    private double _timelineSeconds;
    private readonly Dictionary<string, ClipReader> _readers = [];
    private readonly object _lock = new();
    private bool _disposed;

    public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(
        TimelineAudioPlayer.SampleRate, TimelineAudioPlayer.Channels);

    public TimelineMixerProvider(
        Timeline timeline, Dictionary<string, string> mediaPaths,
        Dictionary<string, Timeline> sequences, int fromFrame, double rate)
    {
        _timeline = timeline;
        _mediaPaths = mediaPaths;
        _sequences = sequences;
        _rate = rate;
        _fps = Math.Max(1, timeline.Fps);
        _timelineSeconds = fromFrame / (double)_fps;
    }

    public int Read(float[] buffer, int offset, int count)
    {
        Array.Clear(buffer, offset, count);
        lock (_lock)
        {
            if (_disposed) return count;
            var framesRequested = count / TimelineAudioPlayer.Channels;
            var bufferSeconds = framesRequested / (double)TimelineAudioPlayer.SampleRate * _rate;
            var timelineFrame = (int)(_timelineSeconds * _fps);

            var audible = TimelineFrameRouter.AudibleClipsAt(
                _timeline, timelineFrame, id => _sequences.GetValueOrDefault(id));
            foreach (var entry in audible)
            {
                if (!_mediaPaths.TryGetValue(entry.Clip.MediaRef, out var path)) continue;
                var playPath = path;
                if (entry.Clip.HasDenoiseEnabled
                    && PalmierPro.Media.Audio.AudioEnhancer.CachedDenoisedPath(entry.Clip.MediaRef) is { } wet)
                    playPath = wet;
                var reader = ReaderFor(entry.Clip, playPath);
                var gain = (float)entry.Gain;
                if (entry.Clip.HasDenoiseEnabled && playPath == path)
                    gain *= (float)(1.0 - entry.Clip.DenoiseAmount * 0.15); // dry fallback cue
                reader?.MixInto(buffer, offset, count, entry.SourceSeconds, gain, _rate * entry.Clip.Speed);
            }

            _timelineSeconds += bufferSeconds;
            return count;
        }
    }

    private ClipReader? ReaderFor(Clip clip, string path)
    {
        if (_readers.TryGetValue(clip.Id, out var existing)) return existing;
        try
        {
            var reader = new ClipReader(path);
            _readers[clip.Id] = reader;
            return reader;
        }
        catch (Exception)
        {
            return null;
        }
    }

    public void Dispose()
    {
        lock (_lock)
        {
            _disposed = true;
            foreach (var reader in _readers.Values) reader.Dispose();
            _readers.Clear();
        }
    }

    /// <summary>One source's decode chain: MF reader → float samples → 48 kHz stereo.</summary>
    private sealed class ClipReader : IDisposable
    {
        private readonly MediaFoundationReader _reader;
        private readonly ISampleProvider _chain;
        private double _positionSeconds = double.NaN;

        public ClipReader(string path)
        {
            _reader = new MediaFoundationReader(path);
            ISampleProvider chain = _reader.ToSampleProvider();
            if (chain.WaveFormat.Channels == 1) chain = new MonoToStereoSampleProvider(chain);
            if (chain.WaveFormat.SampleRate != TimelineAudioPlayer.SampleRate)
                chain = new WdlResamplingSampleProvider(chain, TimelineAudioPlayer.SampleRate);
            _chain = chain;
        }

        public void MixInto(float[] buffer, int offset, int count, double sourceSeconds, float gain, double consumeRate)
        {
            // Reposition when the requested source time drifted from sequential reading
            // (seek, clip boundary, or speed change). 40 ms tolerance avoids re-seeking
            // every buffer from rounding.
            if (double.IsNaN(_positionSeconds) || Math.Abs(sourceSeconds - _positionSeconds) > 0.04)
            {
                _reader.CurrentTime = TimeSpan.FromSeconds(Math.Max(0, sourceSeconds));
                _positionSeconds = sourceSeconds;
            }

            var temp = new float[count];
            var read = ReadRate(temp, count, consumeRate);
            for (var i = 0; i < read; i++)
                buffer[offset + i] += temp[i] * gain;
            _positionSeconds += count / (double)TimelineAudioPlayer.Channels
                / TimelineAudioPlayer.SampleRate * consumeRate;
        }

        /// <summary>Reads at 1× directly; for other speeds consumes proportionally more or
        /// fewer source samples with nearest-sample mapping (preview-quality retiming).</summary>
        private int ReadRate(float[] destination, int count, double consumeRate)
        {
            if (Math.Abs(consumeRate - 1.0) < 0.001)
                return _chain.Read(destination, 0, count);

            var sourceCount = (int)(count * consumeRate) / TimelineAudioPlayer.Channels
                * TimelineAudioPlayer.Channels;
            if (sourceCount <= 0) return 0;
            var source = new float[sourceCount];
            var read = _chain.Read(source, 0, sourceCount);
            if (read == 0) return 0;
            var sourceFrames = read / TimelineAudioPlayer.Channels;
            var destinationFrames = count / TimelineAudioPlayer.Channels;
            for (var frame = 0; frame < destinationFrames; frame++)
            {
                var sourceFrame = Math.Min(sourceFrames - 1, (int)(frame * consumeRate));
                for (var channel = 0; channel < TimelineAudioPlayer.Channels; channel++)
                    destination[frame * TimelineAudioPlayer.Channels + channel] =
                        source[sourceFrame * TimelineAudioPlayer.Channels + channel];
            }
            return count;
        }

        public void Dispose() => _reader.Dispose();
    }
}
