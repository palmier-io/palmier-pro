using System.Text.Json;

namespace PalmierPro.Core.Settings;

/// <summary>JSON settings under %LOCALAPPDATA%\PalmierPro\settings.json.</summary>
public sealed class SettingsStore
{
    public static SettingsStore Shared { get; } = new();

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true,
    };

    private readonly string _path;
    private AppSettings _settings = new();
    private readonly object _gate = new();

    public event Action? Changed;

    public SettingsStore(string? path = null)
    {
        _path = path ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "PalmierPro", "settings.json");
        Load();
    }

    public AppSettings Current
    {
        get { lock (_gate) return Clone(_settings); }
    }

    public void Update(Action<AppSettings> mutate)
    {
        lock (_gate)
        {
            mutate(_settings);
            SaveUnlocked();
        }
        Changed?.Invoke();
    }

    public void Replace(AppSettings settings)
    {
        lock (_gate)
        {
            _settings = Clone(settings);
            SaveUnlocked();
        }
        Changed?.Invoke();
    }

    public void Load()
    {
        lock (_gate)
        {
            try
            {
                if (!File.Exists(_path))
                {
                    _settings = new AppSettings();
                    return;
                }
                var json = File.ReadAllText(_path);
                _settings = JsonSerializer.Deserialize<AppSettings>(json, JsonOptions) ?? new AppSettings();
            }
            catch
            {
                _settings = new AppSettings();
            }
        }
    }

    private void SaveUnlocked()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        var json = JsonSerializer.Serialize(_settings, JsonOptions);
        var tmp = _path + ".tmp";
        File.WriteAllText(tmp, json);
        File.Move(tmp, _path, overwrite: true);
    }

    private static AppSettings Clone(AppSettings s)
        => JsonSerializer.Deserialize<AppSettings>(JsonSerializer.Serialize(s, JsonOptions), JsonOptions)
           ?? new AppSettings();
}
