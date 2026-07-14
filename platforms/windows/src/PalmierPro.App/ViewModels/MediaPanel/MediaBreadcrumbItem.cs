namespace PalmierPro.App.ViewModels.MediaPanel;

/// One crumb in the folder path bar; FolderId null means the library root.
public sealed record MediaBreadcrumbItem(string? FolderId, string Name);
