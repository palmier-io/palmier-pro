using PalmierPro.App.Tests.ViewModels.Editor;
using PalmierPro.App.ViewModels.Editor;
using PalmierPro.App.ViewModels.Inspector;
using PalmierPro.App.Views.Inspector;
using PalmierPro.Core.Models;
using PalmierPro.Services.Engine;

namespace PalmierPro.App.Tests.ViewModels.Inspector;

/// Shared setup for the Transform/Keyframes/Color/Text tab ViewModel tests — an
/// <see cref="InspectorTabContext"/> builder (mirrors EffectsViewModelTests' private `ContextFor`)
/// plus a <see cref="TimelineEditorViewModel"/> factory that can bind an <see cref="IVideoEngine"/>,
/// which EditorFixtures.MakeAsync doesn't expose (Engine is constructor-only — see
/// TimelineEditorViewModel's own field doc). Reuses EditorFixtures.MakeAsync for the actual
/// ProjectDocument/temp-directory plumbing rather than duplicating it; the throwaway first
/// TimelineEditorViewModel it returns is discarded once its track setup has landed on the shared
/// Document, and the engine-bound instance below is built over that same Document.
internal static class InspectorFixtures
{
    public static InspectorTabContext ContextFor(TimelineEditorViewModel vm, params Clip[] clips) => new()
    {
        SelectionState = clips.Length == 1 ? InspectorSelectionState.Single : InspectorSelectionState.Multi,
        SelectedClips = clips,
        Timeline = vm,
    };

    public static async Task<(TimelineEditorViewModel Vm, TempDirectory Temp)> MakeAsync(
        IVideoEngine? engine = null, List<Track>? tracks = null)
    {
        var (seed, temp) = await EditorFixtures.MakeAsync(tracks);
        var vm = new TimelineEditorViewModel(seed.Document, engine);
        return (vm, temp);
    }
}
