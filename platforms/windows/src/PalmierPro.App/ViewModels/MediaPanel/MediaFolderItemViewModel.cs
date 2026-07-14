using CommunityToolkit.Mvvm.ComponentModel;

namespace PalmierPro.App.ViewModels.MediaPanel;

/// Grid tile for one MediaFolder — mirrors FolderTileView.swift's bindable surface.
public sealed partial class MediaFolderItemViewModel : ObservableObject
{
    public string Id { get; }

    [ObservableProperty]
    public partial string Name { get; set; }

    [ObservableProperty]
    public partial int ChildCount { get; set; }

    public MediaFolderItemViewModel(string id, string name, int childCount)
    {
        Id = id;
        Name = name;
        ChildCount = childCount;
    }
}
