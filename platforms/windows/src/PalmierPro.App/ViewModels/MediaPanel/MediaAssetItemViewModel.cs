using CommunityToolkit.Mvvm.ComponentModel;
using PalmierPro.Core.Models;
using PalmierPro.Services.Media;

namespace PalmierPro.App.ViewModels.MediaPanel;

/// Grid tile for one MediaAsset — mirrors AssetThumbnailView.swift's bindable surface. Deliberately
/// WinUI-free (no ImageSource/WriteableBitmap property) so PalmierPro.App.Tests can instantiate and
/// assert on it directly; AssetTileControl (the View) owns turning <see cref="VisualCache"/> +
/// <see cref="Id"/> into pixels on the UI thread.
public sealed partial class MediaAssetItemViewModel : ObservableObject
{
    public string Id { get; }
    public string Url { get; }
    public ClipType Type { get; }

    /// The cache instance backing this asset's thumbnails — passed through so the View can look up
    /// and render frames without the ViewModel layer touching any WinUI type.
    public MediaVisualCache VisualCache { get; }

    [ObservableProperty]
    public partial string Name { get; set; }

    [ObservableProperty]
    public partial double Duration { get; set; }

    [ObservableProperty]
    public partial bool IsMissing { get; set; }

    public string DurationLabel
    {
        get
        {
            var total = (int)Duration;
            return $"{total / 60:D2}:{total % 60:D2}";
        }
    }

    public bool ShowsDuration => (Type == ClipType.Video || Type == ClipType.Audio) && Duration > 0;

    /// Fires when MediaVisualCache publishes a new (possibly partial) thumbnail batch for this
    /// asset — see MediaVisualCache.ThumbnailsUpdated. Raised off the calling thread; the View
    /// marshals to the UI thread before touching any WinUI object.
    public event EventHandler? ThumbnailsChanged;

    public MediaAssetItemViewModel(MediaAsset asset, MediaVisualCache visualCache)
    {
        Id = asset.Id;
        Url = asset.Url;
        Type = asset.Type;
        Name = asset.Name;
        Duration = asset.Duration;
        VisualCache = visualCache;
    }

    partial void OnDurationChanged(double value)
    {
        OnPropertyChanged(nameof(DurationLabel));
        OnPropertyChanged(nameof(ShowsDuration));
    }

    internal void RaiseThumbnailsChanged() => ThumbnailsChanged?.Invoke(this, EventArgs.Empty);
}
