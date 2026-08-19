using System.Text.Json.Serialization;

namespace PalmierPro.Core.Settings;

/// <summary>Persisted app preferences — Mac UserDefaults parity subset.</summary>
public sealed class AppSettings
{
    [JsonPropertyName("appLanguage")] public string AppLanguage { get; set; } = "en";
    [JsonPropertyName("appAppearance")] public string AppAppearance { get; set; } = "system"; // system|dark|light
    [JsonPropertyName("telemetryEnabled")] public bool TelemetryEnabled { get; set; } = true;
    [JsonPropertyName("analyticsEnabled")] public bool AnalyticsEnabled { get; set; } = true;
    [JsonPropertyName("notificationsEnabled")] public bool NotificationsEnabled { get; set; } = true;
    [JsonPropertyName("mcpEnabled")] public bool McpEnabled { get; set; } = true;
    [JsonPropertyName("agentModel")] public string AgentModel { get; set; } = "claude-sonnet-4-20250514";
    [JsonPropertyName("agentPanelVisible")] public bool AgentPanelVisible { get; set; } = true;
    [JsonPropertyName("mediaPanelVisible")] public bool MediaPanelVisible { get; set; } = true;
    [JsonPropertyName("inspectorPanelVisible")] public bool InspectorPanelVisible { get; set; } = true;
    [JsonPropertyName("keyframesPanelVisible")] public bool KeyframesPanelVisible { get; set; } = false;
    [JsonPropertyName("markDeadAir")] public bool MarkDeadAir { get; set; } = true;
    [JsonPropertyName("markBeats")] public bool MarkBeats { get; set; } = true;
    [JsonPropertyName("markSpeakers")] public bool MarkSpeakers { get; set; } = true;
    [JsonPropertyName("searchIndexEnabled")] public bool SearchIndexEnabled { get; set; } = true;
    [JsonPropertyName("hasSeenWelcome")] public bool HasSeenWelcome { get; set; }
    [JsonPropertyName("lastSeenVersion")] public string? LastSeenVersion { get; set; }
    [JsonPropertyName("samplesSectionExpanded")] public bool SamplesSectionExpanded { get; set; } = true;
    [JsonPropertyName("updateFeedUrl")] public string? UpdateFeedUrl { get; set; }
    /// <summary>On-device Whisper size: tiny | base | small (ggml-*.bin).</summary>
    [JsonPropertyName("whisperModelSize")] public string WhisperModelSize { get; set; } = "tiny";
}
