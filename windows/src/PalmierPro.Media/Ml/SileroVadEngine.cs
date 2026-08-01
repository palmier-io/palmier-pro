using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;
using PalmierPro.Core.Analysis;

namespace PalmierPro.Media.Ml;

public sealed class SileroVadEngine : IVadEngine, IDisposable
{
    private const int SampleRate = 16000;
    private const int WindowSamples = 512;
    private const int ContextSamples = 64;
    private const float SpeechThreshold = 0.5f;

    private readonly InferenceSession? _session;
    private readonly object _gate = new();

    public SileroVadEngine()
    {
        var path = LocalModelPaths.ResolveSileroModel();
        if (path is null) return;

        try
        {
            var options = new SessionOptions
            {
                InterOpNumThreads = 1,
                IntraOpNumThreads = 1,
                EnableCpuMemArena = true,
            };
            _session = new InferenceSession(path, options);
        }
        catch
        {
            // EnergyVad remains the effective fallback via VadService registration.
        }
    }

    public bool IsAvailable => _session is not null;

    public bool[] SpeechMask(ReadOnlySpan<float> mono16k)
    {
        if (_session is null || mono16k.IsEmpty)
            return EnergyVadEngine.Instance.SpeechMask(mono16k);

        lock (_gate)
        {
            var cells = (mono16k.Length + WindowSamples - 1) / WindowSamples;
            var mask = new bool[cells];
            var state = CreateZeroState();
            var context = new float[ContextSamples];

            for (var cell = 0; cell < cells; cell++)
            {
                var offset = cell * WindowSamples;
                var chunk = new float[WindowSamples];
                var available = Math.Min(WindowSamples, mono16k.Length - offset);
                mono16k.Slice(offset, available).CopyTo(chunk);

                var input = new float[ContextSamples + WindowSamples];
                context.CopyTo(input.AsSpan(0, ContextSamples));
                chunk.CopyTo(input.AsSpan(ContextSamples));

                var prob = RunChunk(input, state, out state);
                mask[cell] = prob >= SpeechThreshold;
                Array.Copy(input, input.Length - ContextSamples, context, 0, ContextSamples);
            }

            return mask;
        }
    }

    public void Dispose() => _session?.Dispose();

    private float RunChunk(float[] input, float[][][] state, out float[][][] newState)
    {
        var session = _session!;
        var inputTensor = new DenseTensor<float>(input, [1, input.Length]);
        var stateFlat = state.SelectMany(l => l.SelectMany(r => r)).ToArray();
        var stateTensor = new DenseTensor<float>(stateFlat, [2, 1, 128]);
        var srTensor = new DenseTensor<long>(new long[] { SampleRate }, new int[] { 1 });

        using var results = session.Run([
            NamedOnnxValue.CreateFromTensor("input", inputTensor),
            NamedOnnxValue.CreateFromTensor("state", stateTensor),
            NamedOnnxValue.CreateFromTensor("sr", srTensor),
        ]);

        var output = results.First(o => o.Name == "output").AsEnumerable<float>().First();
        var stateOut = results.First(o => o.Name == "stateN").AsTensor<float>();
        newState = TensorToState(stateOut);
        return output;
    }

    private static float[][][] CreateZeroState()
    {
        var state = new float[2][][];
        for (var i = 0; i < 2; i++)
        {
            state[i] = [new float[128]];
        }
        return state;
    }

    private static float[][][] TensorToState(Tensor<float> tensor)
    {
        var state = new float[tensor.Dimensions[0]][][];
        for (var i = 0; i < tensor.Dimensions[0]; i++)
        {
            state[i] = new float[tensor.Dimensions[1]][];
            for (var j = 0; j < tensor.Dimensions[1]; j++)
            {
                state[i][j] = new float[tensor.Dimensions[2]];
                for (var k = 0; k < tensor.Dimensions[2]; k++)
                    state[i][j][k] = tensor[i, j, k];
            }
        }
        return state;
    }
}
