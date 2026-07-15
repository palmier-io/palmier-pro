using PalmierPro.App.ViewModels.Editor;
using PalmierPro.Core.Models;
using PalmierPro.Services.Media;

namespace PalmierPro.App.Views.Timeline;

/// Everything TimelineCanvasControl needs from the hosting document — bundled so
/// EditorPlaceholderView has one call to make (`Attach`/`Attach(null)`) per document switch,
/// mirroring how MediaTabViewModel is constructed/torn down there.
public sealed record TimelineCanvasContext(
    TimelineEditorViewModel Vm,
    MediaVisualCache VisualCache,
    Func<string, MediaAsset?> AssetResolver,
    Func<IReadOnlyList<string>, Task<MediaImportSummary>> ImportPathsAsync);
