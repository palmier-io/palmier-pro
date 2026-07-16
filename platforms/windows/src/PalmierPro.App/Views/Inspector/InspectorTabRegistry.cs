using Microsoft.UI.Xaml;
using PalmierPro.App.ViewModels.Editor;
using PalmierPro.App.ViewModels.Inspector;
using PalmierPro.Core.Models;

namespace PalmierPro.App.Views.Inspector;

/// Everything a tab's content view needs to render the current selection — the resolved clip list
/// plus the owning TimelineEditorViewModel for whatever mutation surface the tab requires (property
/// edits, keyframe stamping, undo grouping, ...). InspectorView builds a fresh instance whenever
/// the active tab or selection changes; a tab view that needs to react to later in-place mutation
/// of a selected Clip (a live reference — see TimelineEditorViewModel's class doc) does so itself.
public sealed class InspectorTabContext
{
    public required InspectorSelectionState SelectionState { get; init; }
    public required IReadOnlyList<Clip> SelectedClips { get; init; }
    public required TimelineEditorViewModel Timeline { get; init; }
}

public delegate FrameworkElement InspectorTabViewFactory(InspectorTabContext context);

/// The hosting seam for M5 tab content. InspectorView never constructs a tab's view directly — it
/// looks the active InspectorTab up here. A tab agent registers its factory from its own file
/// (a `[System.Runtime.CompilerServices.ModuleInitializer]` method next to the view is the expected
/// pattern — see e.g. a future `VideoTabView.cs`) and never needs to touch InspectorView.xaml(.cs)
/// or InspectorViewModel.cs. An unregistered tab (or one InspectorViewModel never offers, e.g.
/// Multicam/AI) renders nothing, matching Phase 1's "render nothing" rule for out-of-scope tabs.
public static class InspectorTabRegistry
{
    private static readonly Dictionary<InspectorTab, InspectorTabViewFactory> Factories = [];

    public static void Register(InspectorTab tab, InspectorTabViewFactory factory) => Factories[tab] = factory;

    /// Test-only escape hatch — production code never needs to unregister a tab.
    public static void Unregister(InspectorTab tab) => Factories.Remove(tab);

    public static FrameworkElement? TryCreate(InspectorTab tab, InspectorTabContext context) =>
        Factories.TryGetValue(tab, out var factory) ? factory(context) : null;
}
