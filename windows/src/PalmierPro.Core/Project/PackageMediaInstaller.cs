namespace PalmierPro.Core.Project;

/// <summary>
/// Installs staged media bytes into the live package's media/ folder through the
/// coordinator: stage → prepare next to the package → admit → atomic install.
/// Retries when a concurrent Save As rebases the package path mid-flight.
/// </summary>
public sealed class PackageMediaInstaller(ProjectPackageCoordinator coordinator)
{
    public const string MediaDirectoryName = "media";
    private const int MaxRetries = 3;

    /// <summary>
    /// Returns the installed absolute path. The staged source file is always consumed.
    /// When the project has no package yet, the file moves to a temp home instead.
    /// </summary>
    public async Task<string> CommitStagedMediaAsync(
        string stagedPath,
        string filename,
        Func<string?> currentProjectPath,
        bool workAlreadyAdmitted = false,
        long? maxBytes = null,
        CancellationToken ct = default)
    {
        try
        {
            if (currentProjectPath() is null)
            {
                var home = Path.Combine(Path.GetTempPath(), "palmier-unsaved-" + Guid.NewGuid().ToString("N"));
                var destination = Path.Combine(home, filename);
                await Task.Run(() => FileIO.MoveReplacingDestination(stagedPath, destination), ct)
                    .ConfigureAwait(false);
                return destination;
            }

            for (var attempt = 0; attempt < MaxRetries; attempt++)
            {
                ct.ThrowIfCancellationRequested();
                var target = currentProjectPath();
                if (target is null) throw new FileNotFoundException("Project package went away.", filename);

                var prepared = await Task.Run(
                    () => FileIO.PrepareStagedFile(stagedPath, target, maxBytes), ct).ConfigureAwait(false);

                var admittedHere = false;
                try
                {
                    ct.ThrowIfCancellationRequested();
                    if (!workAlreadyAdmitted)
                    {
                        coordinator.BeginMutation(ct);
                        admittedHere = true;
                    }

                    var installed = await coordinator.PerformMutationAsync<string?>(() =>
                    {
                        // A Save As between prepare and install rebases the package; retry.
                        if (currentProjectPath() != target) return null;
                        var destination = Path.Combine(target, MediaDirectoryName, filename);
                        FileIO.InstallPreparedFile(prepared, destination);
                        return destination;
                    }, ct).ConfigureAwait(false);

                    if (installed is not null) return installed;
                }
                finally
                {
                    if (admittedHere) coordinator.EndMutation();
                    try { if (File.Exists(prepared)) File.Delete(prepared); } catch { }
                }
            }
            throw new FileNotFoundException("Could not install media into the project package.", filename);
        }
        finally
        {
            try { if (File.Exists(stagedPath)) File.Delete(stagedPath); } catch { }
        }
    }
}
