using Serilog;

namespace PalmierPro.Services;

/// Scripted picker answers for headless smoke runs. Enabled via PALMIER_AUTOMATION=1; each
/// PALMIER_AUTO_* var is a semicolon-separated queue consumed in order, one entry per picker
/// invocation. An exhausted or unset queue answers "canceled" — never falls through to a real
/// picker while automation is on.
public static class AutomationMode
{
    public const string EnabledVariable = "PALMIER_AUTOMATION";
    public const string OpenProjectVariable = "PALMIER_AUTO_OPEN_PROJECT";
    public const string SavePathVariable = "PALMIER_AUTO_SAVE_PATH";
    public const string ImportFilesVariable = "PALMIER_AUTO_IMPORT_FILES";
    public const string PickFolderVariable = "PALMIER_AUTO_PICK_FOLDER";

    private static readonly Lock Gate = new();
    private static readonly Dictionary<string, Queue<string>> Queues = [];

    /// Test seam — defaults to the real process environment.
    public static Func<string, string?> EnvironmentReader { get; set; } = Environment.GetEnvironmentVariable;

    public static bool Enabled => EnvironmentReader(EnabledVariable) == "1";

    public static string? NextOpenProjectPath() => Dequeue(OpenProjectVariable, "open-project");

    public static string? NextSavePath() => Dequeue(SavePathVariable, "save-path");

    public static string? NextPickFolder() => Dequeue(PickFolderVariable, "pick-folder");

    /// One semicolon-delimited group is one import invocation's answer; entries within a group
    /// are comma-separated file paths. Never returns an empty list — "null means canceled" is the
    /// same contract every real picker in this codebase already follows.
    public static IReadOnlyList<string>? NextImportFiles()
    {
        var group = Dequeue(ImportFilesVariable, "import-files");
        if (string.IsNullOrEmpty(group))
        {
            return null;
        }
        var files = group.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        return files.Length == 0 ? null : files;
    }

    /// Test seam — drops parsed queues so a re-pointed <see cref="EnvironmentReader"/> is re-read
    /// on the next call instead of serving whatever the first reader returned.
    public static void Reset()
    {
        lock (Gate)
        {
            Queues.Clear();
        }
    }

    private static string? Dequeue(string variable, string kind)
    {
        string? value;
        lock (Gate)
        {
            if (!Queues.TryGetValue(variable, out var queue))
            {
                queue = Parse(EnvironmentReader(variable));
                Queues[variable] = queue;
            }
            queue.TryDequeue(out value);
        }
        Log.Information("automation: answered {Kind} with {Value}", kind, value ?? "(canceled)");
        return value;
    }

    private static Queue<string> Parse(string? raw) =>
        new(string.IsNullOrEmpty(raw)
            ? []
            : raw.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
}
