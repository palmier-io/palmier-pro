using System.Globalization;

namespace PalmierPro.Core.Localization;

/// <summary>
/// App-owned UI strings. English catalog is the source inventory; additional locales
/// overlay keys when present. Agent/MCP contracts stay English.
/// </summary>
public static class L10n
{
    private static readonly Dictionary<string, string> En = new(StringComparer.Ordinal)
    {
        ["home.welcome"] = "Welcome to Palmier Pro",
        ["home.myProjects"] = "My Projects",
        ["home.sampleProjects"] = "Sample Projects",
        ["home.newProject"] = "New Project",
        ["home.openProject"] = "Open Project",
        ["home.account"] = "Account",
        ["home.accountSignedIn"] = "{0} · {1} credits",
        ["home.settings"] = "Settings",
        ["home.noProjects"] = "No projects yet",
        ["home.noProjectsHint"] = "Create a new project to get started.",
        ["settings.title"] = "Settings",
        ["settings.general"] = "General",
        ["settings.appearance"] = "Appearance",
        ["settings.privacy"] = "Privacy",
        ["settings.agent"] = "Agent",
        ["settings.storage"] = "Storage",
        ["settings.updates"] = "Updates",
        ["settings.language"] = "Language",
        ["settings.appearanceMode"] = "Appearance",
        ["settings.shareUsage"] = "Share usage data",
        ["settings.crashReports"] = "Send crash reports",
        ["settings.mcpEnabled"] = "Enable MCP server",
        ["settings.clearCaches"] = "Clear caches",
        ["settings.checkUpdates"] = "Check for updates",
        ["settings.restartNote"] = "Language changes apply the next time you open Palmier Pro.",
        ["account.signedOut"] = "Signed out",
        ["common.close"] = "Close",
        ["common.ok"] = "OK",
        ["common.cancel"] = "Cancel",
        ["common.save"] = "Save",
        ["common.delete"] = "Delete",
        ["common.open"] = "Open",
        ["editor.export"] = "Export",
        ["editor.import"] = "Import",
        ["editor.media"] = "Media",
        ["editor.audio"] = "Audio",
        ["editor.search"] = "Search",
        ["editor.captions"] = "Captions",
        ["editor.generation"] = "Generation",
        ["editor.inspector"] = "Inspector",
        ["editor.scopes"] = "Scopes",
        ["editor.undo"] = "Undo",
        ["editor.play"] = "Play",
        ["editor.pause"] = "Pause",
        ["editor.agent"] = "Agent",
        ["editor.mediaOffline"] = "Media Offline",
        ["editor.format"] = "Format",
        ["editor.resolution"] = "Resolution",
        ["home.fileMissing"] = "File missing",
    };

    private static readonly Dictionary<string, Dictionary<string, string>> Overlays = new(StringComparer.OrdinalIgnoreCase)
    {
        ["es"] = new(StringComparer.Ordinal)
        {
            ["home.welcome"] = "Bienvenido a Palmier Pro",
            ["home.myProjects"] = "Mis proyectos",
            ["home.settings"] = "Ajustes",
            ["home.newProject"] = "Nuevo proyecto",
            ["home.openProject"] = "Abrir proyecto",
            ["common.close"] = "Cerrar",
            ["common.cancel"] = "Cancelar",
            ["settings.title"] = "Ajustes",
            ["editor.export"] = "Exportar",
            ["editor.import"] = "Importar",
            ["editor.media"] = "Medios",
            ["editor.inspector"] = "Inspector",
            ["editor.play"] = "Reproducir",
            ["editor.pause"] = "Pausa",
        },
        ["fr"] = new(StringComparer.Ordinal)
        {
            ["home.welcome"] = "Bienvenue dans Palmier Pro",
            ["home.myProjects"] = "Mes projets",
            ["home.settings"] = "Réglages",
            ["home.newProject"] = "Nouveau projet",
            ["home.openProject"] = "Ouvrir un projet",
            ["common.close"] = "Fermer",
            ["common.cancel"] = "Annuler",
            ["settings.title"] = "Réglages",
            ["editor.export"] = "Exporter",
            ["editor.import"] = "Importer",
            ["editor.media"] = "Médias",
            ["editor.inspector"] = "Inspecteur",
            ["editor.play"] = "Lecture",
            ["editor.pause"] = "Pause",
        },
        ["ja"] = new(StringComparer.Ordinal)
        {
            ["home.welcome"] = "Palmier Proへようこそ",
            ["home.myProjects"] = "プロジェクト",
            ["home.settings"] = "設定",
            ["home.newProject"] = "新規プロジェクト",
            ["home.openProject"] = "プロジェクトを開く",
            ["common.close"] = "閉じる",
            ["common.cancel"] = "キャンセル",
            ["settings.title"] = "設定",
        },
        ["zh-Hans"] = new(StringComparer.Ordinal)
        {
            ["home.welcome"] = "欢迎使用 Palmier Pro",
            ["home.myProjects"] = "我的项目",
            ["home.settings"] = "设置",
            ["home.newProject"] = "新建项目",
            ["home.openProject"] = "打开项目",
            ["common.close"] = "关闭",
            ["common.cancel"] = "取消",
            ["settings.title"] = "设置",
        },
    };

    public static IReadOnlyList<string> SupportedLanguages { get; } =
        ["en", "es", "fr", "ja", "zh-Hans", "de", "pt-BR", "ko", "it", "ru", "tr", "vi", "ar", "hi", "zh-Hant"];

    private static string _language = "en";

    public static string Language
    {
        get => _language;
        set => _language = Normalize(value);
    }

    public static string String(string key)
    {
        if (Overlays.TryGetValue(_language, out var overlay)
            && overlay.TryGetValue(key, out var localized))
            return localized;
        return En.TryGetValue(key, out var en) ? en : key;
    }

    public static string String(string key, params object[] args)
        => string.Format(CultureInfo.CurrentCulture, String(key), args);

    public static string Key(string value) => value;

    public static string Normalize(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return "en";
        raw = raw.Trim().Replace('_', '-');
        if (SupportedLanguages.Contains(raw, StringComparer.OrdinalIgnoreCase))
            return SupportedLanguages.First(l => l.Equals(raw, StringComparison.OrdinalIgnoreCase));
        var prefix = raw.Split('-')[0];
        return SupportedLanguages.FirstOrDefault(l =>
            l.Equals(prefix, StringComparison.OrdinalIgnoreCase)
            || l.StartsWith(prefix + "-", StringComparison.OrdinalIgnoreCase)) ?? "en";
    }
}
