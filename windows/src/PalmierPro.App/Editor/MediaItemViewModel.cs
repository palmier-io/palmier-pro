using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Media.Imaging;
using PalmierPro.Core.Models;
using PalmierPro.Media.Images;
using PalmierPro.Media.Video;

namespace PalmierPro.App.Editor;

/// <summary>
/// A media panel tile: the runtime asset plus its lazily loaded ~320 px library
/// thumbnail. Thumbnail decodes are bounded at 4 concurrent loads like the Mac app.
/// </summary>
public sealed partial class MediaItemViewModel : ObservableObject
{
    private static readonly SemaphoreSlim ThumbnailGate = new(4);

    public MediaAsset Asset { get; }
    public string Name => Asset.Name;
    public string TypeLabel => Asset.Type.ToString().ToLowerInvariant();
    public bool IsOffline => Asset.IsMediaOffline;

    public string DurationText
    {
        get
        {
            if (Asset.Type is not (ClipType.Video or ClipType.Audio) || Asset.Duration <= 0) return "";
            var ts = TimeSpan.FromSeconds(Asset.Duration);
            return ts.TotalHours >= 1
                ? $"{(int)ts.TotalHours}:{ts.Minutes:00}:{ts.Seconds:00}"
                : $"{ts.Minutes:00}:{ts.Seconds:00}";
        }
    }

    public Microsoft.UI.Xaml.Visibility DurationBadgeVisibility => DurationText.Length > 0
        ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;

    public Microsoft.UI.Xaml.Visibility AiBadgeVisibility =>
        Asset.IsGenerated && !Asset.IsGenerating
            ? Microsoft.UI.Xaml.Visibility.Visible
            : Microsoft.UI.Xaml.Visibility.Collapsed;

    public Microsoft.UI.Xaml.Visibility GeneratingVisibility => Asset.IsGenerating
        ? Microsoft.UI.Xaml.Visibility.Visible
        : Microsoft.UI.Xaml.Visibility.Collapsed;

    public Microsoft.UI.Xaml.Visibility OfflineVisibility => IsOffline && !Asset.IsGenerating
        ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;

    [ObservableProperty] private BitmapImage? _thumbnail;
    private bool _thumbnailRequested;
    private readonly DispatcherQueue _dispatcher;

    public MediaItemViewModel(MediaAsset asset, DispatcherQueue dispatcher)
    {
        Asset = asset;
        _dispatcher = dispatcher;
    }

    /// <summary>Call after mutating Asset.Duration / offline state so bindings refresh.</summary>
    public void RefreshMetadata()
    {
        OnPropertyChanged(nameof(DurationText));
        OnPropertyChanged(nameof(DurationBadgeVisibility));
        OnPropertyChanged(nameof(IsOffline));
        OnPropertyChanged(nameof(OfflineVisibility));
    }

    public async Task LoadThumbnailAsync()
    {
        if (_thumbnailRequested || Asset.Url is null || IsOffline) return;
        _thumbnailRequested = true;
        if (Asset.Type is not (ClipType.Video or ClipType.Image or ClipType.Lottie)) return;

        await ThumbnailGate.WaitAsync();
        try
        {
            var url = Asset.Url;
            var jpeg = await Task.Run(() => DecodeThumbnailJpeg(url, Asset.Type));
            if (jpeg is null) return;
            _dispatcher.TryEnqueue(async () =>
            {
                using var stream = new MemoryStream(jpeg);
                var image = new BitmapImage();
                await image.SetSourceAsync(stream.AsRandomAccessStream());
                Thumbnail = image;
            });
        }
        catch (Exception)
        {
            // Missing/undecodable media keeps the placeholder icon.
        }
        finally
        {
            ThumbnailGate.Release();
        }
    }

    private static byte[]? DecodeThumbnailJpeg(string url, ClipType type)
    {
        const int maxSize = ImageThumbnailer.LibraryThumbnailMaxPixelSize;
        if (type == ClipType.Image)
        {
            using var bitmap = ImageThumbnailer.Thumbnail(url, maxSize);
            return bitmap is null ? null : ImageThumbnailer.EncodeJpeg(bitmap, 0.85);
        }
        using var extractor = new VideoFrameExtractor(url);
        using var frame = extractor.FrameAt(0, maxSize, maxSize);
        return frame is null ? null : ImageThumbnailer.EncodeJpeg(frame, 0.85);
    }
}
