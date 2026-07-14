using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using PalmierPro.App.Theme;
using PalmierPro.App.ViewModels.MediaPanel;
using PalmierPro.Core.Models;
using PalmierPro.Core.Theme;
using PalmierPro.Services.Media;

namespace PalmierPro.App.Views.MediaPanel;

/// Renders one MediaAssetItemViewModel's thumbnail — video frames from MediaVisualCache (updated
/// progressively as generation batches arrive), stills decoded directly, everything else a glyph
/// fallback. Owns the WinUI pixel work the ViewModel layer deliberately stays free of.
public sealed partial class AssetTileControl : UserControl
{
    private MediaAssetItemViewModel? _item;

    public AssetTileControl()
    {
        InitializeComponent();
        DataContextChanged += OnDataContextChanged;
        Unloaded += (_, _) => Detach();

        // {StaticResource} values feeding Thickness/CornerRadius-typed properties don't coerce in
        // WinUI XAML the way literal strings do — every such value below is set here instead.
        var tileRadius = AppTheme.UniformCornerRadius(AppThemeTokens.Radius.Sm);
        ThumbArea.CornerRadius = tileRadius;
        MissingOverlay.CornerRadius = tileRadius;
        DurationBadge.CornerRadius = AppTheme.UniformCornerRadius(AppThemeTokens.Radius.Xs);
        DurationBadge.Padding = AppTheme.UniformThickness(AppThemeTokens.Spacing.Xs);
        DurationBadge.Margin = AppTheme.UniformThickness(AppThemeTokens.Spacing.Xs);
    }

    private void OnDataContextChanged(FrameworkElement sender, DataContextChangedEventArgs args)
    {
        Detach();
        _item = args.NewValue as MediaAssetItemViewModel;
        if (_item is null)
        {
            return;
        }
        _item.PropertyChanged += OnItemPropertyChanged;
        _item.ThumbnailsChanged += OnThumbnailsChanged;
        Render();
    }

    private void Detach()
    {
        if (_item is null)
        {
            return;
        }
        _item.PropertyChanged -= OnItemPropertyChanged;
        _item.ThumbnailsChanged -= OnThumbnailsChanged;
        _item = null;
    }

    private void OnItemPropertyChanged(object? sender, PropertyChangedEventArgs e) =>
        DispatcherQueue.TryEnqueue(Render);

    // MediaVisualCache publishes off a background task — hop back to the UI thread before
    // touching any WinUI object.
    private void OnThumbnailsChanged(object? sender, EventArgs e) =>
        DispatcherQueue.TryEnqueue(LoadVideoThumbnail);

    private void Render()
    {
        if (_item is null)
        {
            return;
        }
        NameText.Text = _item.Name;
        DurationBadge.Visibility = _item.ShowsDuration ? Visibility.Visible : Visibility.Collapsed;
        DurationText.Text = _item.DurationLabel;
        MissingOverlay.Visibility = _item.IsMissing ? Visibility.Visible : Visibility.Collapsed;
        FallbackGlyph.Text = GlyphFor(_item.Type);

        switch (_item.Type)
        {
            case ClipType.Video:
                LoadVideoThumbnail();
                break;
            case ClipType.Image:
                LoadImageThumbnail();
                break;
            default:
                ShowFallback();
                break;
        }
    }

    private void LoadVideoThumbnail()
    {
        if (_item is null)
        {
            return;
        }
        var thumbs = _item.VisualCache.Thumbnails(_item.Id);
        if (thumbs is not { Count: > 0 })
        {
            ShowFallback();
            return;
        }
        ThumbImage.Source = ToBitmap(thumbs[thumbs.Count / 2]);
        ThumbImage.Visibility = Visibility.Visible;
        FallbackGlyph.Visibility = Visibility.Collapsed;
    }

    private void LoadImageThumbnail()
    {
        if (_item is null)
        {
            return;
        }
        try
        {
            ThumbImage.Source = new BitmapImage(new Uri(_item.Url));
            ThumbImage.Visibility = Visibility.Visible;
            FallbackGlyph.Visibility = Visibility.Collapsed;
        }
        catch (Exception ex) when (ex is UriFormatException or FileNotFoundException or COMException)
        {
            ShowFallback();
        }
    }

    private void ShowFallback()
    {
        ThumbImage.Source = null;
        ThumbImage.Visibility = Visibility.Collapsed;
        FallbackGlyph.Visibility = Visibility.Visible;
    }

    private static string GlyphFor(ClipType type) => type switch
    {
        ClipType.Video => "\U0001F3A5",
        ClipType.Audio => "♪",
        ClipType.Image => "\U0001F5BC",
        ClipType.Lottie => "\U0001F39E",
        _ => "\U0001F4C4",
    };

    private static WriteableBitmap ToBitmap(CachedThumbnail t)
    {
        var bitmap = new WriteableBitmap(t.Width, t.Height);
        using var stream = bitmap.PixelBuffer.AsStream();
        int rowBytes = t.Width * 4;
        if (t.StrideBytes == rowBytes)
        {
            stream.Write(t.Bgra, 0, t.Bgra.Length);
        }
        else
        {
            for (int y = 0; y < t.Height; y++)
            {
                stream.Write(t.Bgra, y * t.StrideBytes, rowBytes);
            }
        }
        return bitmap;
    }
}
