using Xunit;

namespace PalmierPro.Agent.Tests;

/// <summary>
/// Serializes tests that mutate the process-global <c>LocalStt.Transcriber</c>.
/// Parallel runs otherwise race and return the wrong stub transcript.
/// </summary>
[CollectionDefinition(Name, DisableParallelization = true)]
public sealed class LocalSttCollection : ICollectionFixture<object>
{
    public const string Name = "LocalStt";
}
