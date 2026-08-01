using System.Collections.ObjectModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using PalmierPro.Cloud.Account;
using PalmierPro.Cloud.Generation;
using PalmierPro.Core.Editing;
using PalmierPro.Core.Localization;
using PalmierPro.Core.Models;
using PalmierPro.Core.Transcription;
using PalmierPro.Media.Ml;

namespace PalmierPro.App.Editor;

public sealed partial class MediaPanelHost : UserControl
{
    private ProjectViewModel? _vm;
    private readonly ObservableCollection<MediaItemViewModel> _audioItems = [];

    public event EventHandler? ImportRequested;
    public event EventHandler? MediaSelectionChanged;
    public event EventHandler<int>? SeekRequested;

    public IReadOnlyList<string> SelectedMediaRefs
    {
        get
        {
            var fromMedia = MediaGrid.SelectedItems.OfType<MediaItemViewModel>().Select(m => m.Asset.Id);
            var fromAudio = AudioGrid.SelectedItems.OfType<MediaItemViewModel>().Select(m => m.Asset.Id);
            return fromMedia.Concat(fromAudio).Distinct(StringComparer.Ordinal).ToList();
        }
    }

    public MediaPanelHost()
    {
        InitializeComponent();
        ApplyLocalizedChrome();
    }

    public void Attach(ProjectViewModel vm)
    {
        _vm = vm;
        MediaGrid.ItemsSource = vm.MediaItems;
        AudioGrid.ItemsSource = _audioItems;
        vm.MediaItems.CollectionChanged += (_, _) => RefreshAudioItems();
        RefreshAudioItems();
        vm.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(ProjectViewModel.StatusText))
                StatusTextBlock.Text = vm.StatusText;
        };
        StatusTextBlock.Text = vm.StatusText;
        RefreshTranscriptPreview();
        RefreshCreditsHint();
        _ = LoadModelsAsync();
    }

    /// <summary>
    /// Deletes the current media-library selection when the panel owns focus.
    /// Returns true when Delete was handled (so the timeline shouldn't also delete).
    /// </summary>
    public bool TryDeleteSelection()
    {
        if (!IsMediaPanelFocused()) return false;
        var ids = SelectedMediaRefs;
        if (ids.Count == 0) return false;
        DeleteMedia(ids);
        return true;
    }

    private bool IsMediaPanelFocused()
    {
        try
        {
            var focused = FocusManager.GetFocusedElement(XamlRoot);
            return focused is DependencyObject node && IsDescendantOf(node, this);
        }
        catch
        {
            return false;
        }
    }

    private static bool IsDescendantOf(DependencyObject node, DependencyObject ancestor)
    {
        for (var current = node; current is not null;
             current = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(current))
        {
            if (ReferenceEquals(current, ancestor)) return true;
        }
        return false;
    }

    private void OnMediaGridKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key is not (Windows.System.VirtualKey.Delete or Windows.System.VirtualKey.Back))
            return;
        var ids = SelectedMediaRefs;
        if (ids.Count == 0) return;
        DeleteMedia(ids);
        e.Handled = true;
    }

    private void OnMediaGridRightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if (sender is not ListViewBase grid) return;
        var ids = SelectedMediaRefs.ToList();
        // Right-click on an unselected tile: target that tile.
        if (e.OriginalSource is FrameworkElement { DataContext: MediaItemViewModel item }
            && !ids.Contains(item.Asset.Id))
        {
            grid.SelectedItems.Clear();
            grid.SelectedItems.Add(item);
            ids = [item.Asset.Id];
        }
        if (ids.Count == 0) return;

        var menu = new MenuFlyout();
        var delete = new MenuFlyoutItem
        {
            Text = ids.Count == 1 ? "Delete" : $"Delete {ids.Count} Items",
        };
        delete.Click += (_, _) => DeleteMedia(ids);
        menu.Items.Add(delete);
        if (e.OriginalSource is UIElement anchor)
            menu.ShowAt(anchor, e.GetPosition(anchor));
        else
            menu.ShowAt(grid, e.GetPosition(grid));
        e.Handled = true;
    }

    private void DeleteMedia(IReadOnlyList<string> ids)
    {
        if (_vm is null || ids.Count == 0) return;
        var removed = _vm.DeleteMediaAssets(ids);
        StatusTextBlock.Text = _vm.StatusText;
        if (removed == 0)
            StatusTextBlock.Text = "Couldn’t delete media";
        RefreshDeleteButton();
    }

    private void ApplyLocalizedChrome()
    {
        ImportButton.Content = "+ " + L10n.String("editor.import");
        NewFolderButton.Content = "New Folder";
        DeleteButtonLabel.Text = "Delete";
        GenerateToolbarLabel.Text = "Generate";
        MediaTab.Header = L10n.String("editor.media");
        AudioTab.Header = "Audio";
        SearchTab.Header = "Search";
        CaptionsTab.Header = "Captions";
        GenerationTab.Header = "Generation";
        SearchButton.Content = "Search";
        TranscribeButton.Content = "Transcribe selected media";
        AddCaptionsButton.Content = "Add Captions to Timeline";
        GenerateButton.Content = "Generate";
        CaptionsHint.Text =
            "Transcribe selected (or first) AV media with on-device Whisper, then add caption clips. " +
            "Cloud STT needs a Convex upload — use Agent get_transcript with storageId when signed in.";
        GenerationHint.Text = "Generate media with your Palmier account credits.";
    }

    private void RefreshAudioItems()
    {
        if (_vm is null) return;
        _audioItems.Clear();
        foreach (var item in _vm.MediaItems.Where(m => m.Asset.Type == ClipType.Audio))
            _audioItems.Add(item);
    }

    private async Task LoadModelsAsync()
    {
        try
        {
            await ModelCatalog.Shared.RefreshAsync();
            ModelBox.ItemsSource = ModelCatalog.Shared.Entries;
            if (ModelBox.Items.Count > 0) ModelBox.SelectedIndex = 0;
        }
        catch
        {
            GenerationStatus.Text = "Could not load model catalog.";
        }
    }

    private void OnImportClicked(object sender, RoutedEventArgs e) => ImportRequested?.Invoke(this, EventArgs.Empty);

    private void OnMediaDragItemsStarting(object sender, DragItemsStartingEventArgs e)
    {
        var refs = e.Items
            .OfType<MediaItemViewModel>()
            .Where(m => !m.Asset.IsGenerating && !m.Asset.IsMediaOffline)
            .Select(m => m.Asset.Id)
            .ToList();
        if (refs.Count == 0)
        {
            e.Cancel = true;
            return;
        }

        e.Data.SetText(MediaDragPayload.Encode(refs));
        e.Data.RequestedOperation = Windows.ApplicationModel.DataTransfer.DataPackageOperation.Copy;
    }

    private void OnNewFolderClicked(object sender, RoutedEventArgs e)
    {
        if (_vm is null) return;
        var name = $"Folder {_vm.Manifest.Folders.Count + 1}";
        var folder = new MediaFolder { Name = name };
        _vm.Manifest.Folders.Add(folder);
        _vm.SaveManifestFireAndForget();
        _vm.StatusText = $"Created folder “{name}”. Move media into it via Agent organize_media.";
        StatusTextBlock.Text = _vm.StatusText;
    }

    private void OnGenerateToolbarClicked(object sender, RoutedEventArgs e)
        => MediaPivot.SelectedItem = GenerationTab;

    private void OnLibrarySearchKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter) FilterLibrarySearch();
    }

    private void OnLibrarySearchClicked(object sender, RoutedEventArgs e) => FilterLibrarySearch();

    private void FilterLibrarySearch()
    {
        if (_vm is null) return;
        var q = LibrarySearchBox.Text?.Trim() ?? "";
        if (string.IsNullOrEmpty(q))
        {
            MediaGrid.ItemsSource = _vm.MediaItems;
            return;
        }
        MediaGrid.ItemsSource = _vm.MediaItems
            .Where(m => m.Name.Contains(q, StringComparison.OrdinalIgnoreCase))
            .ToList();
        MediaPivot.SelectedItem = MediaTab;
    }

    private void OnMediaTileLoaded(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: MediaItemViewModel item })
            _ = item.LoadThumbnailAsync();
    }

    private void OnMediaSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        RefreshDeleteButton();
        MediaSelectionChanged?.Invoke(this, EventArgs.Empty);
    }

    private void OnDeleteClicked(object sender, RoutedEventArgs e)
    {
        var ids = SelectedMediaRefs;
        if (ids.Count == 0)
        {
            StatusTextBlock.Text = "Select media to delete";
            return;
        }
        DeleteMedia(ids);
    }

    private void RefreshDeleteButton()
    {
        var count = SelectedMediaRefs.Count;
        DeleteButton.IsEnabled = count > 0;
        DeleteButtonLabel.Text = count > 1 ? $"Delete ({count})" : "Delete";
    }

    private void OnSearchKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter) RunSearch();
    }

    private void OnSearchClicked(object sender, RoutedEventArgs e) => RunSearch();

    private void RunSearch()
    {
        if (_vm is null || string.IsNullOrWhiteSpace(SearchBox.Text)) return;
        var scope = (SearchScopeBox.SelectedItem as ComboBoxItem)?.Tag as string ?? "both";
        var hits = MediaSearchHelper.Search(
            _vm.PackagePath, _vm.Manifest, SearchBox.Text, scope, limit: 20);
        SearchResults.ItemsSource = hits.Select(h => new MediaSearchHitViewModel
        {
            MediaRef = h.MediaRef,
            StartFrame = h.StartFrame,
            Title = h.Scope == "spoken"
                ? h.Text ?? h.MediaRef
                : $"{h.MediaRef} @ {h.Seconds:0.0}s",
            Detail = h.Scope == "spoken"
                ? $"Frames {h.StartFrame}–{h.EndFrame} · spoken"
                : $"Visual match · score {h.Score:0.###}",
        }).ToList();
        if (hits.Count == 0)
            _vm.StatusText = "No search hits.";
    }

    private void OnSearchResultSelected(object sender, SelectionChangedEventArgs e)
    {
        if (SearchResults.SelectedItem is not MediaSearchHitViewModel hit
            || hit.StartFrame is not { } frame) return;
        SeekRequested?.Invoke(this, frame);
    }

    private void OnRefreshTranscriptClicked(object sender, RoutedEventArgs e)
        => RefreshTranscriptPreview();

    private async void OnTranscribeClicked(object sender, RoutedEventArgs e)
    {
        if (_vm is null) return;
        var engine = (CaptionEngineBox.SelectedItem as ComboBoxItem)?.Tag as string ?? "local";
        if (engine == "cloud")
        {
            TranscribeStatus.Text = AccountService.Shared.IsSignedIn
                ? "Cloud STT from Captions needs a Convex storageId upload. Use Agent get_transcript with storageId, or choose Local."
                : "Sign in from Home for cloud STT, or choose Local (Whisper).";
            return;
        }

        LocalMlBootstrap.EnsureRegistered();
        var entry = ResolveCaptionMedia();
        if (entry is null)
        {
            TranscribeStatus.Text = "Select a video or audio clip in Media, or import one first.";
            return;
        }

        var path = new MediaResolver(() => _vm.Manifest, () => _vm.PackagePath).ResolvePath(entry.Id);
        if (path is null)
        {
            TranscribeStatus.Text = $"Media offline: {entry.Name}";
            return;
        }

        TranscribeButton.IsEnabled = false;
        TranscribeStatus.Text = $"Transcribing {entry.Name}…";
        var mediaRef = entry.Id;
        var fps = Math.Max(1, _vm.ActiveTimeline?.Fps ?? 30);
        var packagePath = _vm.PackagePath;
        try
        {
            var doc = await Task.Run(() => LocalStt.TranscribeFile(path, mediaRef, fps));
            TranscriptCache.Shared.Store(packagePath, doc);
            RefreshTranscriptPreview();
            TranscribeStatus.Text =
                $"{doc.Source} · {doc.Segments.Count} segments · {doc.Words.Count} words";
            _vm.StatusText = $"Transcribed {entry.Name} ({doc.Source}).";
        }
        catch (Exception ex)
        {
            TranscribeStatus.Text = ex.Message;
            _vm.StatusText = $"Transcription failed: {ex.Message}";
        }
        finally
        {
            TranscribeButton.IsEnabled = true;
        }
    }

    private MediaManifestEntry? ResolveCaptionMedia()
    {
        if (_vm is null) return null;
        var selected = SelectedMediaRefs;
        foreach (var id in selected)
        {
            var entry = _vm.Manifest.Entries.FirstOrDefault(e => e.Id == id);
            if (entry?.Type is ClipType.Video or ClipType.Audio) return entry;
        }
        return _vm.Manifest.Entries.FirstOrDefault(e => e.Type is ClipType.Video or ClipType.Audio);
    }

    private void RefreshTranscriptPreview()
    {
        if (_vm is null) return;
        var doc = TranscriptCache.Shared.Get(_vm.PackagePath);
        if (doc is null || doc.Segments.Count == 0)
        {
            TranscriptSummary.Text = "No transcript cached.";
            CaptionPreviewList.ItemsSource = Array.Empty<string>();
            return;
        }
        TranscriptSummary.Text =
            $"{doc.Source} · {doc.Segments.Count} segments · {doc.Words.Count} words" +
            (string.IsNullOrEmpty(doc.Language) ? "" : $" · {doc.Language}");
        CaptionPreviewList.ItemsSource = doc.Segments
            .Take(40)
            .Select(s => $"[{s.StartFrame}–{s.EndFrame}] {s.Text}")
            .ToList();
    }

    private void RefreshCreditsHint()
    {
        var account = AccountService.Shared;
        CreditsHint.Text = account.IsSignedIn
            ? $"Signed in · {account.RemainingCredits:0} credits"
            : "Sign in from Home to spend generation credits.";
    }

    private void OnKindChanged(object sender, SelectionChangedEventArgs e)
    {
        if (KindBox is null || ModelBox is null) return;
        var kind = (KindBox.SelectedItem as ComboBoxItem)?.Tag as string ?? "video";
        var filtered = ModelCatalog.Shared.Entries
            .Where(m => string.Equals(m.Kind, kind, StringComparison.OrdinalIgnoreCase))
            .ToList();
        ModelBox.ItemsSource = filtered.Count > 0 ? filtered : ModelCatalog.Shared.Entries;
        if (ModelBox.Items.Count > 0) ModelBox.SelectedIndex = 0;
    }

    private void OnAddCaptionsClicked(object sender, RoutedEventArgs e)
    {
        if (_vm?.EditOperations is not { } ops || _vm.ActiveTimeline is not { } timeline) return;
        var doc = TranscriptCache.Shared.Get(_vm.PackagePath);
        if (doc is null || doc.Segments.Count == 0)
        {
            _vm.StatusText = "No transcript cached. Use Transcribe on the Captions tab first.";
            return;
        }

        var trackIndex = -1;
        for (var t = 0; t < timeline.Tracks.Count; t++)
        {
            if (ClipType.Text.IsCompatible(timeline.Tracks[t].Type))
            {
                trackIndex = t;
                break;
            }
        }
        if (trackIndex < 0) trackIndex = ops.InsertTrack(0, ClipType.Video);

        var style = new TextStyle { FontSize = CaptionFontSlider.Value };
        var placement = (CaptionStyleBox.SelectedItem as ComboBoxItem)?.Tag as string ?? "lower";
        var transform = placement switch
        {
            "center" => Transform.FromCenter(0.5, 0.5, 0.9, 0.25),
            "top" => Transform.FromCenter(0.5, 0.15, 0.9, 0.2),
            _ => Transform.FromCenter(0.5, 0.85, 0.9, 0.2),
        };
        var specs = doc.Segments.Select(seg => new TextClipSpec(
            trackIndex,
            seg.StartFrame,
            Math.Max(1, seg.EndFrame - seg.StartFrame),
            seg.Text,
            style,
            transform)).ToList();
        var ids = ops.PlaceTextClips(specs);
        _vm.RaiseTimelineChanged();
        RefreshTranscriptPreview();
        _vm.StatusText = ids.Count == 0
            ? "Could not add captions."
            : $"Added {ids.Count} caption clip{(ids.Count == 1 ? "" : "s")}.";
    }

    private async void OnGenerateClicked(object sender, RoutedEventArgs e)
    {
        if (_vm is null) return;
        if (ModelBox.SelectedItem is not CatalogEntry model)
        {
            GenerationStatus.Text = "Select a model.";
            return;
        }
        if (string.IsNullOrWhiteSpace(PromptBox.Text))
        {
            GenerationStatus.Text = "Enter a prompt.";
            return;
        }

        var kind = model.Kind.ToLowerInvariant() switch
        {
            "image" => GenerationKind.Image,
            "audio" => GenerationKind.Audio,
            _ => GenerationKind.Video,
        };

        GenerateButton.IsEnabled = false;
        GenerationStatus.Text = "Submitting…";
        try
        {
            var job = await GenerationClient.Shared.SubmitAsync(new GenerationSubmitRequest
            {
                Kind = kind,
                Model = model.Id,
                Prompt = PromptBox.Text.Trim(),
                ProjectId = _vm.ProjectFile?.Timelines.FirstOrDefault()?.Id ?? _vm.ProjectName,
            });
            if (job.Status == "failed" || !string.IsNullOrEmpty(job.Error))
            {
                GenerationStatus.Text = job.Error ?? "Generation failed.";
                _vm.StatusText = GenerationStatus.Text;
                return;
            }
            GenerationStatus.Text = $"Job queued: {job.Id}";
            _vm.StatusText = GenerationStatus.Text;
            await AccountService.Shared.RefreshAccountAsync();
        }
        catch (Exception ex)
        {
            GenerationStatus.Text = ex.Message;
            _vm.StatusText = $"Generation failed: {ex.Message}";
        }
        finally
        {
            GenerateButton.IsEnabled = true;
        }
    }
}
