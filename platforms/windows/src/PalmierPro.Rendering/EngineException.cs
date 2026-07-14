namespace PalmierPro.Rendering;

public sealed class EngineException : Exception
{
    public int StatusCode { get; }

    public EngineException(int statusCode, string? engineMessage)
        : base(string.IsNullOrEmpty(engineMessage) ? $"PalmierEngine call failed (status {statusCode})." : engineMessage)
    {
        StatusCode = statusCode;
    }
}
