namespace PalmierPro.Services.Project;

/// Per-machine app-state location. Mac has no equivalent file (the registry lives inside
/// `Project.storageDirectory`, alongside the projects themselves); the Windows port instead
/// follows platform convention and puts non-document app state under `%LOCALAPPDATA%`.
public static class AppPaths
{
    public static string AppDataDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PalmierPro");

    public static string RegistryFilePath => Path.Combine(AppDataDirectory, ProjectPackage.RegistryFilename);

    /// Windows analogue of Mac's `DiskCache.rootDirectory` (`~/Library/Caches/PalmierPro`) —
    /// regenerable derived data (filmstrip/waveform sprites, etc.), separate from the app-state
    /// `AppDataDirectory` above so a "clear cache" action can safely wipe just this subtree.
    public static string CacheDirectory => Path.Combine(AppDataDirectory, "Cache");

    public static void EnsureAppDataDirectory() => Directory.CreateDirectory(AppDataDirectory);

    public static void EnsureCacheDirectory() => Directory.CreateDirectory(CacheDirectory);
}
